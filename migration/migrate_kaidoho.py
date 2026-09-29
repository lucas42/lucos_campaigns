#!/usr/bin/env python3
"""One-shot, re-runnable migration of a BookStack book into an empty Kanka campaign.

See migration/README.md and ADR-0001 decision 6. Reads BookStack, writes Kanka, never modifies BookStack.
"""
import argparse
import html
import json
import os
import re
import sys
import time
from urllib.parse import unquote, urlparse

import requests

# BookStack chapter -> (Kanka type, label for Kanka's free-text `type` field; None keeps the chapter name).
# Matched case-insensitively on the exact chapter name. SKIP chapters are not migrated (and are reported).
# Loose pages and any chapter not listed become Notes labelled with the chapter name (and are reported).
SKIP = "skip"
CHAPTER_TYPES = {
    "Player Characters": ("character", None),
    "People": ("character", None),
    "Religon": ("character", "Religion"),  # source spelling; most entries are gods
    "Monsters": ("creature", None),
    "Organisations": ("organisation", None),
    "Military": ("organisation", None),
    "Regions": ("location", None),
    "Settlements": ("location", None),
    "Neighbourhoods": ("location", None),
    "Buildings": ("location", None),
    "Natural Geography": ("location", None),
    "Infrastructure": ("location", None),
    "Session Notes": ("journal", None),
    "History": ("note", None),
    "Culture": ("note", None),
    "Templates": (SKIP, None),
}
KANKA_ENDPOINT = {"character": "characters", "location": "locations", "note": "notes", "creature": "creatures",
                  "organisation": "organisations", "journal": "journals"}
PRESERVED_TAGS = ("details", "summary", "table")


def secret(name):
    path = os.path.join(os.environ.get("SECRETS_DIR", "/run/secrets"), name)
    with open(path) as f:
        return f.read().strip()


class Api:
    def __init__(self, base, headers):
        self.base = base.rstrip("/")
        self.s = requests.Session()
        self.s.headers.update(headers)

    def call(self, method, path, **kw):
        url = path if path.startswith("http") else self.base + path
        for _ in range(8):
            r = self.s.request(method, url, timeout=120, **kw)
            if r.status_code == 429:
                time.sleep(int(r.headers.get("Retry-After", "30")) + 1)
                continue
            if r.status_code >= 400:
                raise RuntimeError(f"{method} {url} -> {r.status_code}: {r.text[:500]}")
            return r
        raise RuntimeError(f"{method} {url}: still rate limited after retries")

    def json(self, method, path, **kw):
        return self.call(method, path, **kw).json()


def mapping_for(chapter_name):
    """(kanka type or SKIP, type label, is_listed). Loose pages are Notes; unlisted chapters are Notes labelled with the chapter."""
    if chapter_name is None:
        return "note", None, True
    listed = {k.lower(): v for k, v in CHAPTER_TYPES.items()}.get(chapter_name.strip().lower())
    if listed is None:
        return "note", chapter_name, False
    return listed[0], listed[1] or chapter_name, True


def fetch_book(bs, book_name):
    books = bs.json("GET", "/api/books", params={"filter[name]": book_name, "count": 100})["data"]
    if len(books) != 1:
        raise SystemExit(f"Expected exactly one book named {book_name!r}, found {len(books)}: {[b['name'] for b in books]}")
    book = bs.json("GET", f"/api/books/{books[0]['id']}")
    pages = []
    for item in book["contents"]:
        if item["type"] == "chapter":
            for p in item.get("pages", []):
                pages.append((item["name"], p["id"]))
        else:
            pages.append((None, item["id"]))
    return book, pages


def load_pages(bs, page_refs):
    out = []
    for chapter, pid in page_refs:
        p = bs.json("GET", f"/api/pages/{pid}")
        atts = bs.json("GET", "/api/attachments", params={"filter[uploaded_to]": pid, "count": 100})["data"]
        out.append({
            "bs_id": p["id"], "name": p["name"], "slug": p["slug"],
            "chapter": chapter, "html": p.get("html") or "", "attachments": [a["name"] for a in atts],
            "kind": mapping_for(chapter)[0], "label": mapping_for(chapter)[1],
        })
    return out


