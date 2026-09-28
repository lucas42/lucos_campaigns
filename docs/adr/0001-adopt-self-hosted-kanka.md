# ADR-0001: Adopt self-hosted Kanka, behind an aithne gate, for running campaigns

**Date:** 2026-09-29
**Discussion:** [lucas42/lucos#309](https://github.com/lucas42/lucos/issues/309)

## Context

`lucos_worlds` (BookStack, `lucos_worlds` ADR-0001) holds two tabletop RPG worlds. One,
Arcadia, is a world lucas42 plays in; it works well and stays where it is. The other,
**Kaidoho**, is a campaign lucas42 is about to start running as **DM**. Preparing it has
shown that BookStack's page-based model is too limiting for running a campaign. In
lucas42's words on lucas42/lucos#309, the limitations are:

- relationships between entities;
- fields on entities;
- structured stat blocks;
- a calendar/timeline;
- (later, maybe) maps. For now these are done on paper.

These are the typed-entity features of a purpose-built campaign manager. **Kanka** is
the purpose-built, self-hostable option that was already evaluated in July. It was
rejected then (`lucos_worlds` ADR-0001, *Alternatives considered*) for *"its own auth…,
an unclear licence, and a large PHP app to security-track"*. That rejection was for a
different job: a *player's* single-user record with three fixed types and wikilinks
deferred. The requirement has changed; the objections have to be weighed again, not
waved away.

### What Kanka is, verified against source

Checked against `owlchester/kanka` at tag **3.15** (`79d9517`, 2026-09-07) unless stated
otherwise:

- **Upstream does not support production self-hosting.** `docs/running.md` says its
  Docker setup is *"meant for developers… **Do not use** this docker setup to host Kanka
  on the web!"*. No production image is published. Self-hosted instances get *"No support
  for premium campaigns"* and no FontAwesome PRO icons.
- **Stack:** PHP 8.4, Laravel 13, a Vite front-end build (no private npm registry needed:
  `package.json` has no FontAwesome Pro dependency), MySQL/MariaDB, Laravel Scout with
  Meilisearch. Upstream's dev stack also runs Redis, MinIO, Thumbor, Mailpit and Reverb.
  - **Redis:** nothing calls `Redis::` directly. Cache, queue, session and broadcast are
    all driver-configurable, and `.env.example` itself uses `QUEUE_DRIVER=sync`.
  - **MinIO:** upstream's own doc calls it *"abandoned and having multiple
    vulnerabilities"*. The filesystem default is the local `public` disk
    (`config/filesystems.php`).
  - **Thumbor:** optional. `ImgService` disables it when `thumbor.key` is empty.
  - **Scheduler** (`app/Console/Kernel.php`): almost entirely kanka.io business
    operations (subscriptions, PayPal, free trials, churn and onboarding mail, Discord
    tokens), plus `backup:run` twice daily into local storage. Only `CalendarAdvancer`
    and the trash/log cleanups are relevant to us.
- **Auth:** there is no generic OIDC. `laravel/socialite` is configured only for
  Facebook, Google and Twitter (`config/services.php`). Registration can be turned off
  with `APP_REGISTRATION_ENABLED=false` (`config/auth.php`).
- **Paid-feature gating** is by a per-campaign counter, `campaigns.boost_count`
  (`app/Models/Concerns/Boosted.php`), which only kanka.io's billing sets. Against
  lucas42's four needs (checked on `develop` at `c700f46`, then re-checked at the pinned
  3.15 tag, with the same result):
  - **Relationships:** available. Only the visual relations graph is gated.
  - **Fields on entities:** available. Attributes work, and so do *local* attribute
    templates: the integer-ID path in `Attributes/TemplateService::apply` has no gate.
  - **Calendar / timeline:** available. Only cosmetic extras are gated.
  - **Structured stat blocks:** stored as templated attributes. The **formatted** layout
    (marketplace character sheets) needs a boosted campaign and kanka.io's marketplace,
    and campaign custom CSS is gated too. lucas42 chose to accept the attribute list for
    now, with our own CSS as a later follow-up.
- **Licence:** `LICENSE` contains only the **Commons Clause** condition (no right to
  *Sell*) and names no underlying licence (GitHub reports `NOASSERTION`). Personal,
  non-commercial self-hosting is not "selling", so the restriction doesn't apply to us,
  but the underlying grant is not stated.
- **Upgrades:** roughly monthly releases with database migrations. `docs/updating.md`
  recommends stepping through **every tag in order**, with a backup first.
- **API:** `routes/api.v1.php` exposes characters, locations, notes, posts, entity types,
  attributes and more. That is enough for a scripted migration.

### Estate constraints

- `lucos_aithne` signs ID tokens **ES256 only** (see `lucos_worlds` ADR-0002). The estate
  already runs the **sidecar pattern** for adopted apps with no usable OIDC: oauth2-proxy
  plus nginx `auth_request`, in `lucos_locations`. That compose file already sets
  `OAUTH2_PROXY_OIDC_ENABLED_SIGNING_ALGS=ES256` and gates on an aithne scope.
