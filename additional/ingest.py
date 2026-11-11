import json
import os

from playwright.sync_api import sync_playwright

URLS = [u.strip() for u in os.environ["INGEST_ADDITIONAL_URLS"].splitlines() if u.strip()]
USER_AGENT = os.environ.get(
    "USER_AGENT",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0 Safari/537.36",
)


def scrape(page, url):
    page.goto(url, wait_until="networkidle", timeout=60000)

    # Prefer structured data embedded in the page
    ld = page.eval_on_selector_all(
        'script[type="application/ld+json"]',
        "els => els.map(e => e.textContent)",
    )
    items = []
    for raw in ld:
        try:
            items.append(json.loads(raw))
        except json.JSONDecodeError:
            pass

    # Fallback: collect links that look like individual listings
    links = page.eval_on_selector_all(
        "a[href]",
        "els => els.map(e => ({text: e.innerText.trim(), href: e.href}))",
    )
    links = [l for l in links if l["text"] and len(l["text"]) > 10]
    return {"structured": items, "links": links}


def main():
    results = {}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_context(user_agent=USER_AGENT).new_page()
        for i, url in enumerate(URLS, 1):
            try:
                results[f"source_{i}"] = scrape(page, url)
            except Exception as e:
                results[f"source_{i}"] = {"error": type(e).__name__}
        browser.close()
    with open("results.json", "w") as f:
        json.dump(results, f, indent=2)


if __name__ == "__main__":
    main()
