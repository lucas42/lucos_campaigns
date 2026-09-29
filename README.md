# lucos_campaigns

Self-hosted [Kanka](https://github.com/owlchester/kanka) for running TTRPG campaigns. The design is [ADR-0001](docs/adr/0001-adopt-self-hosted-kanka.md).

## Shape

Four containers on avalon, on the project's own private network (no shared estate network):

- `lucos_campaigns_app`: Kanka built from a pinned upstream tag (nginx + PHP-FPM, `serversideup/php`).
- `lucos_campaigns_db`: MariaDB.
- `lucos_campaigns_search`: Meilisearch.
- `lucos_campaigns_auth`: oauth2-proxy, gating every request on the `campaigns:use` aithne scope.

`nginx/default.conf` is the only server block. `auth_request` is set at server level, so a new `location` is gated by default; only `= /_info` and `= /favicon.ico` opt out. `test/gate/` runs that config against an oauth2-proxy in CI (redirect when unauthenticated, 5xx when the sidecar is down). `test/full/` runs the real image with its sidecars and checks `/_info` (`docker/_info.php`, which boots Kanka in-process and checks the app, MariaDB, Meilisearch and the oauth2-proxy).

Upstream's Docker/Sail setup is not used anywhere.

## Credentials (lucos_creds)

These must all exist in `lucos_creds` for the environment **before that environment's first deploy**. `PORT`, `APP_ORIGIN` and the other standard variables are provided by `lucos_creds` automatically.

Randomly generated secrets, specific to this system:

- `APP_KEY`: `base64:` followed by 32 random bytes, base64-encoded. Encrypts Kanka's sessions and other encrypted data, so changing it later invalidates them.
- `DB_PASSWORD`: the MariaDB password for Kanka's database user.
- `DB_ROOT_PASSWORD`: the MariaDB root password.
- `MEILI_MASTER_KEY`: shared by Meilisearch and Kanka's search client.
- `OAUTH2_PROXY_COOKIE_SECRET`: 16, 24 or 32 random bytes (raw, or urlsafe-base64-encoded). Signs the oauth2-proxy session cookie.

Values that refer to aithne, which provides login:

- `KEY_LUCOS_AITHNE`: the client secret for this system's aithne client, supplied by the linked credential from `lucos_aithne`.
- `AITHNE_ORIGIN`: aithne's browser-facing origin. It differs per environment, so set it for each one.

Users also need the `campaigns:use` scope granted in aithne to get past the gate.

Optional:

- `APP_REGISTRATION_ENABLED` (default `false`), only used during [first user](#first-user) setup.
- `AITHNE_TOKEN_URL` and `AITHNE_JWKS_URL`: the addresses oauth2-proxy uses to call aithne from inside its container. They default to paths under `AITHNE_ORIGIN`, so leave them unset unless the container can't reach that origin (in development, where `AITHNE_ORIGIN` is `localhost`).

## First user

1. Deploy with `APP_REGISTRATION_ENABLED=true` in creds. `/register` is only reachable through the gate.
2. Register the account.
3. Set `APP_REGISTRATION_ENABLED` to `false` (or remove it: the default is false), redeploy, and check `POST /register` now returns 404.

Mail is logged (`MAIL_DRIVER=log`; Kanka reads that legacy name, not `MAIL_MAILER`), so emailed reset links land in `storage/logs` (daily, 7 days). Reset a password with `docker exec lucos_campaigns_app php artisan users:reset-password <user> [password]` instead of the emailed flow.

Each start also runs `docker/60-kanka-first-run.sh`: it seeds Kanka, creates the Passport keys and client, and builds the search index, skipping each step once its own result exists, so a failure part-way is retried on the next start. To force a search rebuild, run `docker exec lucos_campaigns_app php artisan setup:meilisearch`.

## Migrating Kaidoho

One-off, run on lucas42's own machine through the normal gate; nothing is added to avalon: see [`migration/README.md`](migration/README.md).

## Icons

Kanka's UI is written for Font Awesome Pro, but without a Pro kit (`FONTAWESOME_KIT`) it loads only the bundled Free 6.0.0, which has few regular icons and no light, thin or duotone ones. Most icons would render blank. `docker/fontawesome-free-fallback.css` is appended to that bundled stylesheet in the `Dockerfile`: missing icons fall back to Free solid, and seven Pro-only module icons have Free stand-ins. The build fails if Kanka moves the stylesheet. Setting a kit turns the fallback off. When you pick an icon in Kanka (tags, links, timeline elements, bookmarks), its picker links to Font Awesome's full catalogue, so choose a **Free** icon or it will render blank.

## Upgrading Kanka

Change `KANKA_VERSION` **and** `KANKA_COMMIT` in the `Dockerfile` (the build fails if the tag has moved), one release tag at a time in upstream's order, with a database backup first. Migrations run on container start. Dependabot can't see Kanka's releases or its lockfiles; the build prints `composer audit` and `yarn audit` output as an advisory.
