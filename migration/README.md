# Kaidoho migration (BookStack → Kanka)

One-shot, re-runnable copy of the Kaidoho book from `lucos_worlds` into an **empty** Kanka campaign. Design: [ADR-0001](../docs/adr/0001-adopt-self-hosted-kanka.md), decision 6. `lucos_worlds` is only read, never modified.

## What it does

- Chapter → Kanka type: `PC(s)`/`NPC(s)` → Characters, `Place(s)` → Locations; loose pages and every other chapter → Notes (each unmapped chapter is listed in the report). Edit `CHAPTER_TYPES` in `migrate_kaidoho.py` if the real chapter names differ; `--dry-run` prints the mapping without writing.
- Page HTML becomes the entity entry. Internal links (`/books/<book>/page/<slug>` and `/link/<id>`) become Kanka mentions; links to chapters/books or missing pages stay as plain links and are reported.
- Inline images are downloaded and re-uploaded via the entity-image endpoint (the gallery API writes to an S3 disk this stack doesn't have), so they are served from `/storage` behind the gate.
- After each save the script compares `<details>`/`<summary>`/`<table>` counts in the source and in what Kanka stored, and reports any loss (ADR-0005 stat blocks). Attachments can't be created through Kanka's API and are reported. Both end up in `kaidoho-migration-report.md`, for lucas42.
- Refuses to run against a campaign that already has entities: delete the campaign's entities (or make a new campaign) and re-run.

## Who runs it

**lucas42, over his own SSH session on avalon (as `lucas`).** He holds the production credentials, and the tokens are production data. Everything below, including the secret files in his `$HOME`, is for that account: `/home/lucas` is mode 0700, so no other account can read them.

Agents reach avalon as `lucos-agent`, which cannot read `/home/lucas` (checked: it is `drwx------ lucas lucas`), has no sudo, and has no access to the production env vars this needs. If an agent is to run it instead, lucas42 must place the three files himself (this needs root) in `/home/lucos-agent/.campaigns-migration-secrets`, owned by `lucos-agent`, directory `0700` and files `0600`, and hand over the production environment variables some other way; set `MIGRATION_SECRETS_DIR` to that path. The default is not to do this.

There is no persistent checkout of this repo on avalon, so the run starts from a fresh clone (`git clone https://github.com/lucas42/lucos_campaigns.git ~/campaigns-migration && cd ~/campaigns-migration`) that is deleted at the end.

## Credentials (avalon only; they are production data)

- **BookStack:** create a dedicated **read-only** BookStack user (a role with only "Access system API" plus view rights), and give it an API token. Tokens inherit the user's permissions.
- **Kanka:** lucas42's personal access token (Settings → API), and create the empty campaign in the UI first; its id is in the URL.

Put each in its own file, outside the repo, without the values touching shell history or CI logs (bash, for `read -s`):

```sh
export MIGRATION_SECRETS_DIR=$HOME/.campaigns-migration-secrets
umask 077; mkdir -p "$MIGRATION_SECRETS_DIR"
for f in bookstack_token_id bookstack_token_secret kanka_token; do read -rsp "$f: " v; printf %s "$v" > "$MIGRATION_SECRETS_DIR/$f"; echo; done
```

## Run

From that fresh clone on avalon, with the production environment variables the deploy uses exported (the compose file needs them). Fetch them without typing values into the shell: `scp -P 2202 "creds.l42.eu:lucos_campaigns/production/.env" .env && set -a && . ./.env && set +a && rm .env` (lucas42 only, as production creds):

Pin the project and image to what production is running first. The deploy uses `COMPOSE_PROJECT_NAME=lucos_campaigns`, and an unset `VERSION` would resolve the app image to `:latest` and could rebuild Kanka from source, so both are set and `--no-build` is used:

```sh
export COMPOSE_PROJECT_NAME=lucos_campaigns
export VERSION=$(docker inspect lucos_campaigns_app --format '{{.Config.Image}}' | cut -d: -f2)
export BOOKSTACK_URL=https://worlds.l42.eu   # or http://172.17.0.1:8040, the host port
C="docker compose -f docker-compose.yml -f docker-compose.migration.yml"
$C up -d --no-build --no-deps lucos_campaigns_app   # briefly restarts the production app; adds the ungated /api listener (port 8081, unpublished)
$C run --rm lucos_campaigns_migration --dry-run
$C run --rm lucos_campaigns_migration --campaign <id>
cat migration-report/kaidoho-migration-report.md
```

`BOOKSTACK_PUBLIC_HOSTS` (comma-separated) lists any other hostnames BookStack's own links/images use, if not the one in `BOOKSTACK_URL`.

## Afterwards

1. **Revoke** the BookStack token (and delete its user) and the Kanka token. Remove `$MIGRATION_SECRETS_DIR`, `.env` and the clone (`rm -r ~/campaigns-migration`).
2. Redeploy the app from the shipped configuration (the normal deploy, or `docker compose -f docker-compose.yml up -d --no-build --force-recreate --no-deps lucos_campaigns_app`, with the same `COMPOSE_PROJECT_NAME` and `VERSION` exported (this also briefly restarts the app)).
3. **Verify the listener has gone:**

   ```sh
   docker exec lucos_campaigns_app ls /etc/nginx/conf.d          # only default.conf
   docker exec lucos_campaigns_app grep -c ':1F91' /proc/net/tcp /proc/net/tcp6   # 0 and 0 (port 8081)
   docker port lucos_campaigns_app                               # only 8080
   ```

Nothing here is used by the normal deploy; the override file and `nginx/migration-api.conf` are not in the image.
