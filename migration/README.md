# Kaidoho migration (BookStack → Kanka)

One-shot, re-runnable copy of the Kaidoho book from `lucos_worlds` into an **empty** Kanka campaign. It runs **on lucas42's own machine** against both systems' public HTTPS origins (`https://worlds.l42.eu`, `https://campaigns.l42.eu`). **Nothing is added to or changed on avalon.** `lucos_worlds` is only read, never modified. Design: the approved proposal on lucas42/lucos_campaigns#3 (it replaces the on-avalon mechanism in ADR-0001 decision 6).

## What it does

- Chapter → Kanka type, per `CHAPTER_TYPES` in `migrate_kaidoho.py` (agreed on lucas42/lucos_campaigns#3): People/Player Characters/Religon → Characters, Monsters → Creatures, Organisations/Military → Organisations, the place chapters → Locations, Session Notes → Journals, History/Culture → Notes. Templates is skipped. Each entity's Kanka `type` label is its chapter name (Religon is relabelled Religion). Loose pages and any unlisted chapter become Notes and are reported.
- Page HTML becomes the entity entry. Internal links (`/books/<book>/page/<slug>` and `/link/<id>`) become Kanka mentions; links to chapters/books, skipped pages or missing pages stay as plain links and are reported.
- Inline images are downloaded and re-uploaded via the entity-image endpoint (the gallery API writes to an S3 disk this stack doesn't have), so they are served from `/storage` behind the gate.
- After each save the script compares `<details>`/`<summary>`/`<table>` counts in the source and in what Kanka stored, and reports any loss (ADR-0005 stat blocks). Attachments can't be created through Kanka's API and are reported. Both end up in `kaidoho-migration-report.md` in the working directory.
- Refuses to run against a campaign that already has entities.

## How it authenticates

- **BookStack:** an API token belonging to a dedicated read-only BookStack user.
- **Kanka:** every request carries your **aithne gate session cookie** (copied from your browser) **and** your Kanka personal access token in `Authorization: Bearer`. The gate decides on the cookie alone and ignores the header, so the two don't conflict. Before doing anything else, a real run checks this: it sends the token with **no** cookie and aborts unless the gate redirects.
- Everything is typed at a hidden prompt (`getpass`): never an argument, environment variable or file, and never printed. Only the `_oauth2_proxy`/`_oauth2_proxy_0`/`_oauth2_proxy_1` cookies are kept from what you paste; the rest of the Cookie header is discarded.
- Redirects are never followed. A redirect or a non-JSON response from Kanka means the gate turned the request away, and the script asks for a fresh cookie and retries the same call (safe even for writes: the gate rejects before Kanka sees the request).
- The Kanka and BookStack hosts are fixed in the script; there is no URL flag.

## Before you run it

1. In the BookStack at worlds.l42.eu: a dedicated **read-only** user (a role with only "Access System API" plus View on the Kaidoho book) with an API token. Tokens inherit the user's permissions.
2. At campaigns.l42.eu: create the **empty** campaign (its id is in the URL, `/w/<id>/`) and a personal access token (Settings → API).
3. Have your browser logged in to campaigns.l42.eu with devtools open, so you can copy the `Cookie` request header from any request.

## Run

Needs Python 3.12+ (or Docker). From this directory:

```sh
python3 -m venv /tmp/kaidoho-venv && . /tmp/kaidoho-venv/bin/activate
pip install --require-hashes -r requirements.txt

python3 migrate_kaidoho.py --dry-run             # prompts for the BookStack token only; prints the mapping and the page count N
python3 migrate_kaidoho.py --campaign <id>       # the real run
```

Or with Docker: `docker build -t kaidoho-migration . && docker run -it --rm -v "$PWD:/out" kaidoho-migration --campaign <id>` (`-it` is needed for the hidden prompts).

The dry run prints the chapter → type mapping and N, and writes nothing. Kanka's API allows 30 requests a minute, about 2 calls per page plus about 2 per image, so expect roughly N/15 minutes. **Gate sessions last 15 minutes** (aithne issues no refresh token), so the script will stop and ask for a fresh cookie about that often: refresh campaigns.l42.eu in your browser, copy the Cookie header again, paste it.

## If a run fails part-way

Delete the campaign's entities (or create a new empty campaign) and run again. There is no resume mode.

## Afterwards

1. **Revoke** the Kanka token, and revoke the BookStack token and delete its user.
2. **Delete the secrets placed on avalon earlier**: `rm -r ~/.campaigns-migration-secrets` in lucas42's home directory there. This design doesn't use them.
3. Read `kaidoho-migration-report.md` for anything that didn't transfer cleanly.

## Tests

`python -m unittest -v` in this directory (run in CI): the redirect-as-expiry path, the retry, the cookie filter and the preflight, against a local stand-in for the gate.
