# ADR-0002: Run the Kaidoho migration from lucas42's machine, through the aithne gate

**Date:** 2026-09-29
**Discussion:** [lucas42/lucos_campaigns#3](https://github.com/lucas42/lucos_campaigns/issues/3)
**Supersedes:** [ADR-0001](0001-adopt-self-hosted-kanka.md) decision 6, in part: its "How it reaches Kanka's API" mechanism

## Context

ADR-0001 decision 6 migrates Kaidoho from `lucos_worlds` (BookStack) into Kanka with a
one-shot script. Kanka's nginx has `auth_request` to the oauth2-proxy sidecar at server
level (decision 3), so a script can't reach `/api` without getting through the aithne gate.
Decision 6 dealt with that on the production host:

- a fresh clone of this repo on avalon;
- a migration-only compose override that recreated the production app with an extra,
  **ungated** nginx server block serving `/api` on an unpublished port;
- the script running as a one-off container on the project-private network;
- a redeploy from the shipped configuration afterwards, then a check that the listener had
  gone.

Its safety rested on the project's compose network staying private for the length of the
run.

When the runbook reached him, lucas42 rejected it: he won't run a procedure like that in
production. It checks out a repository and starts ad-hoc containers on a production host,
recreates the production app twice, and leaves things behind that need cleaning up, and a
clean-up script afterwards doesn't answer that. He asked for the script to run on his own
machine instead, with an SSH tunnel only if one was genuinely needed.

What was verified while redesigning, in lucas42/lucos_campaigns#3:

- **BookStack needs no special access.** Its API is public with token auth, and
  production stores images with `STORAGE_TYPE=local`, so `/uploads/...` downloads need no
  session.
- **An SSH tunnel wouldn't help.** It would only reach the same gated nginx.
- **The gate cookie and Kanka's API token don't conflict.** In oauth2-proxy v7.15.4
  (`buildSessionChain`), the bearer-token session loader is only added when
  `skip_jwt_bearer_tokens` is set, and basic auth only with an htpasswd file. We set
  neither, so the gate ignores `Authorization` and decides on the session cookie alone.
  Kanka's Passport token can use that header undisturbed.
- **Gate sessions last 15 minutes.** aithne's `DefaultSessionTTL` is 15 minutes and it
  issues no refresh token. oauth2-proxy's OIDC `createSession` sets the session's
  `ExpiresOn` from the token's expiry, and `validateSession` rejects an expired session.
- **Kanka's API is limited to 30 requests a minute** for a non-subscriber
  (`limits.api.throttle.default`), so a run takes roughly N/15 minutes for a book of N
  pages.

## Decision

1. **The migration runs on lucas42's own machine and changes nothing on the production
   host.** No clone, no containers, no compose override, no app recreation and no SSH
   tunnel. The script talks only to the two public HTTPS origins, `https://worlds.l42.eu`
   and `https://campaigns.l42.eu`, which are module constants with no flag or environment
   override.
2. **Kanka's API is reached through the unchanged aithne gate.** Every Kanka request
   carries two credentials:
   - lucas42's browser gate session cookie. Only cookies matching
     `^_oauth2_proxy(_\d+)?$` are kept, held in the session's cookie jar so any cookie the
     gate rotates is picked up.
   - His Kanka personal access token, in `Authorization: Bearer`.
3. **Gate expiry is detected by redirect, and only by redirect.** Redirects are never
   followed (`allow_redirects=False` everywhere), so the token can't be carried to aithne.
   A 3xx from Kanka means the gate refused the request: the script prompts for a fresh
   cookie and sends the same request again.
   - That retry is safe even for writes, because the gate rejects before Kanka sees the
     request.
   - Every other failure is an error and is **never resent**. That includes a non-JSON
     401/403, an HTML 5xx or 413, or a 200 HTML page.
   - lucas42/lucos_campaigns#3 originally said "a 3xx or any non-JSON response". It was
     narrowed in review, with lucos-security's agreement. A non-JSON error comes from
     *behind* the gate (nginx or PHP-FPM while the app restarts, or a timeout), so the
     write may already have happened, and resending it could duplicate it. The gate itself
     always answers with a redirect.
4. **Preflight before anything is written.** The script sends the token with no cookie and
   requires a gate redirect. That checks empirically, against the live gate, that the gate
   doesn't honour the `Authorization` header, rather than relying on a reading of the
   source.
5. **Secrets are entered with `getpass`, and only there:** the gate cookie, the Kanka token
   and the BookStack token id and secret. Never argv, environment variables or files, and
   never printed. Dependencies are hash-pinned (`migration/requirements.txt`).
6. **The migration-only compose override and ungated nginx block are deleted from the
   repo.** Kanka's `/api` is gated in every configuration this repo contains.

Everything else in decision 6 stands: the script targets an empty campaign and refuses one
that has entities, the chapter-to-type mapping is confirmed with lucas42, losses are
reported rather than dropped, and Kaidoho goes view-only in `lucos_worlds` after cutover.

## Consequences

### Positive

- **`/api` is never ungated, at any point.** Decision 6 needed a window with an ungated
  listener, whose safety rested on the compose network staying project-private. That
  argument, and its standing caveat about shared networks, no longer applies to the
  migration. ADR-0001's line that keeping `/api` gated means decision 3 needs no exception
  now holds without a carve-out.
- **Nothing to clean up on the production host.** No redeploy is needed to remove a
  listener, and there's no check afterwards that it has gone.
- The script exercises the same gate path as a real user, including the `campaigns:use`
  group check. The preflight tests the one property the design depends on.

### Negative

- **The run needs lucas42 at the keyboard.** He pastes a fresh cookie roughly every 15
  minutes. At 30 requests a minute and about 2 calls per page plus about 2 per image, a
  300-page book takes about 20 minutes, so one or two prompts. A much longer book would
  make this tedious. The script has no resume mode: a run that dies part-way is recovered
  by emptying the campaign and running again.
- **Credentials now live on a laptop and cross the internet.** The Kanka token and the
  BookStack token sit in process memory on lucas42's machine. The Kanka token travels over
  TLS to the pinned origin. The token was already a full-account credential under the old
  design. Both are revoked after the final run.
- **A copied gate cookie is a bearer credential** until it expires. It's the same as his
  browser session and dies within 15 minutes.
- **The run depends on the live gate's behaviour.** If the gate ever started honouring
  `Authorization` (for example if `skip_jwt_bearer_tokens` were enabled), the preflight
  would stop the run before any write. So the failure is loud rather than silent, but the
  migration is then blocked until the design is revisited.
- The 15-minute session also affects normal browser use. That's tracked separately in
  lucas42/lucos_campaigns#29, and this decision doesn't depend on it.

## Alternatives considered

- **ADR-0001's on-host mechanism** (override file, ungated unpublished listener, one-off
  container). Rejected by lucas42: ad-hoc repository checkouts and containers on a
  production host, recreation of the production app, and things left behind.
- **The same mechanism, with a clean-up script.** Rejected by lucas42 in advance: it adds
  to what runs in production instead of removing it.
- **An SSH tunnel to the app.** It gains nothing, because it reaches the same gated nginx.
  An ungated listener for the tunnel to reach would bring back the thing this decision
  removes.
- **Exempting `/api` from the gate** (for example oauth2-proxy `skip_auth_routes`) and
  relying on Kanka's own token auth. It would permanently put Kanka's API authentication
  on the internet, which is what ADR-0001 decision 3 exists to prevent.
- **Enabling `skip_jwt_bearer_tokens` and presenting an aithne token.** Both credentials
  would then need the same `Authorization` header as Kanka's Passport token, and
  separating them would mean nginx changes to the gate. That's more gate surface for a
  one-off run.
- **Raising `API_THROTTLE_LIMIT`** to fit the run inside one 15-minute session. It's not
  needed, because the re-prompt makes run length irrelevant. It remains an option if the
  book turns out large, as an ordinary deployed config change.
