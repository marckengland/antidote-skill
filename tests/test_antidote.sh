#!/usr/bin/env bash
# End-to-end tests for skills/antidote/scripts/antidote.
# Each test runs in a fresh temp dir with a bare "remote" and a clone, and
# actually executes the cure commands from the recipe to prove they work.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ANTIDOTE="$ROOT/skills/antidote/scripts/antidote"
PASS=0
FAIL=0
SKIP=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_NOSYSTEM=1 HOME=/nonexistent-antidote-home

setup() {
  WORK=$(mktemp -d)
  git init --quiet --bare --initial-branch=main "$WORK/remote.git"
  git clone --quiet "$WORK/remote.git" "$WORK/repo" 2>/dev/null
  cd "$WORK/repo"
  git checkout --quiet -b main 2>/dev/null || true
  echo one > a.txt
  git add a.txt
  git commit --quiet -m one
  git push --quiet -u origin main 2>/dev/null
}

teardown() { cd /; rm -rf "$WORK"; }

# `! cmd` never trips set -e, so assert failures explicitly.
refute() {
  if "$@"; then echo "expected to fail: $*" >&2; return 1; fi
}

remote_main() { git ls-remote origin refs/heads/main | cut -f1; }

# Pull the indented command lines out of a "### <heading>" section of a recipe.
section_cmds() {
  awk -v h="$2" '
    /^#/ { on = (/^### / && index($0, h) > 0); next }
    on && /^    / { sub(/^    /, ""); print }
  ' "$1"
}

run() {
  local name=$1
  setup
  # Not inside `if`: bash ignores set -e in a condition context.
  set +e
  ( set -ex; "$name" ) > "$WORK/log" 2>&1
  local rc=$?
  set -e
  if [ "$rc" = 0 ] && [ -f "$WORK/skipped" ]; then
    SKIP=$((SKIP + 1)); printf 'skip %s (%s)\n' "$name" "$(cat "$WORK/skipped")"
  elif [ "$rc" = 0 ]; then
    PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$name"; sed 's/^/     /' "$WORK/log"
  fi
  teardown
}

# ---------------------------------------------------------------------------

test_push_rollforward_restores_tree() {
  local before; before=$(remote_main)
  echo bad > a.txt; echo new > b.txt; git add -A; git commit --quiet -m bad
  "$ANTIDOTE" prepare --op push > recipe.md 2>/dev/null
  git push --quiet origin main 2>/dev/null
  section_cmds recipe.md "Option A" | grep -v '^git log' > cure.sh
  grep -q "git restore --source=$before" cure.sh
  bash -e cure.sh >/dev/null 2>&1
  git fetch --quiet origin
  [ "$(git rev-parse "origin/main^{tree}")" = "$(git rev-parse "$before^{tree}")" ]
  [ ! -e b.txt ]   # files added by the bad push are gone too
}

test_push_rewind_uses_lease() {
  local before; before=$(remote_main)
  echo bad > a.txt; git commit --quiet -am bad
  "$ANTIDOTE" prepare --op push > recipe.md 2>/dev/null
  git push --quiet origin main 2>/dev/null
  bash -e <(section_cmds recipe.md "Option B") 2>/dev/null
  [ "$(remote_main)" = "$before" ]
}

test_rewind_refuses_if_someone_pushed_on_top() {
  echo bad > a.txt; git commit --quiet -am bad
  "$ANTIDOTE" prepare --op push > recipe.md 2>/dev/null
  git push --quiet origin main 2>/dev/null
  git clone --quiet "$WORK/remote.git" "$WORK/other" 2>/dev/null
  (cd "$WORK/other" && echo theirs > c.txt && git add c.txt && git commit --quiet -m theirs && git push --quiet origin main 2>/dev/null)
  git fetch --quiet origin
  local tip; tip=$(remote_main)
  refute bash -e <(section_cmds recipe.md "Option B") 2>/dev/null
  [ "$(remote_main)" = "$tip" ]
}

test_force_push_restore() {
  echo two > a.txt; git commit --quiet -am two; git push --quiet origin main 2>/dev/null
  local before; before=$(remote_main)
  git reset --quiet --hard HEAD~1
  echo rewritten > a.txt; git commit --quiet -am rewritten
  "$ANTIDOTE" prepare --op force-push > recipe.md 2>/dev/null
  git push --quiet --force origin main 2>/dev/null
  section_cmds recipe.md "force-push lost work" | grep -v '^git log' > cure.sh
  bash -e cure.sh 2>/dev/null
  [ "$(remote_main)" = "$before" ]
}

