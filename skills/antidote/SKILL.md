---
name: antidote
description: Prepare a tested way to undo a risky change BEFORE making it. Use whenever you are about to push to a shared or protected branch, force-push, merge a PR, rebase/reset/amend history others have, delete a branch or tag, run a database migration, deploy, publish a package or release, bump major dependencies, or change infra, config, permissions or secrets. Also use when the user mentions a rollback plan, undo, revert, backout plan or "antidote".
---

# Antidote

**Every poison needs an antidote.** Before you run anything that is hard to undo
or that other people depend on, have the cure ready:

1. a **snapshot** of the state you would go back to,
2. the **exact undo commands**, with real commit hashes, versions and names filled in,
3. evidence that the undo **works**, and
4. a **record** a human can find if you are gone.

If you cannot make an antidote for a change, stop and tell the user before you
make the change. Never say an antidote exists unless you have checked it.

## 1. Assess the risk

Ask: Who else sees this? Can one command undo it? Does it destroy data? Does it
leave this machine (published, sent, deployed)?

| Level | Examples | What you need |
|---|---|---|
| **Safe** | local commits; pushing your own unshared feature branch; opening a draft PR | Nothing. Carry on. |
| **Risky** | pushing to or merging into `main`/`develop`/release branches; merging a PR; dependency or lockfile upgrades; CI/workflow changes; config or feature-flag changes; staging deploys | Steps 2, 3 (quick check) and 4. |
| **Destructive** | force-pushing or rewriting shared history; deleting branches, tags or releases; migrations that drop or rewrite data; production deploys; publishing packages; rotating secrets; changing permissions; infra destroy/replace; bulk data changes | Steps 2–4 with a **rehearsed** antidote, plus the user's explicit go-ahead for this specific change. |

When unsure, treat it as one level worse.

Some changes have **no full antidote**: a published package version can never be
reused, a sent email or webhook cannot be unsent, a leaked secret stays leaked,
deleted data without a backup is gone. Say so plainly, offer the best mitigation
(yank/deprecate, rotate, restore from backup), and get confirmation first.

## 2. Prepare the antidote

### Git operations: use the helper

This skill ships `scripts/antidote` (bash + git). Run it from inside the repo,
right before the risky command:

```bash
<skill-dir>/scripts/antidote prepare --op push          --target origin/main   --note "release 2.3"
<skill-dir>/scripts/antidote prepare --op merge         --target origin/main   --note "merge PR #42"
<skill-dir>/scripts/antidote prepare --op force-push    --target origin/feature
<skill-dir>/scripts/antidote prepare --op rewrite                              # before rebase/reset/amend
<skill-dir>/scripts/antidote prepare --op delete-branch --target origin/old-thing
<skill-dir>/scripts/antidote prepare --op tag           --target origin/v2.3.0  # create, move or delete a tag
```

It asks the remote where the target branch is *right now*, pins that commit,
your HEAD and any uncommitted changes under `refs/antidote/<id>/` (so even
`git gc` cannot lose them), and prints a recipe with copy-pasteable cures:
a history-preserving **roll forward** and a `--force-with-lease` **rewind** that
refuses to clobber anyone who pushed after you. Add `--bundle` to also write an
offline copy you can move off the machine. `--target` defaults to the current
branch's upstream; `--head REV` snapshots something other than HEAD.

Other commands: `verify [id]`, `show [id]`, `list`, `drop <id>`, `prune --keep N`,
`covers --op OP [--branch B]`, `install-hook` (see Guardrail below). Records live in `.git/antidote/` and are
never committed or pushed.

If the helper cannot run, do it by hand and write the recipe yourself:

```bash
git fetch origin && git rev-parse origin/main        # the "before" commit: write it down
git update-ref refs/antidote/manual/main <that-sha>  # keep it alive locally
git stash create                                      # prints a commit of uncommitted work, if any
```

### Databases: use the helper too

Before a migration, a bulk `UPDATE`/`DELETE`, or any `DROP`/`TRUNCATE`:

```bash
<skill-dir>/scripts/antidote prepare --op db --db-env DATABASE_URL --note "drop legacy_users"
<skill-dir>/scripts/antidote prepare --op db --db app.db                    # a SQLite file
<skill-dir>/scripts/antidote prepare --op db --name mongo \
    --dump-cmd 'mongodump --uri "$MONGO_URL" --archive={out} --gzip' \
    --restore-cmd 'mongorestore --uri "$MONGO_URL" --drop --archive={file} --gzip' \
    --verify-cmd 'mongorestore --archive={file} --gzip --dryRun'          # any other engine
```

