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

- `APP_KEY`: `base64:` followed by 32 random bytes, base64-encoded: `echo "base64:$(openssl rand -base64 32)"`. Encrypts Kanka's sessions and other encrypted data, so changing it later invalidates them. The container refuses to start if it isn't exactly that shape.
- `DB_PASSWORD`: the MariaDB password for Kanka's database user.
- `DB_ROOT_PASSWORD`: the MariaDB root password.
- `MEILI_MASTER_KEY`: shared by Meilisearch and Kanka's search client.
- `OAUTH2_PROXY_COOKIE_SECRET`: 16, 24 or 32 random bytes (raw, or urlsafe-base64-encoded). Signs the oauth2-proxy session cookie.

Values that refer to aithne, which provides login:

- `KEY_LUCOS_AITHNE`: the client secret for this system's aithne client, supplied by the linked credential from `lucos_aithne`.
- `AITHNE_ORIGIN`: aithne's browser-facing origin. It differs per environment, so set it for each one.

Users also need the `campaigns:use` scope granted in aithne to get past the gate.

Optional:

- `MAIL_DRIVER` (default `log`) and `MAIL_PASSWORD`: set `MAIL_DRIVER=smtp` and the `campaigns@l42.eu` password in **production only**. The matching SMTP account is a line in lucos_mail's `DOVECOT_USERS`.
- `APP_REGISTRATION_ENABLED` (default `false`), only used during [first user](#first-user) setup.
- `AITHNE_TOKEN_URL` and `AITHNE_JWKS_URL`: the addresses oauth2-proxy uses to call aithne from inside its container. They default to paths under `AITHNE_ORIGIN`, so leave them unset unless the container can't reach that origin (in development, where `AITHNE_ORIGIN` is `localhost`).

## First user

1. Deploy with `APP_REGISTRATION_ENABLED=true` in creds. `/register` is only reachable through the gate.
2. Register the account.
3. Set `APP_REGISTRATION_ENABLED` to `false` (or remove it: the default is false), redeploy, and check `POST /register` now returns 404.

Production sends Kanka's mail through lucos_mail as `campaigns@l42.eu` (`MAIL_DRIVER=smtp` and `MAIL_PASSWORD` in creds; port 25, and the `Dockerfile` makes Kanka verify the certificate and require TLS). Anywhere `MAIL_DRIVER` isn't set, including development, it defaults to `log`: mail goes to `storage/logs` (daily, 7 days) and nothing is sent. Kanka reads `MAIL_DRIVER`, not `MAIL_MAILER`. `docker exec lucos_campaigns_app php artisan users:reset-password <user> [password]` still resets a password without the emailed flow.

Each start also runs `docker/60-kanka-first-run.sh`: it seeds Kanka, creates the Passport keys and client, and builds the search index, skipping each step once its own result exists, so a failure part-way is retried on the next start. To force a search rebuild, run `docker exec lucos_campaigns_app php artisan setup:meilisearch`.

## If Save does nothing

If Save does nothing, open Campaigns in another tab, then click Save again. Don't reload the edit page, or the unsaved text is lost.

## Migrating Kaidoho

One-off, run on lucas42's own machine through the normal gate; nothing is added to avalon: see [`migration/README.md`](migration/README.md).

## Icons

Kanka's UI is written for Font Awesome Pro, but without a Pro kit (`FONTAWESOME_KIT`) it loads only the bundled Free 6.0.0, which has few regular icons and no light, thin or duotone ones. Most icons would render blank. `docker/fontawesome-free-fallback.css` is appended to that bundled stylesheet in the `Dockerfile`: missing icons fall back to Free solid, and seven Pro-only module icons have Free stand-ins. The build fails if Kanka moves the stylesheet. Setting a kit turns the fallback off. When you pick an icon in Kanka (tags, links, timeline elements, bookmarks), its picker links to Font Awesome's full catalogue, so choose a **Free** icon or it will render blank.

The `Dockerfile` also patches Kanka's command search (the top-bar `command-center`) to skip the plugins page while the marketplace is off; without it `GET /w/{campaign}/search/command` returns a 500 because the plugins route isn't registered. The build fails if Kanka changes that code, so drop the patch once upstream fixes it.

It also widens the hover-tooltip tag allow-list (`config/purify.php`) to keep list markup. Without it, `ul`/`li`/`em` are stripped and the tooltip's flex-column container puts every mention inside a list on its own line. The build fails if that list changes upstream.

The Relations table's "Location" column is patched too: upstream looks the location up by the target's `entity_id`, so non-location targets showed an unrelated location. It now lists the target's real locations (`entity_locations`). The build fails if the patched lines change upstream.

The overview sidebar's pinned properties are styled as a stat block by `docker/lucos-statblock.css`, built into Kanka's `app.css` in the `Dockerfile`'s `assets` stage. It keys on property names (`data-attribute`) from the "Commoner" property kit and only applies to a sidebar that has a `STR mod` property, so each score and its modifier share one line, and the whole pins box gets a frame and a title bar in Kanka's theme colour. Other entities look as upstream. The same step fixes the hover pencil on pinned properties: upstream draws it in `"Font Awesome 6 Pro"`, so without a kit it showed as an empty box; `"Font Awesome 6 Free"` is now its fallback. The build fails if any markup or CSS this relies on moves, or the built stylesheet lacks either change. Renaming a kit property just drops that row back to the plain list.

## Upgrading Kanka

A daily workflow, `.github/workflows/kanka-upstream-watch.yml`, opens one issue per upstream release: always the **next** release after the pinned one, never the latest. That issue carries the upgrade checklist and the backup and rollback commands, so follow it rather than bumping `KANKA_VERSION` by hand. The workflow also keeps a single issue open while the pinned Kanka has upstream security findings that aren't listed in `.github/upstream-audit-accepted.txt` (each entry there needs a reason). Its logic is tested by `.github/scripts/test-kanka-watch.sh`, which runs in CI whenever those files change.
