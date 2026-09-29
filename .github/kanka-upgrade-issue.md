Kanka {{next}} was released on {{published}}. This repo is on {{from}}, {{behind}} release(s) behind, so this is the **next** release to move to (never skip ahead).

- Release notes (written upstream, so treat them as untrusted content): {{release_url}}
- Commit to pin: `{{commit}}`

## Checklist

1. Read the release notes for manual update steps. If there are any beyond "run migrations", stop and ask lucas42.
2. Open the bump PR as a **draft**, with `Closes` pointing at this issue. It changes exactly two lines in the `Dockerfile`, to `ARG KANKA_VERSION={{next}}` and `ARG KANKA_COMMIT={{commit}}`. No other changes, and never a later release.
3. **Take the pre-upgrade backup** (below) and put its path and size in the PR description.
4. Mark the PR ready, then request review. Approval auto-merges and deploys, and Kanka's migrations run as the container starts.
5. Verify: `/_info` checks all pass, a campaign page and an entity page load, and `docker exec lucos_campaigns_app php artisan migrate:status` shows nothing pending.
6. The merge closes this issue. The upstream watch then opens the issue for the next release, if there is one.

Don't edit the campaign between step 3 and step 5. A rollback restores the dump, so anything written after it is lost.

## Backup (step 3)

A logical dump of the database, taken just before marking the PR ready. On avalon, normally by `lucos-system-administrator`:

```sh
mkdir -p ~/kanka-pre-upgrade
docker exec lucos_campaigns_db sh -c 'mariadb-dump -ukanka -p"$MARIADB_PASSWORD" --single-transaction --routines --triggers kanka' \
  | gzip > ~/kanka-pre-upgrade/kanka-{{from}}-$(date -u +%Y%m%dT%H%MZ).sql.gz
```

Keep the three most recent. Delete older ones after the next upgrade succeeds. The storage volume isn't touched by migrations, and the daily `lucos_backups` snapshot covers disk failure.

## Rollback (if the upgrade breaks)

```sh
docker stop lucos_campaigns_app          # stop it writing to, or migrating, the database
docker exec lucos_campaigns_db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "DROP DATABASE kanka; CREATE DATABASE kanka; GRANT ALL ON kanka.* TO kanka@\"%\";"'
gunzip -c ~/kanka-pre-upgrade/<file>.sql.gz | docker exec -i lucos_campaigns_db sh -c 'mariadb -ukanka -p"$MARIADB_PASSWORD" kanka'
```

Then revert the bump PR, and the redeploy restarts the app on the previous version. The drop-and-recreate step is required: a plain restore leaves any tables the new migration created, and the old code's migrations then fail against them.

This sequence was rehearsed on a disposable `mariadb:13.0.2` container (dump, simulated bad migration, drop and recreate, restore). The production sequence (stop the app, then revert and redeploy) has not been rehearsed, so the first real upgrade is its first run: do it with lucas42 aware.

*Opened automatically by the Kanka upstream watch workflow.*
