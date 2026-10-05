# Contributing

Thanks for helping make agents safer to hand the keys to.

## Layout

```
skills/antidote/SKILL.md              instructions the agent follows
skills/antidote/references/recipes.md per-platform snapshot / cure / test recipes
skills/antidote/scripts/antidote      the git helper (bash + git, no other deps)
hooks/                                Claude Code PreToolUse hook (python3, stdlib only)
action.yml, ci/check-antidote.sh      GitHub Action: require an Antidote section in PRs
evals/                                behavioural evals with real agent runs (see evals/README.md)
tests/test_antidote.sh                end-to-end tests against a real local remote
.claude-plugin/                       Claude Code plugin + marketplace manifests
```

## Branches

Branch from `main` and name the branch with a type prefix: `feat/`, `fix/`,
`docs/`, `chore/`, `refactor/`, `test/`, `ci/` or `perf/`, then a short
kebab-case description (e.g. `fix/bundle-verify`).

## Before opening a PR

PRs into `main` need a filled-in `## Antidote` section (the PR template has
one; CI checks it). For a harmless change, one line saying why is enough.

```bash
shellcheck skills/antidote/scripts/antidote tests/test_antidote.sh ci/check-antidote.sh
bash tests/test_antidote.sh            # or: bash tests/test_antidote.sh test_name ...
```

Postgres and MySQL tests skip unless you point them at a server (they create and
drop their own databases); CI runs them against service containers:

```bash
export ANTIDOTE_TEST_PG_URL=postgresql://postgres:pw@127.0.0.1:5432
export ANTIDOTE_TEST_MYSQL_URL=mysql://root:pw@127.0.0.1:3306
```

- Every cure the helper prints must be covered by a test that actually runs it
  and checks the result. A cure nobody has run is not an antidote.
- Keep the script portable: bash 3.2 (macOS) and git 2.23+, no other tools
  beyond POSIX `awk`, `sort`, `wc`.
- Keep `SKILL.md` short; detail belongs in `references/`.
- If you change how the skill reads (SKILL.md, the description), run the evals
  (`evals/run.sh`, costs tokens) and include the summary table in the PR.
- Recipes must be accurate. If a command depends on a platform's current policy
  (e.g. npm's unpublish window), say so and link or name the policy.

