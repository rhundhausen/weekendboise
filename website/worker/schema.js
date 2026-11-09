// The visitor log table, in the private D1 database bound as LOG_DB (see wrangler.jsonc). The
// Worker runs these on its first log request after it starts, so a new database needs no setup.
export const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS visits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    kind TEXT NOT NULL,
    ip TEXT,
    country TEXT,
    region TEXT,
    city TEXT,
    asn_org TEXT,
    device TEXT,
    browser TEXT,
    os TEXT,
    bot INTEGER NOT NULL DEFAULT 0,
    width INTEGER,
    path TEXT,
    qs TEXT,
    q TEXT,
    results INTEGER,
    referrer TEXT,
    ua TEXT
  )`,
  'CREATE INDEX IF NOT EXISTS visits_ts ON visits (ts)',
  'CREATE INDEX IF NOT EXISTS visits_ip ON visits (ip)',
];

// Columns:
//   ts       UTC, ISO 8601
//   kind     view (the page opened) or search (the filters changed, then settled for 2 seconds)
//   ip       the visitor's address, from CF-Connecting-IP
//   country, region, city, asn_org
//            Cloudflare's guess from the address, and the network (such as Sparklight)
//   device   phone, tablet, or desktop; browser and os from the User-Agent; bot is 1 for crawlers
//   width    window width in CSS pixels
//   path, qs the page and its query string: the search words and every filter
//   q        the search words alone; results is how many events the filters matched
//   referrer on view entries, the page that linked here
//   ua       the raw User-Agent

// How long a row is kept. The daily cron in wrangler.jsonc deletes older rows.
export const KEEP_DAYS = 90;
