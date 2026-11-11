import os
import unittest
from unittest.mock import Mock, patch

from playwright.sync_api import sync_playwright

with patch.dict(os.environ, {"INGEST_ADDITIONAL_URLS": ""}):
    import ingest


LISTING_URL = "https://estatesales.org/estate-sales/id/boise?sort=distance&radius=100&view=list"

# Reduced from the listing HTML supplied on November 11, 2026.
LISTING_HTML = """
<div class="split-view__list">
  <div class="card" data-auction-id="L2470866">
    <h3 class="card__title" title="Nice W Hillcrest View Dr 2-Day Estate Sale">
      <a href="/estate-sales/id/boise-/83705/nice-w-hillcrest-view-dr-2470866">
        Nice W Hillcrest View Dr 2-Day Estate Sale
      </a>
    </h3>
    <div class="card__type"><span>In-person estate sale</span></div>
    <div class="card__location"><span><a>Boise, ID 83705</a></span></div>
    <div class="card__dates">Sale starts Fri. Nov 20, 2026 at 9:00 AM MST</div>
  </div>
  <div class="card" data-auction-id="L2472583">
    <h3 class="card__title"
        title="A Little Fringe, A LOT of Farmhouse! | 4 Days of Incredible Finds in Kuna">
      <a href="/estate-sales/id/kuna/83634/a-little-fringe-a-lot-2472583">
        A Little Fringe, A LOT of Farmhouse! | 4 Days of Incredible Finds...
      </a>
    </h3>
    <div class="card__type"><span>In-person estate sale</span></div>
    <div class="card__location"><span><a>Kuna, ID 83634</a></span></div>
    <div class="card__dates">Sale starts Thu. Dec 3, 2026 at 9:00 AM MST</div>
  </div>
  <div class="card card--featured" data-auction-id="online">
    <h3 class="card__title" title="Promoted online auction"><a href="/online">Auction</a></h3>
    <div class="card__type">Online auction</div>
    <div class="card__location">Boise, ID 83705</div>
  </div>
  <div class="card card--featured" data-auction-id="out-of-state">
    <h3 class="card__title" title="Out-of-state sale"><a href="/other">Sale</a></h3>
    <div class="card__type">In-person estate sale</div>
    <div class="card__location">Portland, OR 97201</div>
  </div>
</div>
"""


class EstateSalesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch()

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()

    def setUp(self):
        self.page = self.browser.new_page()
        self.addCleanup(self.page.close)

    def test_listing_cards_reach_output_schema_without_json_ld(self):
        self.page.set_content(LISTING_HTML)
        page = Mock(wraps=self.page)
        page.goto.return_value = Mock(ok=True)
        nodes = ingest.scrape(page, LISTING_URL)
        events = [
            ingest.to_event(node, LISTING_URL, "2026-11-11T00:00:00Z", "auctions-estate-sales")
            for node in nodes
        ]
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0]["title"], "Nice W Hillcrest View Dr 2-Day Estate Sale")
        self.assertEqual(events[0]["start"], "2026-11-20T09:00:00-07:00")
        self.assertEqual(events[0]["city"], "Boise")
        self.assertEqual(events[1]["city"], "Kuna")
        self.assertTrue(events[1]["title"].endswith("Incredible Finds in Kuna"))
        self.assertEqual(events[1]["start"], "2026-12-03T09:00:00-07:00")
        self.assertEqual(events[1]["category"], "auctions-estate-sales")
        self.assertEqual(events[1]["end"], events[1]["start"])
        self.assertFalse(events[1]["allDay"])
        self.assertEqual(
            events[1]["url"],
            "https://estatesales.org/estate-sales/id/kuna/83634/a-little-fringe-a-lot-2472583",
        )
        self.assertEqual(events[1]["sources"][0]["url"], events[1]["url"])

    def test_invalid_start_is_reported_instead_of_silently_returning_zero(self):
        self.page.set_content(LISTING_HTML.replace(
            "Sale starts Fri. Nov 20, 2026 at 9:00 AM MST", "Dates unavailable"
        ))
        with self.assertRaisesRegex(ValueError, "Unrecognized estate sale start time"):
            ingest.scrape_estatesales_org(self.page, LISTING_URL)

    def test_summer_time_uses_boise_daylight_saving_offset(self):
        self.page.set_content(LISTING_HTML.replace(
            "Nov 20, 2026 at 9:00 AM MST", "Jul 17, 2026 at 9:00 AM MDT"
        ))
        nodes = ingest.scrape_estatesales_org(self.page, LISTING_URL)
        self.assertEqual(nodes[0]["startDate"], "2026-07-17T09:00:00-06:00")

    def test_http_failure_is_not_treated_as_an_empty_listing(self):
        page = Mock()
        page.goto.return_value = Mock(ok=False, status=403)
        with self.assertRaisesRegex(RuntimeError, "HTTP 403"):
            ingest.scrape(page, LISTING_URL)

    def test_existing_json_ld_scraping_is_preserved(self):
        self.page.set_content("""
            <script type="application/ld+json">
              {"@type": "Event", "name": "Existing sale", "startDate": "2026-11-12"}
            </script>
        """)
        page = Mock(wraps=self.page)
        page.goto.return_value = Mock(ok=True)
        nodes = ingest.scrape(page, "https://www.estatesales.net/ID/Boise")
        self.assertEqual(len(nodes), 1)
        self.assertEqual(nodes[0]["name"], "Existing sale")


if __name__ == "__main__":
    unittest.main()
