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

For git operations the skill ships a small dependency-free script (bash + git):

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
| `verify [id]` | Check the snapshot still resolves, the bundle (if any) is valid, and whether the remote moved since. Non-zero exit if unusable. |
| `show [id]` / `list` | Print a recipe / list antidotes. |
| `drop <id>` / `prune [--keep N]` | Remove antidotes and their refs. |
| `covers --op OP [--branch B]` | Exit 0 if a fresh antidote exists for OP (on B). Used before server-side PR merges. |
| `install-hook` | Install a `pre-push` hook that blocks pushes to protected branches without a matching antidote. |

Snapshots are plain git refs, so they survive `git gc`, rebases and branch
deletion. Records live in `.git/antidote/` and are never committed or pushed.
Every cure in the recipes is exercised end-to-end by the test suite against a
real remote.

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

Anything it can't parse is allowed, and the git `pre-push` hook stays the
backstop. Turn it off for one repo with `git config antidote.enabled false`, or
everywhere with `ANTIDOTE_HOOK=off`.

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