LINK_RE = re.compile(r'<a\b[^>]*?\bhref="([^"]*)"[^>]*>(.*?)</a>', re.S | re.I)
IMG_RE = re.compile(r'<img\b[^>]*?\bsrc="([^"]*)"[^>]*>', re.S | re.I)
TAG_RE = re.compile(r"<[^>]+>")


def plain(s):
    return re.sub(r"[\[\]|]", "", html.unescape(TAG_RE.sub("", s))).strip()


def internal_path(url):
    """Path of a BookStack-internal URL, or None for an external one (any host serving BookStack paths counts)."""
    path = unquote(urlparse(url).path)
    if re.match(r"^/(books|link|uploads)/", path):
        host = urlparse(url).netloc
        return path if (not host or host in INTERNAL_HOSTS) else None
    return None


INTERNAL_HOSTS = set()


def rewrite_links(pages, by_slug, by_id, report):
    def make(page):
        def sub(m):
            href, inner = m.group(1), m.group(2)
            path = internal_path(href)
            if path is None or path.startswith("/uploads/"):
                return m.group(0)
            target = None
            pm = re.match(r"^/books/[^/]+/page/([^/#?]+)", path)
            lm = re.match(r"^/link/(\d+)", path)
            if pm:
                target = by_slug.get((pm.group(1)))
            elif lm:
                target = by_id.get(int(lm.group(1)))
            if target is None or "kanka" not in target:
                report.append(f"{page['name']}: link to BookStack {path} has no Kanka entity; left as a plain link")
                return m.group(0)
            text = plain(inner) or target["name"]
            return f"[{target['kanka']['type']}:{target['kanka']['entity_id']}|{text}]"
        return sub
    for p in pages:
        p["entry"] = LINK_RE.sub(make(p), p["html"])


def upload_images(bs, kanka, cid, page, report):
    """Kanka's gallery API writes to an S3 disk we don't run; the entity-image endpoint uses the local disk instead."""
    ent = page["kanka"]
    urls = {}
    for m in IMG_RE.finditer(page["entry"]):
        src = m.group(1)
        path = internal_path(src)
        if path is None or not path.startswith("/uploads/") or src in urls:
            continue
        try:
            data = bs.call("GET", path).content
            name = os.path.basename(path)
            r = kanka.json("POST", f"/api/1.0/campaigns/{cid}/entities/{ent['entity_id']}/image",
                           files={"file": (name, data)})
            urls[src] = r.get("data", r)["image"]["full"]
        except Exception as e:  # noqa: BLE001 - report and carry on, never silently drop
            report.append(f"{page['name']}: image {src} not transferred ({e})")
    if urls:
        # The endpoint sets the entity's own image each time; clear it so only inline images remain.
        kanka.call("DELETE", f"/api/1.0/campaigns/{cid}/entities/{ent['entity_id']}/image")
    page["entry"] = IMG_RE.sub(lambda m: m.group(0).replace(m.group(1), urls.get(m.group(1), m.group(1))), page["entry"])
    return len(urls)


