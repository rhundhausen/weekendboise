# website

Hugo site, deployed by Cloudflare Workers Builds on every push to `main` (see "Deploying" in `docs/development.md`). A single page lists upcoming events in a grid with search and filters, including a rough cost tier and a 3-line card on phones.

Reads events from the repo-level `data/` folder via a `module.mounts` entry (source `../data`, target `data`), so ingestion never writes into this tree. `ingestion/sources.json` is mounted the same way as `data/sources.json`, for the `/sources/` page (every running source, with its upcoming event count linking to the grid filtered by `?source=<name>`) and the header count. The `/bot` page for site owners who see the `WeekendBoise` user agent will live at `content/bot.md`.

## Run it

From the repo root (Hugo extended 0.156 or later):

```powershell
hugo server -s website          # http://localhost:1313, rebuilds on change
hugo -s website --minify        # builds to website/public/ (gitignored)
```

## How it works

- `layouts/home.html` reads `events.json` and the category and size lookups at build time, and writes a slimmer copy (short keys, only the fields the page shows) to `data/events.<hash>.json`.
- `assets/js/app.js` loads that file and does the rest in the browser: search (all words must match, accents ignored), the date, city, size, and category filters, sorting, and paging. The filters are kept in the URL, so a filtered view can be shared or bookmarked.
- `assets/css/site.css` holds the styles. Colors are CSS variables with a dark set for `prefers-color-scheme: dark`. Below 760px wide, each row becomes a card.
- No external scripts, fonts, or CDNs. Event text comes from outside sources, so the script only ever sets it with `textContent`.

## Visitor log

A private log of who uses the site and what they search for. Only the Cloudflare account can read it; nothing serves it over the web.

- **What is logged:** `app.js` posts to `/api/log` when the page opens (a `view`) and each time the filters settle for 2 seconds (a `search`): the query string, the search words, how many events matched, the window width, and on views the referring page. The Worker (`worker/index.js`, which `wrangler.jsonc` runs only for `/api/*`) adds the time, the IP address, Cloudflare's location and network for that address, and the device (phone, tablet, or desktop), browser, and OS from the User-Agent, then stores one row in the `visits` table. Columns are described in `worker/schema.js`.
- **Where:** the D1 database `weekendboise-log`, bound as `LOG_DB`. The table is created on the first log request. A daily cron (10:00 UTC) deletes rows older than 90 days.
- **Viewing:** `./website/scripts/Get-VisitorLog.ps1` (newest 100 rows from the last 7 days; `-Days`, `-Last`, `-Ip`, `-Search`, `-IncludeBots`) or `-Summary` (visits by device, browser, and city, top searches, and searches that found nothing). It runs `wrangler d1 execute` as you, so run `npx wrangler login` once first. The Cloudflare dashboard's D1 console (Storage and databases > D1 > weekendboise-log) runs any SQL, for example `SELECT * FROM visits ORDER BY ts DESC LIMIT 50`.
- **Tests:** `node --test` in `website/worker` (also run by the test workflow).
- **Setting it up:** create the database once with `npx wrangler d1 create weekendboise-log` (or in the dashboard), then add its binding to `wrangler.jsonc`:
  `"d1_databases": [{ "binding": "LOG_DB", "database_name": "weekendboise-log", "database_id": "<id>" }]`.
  Until the binding exists, `/api/log` answers 204 and stores nothing.