- The only HTTP-serving host with room is **avalon** (x86_64, 4 cores, ~7 GB RAM, ~3 GB
  available on 2026-09-29, ~57 containers). It already hosts `lucos_worlds`,
  `lucos_locations` and `lucos_aithne`.
- **Timing:** lucas42 starts running Kaidoho in the week of 2026-10-05. `lucos_worlds` is
  the fallback if this system isn't ready. Nothing is to be deleted from `lucos_worlds`
  until lucas42 is confident in Kanka.

## Decision

Create a new system, **`lucos_campaigns`**, that self-hosts Kanka for running campaigns,
starting with Kaidoho.

1. **Adopt Kanka, pinned to a release tag, built into our own image.**
   `lucas42/lucos_campaigns_app` is built from source at a pinned Kanka tag, starting at
   **3.15**. The Dockerfile has an `ARG KANKA_VERSION` and does a multi-stage build:
   `git clone --branch` the tag, `composer install --no-dev --optimize-autoloader`, and
   `yarn install && yarn build` for the Vite assets. The runtime stage is based on
   **`serversideup/php:8.4-fpm-nginx-v4.5.1`** (the latest stable tag on 2026-09-29; v5 is still in beta): a
   production-oriented Laravel base that runs nginx and PHP-FPM together, unprivileged,
   with process supervision included. That gives us the production packaging upstream
   doesn't provide, without writing our own supervisor setup.

2. **Run the smallest service set that serves the four features.** The containers are
   `lucos_campaigns_app` (nginx + PHP-FPM), `lucos_campaigns_db` (MariaDB, pinned),
   `lucos_campaigns_search` (Meilisearch v1.x, pinned) and `lucos_campaigns_auth`
   (oauth2-proxy). They run with:
   - `QUEUE_DRIVER=sync`, `CACHE_DRIVER=file`, `SESSION_DRIVER=database`,
     `BROADCAST_DRIVER=null`, `MAIL_MAILER=log`, `FILESYSTEM_DRIVER=public`;
   - Thumbor disabled (empty `THUMBOR_KEY`);
   - the marketplace disabled (`APP_MARKETPLACE_URL` unset).

   **No Redis, no MinIO, no Thumbor, no Reverb, no queue worker, no scheduler.** If
   running without Redis turns out to break something, the fallback is a Redis container
   with no volume, since everything Redis would hold is cache or ephemeral. That fallback
   is decided here so the scaffold doesn't stall on it.

3. **Authentication: an aithne gate in front, Kanka's own account behind it.**
   - nginx in the app container sends every request through `auth_request` to the
     oauth2-proxy sidecar. The sidecar's config is copied from `lucos_locations`,
     including `OAUTH2_PROXY_OIDC_ENABLED_SIGNING_ALGS=ES256`, the explicit
     `OAUTH2_PROXY_SCOPE` and the groups-claim settings.
   - It is gated on a new **`campaigns:use`** scope in `lucos_auth_scopes`, following the
     `<domain>:use` pattern that `notes:use` and `photos:use` set.
   - Kanka keeps its own single account, with **`APP_REGISTRATION_ENABLED=false`** once
     lucas42's account exists. Until then, registration is reachable only through the
     aithne gate.
   - The double login is accepted by lucas42 (decision 4 on lucas42/lucos#309) and may be
     revisited.
   - No path, including Kanka's `/api`, bypasses the gate.
   - **The domain is not routed until the gate is in place.** Kanka's install must never
     be reachable from the internet ungated, even briefly.

4. **Storage and backups.**
   - Two named volumes hold data we can't regenerate: the **MariaDB data** volume and the
     **Kanka storage** volume (uploads on the `public` disk, plus Passport's OAuth keys
     from `passport:install`). Both are registered in `lucos_configy` and backed up.
   - Meilisearch's volume is **rebuildable** (via `artisan setup:meilisearch` and a
     re-import) and is not backed up.
   - The MariaDB volume is registered the same way as `lucos_worlds_db_data` (`recreate_effort: huge`), so the estate's second MariaDB gets the same backup treatment as its first. No new procedure.

5. **Upgrades are manual, one release tag at a time.** We move to a new Kanka release by
   changing `KANKA_VERSION` one tag at a time, in the order upstream asks, with a
   database backup before each step. Migrations run on container start. Dependabot can
   see the base images but **not** Kanka's release tag, so noticing that a release exists
   is deferred work.