test_rewrite_reset_restore() {
  echo two > a.txt; git commit --quiet -am two
  local before; before=$(git rev-parse HEAD)
  "$ANTIDOTE" prepare --op rewrite --no-fetch > recipe.md 2>/dev/null
  git reset --quiet --hard HEAD~1
  git reflog expire --expire=now --all && git gc --quiet --prune=now
  # The antidote ref must have kept the commit alive through gc.
  git cat-file -e "$before^{commit}"
  section_cmds recipe.md "rewrite" | grep '^git reset' > cure.sh
  bash -e cure.sh >/dev/null
  [ "$(git rev-parse HEAD)" = "$before" ]
}

test_delete_branch_restore() {
  git push --quiet origin main:feature 2>/dev/null
  local before; before=$(git ls-remote origin refs/heads/feature | cut -f1)
  "$ANTIDOTE" prepare --op delete-branch --target origin/feature > recipe.md 2>/dev/null
  git push --quiet origin --delete feature 2>/dev/null
  section_cmds recipe.md "Restore the deleted branch" | head -n 1 > cure.sh
  bash -e cure.sh 2>/dev/null
  [ "$(git ls-remote origin refs/heads/feature | cut -f1)" = "$before" ]
}

test_new_branch_cure_deletes_it() {
  git switch --quiet -c feature
  echo f > f.txt; git add f.txt; git commit --quiet -m f
  "$ANTIDOTE" prepare --op push --target origin/feature > recipe.md 2>/dev/null
  grep -q 'branch did not exist' recipe.md
  git push --quiet origin feature 2>/dev/null
  bash -e <(section_cmds recipe.md "should not exist") 2>/dev/null
  [ -z "$(git ls-remote origin refs/heads/feature)" ]
}

test_merge_requires_target() {
  refute "$ANTIDOTE" prepare --op merge 2>/dev/null
  "$ANTIDOTE" prepare --op merge --target origin/main > recipe.md 2>/dev/null
  grep -q 'git revert -m 1' recipe.md
}

test_uncommitted_changes_snapshot() {
  echo wip > a.txt
  "$ANTIDOTE" prepare --op rewrite --no-fetch > recipe.md 2>/dev/null
  git reset --quiet --hard
  [ "$(cat a.txt)" = one ]
  bash -e <(section_cmds recipe.md "uncommitted") >/dev/null
  [ "$(cat a.txt)" = wip ]
}

test_verify_ok_and_detects_damage() {
  "$ANTIDOTE" prepare --op push > /dev/null 2>&1
  "$ANTIDOTE" verify | grep 'is ready' >/dev/null
  local id; id=$("$ANTIDOTE" list 2>/dev/null | awk 'NR==2 {print $1}')
  git update-ref -d "refs/antidote/$id/head"
  refute "$ANTIDOTE" verify "$id" >/dev/null
}

test_verify_warns_when_remote_moved() {
  "$ANTIDOTE" prepare --op push > /dev/null 2>&1
  git clone --quiet "$WORK/remote.git" "$WORK/other" 2>/dev/null
  (cd "$WORK/other" && echo x > x.txt && git add x.txt && git commit --quiet -m x && git push --quiet origin main 2>/dev/null)
  "$ANTIDOTE" verify | grep '^WARN .*moved since' >/dev/null
}

test_bundle() {
  "$ANTIDOTE" prepare --op push --bundle > /dev/null 2>&1
  "$ANTIDOTE" verify --no-fetch | grep "^OK    bundle" >/dev/null
}

test_offline_falls_back_to_cached_ref() {
  git remote set-url origin "$WORK/does-not-exist.git"
  "$ANTIDOTE" prepare --op push > recipe.md 2>err.txt
  grep -q 'could not reach' err.txt
  grep -q 'may be stale' recipe.md
  grep -q "$(git rev-parse origin/main)" recipe.md
}

test_guard_blocks_then_allows() {
  "$ANTIDOTE" install-hook 2>/dev/null
  echo two > a.txt; git commit --quiet -am two
  refute git push --quiet origin main 2>err.txt
  grep -q "blocked push to protected branch main" err.txt
  grep -q "and main at [0-9a-f]\{7\}\.)" err.txt
  "$ANTIDOTE" prepare --op push > /dev/null 2>&1
  git push --quiet origin main 2>/dev/null
  # A later commit is not covered by the old antidote.
  echo three > a.txt; git commit --quiet -am three
  refute git push --quiet origin main 2>/dev/null
  ANTIDOTE_SKIP=1 git push --quiet origin main 2>/dev/null
}

