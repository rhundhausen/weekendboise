import hashlib
import json
import os
import re
from datetime import datetime, timezone
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

from playwright.sync_api import sync_playwright

URLS = [u.strip() for u in os.environ["INGEST_ADDITIONAL_URLS"].splitlines() if u.strip()]
OUTPUT = "data/events-additional.json"
STATE = "ID"
BOISE = ZoneInfo("America/Boise")
USER_AGENT = os.environ.get(
    "USER_AGENT",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0 Safari/537.36",
)


def category_id():
    with open("data/schema/categories.json") as f:
        return next(c["id"] for c in json.load(f) if c["id"].startswith("auctions"))


def walk(node):
    # Yield every dict inside nested JSON-LD (handles @graph and ItemList)
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)


def is_event(node):
    t = node.get("@type")
    types = t if isinstance(t, list) else [t]
    return any(isinstance(x, str) and x.endswith("Event") for x in types) and node.get("startDate")


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def local_time(value):
    # Date-only values stay as-is; timestamps become Boise local time like events.json
    if "T" not in value:
        return value
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=BOISE)
    return dt.astimezone(BOISE).isoformat(timespec="seconds")


def state_of(node, addr, url):
    region = addr.get("addressRegion") if isinstance(addr, dict) else None
    if region:
        return region.strip().upper()
    parts = [p for p in urlparse(url).path.split("/") if p]
    return parts[0].upper() if parts else ""


def city_from_url(url):
    parts = [p for p in urlparse(url).path.split("/") if p]
    return parts[1] if len(parts) > 1 else ""


def to_event(node, page_url, fetched_at, category):
    loc = node.get("location") or {}
    if isinstance(loc, list):
        loc = loc[0] if loc else {}
    addr = loc.get("address") or {}
    if isinstance(addr, str):
        addr = {}
    url = node.get("url") or page_url
    if state_of(node, addr, url) != STATE:
        return None
    start = local_time(node["startDate"])
    end = local_time(node.get("endDate") or node["startDate"])
    venue = (loc.get("name") or "").strip()
    title = (node.get("name") or "").strip()
    event = {
        "id": hashlib.sha1(f"{url}|{start}".encode()).hexdigest()[:12],
        "title": title,
        "start": start,
        "end": end,
        "allDay": "T" not in start,
        "venue": venue,
        "venueKey": slug(venue),
        "city": addr.get("addressLocality") or city_from_url(url),
        "category": category,
        "tags": [],
        "size": "S",
        "url": url,
    }
    desc = (node.get("description") or "").strip()
    if desc:
        event["description"] = desc
    event["sources"] = [{"name": "additional", "url": url, "fetchedAt": fetched_at}]
    return event


def scrape(page, url):
    page.goto(url, wait_until="networkidle", timeout=60000)
    blocks = page.eval_on_selector_all(
        'script[type="application/ld+json"]',
        "els => els.map(e => e.textContent)",
    )
    nodes = []
    for raw in blocks:
        try:
            nodes.extend(n for n in walk(json.loads(raw)) if is_event(n))
        except json.JSONDecodeError:
            pass
    return nodes


def main():
    category = category_id()
    fetched_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    events = {}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_context(user_agent=USER_AGENT).new_page()
        for i, url in enumerate(URLS, 1):
            try:
                found = scrape(page, url)
            except Exception as e:
                print(f"source {i}: {type(e).__name__}")
                continue
            print(f"source {i}: {len(found)} events")
            for node in found:
                ev = to_event(node, url, fetched_at, category)
                if ev and ev["title"]:
                    events[ev["id"]] = ev
        browser.close()

    out = sorted(events.values(), key=lambda e: (e["start"], e["title"]))
    # Don't wipe the previous file when every source failed
    if out or not os.path.exists(OUTPUT):
        with open(OUTPUT, "w") as f:
            json.dump(out, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    main()
