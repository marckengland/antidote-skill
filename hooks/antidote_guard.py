#!/usr/bin/env python3
"""Claude Code PreToolUse hook: every poison needs an antidote.

Looks at Bash commands and PR-merge tool calls before they run:

* ``git push ...``: asks git itself what the push would change by running the
  same push with ``--dry-run`` and the antidote pre-push guard. If a protected
  branch would change without a matching antidote, the call is denied and the
  agent is told how to prepare one. Nothing is pushed.
* ``git push --no-verify``, ``ANTIDOTE_SKIP=1 git push``, ``git -c core.hooksPath=...
  push``: these bypass the guard, so the user is asked to approve.
* ``gh pr merge`` and MCP ``merge_pull_request`` tools: denied unless
  ``antidote covers --op merge`` finds a fresh merge antidote for the PR's base.
* Database migrations (alembic, rails, django, prisma, knex, flyway, ...) and
  destructive SQL (DROP, TRUNCATE, DELETE/UPDATE without WHERE) through psql,
  mysql, sqlite3 or mongosh: denied on a non-local database unless
  ``antidote covers --op db`` finds a fresh database antidote for it.
  ``git config antidote.dbGuard always|remote|off`` (default remote).

Anything it cannot understand is allowed: the git pre-push hook
(``antidote install-hook``) is the backstop. Disable per repository with
``git config antidote.enabled false``, or everywhere with ANTIDOTE_HOOK=off.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ANTIDOTE = os.environ.get("ANTIDOTE_BIN") or os.path.normpath(
    os.path.join(HERE, "..", "skills", "antidote", "scripts", "antidote")
)
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
OPERATORS = set(";&|()")
# gh pr merge flags that take a value (so their value is not the PR selector).
GH_VALUE_FLAGS = {
    "-t", "--subject", "-b", "--body", "-F", "--body-file", "-A",
    "--author-email", "--match-head-commit", "-R", "--repo",
}
# git global options that take a separate value.
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}


def decide(decision, reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def run(cmd, cwd, env=None, timeout=60):
    try:
        return subprocess.run(
            cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None


def enabled(cwd):
    if os.environ.get("ANTIDOTE_HOOK", "").lower() in ("off", "0", "false"):
        return False
    r = run(["git", "config", "--bool", "antidote.enabled"], cwd)
    return not (r and r.stdout.strip() == "false")


def segments(command):
    """Split a shell command into simple commands (lists of words)."""
    lex = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=";&|()")
    lex.whitespace_split = True
    seg = []
    for tok in lex:
        if tok and set(tok) <= OPERATORS:
            if seg:
                yield seg
            seg = []
        else:
            seg.append(tok)
    if seg:
        yield seg


def check_push(git_opts, args, env_prefix, cwd):
    bypass = (
        "--no-verify" in args
        or env_prefix.get("ANTIDOTE_SKIP") == "1"
        or any(o.startswith("core.hooksPath") for o in git_opts)
    )
    if bypass:
        decide("ask", "This git push skips the antidote pre-push guard. Allow it only if "
                      "you have approved pushing without an antidote.")

    push_args = [a for a in args if a not in ("-u", "--set-upstream", "--dry-run", "-n")]
    with tempfile.TemporaryDirectory() as hooks:
        hook = os.path.join(hooks, "pre-push")
        with open(hook, "w") as f:
            f.write("#!/bin/sh\nexec %s guard \"$@\"\n" % shlex.quote(ANTIDOTE))
        os.chmod(hook, 0o755)
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0", **env_prefix)
        env.pop("ANTIDOTE_SKIP", None)
        r = run(["git", *git_opts, "-c", "core.hooksPath=" + hooks,
                 "push", "--dry-run", *push_args], cwd, env=env)
    if r is None or "antidote: blocked " not in r.stderr:
        return  # allowed, or git failed for some other reason the real push will report
    lines = r.stderr.splitlines()
    start = next(i for i, l in enumerate(lines) if "antidote: blocked " in l)
    decide("deny", "\n".join(l for l in lines[start:] if not l.startswith("error:")))


def pr_base(selector, repo, cwd):
    cmd = ["gh", "pr", "view", "--json", "baseRefName", "-q", ".baseRefName"]
    if selector:
        cmd.insert(3, selector)
    if repo:
        cmd += ["-R", repo]
    r = run(cmd, cwd, timeout=30)
    return r.stdout.strip() if r and r.returncode == 0 else ""


def check_merge(selector, repo, cwd):
    base = pr_base(selector, repo, cwd)
    r = run([ANTIDOTE, "covers", "--op", "merge"] + (["--branch", base] if base else []), cwd)
    if r is None or r.returncode == 0:
        return
    target = "origin/" + (base or "<base-branch>")
    decide("deny",
           "No antidote for this PR merge. %s\nPrepare one, put it in the PR description, "
           "then merge again:\n  %s prepare --op merge --target %s --note \"merge PR %s\""
           % (r.stderr.strip(), ANTIDOTE, target, selector or ""))


# --- databases --------------------------------------------------------------
#
# Migrations and destructive SQL against a database that is not local need a
# fresh database antidote (antidote prepare --op db). Local databases (localhost,
# sockets, SQLite files) are left alone unless antidote.dbGuard is "always".

DB_CLIENTS = {"psql", "mysql", "mariadb", "sqlite3", "mongosh", "mongo"}
LAUNCHERS = {"npx", "bunx", "pnpx"}
LAUNCHER_PAIRS = {
    ("bundle", "exec"), ("poetry", "run"), ("uv", "run"), ("pipenv", "run"), ("pdm", "run"),
    ("hatch", "run"), ("pnpm", "exec"), ("pnpm", "dlx"), ("yarn", "dlx"), ("yarn", "exec"),
    ("npm", "exec"), ("bun", "x"),
}
# Subcommands that change a schema or its data, per migration tool.
MIGRATING = {
    "alembic": {"upgrade", "downgrade", "stamp"},
    "manage.py": {"migrate", "flush"},
    "django-admin": {"migrate", "flush"},
    "knex": {"migrate:latest", "migrate:up", "migrate:down", "migrate:rollback"},
    "sequelize": {"db:migrate", "db:migrate:undo", "db:migrate:undo:all", "db:drop"},
    "sequelize-cli": {"db:migrate", "db:migrate:undo", "db:migrate:undo:all", "db:drop"},
    "typeorm": {"migration:run", "migration:revert", "schema:sync", "schema:drop"},
    "flyway": {"migrate", "clean", "undo", "baseline", "repair"},
    "liquibase": {"update", "rollback", "rollback-count", "rollbackCount", "drop-all", "dropAll"},
    "migrate": {"up", "down", "drop", "force", "goto"},
    "goose": {"up", "up-by-one", "up-to", "down", "down-to", "redo", "reset"},
    "dbmate": {"up", "migrate", "rollback", "down", "drop"},
    "mix": {"ecto.migrate", "ecto.rollback", "ecto.drop", "ecto.reset"},
    "artisan": {"migrate", "migrate:fresh", "migrate:refresh", "migrate:reset", "migrate:rollback", "db:wipe"},
    "drizzle-kit": {"push", "migrate", "drop"},
}
MIGRATING_PAIRS = {
    "prisma": {("migrate", "deploy"), ("migrate", "reset"), ("migrate", "dev"), ("db", "push")},
    "diesel": {("migration", "run"), ("migration", "revert"), ("migration", "redo"),
               ("database", "reset"), ("database", "drop")},
    "sqlx": {("migrate", "run"), ("migrate", "revert"), ("database", "drop"), ("database", "reset")},
    "atlas": {("migrate", "apply"), ("schema", "apply"), ("schema", "clean")},
    "supabase": {("db", "push"), ("db", "reset")},
}
RAILS_DB = re.compile(r"^db:(migrate(:\w+)?|rollback|schema:load|structure:load|reset|drop(:\w+)?"
                      r"|setup|truncate_all|seed:replant)$")
PROD_ENV_KEYS = ("RAILS_ENV", "RACK_ENV", "APP_ENV", "NODE_ENV", "MIX_ENV", "ENVIRONMENT", "ENV", "STAGE")
DESTRUCTIVE = [
    re.compile(r"\bDROP\s+(TABLE|DATABASE|SCHEMA|COLUMN|MATERIALIZED\s+VIEW)\b", re.I),
    re.compile(r"\bTRUNCATE\b", re.I),
    re.compile(r"\bALTER\s+TABLE\b[^;]*\bDROP\b", re.I),
    re.compile(r"dropDatabase\s*\(|\.drop\s*\(\s*\)|\b(deleteMany|remove)\s*\(\s*\{\s*\}\s*\)"),
]
DB_URL = re.compile(r"^(postgres(ql)?|mysql|mariadb|mongodb(\+srv)?)://", re.I)


def git_config(cwd, key, all_values=False):
    r = run(["git", "config", "--get-all" if all_values else "--get", key], cwd)
    if not r or r.returncode != 0:
        return [] if all_values else ""
    return r.stdout.split() if all_values else r.stdout.strip()


def expand(word, env):
    return re.sub(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", lambda m: env.get(m.group(1), m.group(0)), word)


def redact(url):
    return re.sub(r"(://[^:/@]*):[^@/]*@", r"\1:***@", url)


def unwrap(words):
    """Drop launchers such as npx, bundle exec, poetry run and python -m."""
    while words:
        w0 = os.path.basename(words[0])
        if w0 in LAUNCHERS:
            words = words[1:]
            while words and words[0].startswith("-"):
                words = words[1:]
        elif len(words) > 1 and (w0, words[1]) in LAUNCHER_PAIRS:
            words = words[2:]
        elif re.match(r"python[0-9.]*$", w0) and len(words) > 2 and words[1] == "-m":
            words = words[2:]
        else:
            return words
    return words


def migration_tool(words):
    """'<tool> <subcommand>' if WORDS runs a schema migration, else None."""
    w = unwrap(words)
    if not w:
        return None
    prog, args = os.path.basename(w[0]), w[1:]
    if re.match(r"python[0-9.]*$", prog) and args and os.path.basename(args[0]) == "manage.py":
        prog, args = "manage.py", args[1:]
    if prog == "php" and args and os.path.basename(args[0]) == "artisan":
        prog, args = "artisan", args[1:]
    if prog in ("rails", "rake"):
        hit = next((a for a in args if RAILS_DB.match(a)), None)
        return "%s %s" % (prog, hit) if hit else None
    if prog in MIGRATING:
        hit = next((a for a in args if a in MIGRATING[prog]), None)
        return "%s %s" % (prog, hit) if hit else None
    if prog in MIGRATING_PAIRS:
        for x, y in zip(args, args[1:]):
            if (x, y) in MIGRATING_PAIRS[prog]:
                return "%s %s %s" % (prog, x, y)
        return None
    # Package scripts and make targets named like migrations: npm run db:migrate, make migrate.
    if prog in ("npm", "yarn", "pnpm", "bun", "make"):
        rest = args[1:] if args[:1] == ["run"] else args
        script = next((a for a in rest if not a.startswith("-")), "")
        if re.search(r"migrat|^db:(push|reset|drop)", script):
            return "%s %s" % (prog, script)
    return None


def dotenv_value(cwd, name):
    for fname in (".env.local", ".env"):
        try:
            with open(os.path.join(cwd, fname)) as f:
                for line in f:
                    m = re.match(r"\s*(?:export\s+)?%s\s*=\s*(.*)$" % re.escape(name), line)
                    if m:
                        return m.group(1).strip().strip("'\"")
        except OSError:
            continue
    return ""


def migration_target(env, cwd):
    """(url, env var name) of the database migrations would run against, if known."""
    for name in git_config(cwd, "antidote.dbEnv", all_values=True) or ["DATABASE_URL"]:
        url = env.get(name) or dotenv_value(cwd, name)
        if url:
            return url, name
    return "", ""


def host_of(url):
    m = re.match(r"^[a-z0-9+.-]+://(?:[^@/]*@)?(\[[^\]]*\]|[^:/?,]*)", url, re.I)
    return m.group(1) if m else ""


def is_local(host, cwd):
    host = (host or "").strip("[]").lower()
    if host in ("", "localhost", "::1", "0.0.0.0") or host.startswith("127.") or host.startswith("/"):
        return True
    return host in [h.lower() for h in git_config(cwd, "antidote.dbLocalHost", all_values=True)]


def client_target(prog, args, env):
    """(url, host) a database client would connect to."""
    if prog == "sqlite3":
        path = next((a for a in args if not a.startswith("-")), "")
        return path, "/"
    url, host = "", None
    for i, a in enumerate(args):
        nxt = args[i + 1] if i + 1 < len(args) else ""
        if DB_URL.match(a):
            url = a
        elif a in ("-h", "--host"):
            host = nxt
        elif a.startswith("--host="):
            host = a.split("=", 1)[1]
        elif a in ("-d", "--dbname") and DB_URL.match(nxt):
            url = nxt
        elif a.startswith("--dbname=") and DB_URL.match(a.split("=", 1)[1]):
            url = a.split("=", 1)[1]
        elif "host=" in a and "=" in a.split()[0]:  # libpq conninfo: "host=db.example.com dbname=app"
            m = re.search(r"\bhost=(\S+)", a)
            host = m.group(1) if m else host
    if url:
        return url, host_of(url)
    if host is None and prog == "psql":
        host = env.get("PGHOST", "")
    return "", host or ""


def sql_text(raw, args, cwd):
    """The SQL a client command would run: the command line plus any -f / < files."""
    text = [raw]
    for i, a in enumerate(args):
        path = ""
        if a in ("-f", "--file", "<") and i + 1 < len(args):
            path = args[i + 1]
        elif a.startswith("--file="):
            path = a.split("=", 1)[1]
        elif a.startswith("<") and len(a) > 1:
            path = a[1:]
        if path:
            try:
                with open(os.path.join(cwd, path)) as f:
                    text.append(f.read(1 << 20))
            except OSError:
                pass
    return "\n".join(text)


def destructive_sql(text):
    for rx in DESTRUCTIVE:
        m = rx.search(text)
        if m:
            return " ".join(m.group(0).split()[:3])
    for stmt in text.split(";"):
        m = re.search(r"\b(DELETE\s+FROM|UPDATE\s+[\w.\"`]+\s+SET)\b", stmt, re.I)
        if m and not re.search(r"\bWHERE\b", stmt, re.I):
            return "%s without WHERE" % " ".join(m.group(1).split()[:2]).upper()
    return None


def looks_like_db(words):
    """Cheap pre-check, so ordinary commands never pay for git config lookups."""
    w = unwrap(words)
    return bool(w) and (os.path.basename(w[0]) in DB_CLIENTS or migration_tool(words) is not None)


def check_db(words, env_prefix, raw, cwd):
    mode = (git_config(cwd, "antidote.dbGuard") or "remote").lower()
    if mode == "off":
        return
    env = dict(os.environ, **env_prefix)
    words = [expand(w, env) for w in words]
    tool = migration_tool(words)
    w = unwrap(words)
    prog = os.path.basename(w[0]) if w else ""
    url, var, local = "", "", None
    if tool:
        what = "runs migrations (%s)" % tool
        url, var = migration_target(env, cwd)
        if url:
            local = is_local(host_of(url), cwd)
        if any(env.get(k, "").lower() in ("production", "prod", "staging") for k in PROD_ENV_KEYS):
            local = False
    elif prog in DB_CLIENTS:
        hit = destructive_sql(sql_text(raw, w[1:], cwd))
        if not hit:
            return
        what = "runs destructive SQL (%s)" % hit
        url, host = client_target(prog, w[1:], env)
        local = is_local(host, cwd)
        for name, value in env.items():  # psql "$DATABASE_URL": suggest --db-env DATABASE_URL
            if url and value == url and re.match(r"^[A-Z][A-Z0-9_]*$", name):
                var = name
                break
    else:
        return
    if mode != "always" and local is not False:
        return  # local, or we cannot tell where it goes
    check_env = dict(os.environ, ANTIDOTE_HOOK_DB=url) if url else None
    r = run([ANTIDOTE, "covers", "--op", "db"] + (["--db-env", "ANTIDOTE_HOOK_DB"] if url else []),
            cwd, env=check_env)
    if r is None or r.returncode == 0:
        return
    where = redact(url) if url else ("the database it targets")
    if var:
        how = "--db-env %s" % var
    elif url:
        how = "--db %s" % shlex.quote(redact(url))
    else:
        how = "--db <database URL>"
    decide("deny",
           "This command %s on %s, and there is no fresh database antidote for it. %s\n"
           "Back the database up first (it checks the backup and prints the restore command), then retry:\n"
           "  %s prepare --op db %s --note \"<what you are about to change>\""
           % (what, where, (r.stderr or "").strip(), ANTIDOTE, how))


def check_bash(command, cwd):
    try:
        segs = list(segments(command))
    except ValueError:
        return  # unbalanced quotes etc.: let the shell complain
    for words in segs:
        env_prefix = {}
        while words and (words[0] == "env" or ASSIGNMENT.match(words[0])):
            if words[0] != "env":
                k, v = words[0].split("=", 1)
                env_prefix[k] = v
            words = words[1:]
        if not words:
            continue
        prog = os.path.basename(words[0])
        if prog == "cd" and len(words) > 1:
            cwd = os.path.join(cwd, os.path.expanduser(words[1]))
        elif prog == "git":
            opts, i = [], 1
            while i < len(words) and words[i].startswith("-"):
                if words[i] in GIT_VALUE_OPTS and i + 1 < len(words):
                    opts += words[i:i + 2]
                    i += 2
                else:
                    opts.append(words[i])
                    i += 1
            if i < len(words) and words[i] == "push" and enabled(cwd):
                check_push(opts, words[i + 1:], env_prefix, cwd)
        elif prog == "gh" and words[1:3] == ["pr", "merge"] and enabled(cwd):
            selector, repo, rest = "", "", words[3:]
            j = 0
            while j < len(rest):
                if rest[j] in GH_VALUE_FLAGS:
                    if rest[j] in ("-R", "--repo") and j + 1 < len(rest):
                        repo = rest[j + 1]
                    j += 2
                    continue
                if rest[j].startswith("--repo="):
                    repo = rest[j].split("=", 1)[1]
                elif not rest[j].startswith("-") and not selector:
                    selector = rest[j]
                j += 1
            check_merge(selector, repo, cwd)
        elif looks_like_db(words) and enabled(cwd):
            check_db(words, env_prefix, command, cwd)


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    cwd = data.get("cwd") or os.getcwd()
    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}
    if tool == "Bash":
        check_bash(tool_input.get("command", ""), cwd)
    elif tool.endswith("merge_pull_request") and enabled(cwd):
        owner, repo = tool_input.get("owner"), tool_input.get("repo")
        number = tool_input.get("pullNumber") or tool_input.get("pull_number")
        check_merge(str(number or ""), "%s/%s" % (owner, repo) if owner and repo else "", cwd)


if __name__ == "__main__":
    main()