6. **Migrate Kaidoho by script, once, re-runnably.** A one-shot script in this repo reads
   the Kaidoho book through BookStack's API and writes a new Kanka campaign through
   Kanka's API.
   - Kaidoho's chapters (types, per `lucos_worlds` ADR-0004) map to Kanka entity types:
     PCs and NPCs become Characters, Places become Locations, everything else becomes
     Notes. The mapping is confirmed against the book's actual chapter list first.
   - Page HTML becomes each entity's entry, with internal links rewritten as Kanka
     mentions, and images are re-uploaded.
   - NPC stat blocks are carried across as page content. Turning them into
     attribute-template data is a separate, manual step lucas42 controls.
   - The script targets an empty campaign, so a bad run is thrown away and repeated. It
     runs **inside the compose network** (a one-off container talking to the app
     directly), not through the public gate. That is why decision 3 can allow no
     exceptions.
   - **Kaidoho stays in `lucos_worlds`.** After cutover, its book is made **view-only**
     there rather than deleted, so the two copies can't quietly drift apart.

7. **Monitoring.** Kanka serves no `/_info`. Until that is addressed (deferred work), the
   system is registered in `lucos_configy` like any other, and its monitoring gap is
   explicit, not accidental.

## Consequences

### Positive

- lucas42 gets relationships, typed fields with reusable templates, calendars and
  timelines, all verified available without paid features, on data we host (MariaDB
  plus files, encrypted with nobody else's key).
- No patch to Kanka's authentication code. The ES256 problem that forced
  `lucos_worlds` ADR-0002 doesn't arise, because oauth2-proxy already handles ES256 in
  production.
- The public attack surface is limited to oauth2-proxy until aithne has authenticated
  someone. That matters more than usual for an app whose own developers say not to
  expose it to the web.
- Four containers rather than upstream's nine.

### Negative / trade-offs

- **We are the production packager of an app upstream doesn't support in production.**
  Any self-hosting breakage is ours to diagnose. We can expect only *"limited support…
  on Discord"*.
- **The heaviest upgrade burden in the estate for its size.** Monthly releases, each
  applied in order with a backup first, with nothing automatic telling us one exists
  (see Deferred work). This is the July objection, and it has got worse since then, not
  better.
- **The licence is ambiguous.** Commons Clause with no named base licence. Fine for
  personal use, but recorded because it is not the clean position `lucos_worlds` had
  with MIT.
- **We deliberately run without upstream's supporting services.** The sync queue, file
  cache, no scheduler and no Thumbor are all configurations upstream doesn't exercise.
  Slow requests (sync search indexing), untrimmed trash and a calendar that doesn't
  auto-advance are expected. Anything worse gets handled as it is found.
- **Structured stat blocks are data, not a formatted layout.** Rendering them properly is
  deferred, and campaign CSS isn't available to us, so it will mean CSS baked into our
  image: a small patch that breaks quietly when upstream markup changes.
- **Double login**, as accepted.
- **Monitoring blind spot:** a sidecar in front of an app can't be seen by the app's own
  health checks. This is the lesson from incident lucas42/lucos#265, now applied to a
  second system.
- **avalon's memory headroom shrinks.** PHP-FPM, a second MariaDB and Meilisearch
  together are plausibly 0.7–1.2 GB on ~3 GB free. That is an estimate, not a
  measurement. Meilisearch indexing memory should be capped.
- **Two copies of Kaidoho exist for a while.** Mitigated by making the `lucos_worlds`
  copy view-only.

## Alternatives considered

- **Stay on BookStack.** It can't provide relationships, typed fields or calendars
  without building a campaign manager inside a wiki. Rejected for Kaidoho; kept for
  Arcadia.
- **kanka.io (hosted).** The fastest route, with premium features available for payment.
  It breaks the data-control requirement set for `lucos_worlds` (self-hosted, no foreign
  keys). lucas42 chose self-hosting.
- **Patch an OIDC client into Kanka** (the `lucos_worlds` ADR-0002 pattern). It would
  remove the double login. It would also mean owning a patch to authentication code in an
  app that releases monthly and that we already have to step through tag by tag.
  Rejected for now, and open to revisiting if the double login grates.
- **Upstream's Sail dev stack as-is.** Upstream explicitly calls it insecure
  (*"0 security"*) and it depends on an abandoned MinIO.
- **Official `php:8.4-fpm` plus our own nginx and supervisor.** More boring, but it is
  exactly the process-supervision work `serversideup/php` already does well, and it would
  land on this week's critical path. Worth revisiting if that base image ever becomes a
  liability.
- **Unlock paid features by setting `boost_count`.** It is unsupported, turns on code
  that expects kanka.io's services, still leaves the marketplace missing, and works round
  the product's paid tier. Rejected.
- **Scout without Meilisearch** (a database driver). `EntitySearchService` constructs a `Meilisearch\Client`
  directly, bypassing Scout, so switching the Scout driver wouldn't cover it. Rejected for now.

## Deferred work

- Stat-block presentation CSS in the wrapper image: #6
- A `/_info` endpoint and monitoring integration: #4
- Noticing new Kanka releases (Dependabot can't see the source tag): #5
- Make Kaidoho view-only in `lucos_worlds` after cutover: lucas42/lucos_worlds#94
