# lucos_campaigns

Self-hosted [Kanka](https://github.com/owlchester/kanka) for running TTRPG campaigns, at `campaigns.l42.eu`. The design is [ADR-0001](docs/adr/0001-adopt-self-hosted-kanka.md).

## Shape

Four containers on avalon, on the project's own private network (no shared estate network):

- `lucos_campaigns_app`: Kanka built from a pinned upstream tag (nginx + PHP-FPM, `serversideup/php`).
- `lucos_campaigns_db`: MariaDB.
- `lucos_campaigns_search`: Meilisearch.
- `lucos_campaigns_auth`: oauth2-proxy, gating every request on the `campaigns:use` aithne scope.

`nginx/default.conf` is the only server block. `auth_request` is set at server level, so a new `location` is gated by default; only `= /_info` and `= /favicon.ico` opt out. `test/gate/` runs that config against an oauth2-proxy in CI (redirect when unauthenticated, 5xx when the sidecar is down).

Upstream's Docker/Sail setup is not used anywhere.

## Credentials (lucos_creds)

Production values can only be set by lucas42 and must exist **before the first production deploy**: `APP_KEY` (`base64:` plus 32 random bytes), `DB_PASSWORD`, `DB_ROOT_PASSWORD`, `MEILI_MASTER_KEY`, `OAUTH2_PROXY_COOKIE_SECRET` (32 random bytes, urlsafe base64), and the linked aithne client credential (`KEY_LUCOS_AITHNE`, with `AITHNE_ORIGIN`, `AITHNE_TOKEN_URL`, `AITHNE_JWKS_URL`). `campaigns:use` must also be granted to a principal in aithne.

## First user

1. Deploy with `APP_REGISTRATION_ENABLED=true` in creds. `/register` is only reachable through the gate.
2. Register the account.
3. Set `APP_REGISTRATION_ENABLED` to `false` (or remove it: the default is false), redeploy, and check `POST /register` now returns 404.

Mail is logged (`MAIL_MAILER=log`), so emailed reset links land in `storage/logs` (daily, 7 days). Reset a password with `docker exec lucos_campaigns_app php artisan users:reset-password <user> [password]` instead of the emailed flow.

Each start also runs `docker/60-kanka-first-run.sh`: it seeds Kanka, creates the Passport keys and client, and builds the search index, skipping each step once its own result exists, so a failure part-way is retried on the next start. To force a search rebuild, run `docker exec lucos_campaigns_app php artisan setup:meilisearch`.

## Upgrading Kanka

Change `KANKA_VERSION` **and** `KANKA_COMMIT` in the `Dockerfile` (the build fails if the tag has moved), one release tag at a time in upstream's order, with a database backup first. Migrations run on container start. Dependabot can't see Kanka's releases or its lockfiles; the build prints `composer audit` and `yarn audit` output as an advisory.
