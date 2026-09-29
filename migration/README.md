# Kaidoho migration (BookStack → Kanka)

One-shot, re-runnable copy of the Kaidoho book from `lucos_worlds` into an **empty** Kanka campaign. Design: [ADR-0001](../docs/adr/0001-adopt-self-hosted-kanka.md), decision 6. `lucos_worlds` is only read, never modified.

## What it does

- Chapter → Kanka type: `PC(s)`/`NPC(s)` → Characters, `Place(s)` → Locations; loose pages and every other chapter → Notes (each unmapped chapter is listed in the report). Edit `CHAPTER_TYPES` in `migrate_kaidoho.py` if the real chapter names differ; `--dry-run` prints the mapping without writing.
- Page HTML becomes the entity entry. Internal links (`/books/<book>/page/<slug>` and `/link/<id>`) become Kanka mentions; links to chapters/books or missing pages stay as plain links and are reported.
- Inline images are downloaded and re-uploaded via the entity-image endpoint (the gallery API writes to an S3 disk this stack doesn't have), so they are served from `/storage` behind the gate.
- After each save the script compares `<details>`/`<summary>`/`<table>` counts in the source and in what Kanka stored, and reports any loss (ADR-0005 stat blocks). Attachments can't be created through Kanka's API and are reported. Both end up in `kaidoho-migration-report.md`, for lucas42.
- Refuses to run against a campaign that already has entities: delete the campaign's entities (or make a new campaign) and re-run.

## Credentials (avalon only; they are production data)

- **BookStack:** create a dedicated **read-only** BookStack user (a role with only "Access system API" plus view rights), and give it an API token. Tokens inherit the user's permissions.
- **Kanka:** lucas42's personal access token (Settings → API), and create the empty campaign in the UI first; its id is in the URL.

Put each in its own file, outside the repo, without the values touching shell history or CI logs:

```sh
export MIGRATION_SECRETS_DIR=$HOME/.campaigns-migration-secrets
umask 077; mkdir -p "$MIGRATION_SECRETS_DIR"
for f in bookstack_token_id bookstack_token_secret kanka_token; do read -rsp "$f: " v; printf %s "$v" > "$MIGRATION_SECRETS_DIR/$f"; echo; done
```

## Run

From a checkout of this repo on avalon, with the production environment variables the deploy uses exported (the compose file needs them; take them from `lucos_creds`, not from history):

```sh
export BOOKSTACK_URL=https://worlds.l42.eu   # or http://172.17.0.1:8040, the host port
C="docker compose -f docker-compose.yml -f docker-compose.migration.yml"
$C up -d --no-deps lucos_campaigns_app       # adds the ungated /api listener (port 8081, unpublished)
$C run --rm lucos_campaigns_migration --dry-run
$C run --rm lucos_campaigns_migration --campaign <id>
cat migration-report/kaidoho-migration-report.md
```

`BOOKSTACK_PUBLIC_HOSTS` (comma-separated) lists any other hostnames BookStack's own links/images use, if not the one in `BOOKSTACK_URL`.

## Afterwards

1. **Revoke** the BookStack token (and delete its user) and the Kanka token. Remove `$MIGRATION_SECRETS_DIR`.
2. Redeploy the app from the shipped configuration (the normal deploy, or `docker compose -f docker-compose.yml up -d --force-recreate --no-deps lucos_campaigns_app`).
3. **Verify the listener has gone:**

   ```sh
   docker exec lucos_campaigns_app ls /etc/nginx/conf.d          # only default.conf
   docker exec lucos_campaigns_app grep -c ':1F91' /proc/net/tcp /proc/net/tcp6   # 0 and 0 (port 8081)
   docker port lucos_campaigns_app                               # only 8080
   ```

Nothing here is used by the normal deploy; the override file and `nginx/migration-api.conf` are not in the image.
