# antidote

**Every poison needs an antidote.**

An [Agent Skill](https://agentskills.io) that makes coding agents prepare,
verify and write down a way to undo a risky change *before* they make it. That
covers pushing to `main`, merging a PR, force-pushing, rewriting history,
deleting branches, running migrations, deploying, publishing a package, or
rotating secrets.

Agents move fast and push confidently. One bad push to `main`, one force-push
or one dropped table reaches everyone before anyone notices. This skill makes
the agent stop for ten seconds and answer *"if this goes wrong, what exactly do
we run?"*, with real commit hashes and tested commands rather than "we can
always revert".

## What the agent does

1. **Assess the risk.** Safe, risky or destructive, decided by who else sees
   the change, whether one command can undo it, and whether it destroys data.
2. **Prepare the antidote.** Snapshot the state to return to and generate the
   exact undo commands.
3. **Test it.** Verify the snapshot and, for destructive changes, rehearse the cure.
4. **Write it down.** An `## Antidote` section in the PR or in its message to you.
5. **Make the change** and watch for the warning signs it defined up front.
6. **Undo it if it goes wrong:** roll forward first, rewind with
   `--force-with-lease` only when safe, and ask you before anything destructive.

See [`skills/antidote/SKILL.md`](skills/antidote/SKILL.md) for the full
instructions and [`references/recipes.md`](skills/antidote/references/recipes.md)
for databases, deploys, packages, infra, config and secrets.

## The `antidote` helper

The skill ships a small script (bash + git; the database drivers use each
engine's own client tools) for git operations and databases:

```console
$ antidote prepare --op push --target origin/main --note "release 2.3"
# Antidote 20261002-101500-7c0437c
...
| origin/main before | `ae2ae1a…` | `refs/antidote/20261002-101500-7c0437c/target` |

## Cure

### Option A: roll forward (safe on shared branches, keeps history)
    git switch -c antidote/cure-20261002-101500-7c0437c origin/main
    git restore --source=ae2ae1a… --staged --worktree -- :/
    git commit -m "Restore main to ae2ae1a (antidote 20261002-101500-7c0437c)"
    git push origin HEAD:main

### Option B: rewind (only if nobody else has pulled origin/main since)
    git push --force-with-lease=refs/heads/main:7c0437c… origin ae2ae1a…:refs/heads/main
```

| Command | What it does |
|---|---|
| `prepare --op OP [--target R/B] [--head REV] [--note T] [--bundle] [--no-fetch]` | Ask the remote where the target is now, pin it plus HEAD and uncommitted work under `refs/antidote/<id>/`, print the cure. `OP` is `push` (default), `merge`, `force-push`, `rewrite`, `delete-branch` or `tag` (create, move or delete the tag `R/TAG`). |
| `prepare --op db (--db URL\|FILE \| --db-env VAR) [--note T] [--out DIR]` | Back up a database before a migration or data change, check the backup restores, record where migrations stand, print the cure. Postgres, MySQL/MariaDB and SQLite built in; any engine with `--dump-cmd/--restore-cmd/--verify-cmd`. |
| `verify [id] [--rehearse-into URL \| --rehearse]` | Check the snapshot still resolves, the bundle (if any) is valid, and whether the remote moved since. For databases, check the backup and optionally restore it into a scratch database. Non-zero exit if unusable. |
| `show [id]` / `list` | Print a recipe / list antidotes. |
| `drop <id>` / `prune [--keep N]` | Remove antidotes, their refs and database backups. |
| `covers --op OP [--branch B]` / `covers --op db [--db-env VAR]` | Exit 0 if a fresh antidote exists. Used by the hook. |
| `install-hook` | Install a `pre-push` hook that blocks pushes to protected branches without a matching antidote. |

Snapshots are plain git refs, so they survive `git gc`, rebases and branch
deletion. Records live in `.git/antidote/` and are never committed or pushed.
Every cure in the recipes is exercised end-to-end by the test suite against a
real remote, and against real Postgres, MySQL and SQLite databases.

### Databases

```console
$ antidote prepare --op db --db-env DATABASE_URL --note "drop legacy table"
| Database backup | `.git/antidote/db/20261005-035521-postgres.dump` (3 KB) | 2 tables with data, readable by pg_restore |
| Migrations (alembic) | at `ae1027a6acf` | |

### Option A: step the migrations back (keeps data written since the backup)
    alembic downgrade ae1027a6acf

### Option B: restore the backup (brings back dropped or changed data; anything written after the backup is lost)
    pg_restore --clean --if-exists --no-owner --single-transaction --dbname="$DATABASE_URL" .git/antidote/db/20261005-035521-postgres.dump
```

- **Credentials are never stored.** With `--db-env`, the cure refers to the
  variable; otherwise passwords are redacted.
- **Backups are private** (mode 600 in a 700 directory) and live in
  `.git/antidote/db/`, or `git config antidote.dbBackupDir <dir>`. They are
  deleted with `antidote drop`/`prune`.
- **If the backup fails or doesn't verify, there is no antidote**, and the command
  says so instead of pretending.
- `antidote verify --rehearse-into <scratch URL>` restores into a throwaway
  database to prove the cure works, and refuses to touch the protected one.

### The guardrail

```bash
antidote install-hook
git config --add antidote.protect 'hotfix/*'   # optional; defaults: main master trunk develop release/* production prod
```

A push or deletion on a protected branch is refused unless an antidote was
prepared for exactly that push: same branch, same "before" commit on the
remote, same commit being pushed. Prepare again after new commits.

Tags: creating a new tag is always allowed, but **moving or deleting an
existing tag** needs an `--op tag` antidote (release pipelines and everyone's
clones depend on tags not moving). Limit which tags this applies to with
`git config --add antidote.protectTag 'v*'` (default: all tags).

Skip once with `ANTIDOTE_SKIP=1 git push ...`.

### The Claude Code hook

Installing the plugin also installs a `PreToolUse` hook
([`hooks/antidote_guard.py`](hooks/antidote_guard.py), needs `python3`). It
stops the agent before the risky command runs, rather than after git rejects it:

| The agent runs | The hook |
|---|---|
| `git push ...` | Runs the same push with `--dry-run` through the antidote guard, so git itself decides which refs would change. A protected branch without a matching antidote is **denied** and the agent is told how to prepare one. Nothing is pushed. |
| `git push --no-verify`, `ANTIDOTE_SKIP=1 git push`, `git -c core.hooksPath=... push` | **Asks you**, since these skip the guard. |
| `gh pr merge` or a GitHub MCP `merge_pull_request` tool | **Denied** unless `antidote covers --op merge` finds a merge antidote for the PR's base branch that is still fresh (the base hasn't moved). |
| A migration (`alembic upgrade`, `rails db:migrate`, `manage.py migrate`, `prisma migrate deploy`, `knex migrate:latest`, `flyway migrate`, … also behind `npx`, `bundle exec`, `poetry run`, `npm run db:migrate`) or destructive SQL (`DROP`, `TRUNCATE`, `DELETE`/`UPDATE` without `WHERE`) through `psql`, `mysql`, `sqlite3` or `mongosh` | **Denied** on a non-local database unless a database antidote for it is fresh (`antidote.dbMaxAge`, default 1 hour). The target comes from the URL, `-h`, `PGHOST`, `DATABASE_URL` or `.env`. |

Anything it can't parse is allowed, and the git `pre-push` hook stays the
backstop. Turn it off for one repo with `git config antidote.enabled false`, or
everywhere with `ANTIDOTE_HOOK=off`.

Database checks leave local databases alone (localhost, sockets, SQLite files),
so everyday dev migrations are never blocked. `RAILS_ENV=production` and similar
never count as local. Tune it per repo:

```bash
git config antidote.dbGuard always             # remote (default) | always | off
git config --add antidote.dbLocalHost db       # e.g. a docker-compose service name
git config --add antidote.dbEnv PRIMARY_DB_URL # where to find the target (default DATABASE_URL)
git config antidote.dbMaxAge 1800              # seconds a database antidote stays fresh
```

Without the plugin, add it to `~/.claude/settings.json` yourself:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|mcp__.*merge_pull_request",
        "hooks": [{ "type": "command", "command": "python3 /path/to/antidote/hooks/antidote_guard.py", "timeout": 90 }]
      }
    ]
  }
}
```

### The PR check (GitHub Action)

Fails a pull request into a protected branch unless its description has a
filled-in `## Antidote` section. Comments and unfilled template labels like
`**Cure:**` don't count, and one line is enough for a harmless change. This
covers humans and every agent, whatever tool they use.