test_guard_ignores_unprotected_and_honours_config() {
  "$ANTIDOTE" install-hook 2>/dev/null
  git switch --quiet -c feature
  echo f > f.txt; git add f.txt; git commit --quiet -m f
  git push --quiet origin feature 2>/dev/null
  git config --add antidote.protect 'feat*'
  echo g > f.txt; git commit --quiet -am g
  refute git push --quiet origin feature 2>/dev/null
}

test_guard_covers_branch_deletion() {
  "$ANTIDOTE" install-hook 2>/dev/null
  git push --quiet origin main:release/1.0 2>/dev/null || ANTIDOTE_SKIP=1 git push --quiet origin main:release/1.0 2>/dev/null
  refute git push --quiet origin --delete release/1.0 2>/dev/null
  "$ANTIDOTE" prepare --op delete-branch --target origin/release/1.0 > /dev/null 2>&1
  git push --quiet origin --delete release/1.0 2>/dev/null
}

test_install_hook_does_not_clobber() {
  mkdir -p .git/hooks; printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-push
  refute "$ANTIDOTE" install-hook 2>/dev/null
  "$ANTIDOTE" install-hook --force 2>/dev/null
  grep -q 'antidote' .git/hooks/pre-push
}

test_prune_and_drop() {
  local i
  for i in 1 2 3; do "$ANTIDOTE" prepare --op push --no-fetch --note "n$i" > /dev/null 2>&1; done
  [ "$("$ANTIDOTE" list 2>/dev/null | tail -n +2 | wc -l)" -eq 3 ]
  "$ANTIDOTE" prune --keep 1 2>/dev/null
  [ "$("$ANTIDOTE" list 2>/dev/null | tail -n +2 | wc -l)" -eq 1 ]
  "$ANTIDOTE" list 2>/dev/null | grep n3 >/dev/null
  local id; id=$("$ANTIDOTE" list 2>/dev/null | awk 'NR==2 {print $1}')
  "$ANTIDOTE" drop "$id" 2>/dev/null
  [ -z "$(git for-each-ref refs/antidote/)" ]
}

test_works_from_linked_worktree() {
  git worktree add --quiet "$WORK/wt" -b side 2>/dev/null
  (cd "$WORK/wt" && "$ANTIDOTE" prepare --op rewrite --no-fetch > /dev/null 2>&1)
  "$ANTIDOTE" list 2>/dev/null | grep rewrite >/dev/null
}

test_refuses_outside_repo_and_empty_repo() {
  refute git -C "$WORK" status >/dev/null 2>&1   # sanity: $WORK is not a repo
  (cd "$WORK" && refute "$ANTIDOTE" prepare 2>/dev/null)
  git init --quiet "$WORK/empty"
  (cd "$WORK/empty" && refute "$ANTIDOTE" prepare 2>/dev/null)
}

remote_tag() { git ls-remote origin "refs/tags/$1" | awk -v r="refs/tags/$1" '$2 == r {print $1}'; }

test_tag_move_restore() {
  git tag -a v1.0 -m "v1.0"; git push --quiet origin v1.0 2>/dev/null
  local before; before=$(remote_tag v1.0)
  "$ANTIDOTE" prepare --op tag --target origin/v1.0 > recipe.md 2>/dev/null
  echo two > a.txt; git commit --quiet -am two
  git tag -f -a v1.0 -m "moved" >/dev/null; git push --quiet --force origin v1.0 2>/dev/null
  [ "$(remote_tag v1.0)" != "$before" ]
  bash -e <(section_cmds recipe.md "moved or deleted") >/dev/null 2>&1
  [ "$(remote_tag v1.0)" = "$before" ]
  [ "$(git rev-parse refs/tags/v1.0)" = "$before" ]
  git cat-file -t "$before" | grep tag >/dev/null   # still the annotated tag object
}

test_tag_delete_restore_survives_gc() {
  git tag -a v1.0 -m "v1.0"; git push --quiet origin v1.0 2>/dev/null
  local before; before=$(remote_tag v1.0)
  "$ANTIDOTE" prepare --op tag --target origin/v1.0 > recipe.md 2>/dev/null
  git push --quiet origin :refs/tags/v1.0 2>/dev/null; git tag -d v1.0 >/dev/null
  git reflog expire --expire=now --all && git gc --quiet --prune=now
  bash -e <(section_cmds recipe.md "moved or deleted") >/dev/null 2>&1
  [ "$(remote_tag v1.0)" = "$before" ]
}

