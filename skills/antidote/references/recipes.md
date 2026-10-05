# Antidote recipes

One section per kind of change. Each gives the snapshot to take, the cure, and
how to test it. Fill in real names, versions and commit hashes; a recipe with
placeholders left in it is not an antidote.

## Contents

- [Git](#git)
- [Database migrations and data changes](#database-migrations-and-data-changes)
- [Deploys](#deploys)
- [Packages and releases](#packages-and-releases)
- [Dependency upgrades](#dependency-upgrades)
- [Config, feature flags and CI](#config-feature-flags-and-ci)
- [Infrastructure as code](#infrastructure-as-code)
- [Secrets and permissions](#secrets-and-permissions)
- [Files outside git](#files-outside-git)

---

## Git

Use `scripts/antidote prepare --op <op>`; it writes these for you. For reference:

| Change | Snapshot | Cure |
|---|---|---|
| Push / merge to a shared branch | remote tip before: `git ls-remote origin refs/heads/main` | Roll forward: `git revert -m 1 <merge>` (merge commit), `git revert <sha>` (squash), or restore the whole tree: `git restore --source=<before> --staged --worktree -- :/` then commit. Rewind (nobody pulled): `git push --force-with-lease=refs/heads/main:<pushed> origin <before>:refs/heads/main` |
| Force-push | remote tip before | `git push --force-with-lease=refs/heads/<b>:<pushed> origin <before>:refs/heads/<b>` |
| Rebase / reset / amend | `git update-ref refs/antidote/<name> HEAD` | `git reset --hard <before>` or `git branch rescue <before>`. `git reflog` is the last resort, but it is local and expires. |
| Delete a branch | its tip | `git push origin <sha>:refs/heads/<branch>` |
| Delete or move a tag | `antidote prepare --op tag --target origin/<tag>` (or `git ls-remote --tags origin <tag>`; annotated tags show the tag object and `^{}` commit) | `git push --force origin <tag-object-sha>:refs/tags/<tag>`. Clones that already fetched the tag keep the old one, and pipelines it triggered have already run, so say so |
| Delete a GitHub release | `gh release view <tag> --json name,body,tagName,isDraft,isPrerelease,assets > release.json` and `gh release download <tag> -D release-assets/` | `gh release create <tag> release-assets/* --title ... --notes-file ...` |
| `git filter-repo` / history purge | `git clone --mirror` to a safe place, or `antidote prepare --op rewrite --bundle` | push the mirror back with the user's approval. If you are purging a leaked secret, rotate the secret: rewriting history does not un-leak it. |

## Database migrations and data changes

**Snapshot first, always,** even when a down migration exists. Down migrations
cannot bring back dropped columns, tables or rows.

`antidote prepare --op db --db-env DATABASE_URL` does the snapshot, the check
and the cure for Postgres, MySQL/MariaDB and SQLite, and any other engine with
`--dump-cmd/--restore-cmd`. The table below is what it runs, for when you need
to do it by hand.

| Engine | Snapshot | Restore | Test the backup |
|---|---|---|---|
| PostgreSQL | `pg_dump -Fc -f before.dump "$DATABASE_URL"` (or `-t table` for just the touched tables) | `pg_restore --clean --if-exists -d "$DATABASE_URL" before.dump` | `pg_restore --list before.dump \| head` |
| MySQL / MariaDB | `mysqldump --single-transaction --routines db > before.sql` | `mysql db < before.sql` | check the file ends with `-- Dump completed` |
| SQLite | `sqlite3 app.db ".backup before.db"` | copy `before.db` back while the app is stopped | `sqlite3 before.db "PRAGMA integrity_check"` |
| MongoDB | `mongodump --uri "$URI" --out before/` | `mongorestore --uri "$URI" --drop before/` | list the dump's collections |
| Managed (RDS, Cloud SQL, Neon, PlanetScale, Supabase...) | take an on-demand snapshot or branch and wait until it is *available* | restore or point-in-time-recover to a new instance, then switch over | confirm the snapshot's status and time |

Down migrations by framework: Rails `bin/rails db:rollback STEP=1`; Django
`python manage.py migrate <app> <previous_migration>`; Alembic `alembic downgrade -1`;
Knex `knex migrate:rollback`; Laravel `php artisan migrate:rollback --step=1`;
Ecto `mix ecto.rollback`; golang-migrate `migrate ... down 1`. Prisma Migrate and
many other tools do not generate down migrations: rely on the backup, or write
the reverse SQL yourself and test it.

Make destructive schema changes survivable with **expand / contract**: add the
new column or table, deploy code that writes both, backfill, switch reads, and
only drop the old one in a later release, once the new path has been proven.
Each step then has a trivial antidote.

For one-off data fixes (`UPDATE`, `DELETE`): first copy the rows you will touch
(`CREATE TABLE backup_<ticket> AS SELECT * FROM t WHERE <same condition>`), run
the change in a transaction, and check the affected row count before `COMMIT`.

**Test:** restore the backup (or run the down migration) on a copy of the data and
compare row counts or checksums on the tables you touched.

## Deploys

Record **exactly** what is running before you deploy: image digest (not just a
tag like `latest`), release number, or commit SHA, plus how to get it back.

| Platform | Record before | Cure |
|---|---|---|
| Kubernetes | `kubectl rollout history deploy/<name>` and `kubectl get deploy/<name> -o yaml > before.yaml` | `kubectl rollout undo deploy/<name> [--to-revision=N]` |
| Helm | `helm history <release>` | `helm rollback <release> <revision>` |
| Docker / Compose | `docker inspect --format '{{.Image}}' <container>` | redeploy the previous image digest |
| Heroku | `heroku releases -a <app>` | `heroku rollback v<N> -a <app>` |
| Vercel | `vercel ls` (note the current production deployment) | `vercel rollback <deployment-url>` |
| Fly.io | `fly releases -a <app> --image` | `fly deploy --image <previous-image>` |
| Serverless (Lambda, Cloud Run...) | current version / revision | shift traffic back to the previous version / revision |
| Anything else | the commit SHA that is live | redeploy that SHA through the normal pipeline |

Prefer gradual rollouts (canary, percentage traffic, blue/green) so the cure is
"shift traffic back". Database migrations shipped with a deploy usually make code
rollback unsafe: snapshot the database too, and check the old code still works
with the new schema before calling the deploy reversible.

**Test:** confirm the previous artifact still exists (images and old releases get
garbage-collected) and that your credentials allow the rollback command.

## Packages and releases

Publishing is close to irreversible. Treat it as **destructive** and confirm with the user.

- **npm:** `npm unpublish <pkg>@<ver>` is limited by npm's unpublish policy
  (freely within 72 hours if nothing depends on it, after that only in narrow
  cases), and the version number can never be reused. Otherwise `npm deprecate <pkg>@<ver> "<reason>"` and
  publish a fixed patch. Dist-tags are cheap to fix:
  `npm dist-tag add <pkg>@<good-ver> latest`.
- **PyPI:** yank the release in the project settings (installers then skip it
  unless it is pinned). Deleted files can never be re-uploaded under the same name.
- **crates.io:** `cargo yank --version <ver>`; there is no delete.
- **Containers:** re-point the moving tag (`latest`, `stable`) at the previous
  digest; never overwrite a version tag.

Antidote before publishing: dry run first (`npm publish --dry-run`,
`npm pack` and inspect the tarball, `python -m build` plus `twine check`,
`cargo publish --dry-run`), publish to a pre-release tag (`--tag next`) and
promote later, and write down the last good version.

## Dependency upgrades

- Snapshot: the lockfile is the antidote, so commit it in the same commit as the
  manifest change, keeping the upgrade one revertable commit.
- Cure: `git revert <upgrade-commit>` and reinstall from the lockfile
  (`npm ci`, `pip install -r` against the old pins, `bundle install`, `cargo build --locked`).
- Upgrade major versions one at a time in separate commits so each can be reverted alone.
- Test: the full test suite plus a build of the deployable artifact, not just unit tests.

## Config, feature flags and CI

- Feature flags: ship risky behaviour behind a flag that defaults to off; the
  cure is turning the flag off. Note the flag name and where it is toggled.
- Runtime config (env vars, config maps, remote config): save the current values
  (`kubectl get configmap <name> -o yaml`, the platform's env listing) before changing them.
  Never paste secret values into the antidote record; record where they live.
- CI / workflow files: a broken workflow can block the revert that fixes it. Keep
  the change small and in its own commit, and make sure the default branch can
  still be pushed or merged to if CI goes red.
- Branch protection, repo settings, DNS, CDN: screenshot or export the current
  settings (`gh api repos/<owner>/<repo>/branches/<b>/protection`, the DNS zone
  file) so they can be re-applied.

## Infrastructure as code

- Terraform / OpenTofu: `terraform plan -out=change.tfplan` and read it for any
  `destroy` or `must be replaced`; back up state with `terraform state pull > before.tfstate`.
  The cure for a config change is applying the previous commit's config. There
  is **no** cure for data inside destroyed resources, so snapshot databases,
  disks and buckets first, and consider `prevent_destroy` on stateful resources.
- Pulumi: `pulumi preview --diff`; `pulumi stack export > before.json`.
- CloudFormation / CDK: use change sets and read them before executing; stacks roll
  back failed updates automatically, but not deleted data.
- Kubernetes manifests: `kubectl diff -f ...` first; save the live objects you will change.

## Secrets and permissions

- Rotation: create the new credential, deploy it, verify it works, and only then
  revoke the old one. Until revocation, the cure is switching back.
- Revoking access or deleting keys and users: record exactly what existed (roles,
  scopes, policy JSON) so it can be re-granted. Deleted keys usually cannot be
  restored, only reissued, so check what still uses them first.
- A leaked secret has no antidote: rotate it immediately, then clean up history.

## Files outside git

- Before bulk edits, moves or deletes on untracked or ignored files: copy them
  (`tar czf before.tgz <paths>`) somewhere outside the directory being changed.
- Prefer moving to a trash folder over `rm -rf`, and print the list of paths that
  will be touched before touching them.