```yaml
# .github/workflows/antidote.yml
name: Antidote
on:
  pull_request:
    types: [opened, edited, synchronize, reopened, labeled, unlabeled]
jobs:
  antidote:
    runs-on: ubuntu-latest
    steps:
      - uses: marckengland/antidote-skill@main   # pin a release tag or commit SHA once you adopt it
        with:
          base-branches: "main release/*"  # default: main master trunk develop release/* production prod
          skip-label: no-antidote          # waive it for one PR
```

Pair it with a PR template containing an `## Antidote` section, like
[this repo's](.github/pull_request_template.md).

## Install

**Claude Code (plugin, recommended: skill + hook):**

```text
/plugin marketplace add marckengland/antidote-skill
/plugin install antidote@antidote
```

**Claude Code (plain skill):** copy `skills/antidote` into `~/.claude/skills/`
(all projects) or `.claude/skills/` (one project):

```bash
git clone https://github.com/marckengland/antidote-skill
cp -r antidote-skill/skills/antidote ~/.claude/skills/
```

**Other agents:** any agent that supports the Agent Skills format (a folder with
a `SKILL.md`) can load `skills/antidote` the same way. Agents without skill
support can be pointed at `SKILL.md` from their instructions file (`AGENTS.md`,
`.cursor/rules`, etc.).

**Just the CLI:** put `skills/antidote/scripts/antidote` on your `PATH`.

Requires bash and git 2.23 or newer.

## Evals

[`evals/`](evals/) runs real `claude -p` sessions against scratch repos and
grades the end state: was there an antidote pinning the "before" state for the
risky changes (push to `main`, force-push, branch deletion, dropping a table),
and **no** antidote ceremony for harmless ones? Each scenario runs without the
skill, with the skill, and with the full plugin.

## Contributing

Issues and PRs welcome, especially new recipes for platforms you know well. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