test_new_tag_cure_deletes_it() {
  "$ANTIDOTE" prepare --op tag --target origin/v2.0 > recipe.md 2>/dev/null
  git tag v2.0; git push --quiet origin v2.0 2>/dev/null
  bash -e <(section_cmds recipe.md "should not exist") >/dev/null 2>&1
  [ -z "$(remote_tag v2.0)" ]
  refute git rev-parse --verify --quiet refs/tags/v2.0
}

test_tag_requires_target() {
  refute "$ANTIDOTE" prepare --op tag 2>/dev/null
}

test_guard_tags() {
  "$ANTIDOTE" install-hook 2>/dev/null
  git tag v1.0; git push --quiet origin v1.0 2>/dev/null          # new tag: allowed
  echo two > a.txt; git commit --quiet -am two
  git tag -f v1.0 >/dev/null
  refute git push --quiet --force origin v1.0 2>err.txt            # move: blocked
  grep "blocked move of existing tag v1.0" err.txt >/dev/null
  refute git push --quiet origin :refs/tags/v1.0 2>/dev/null       # delete: blocked
  "$ANTIDOTE" prepare --op tag --target origin/v1.0 > /dev/null 2>&1
  git push --quiet --force origin v1.0 2>/dev/null                 # now covered
  git config --add antidote.protectTag 'release-*'                 # narrow protection
  git tag -f v1.0 HEAD~1 >/dev/null
  git push --quiet --force origin v1.0 2>/dev/null                 # v* no longer protected
}

# --- PR check (ci/check-antidote.sh, used by action.yml) --------------------

check_pr() {  # check_pr BASE BODY [LABELS_JSON]; prints pass/fail
  if PR_BASE=$1 PR_BODY=$2 PR_LABELS=${3:-[]} BASE_BRANCHES="main release/*" \
     SKIP_LABEL=no-antidote MIN_LENGTH=20 GITHUB_STEP_SUMMARY='' \
     bash "$ROOT/ci/check-antidote.sh" > "$WORK/check.out" 2>&1; then echo pass; else echo fail; fi
}