def counts(s):
    return {t: len(re.findall(rf"<{t}\b", s, re.I)) for t in PRESERVED_TAGS}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--book", default="Kaidoho")
    ap.add_argument("--campaign", type=int, help="Kanka campaign id (must be empty)")
    ap.add_argument("--bookstack-url", default=os.environ.get("BOOKSTACK_URL"))
    ap.add_argument("--kanka-url", default=os.environ.get("KANKA_URL"))
    ap.add_argument("--dry-run", action="store_true", help="read BookStack and print the mapping; write nothing")
    ap.add_argument("--report", default="/report/kaidoho-migration-report.md")
    args = ap.parse_args()

    if not args.bookstack_url:
        raise SystemExit("BOOKSTACK_URL / --bookstack-url is required")
    INTERNAL_HOSTS.add(urlparse(args.bookstack_url).netloc)
    for extra in filter(None, os.environ.get("BOOKSTACK_PUBLIC_HOSTS", "").split(",")):
        INTERNAL_HOSTS.add(extra.strip())
    bs = Api(args.bookstack_url, {"Authorization": f"Token {secret('bookstack_token_id')}:{secret('bookstack_token_secret')}"})

    book, refs = fetch_book(bs, args.book)
    pages = load_pages(bs, refs)
    report = []
    skipped = [p for p in pages if p["kind"] == SKIP]
    pages = [p for p in pages if p["kind"] != SKIP]

    print(f"Book {book['name']!r}: {len(pages)} pages to migrate, {len(skipped)} skipped")
    chapters = {}
    for p in pages:
        chapters.setdefault(p["chapter"], []).append(p)
    for chapter, ps in chapters.items():
        label = chapter if chapter is not None else "(no chapter)"
        print(f"  {label:30} -> {ps[0]['kind']:12} type={ps[0]['label']!s:18} {len(ps)} pages")
        if chapter is not None and not mapping_for(chapter)[2]:
            report.append(f"Chapter {chapter!r} is not in the mapping, so its {len(ps)} pages became Notes.")
    for chapter in sorted({p["chapter"] for p in skipped}):
        n = sum(1 for p in skipped if p["chapter"] == chapter)
        report.append(f"Chapter {chapter!r} is skipped by design: {n} pages were not migrated.")
        print(f"  {chapter:30} -> SKIPPED ({n} pages)")
    if args.dry_run:
        for line in report:
            print("NOTE:", line)
        return

    if not args.kanka_url or not args.campaign:
        raise SystemExit("--kanka-url and --campaign are required for a real run")
    kanka = Api(args.kanka_url, {"Authorization": f"Bearer {secret('kanka_token')}", "Accept": "application/json"})
    cid = args.campaign
    existing = kanka.json("GET", f"/api/1.0/campaigns/{cid}/entities", params={"page": 1})
    if existing["data"]:
        raise SystemExit(f"Campaign {cid} is not empty: delete its entities (or use a fresh campaign) and re-run.")

    # Pass 1: create every entity, so pass 2 can resolve links between them.
    for p in pages:
        r = kanka.json("POST", f"/api/1.0/campaigns/{cid}/{KANKA_ENDPOINT[p['kind']]}", json={"name": p["name"], "entry": "", "type": p["label"]})["data"]
        p["kanka"] = {"id": r["id"], "entity_id": r["entity_id"], "type": p["kind"]}
        print(f"created {p['kind']} {p['name']!r}")
    by_slug = {p["slug"]: p for p in pages}
    by_id = {p["bs_id"]: p for p in pages}

    # Pass 2: links, images, then the real entry.
    rewrite_links(pages, by_slug, by_id, report)
    n_images = 0
    for p in pages:
        n_images += upload_images(bs, kanka, cid, p, report)
        r = kanka.json("PUT", f"/api/1.0/campaigns/{cid}/{KANKA_ENDPOINT[p['kind']]}/{p['kanka']['id']}",
                       json={"name": p["name"], "entry": p["entry"], "type": p["label"]})["data"]
        before, after = counts(p["html"]), counts(r.get("entry") or "")
        lost = {t: (before[t], after[t]) for t in PRESERVED_TAGS if after[t] < before[t]}
        if lost:
            report.append(f"{p['name']}: markup lost on save (tag: source, kanka) {json.dumps(lost)}")
        for a in p["attachments"]:
            report.append(f"{p['name']}: attachment {a!r} not transferred (Kanka has no equivalent via the API)")

    lines = ["# Kaidoho migration report", "", f"{len(pages)} pages -> {len(pages)} entities, {n_images} inline images uploaded.", ""]
    lines += ["## Did not transfer cleanly", ""] + ([f"- {x}" for x in report] or ["- Nothing reported."])
    text = "\n".join(lines) + "\n"
    os.makedirs(os.path.dirname(args.report), exist_ok=True)
    with open(args.report, "w") as f:
        f.write(text)
    print(text)


if __name__ == "__main__":
    sys.exit(main())