It backs the database up with its native tool (Postgres `pg_dump -Fc`, MySQL and
MariaDB `mysqldump --single-transaction`, SQLite's online backup), checks the
backup is restorable, records where the project's migrations stand (Alembic,
Rails, Django, Knex; notes for Prisma and Laravel), and prints the cure: step
the migrations back, or restore the backup. Prefer `--db-env VAR` over `--db URL`:
credentials are never stored, and the cure then refers to `$VAR`.

For a destructive change, also prove the restore works:
`antidote verify --rehearse-into <URL of an empty scratch database>` (Postgres,
MySQL) or `antidote verify --rehearse` (SQLite). It refuses to rehearse into the
database it protects. If the backup fails, do not make the change.

### Everything else

Deploys, packages, infra, secrets and config each need their own antidote, and
so do databases the helper cannot reach. Read [references/recipes.md](references/recipes.md) for the matching
section before you start.

The antidote must not depend on the thing you are about to break: no backups
only on the disk being wiped, no rollback that needs the service being replaced,
no snapshot stored only in the branch being force-pushed.

The antidote must also **outlive your session**. Keep backups next to the data
they protect (e.g. `app.db.before-drop-legacy`, kept out of git), or wherever
the user says, never only in a temp, scratchpad or sandbox directory that gets
cleaned up. Tell the user the exact path.

## 3. Test the antidote

An untested antidote is a guess.

- **Git:** run `scripts/antidote verify`. It checks every snapshot ref still
  resolves and its objects exist, and warns if the target moved since you
  prepared (if it did, prepare a fresh antidote; the old one is stale).
- **Destructive git changes:** rehearse the cure in a throwaway clone or
  `git worktree` first.
- **Migrations:** run the down migration (or a restore from the backup) on a
  copy of the data, not just on an empty database.
- **Deploys:** confirm the previous version or artifact still exists and that
  you have the permissions to roll back to it.
- **Backups:** confirm they are non-empty and restorable (e.g. `pg_restore --list`).

## 4. Write it down

Put the antidote where people will look, normally the PR description, or the
message to the user before you act. Do not commit antidote files into the repo.
If the repo has a PR template with an `## Antidote` section, fill that in: an
antidote PR check in CI may fail the PR while the section is empty.

```markdown
## Antidote
**Risk:** risky: merges 14 commits into `main`.
**Before:** `main` was at `abc1234` (pinned as `refs/antidote/20261002-101500-def5678/target`).
**Warning signs:** CI red on `main`; `/health` not 200 within 5 min.
**Cure:**
    git switch -c antidote/cure origin/main
    git restore --source=abc1234 --staged --worktree -- :/
    git commit -m "Restore main to abc1234" && git push origin HEAD:main
**Tested:** `antidote verify` OK; cure rehearsed in a scratch clone.
```

## 5. Make the change, then watch for warning signs

Run the risky operation only now. Straight after, check the warning signs you wrote
down: CI on the new head, the remote is where you expected, smoke tests, error
rates or logs. Tell the user what you did and where the antidote is.

## 6. If it goes wrong, apply the antidote

- Stop making new changes on top.
- On shared branches prefer **roll forward** (a new commit or revert) over
  rewinding history; rewind only if nobody else could have pulled.
- Use `--force-with-lease`, never bare `--force`.
- Ask the user before running a destructive cure, unless they already authorised it.
- Afterwards, report what broke, what you ran, and the current state.

## Guardrail: the pre-push hook

```bash
<skill-dir>/scripts/antidote install-hook
```

This installs a `pre-push` hook that blocks pushes and deletions on protected
branches (default `main master trunk develop release/* production prod`;
change with `git config --add antidote.protect '<glob>'`) unless an antidote
was prepared for exactly that push: same branch, same remote "before" commit,
same commit being pushed. Moving or deleting an existing tag needs an
`--op tag` antidote (`antidote.protectTag`, default all tags); creating a new
tag does not. Never bypass it (`ANTIDOTE_SKIP=1` or `--no-verify`)
without the user's approval.

When this skill is installed as a Claude Code plugin, a hook also checks
`git push`, `gh pr merge` and MCP `merge_pull_request` calls, database
migrations and destructive SQL against non-local databases before they run.
If it denies one, do what its message says (prepare the antidote, then retry);
do not try to get around it.