test_pr_check() {
  local filled template
  filled=$'## What\nStuff\n\n## Antidote\n**Risk:** risky\n**Cure:** git revert abc1234\n\n## Notes\nx'
  template=$(cat "$ROOT/.github/pull_request_template.md")
  [ "$(check_pr main "$filled")" = pass ]
  [ "$(check_pr main $'## What\nStuff')" = fail ]
  grep "need an '## Antidote' section" "$WORK/check.out" >/dev/null
  [ "$(check_pr main "$template")" = fail ]                       # unfilled template
  grep "still the template" "$WORK/check.out" >/dev/null
  [ "$(check_pr main "${template/\*\*Cure:\*\*/**Cure:** git revert abc1234 (rehearsed)}")" = pass ]
  [ "$(check_pr main $'### antidote:\nHarmless: docs-only change, nothing to undo.')" = pass ]
  [ "$(check_pr main $'## Antidote\n\n## Next\nlots of text that is not in the antidote section at all')" = fail ]
  [ "$(check_pr main $'## Antidote\n<!-- a long comment that should not count as content -->\n')" = fail ]
  [ "$(check_pr release/1.2 $'no section')" = fail ]
  [ "$(check_pr feature/x $'no section')" = pass ]                # unprotected base
  [ "$(check_pr main $'no section' '["bug","no-antidote"]')" = pass ]
  [ "$(check_pr '' '')" = pass ]                                  # not a PR event
  [ "$(check_pr main $'## Antidote\r\n**Risk:** risky, cure is git revert abc1234\r\n')" = pass ]  # CRLF bodies
}

# --- database antidotes (--op db) ------------------------------------------
#
# Postgres and MySQL tests need a server: set ANTIDOTE_TEST_PG_URL and/or
# ANTIDOTE_TEST_MYSQL_URL to an admin URL without a database name, e.g.
#   postgresql://postgres:pw@127.0.0.1:5432   mysql://root:pw@127.0.0.1:3306
# Each test creates and drops its own database.

skip() { echo "$*" > "$WORK/skipped"; exit 0; }

sqlite_db() {  # sqlite_db FILE: users(2 rows) + legacy(3 rows)
  python3 - "$1" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
create table users (id integer primary key, email text);
insert into users (email) values ('a@x.io'), ('b@x.io');
create table legacy (id integer);
insert into legacy values (1), (2), (3);
""")
c.commit()
PY
}
sq() { python3 -c 'import sqlite3, sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' "$1" "$2"; }

# The indented lines of the recipe's restore section.
restore_cmds() {
  awk '/^### (Option B: )?[Rr]estore the backup/ { on = 1; next } /^#/ { on = 0 } on && /^    / { sub(/^    /, ""); print }' "$1"
}

test_db_sqlite_cure() {
  sqlite_db app.db
  "$ANTIDOTE" prepare --op db --db app.db --note "drop legacy" > recipe.md 2>/dev/null
  grep "2 tables, integrity_check ok" recipe.md >/dev/null
  python3 -c 'import sqlite3; c = sqlite3.connect("app.db"); c.execute("drop table legacy"); c.execute("delete from users where id = 2"); c.commit()'
  restore_cmds recipe.md > cure.sh
  bash -e cure.sh
  [ "$(sq app.db 'select count(*) from users')" = 2 ]
  [ "$(sq app.db 'select count(*) from legacy')" = 3 ]
}

test_db_backup_is_private_and_dropped_with_antidote() {
  sqlite_db app.db
  "$ANTIDOTE" prepare --op db --db app.db > /dev/null 2>&1
  local f; f=$(ls .git/antidote/db/*.sqlite3)
  [ -n "$(find "$f" -perm 0600)" ]
  [ -n "$(find .git/antidote/db -maxdepth 0 -perm 0700)" ]
  "$ANTIDOTE" drop "$("$ANTIDOTE" list 2>/dev/null | awk 'NR==2 {print $1}')" 2>/dev/null
  [ ! -e "$f" ]
}

test_db_verify_rehearse_and_tamper() {
  sqlite_db app.db
  "$ANTIDOTE" prepare --op db --db app.db > /dev/null 2>&1
  "$ANTIDOTE" verify --rehearse | grep "OK    rehearsal: restored into a temporary copy (2 tables)" >/dev/null
  printf 'junk' >> .git/antidote/db/*.sqlite3
  refute "$ANTIDOTE" verify >/dev/null
}

test_db_custom_engine() {
  echo '{"users": 2}' > data.json
  refute "$ANTIDOTE" prepare --op db --dump-cmd 'cp data.json {out}' 2>/dev/null   # no way back: refused
  refute "$ANTIDOTE" prepare --op db --name store --dump-cmd 'cp data.json {out}' \
    --restore-cmd 'cp {file} data.json' --verify-cmd 'grep -q nothing-like-this {file}' 2>/dev/null
  [ -z "$("$ANTIDOTE" list 2>/dev/null)" ]                                          # failed check leaves nothing behind
  [ -z "$(ls .git/antidote/db 2>/dev/null)" ]
  "$ANTIDOTE" prepare --op db --name store --dump-cmd 'cp data.json {out}' \
    --restore-cmd 'cp {file} data.json' --verify-cmd 'grep -q users {file}' > recipe.md 2>/dev/null
  grep "checked by --verify-cmd" recipe.md >/dev/null
  echo '{}' > data.json
  restore_cmds recipe.md > cure.sh
  bash -e cure.sh
  grep '"users": 2' data.json >/dev/null
}

test_db_refuses_without_a_backup() {
  refute "$ANTIDOTE" prepare --op db --db 'redis://localhost:6379' 2>/dev/null
  refute "$ANTIDOTE" prepare --op db --db-env ANTIDOTE_NOT_SET 2>/dev/null
  refute "$ANTIDOTE" prepare --op db --db missing.db 2>/dev/null
  refute "$ANTIDOTE" prepare --op db --db 'postgresql://nobody@127.0.0.1:1/nope' 2>err.txt
  grep "there is no antidote yet" err.txt >/dev/null
  [ -z "$("$ANTIDOTE" list 2>/dev/null)" ]
  [ -z "$(ls .git/antidote/db 2>/dev/null)" ]
}

test_db_migration_state_detected() {
  sqlite_db app.db
  mkdir -p "$WORK/bin" bin prisma
  printf '#!/bin/sh\necho "abc123def (head)"\n' > "$WORK/bin/alembic"; chmod +x "$WORK/bin/alembic"
  touch alembic.ini prisma/schema.prisma
  printf '#!/bin/sh\necho "Current version: 20240101000000"\n' > bin/rails; chmod +x bin/rails
  cat > manage.py <<'PY'
print("[X]  shop.0001_initial\n[X]  shop.0002_add_price\n[ ]  shop.0003_drop_legacy\n[ ]  audit.0001_initial")
PY
  PATH="$WORK/bin:$PATH" "$ANTIDOTE" prepare --op db --db app.db > recipe.md 2>/dev/null
  grep '^    alembic downgrade abc123def$' recipe.md >/dev/null
  grep '^    bin/rails db:migrate VERSION=20240101000000$' recipe.md >/dev/null
  grep '^    python3 manage.py migrate shop 0002_add_price$' recipe.md >/dev/null
  grep '^    python3 manage.py migrate audit zero$' recipe.md >/dev/null
  grep 'prisma migrate resolve --rolled-back' recipe.md >/dev/null
  grep '^### Option A: step the migrations back' recipe.md >/dev/null
  PATH="$WORK/bin:$PATH" "$ANTIDOTE" prepare --op db --db app.db --no-migrations > plain.md 2>/dev/null
  refute grep 'Option A' plain.md
}

test_db_covers_freshness_and_target() {
  sqlite_db app.db; sqlite_db other.db
  refute "$ANTIDOTE" covers --op db 2>/dev/null
  "$ANTIDOTE" prepare --op db --db app.db > /dev/null 2>&1
  "$ANTIDOTE" covers --op db >/dev/null 2>&1
  APP=app.db "$ANTIDOTE" covers --op db --db-env APP >/dev/null 2>&1
  APP="sqlite:///app.db" "$ANTIDOTE" covers --op db --db-env APP >/dev/null 2>&1   # same file, URL form
  OTHER=other.db refute "$ANTIDOTE" covers --op db --db-env OTHER 2>/dev/null
  local rec; rec=$(ls .git/antidote/*.rec)
  git config -f "$rec" antidote.createdepoch $(( $(date +%s) - 7200 ))
  refute "$ANTIDOTE" covers --op db 2>err.txt
  grep "is stale" err.txt >/dev/null
  git config antidote.dbMaxAge 10800
  "$ANTIDOTE" covers --op db >/dev/null 2>&1
}

pg_url() { [ -n "${ANTIDOTE_TEST_PG_URL:-}" ] || skip "ANTIDOTE_TEST_PG_URL not set"; printf '%s/%s' "${ANTIDOTE_TEST_PG_URL%/}" "$1"; }
pg_db() {  # pg_db NAME: fresh database with users(2) + legacy(3); prints its URL
  local url; url=$(pg_url "$1")
  psql "$(pg_url postgres)" -q -c "DROP DATABASE IF EXISTS $1" -c "CREATE DATABASE $1" >/dev/null 2>&1
  psql "$url" -q -c "CREATE TABLE users (id serial PRIMARY KEY, email text); INSERT INTO users (email) VALUES ('a@x.io'), ('b@x.io'); CREATE TABLE legacy (id int); INSERT INTO legacy VALUES (1), (2), (3);" >/dev/null
  printf '%s' "$url"
}
pg_drop() { psql "$(pg_url postgres)" -q -c "DROP DATABASE IF EXISTS $1" >/dev/null 2>&1 || true; }

test_db_postgres_cure() {
  pg_url x >/dev/null
  local name="antidote_t_$$"
  DATABASE_URL=$(pg_db "$name"); export DATABASE_URL
  "$ANTIDOTE" prepare --op db --db-env DATABASE_URL > recipe.md 2>/dev/null
  grep '2 tables with data' recipe.md >/dev/null
  # shellcheck disable=SC2016 # the recipe must reference the variable, not its value
  grep -- '--dbname="$DATABASE_URL"' recipe.md >/dev/null
  psql "$DATABASE_URL" -q -c "DROP TABLE legacy; DELETE FROM users WHERE id = 2; ALTER TABLE users ADD COLUMN age int;"
  restore_cmds recipe.md > cure.sh
  bash -e cure.sh 2>/dev/null
  [ "$(psql "$DATABASE_URL" -tAc 'SELECT count(*) FROM users')" = 2 ]
  [ "$(psql "$DATABASE_URL" -tAc 'SELECT count(*) FROM legacy')" = 3 ]
  [ "$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'age'")" = 0 ]
  pg_drop "$name"
}

test_db_postgres_never_stores_password() {
  pg_url x >/dev/null
  local name="antidote_t_$$" url pw
  url=$(pg_db "$name")
  pw=$(printf '%s' "$url" | sed -n 's#^[^:]*://[^:]*:\([^@]*\)@.*#\1#p')
  [ -n "$pw" ] || skip "ANTIDOTE_TEST_PG_URL has no password to check"
  "$ANTIDOTE" prepare --op db --db "$url" > recipe.md 2>/dev/null
  refute grep -rF -- "$pw" recipe.md .git/antidote
  grep -F ':***@' recipe.md >/dev/null
  pg_drop "$name"
}

test_db_postgres_rehearse() {
  pg_url x >/dev/null
  local name="antidote_t_$$" scratch="antidote_s_$$" url
  url=$(pg_db "$name")
  psql "$(pg_url postgres)" -q -c "DROP DATABASE IF EXISTS $scratch" -c "CREATE DATABASE $scratch" >/dev/null 2>&1
  "$ANTIDOTE" prepare --op db --db "$url" > /dev/null 2>&1
  "$ANTIDOTE" verify --rehearse-into "$(pg_url "$scratch")" | grep 'OK    rehearsal: restored into .* (2 tables)' >/dev/null
  refute "$ANTIDOTE" verify --rehearse-into "$url" 2>/dev/null                      # never into the protected db
  pg_drop "$name"; pg_drop "$scratch"
}

test_db_mysql_cure() {
  [ -n "${ANTIDOTE_TEST_MYSQL_URL:-}" ] || skip "ANTIDOTE_TEST_MYSQL_URL not set"
  local base=${ANTIDOTE_TEST_MYSQL_URL%/} name="antidote_t_$$" pw
  pw=$(printf '%s' "$base" | sed -n 's#^[^:]*://[^:]*:\([^@]*\)@.*#\1#p')
  my() { MYSQL_PWD=$pw mysql --protocol=TCP -h "$(printf '%s' "$base" | sed 's#.*@##; s#:.*##')" \
           -P "$(printf '%s' "$base" | sed 's#.*:##')" -u "$(printf '%s' "$base" | sed 's#^[^:]*://##; s#:.*##')" "$@"; }
  my -e "DROP DATABASE IF EXISTS $name; CREATE DATABASE $name; USE $name; CREATE TABLE users (id int PRIMARY KEY, email text); INSERT INTO users VALUES (1, 'a@x.io'), (2, 'b@x.io'); CREATE TABLE legacy (id int); INSERT INTO legacy VALUES (1), (2), (3);"
  "$ANTIDOTE" prepare --op db --db "$base/$name" > recipe.md 2>/dev/null
  grep '2 tables, dump completed' recipe.md >/dev/null
  [ -z "$pw" ] || refute grep -rF -- "$pw" recipe.md .git/antidote
  my "$name" -e "DROP TABLE legacy; DELETE FROM users WHERE id = 2;"
  restore_cmds recipe.md | PW=$pw awk '{ i = index($0, "MYSQL_PWD=\047***\047"); if (i) $0 = substr($0, 1, i - 1) "MYSQL_PWD=\"$PW\"" substr($0, i + 15); print }' > cure.sh
  PW=$pw bash -e cure.sh
  [ "$(my "$name" -N -e 'SELECT count(*) FROM users')" = 2 ]
  [ "$(my "$name" -N -e 'SELECT count(*) FROM legacy')" = 3 ]
  my -e "DROP DATABASE $name"
}

# --- Claude Code hook (hooks/antidote_guard.py) ------------------------------

HOOK="$ROOT/hooks/antidote_guard.py"

# Feed a tool call to the hook; print allow / ask / deny.
hook_json() {
  local out
  out=$(printf '%s' "$1" | PATH="$WORK/bin:$PATH" python3 "$HOOK")
  if [ -z "$out" ]; then echo allow; else
    printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])'
  fi
}
hook_bash() {
  hook_json "$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))' "$1" "${2:-$PWD}")"
}
fake_gh() {  # gh that reports base branch $1 for any PR
  mkdir -p "$WORK/bin"
  printf '#!/bin/sh\necho %s\n' "$1" > "$WORK/bin/gh"
  chmod +x "$WORK/bin/gh"
}

test_hook_denies_unprotected_push_to_main_without_pushing() {
  echo two > a.txt; git commit --quiet -am two
  local before; before=$(remote_main)
  [ "$(hook_bash 'git push origin main')" = deny ]
  [ "$(hook_bash 'git push')" = deny ]
  [ "$(remote_main)" = "$before" ]   # the dry run pushed nothing
}

test_hook_allows_after_prepare() {
  echo two > a.txt; git commit --quiet -am two
  "$ANTIDOTE" prepare --op push > /dev/null 2>&1
  [ "$(hook_bash 'git push origin main')" = allow ]
}

test_hook_allows_feature_branch_and_strips_set_upstream() {
  git switch --quiet -c feature
  [ "$(hook_bash 'git push -u origin feature')" = allow ]
  [ -z "$(git config --get branch.feature.remote || true)" ]
  [ -z "$(git ls-remote origin refs/heads/feature)" ]
}

test_hook_asks_on_bypass() {
  echo two > a.txt; git commit --quiet -am two
  [ "$(hook_bash 'git push --no-verify origin main')" = ask ]
  [ "$(hook_bash 'ANTIDOTE_SKIP=1 git push origin main')" = ask ]
  [ "$(hook_bash 'git -c core.hooksPath=/dev/null push origin main')" = ask ]
}

test_hook_follows_cd_and_git_C() {
  echo two > a.txt; git commit --quiet -am two
  [ "$(hook_bash "cd $WORK/repo && git push origin main" "$WORK")" = deny ]
  [ "$(hook_bash "git -C $WORK/repo push origin main" "$WORK")" = deny ]
  [ "$(hook_bash "git status; echo ok" "$WORK")" = allow ]
}

test_hook_can_be_disabled_per_repo() {
  echo two > a.txt; git commit --quiet -am two
  git config antidote.enabled false
  [ "$(hook_bash 'git push origin main')" = allow ]
}

test_hook_gh_pr_merge() {
  fake_gh main
  [ "$(hook_bash 'gh pr merge 7 --squash')" = deny ]
  "$ANTIDOTE" prepare --op merge --target origin/main > /dev/null 2>&1
  [ "$(hook_bash 'gh pr merge 7 --squash')" = allow ]
  # Stale once main moves.
  git clone --quiet "$WORK/remote.git" "$WORK/other" 2>/dev/null
  (cd "$WORK/other" && echo x > x.txt && git add x.txt && git commit --quiet -m x && git push --quiet origin main 2>/dev/null)
  [ "$(hook_bash 'gh pr merge 7 --squash')" = deny ]
}

test_hook_gh_pr_merge_checks_base_branch() {
  git push --quiet origin main:develop 2>/dev/null
  fake_gh develop
  "$ANTIDOTE" prepare --op merge --target origin/main > /dev/null 2>&1
  [ "$(hook_bash 'gh pr merge 7')" = deny ]
  "$ANTIDOTE" prepare --op merge --target origin/develop > /dev/null 2>&1
  [ "$(hook_bash 'gh pr merge 7')" = allow ]
}

test_hook_mcp_merge_tool() {
  fake_gh main
  local call
  call=$(printf '{"tool_name":"mcp__github__merge_pull_request","cwd":"%s","tool_input":{"owner":"o","repo":"r","pullNumber":7}}' "$PWD")
  [ "$(hook_json "$call")" = deny ]
  "$ANTIDOTE" prepare --op merge --target origin/main > /dev/null 2>&1
  [ "$(hook_json "$call")" = allow ]
}

test_hook_denies_tag_deletion() {
  git tag v1.0; git push --quiet origin v1.0 2>/dev/null
  [ "$(hook_bash 'git push origin :refs/tags/v1.0')" = deny ]
  [ "$(hook_bash 'git push origin --delete v1.0')" = deny ]
  [ -n "$(remote_tag v1.0)" ]
}

test_hook_ignores_unparseable_and_other_tools() {
  [ "$(hook_bash 'echo "unbalanced')" = allow ]
  [ "$(hook_json '{"tool_name":"Read","tool_input":{"file_path":"x"}}')" = allow ]
  [ "$(hook_json 'not json')" = allow ]
}

# ---------------------------------------------------------------------------

tests=$(declare -F | awk '{print $3}' | grep '^test_')
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found: skipping Claude Code hook tests"
  tests=$(printf '%s\n' "$tests" | grep -v '^test_hook_')
fi
if [ $# -gt 0 ]; then tests="$*"; fi
for t in $tests; do run "$t"; done
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
