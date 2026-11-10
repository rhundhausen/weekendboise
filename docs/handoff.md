# Handoff

## 2026-11-06: ingest split into ingest and refine

The nightly run is now two workflows, refine starting when ingest finishes. Where this conflicts with the sections below, this section wins; [development.md](development.md#nightly-workflows) has the details.

- **Ingest** (`ingest.yml`, midnight Boise time, `Invoke-Ingest.ps1`) only fetches. It writes `data/raw-events.json`: `asOf` plus each source's last good fetch. A failed source keeps its last entry; a one-source run (`source` input) replaces only that entry and keeps `asOf`. It commits that file alone, with `[skip ci]`. It is the only workflow given the API key secrets.
- **Refine** (`refine.yml`, `Invoke-Refine.ps1`) starts each time an ingest run finishes, whether ingest succeeded or failed, and reads the committed raw file and does everything else: merge and dedupe, canceled events, cities, moving old cost fields to `costTier`, the archive, and the link check. It also reads the pages of events stored as Other to find their city (`lib/CityLookup.ps1`, remembered in `data/city-lookup.json`). It writes and commits `data/events.json`, `data/archive/`, `data/links.json`, `data/city-lookup.json`, and `data/meta.json` (`lastIngest` copied from the raw file's `asOf`), which deploys the site. It uses no source API keys and fails clearly if the raw file is missing.
- **Report emails:** both workflows end with a `report` job (`Save-RunLogs.ps1`, `Send-Report.ps1`, `lib/Report.ps1`) that runs after the main job, even when it failed, and emails a summary through Resend with the run output and the job logs attached.
- **Site and sources (2026-11-09, evening):** a new About page (layouts/about.html, content/about.md, linked from the home header) describes the site and ends with a legend for size, cost, category, and city, built from sizes.json, categories.json, and the cost breakpoints in meta.json, with a GitHub issue link for suggestions. The Cost column is centered. The City options' counts now follow the other filters, like the category chips (app.js renderCityCounts; a city stays listed at (0)). New sources: telaya-wine (tribe; the site is set to Pacific time, so localTimeAsUtc) replaces the Idaho Wine Commission's Telaya copies, which listed as Idaho wineries, city Other, and are now skipped; mccall-public-library reads the library's category (CID 24) of the McCall CivicPlus calendar, and city-of-mccall now names the other categories (23, 27, 38), since the civicplus reader keeps a url's query on every month's page. Ruled out: Middleton, Payette, and Cascade libraries (Google Calendar embeds; calendar.google.com robots.txt disallows everything) and Weiser library (its calendar is a JPEG). Fever (feverup.com/en/boise) is blocked-by-terms: its terms forbid automated copying and aggregation without written permission. Boise Hawks stays ready: the 2026 feed now reads 53 home games cleanly, but the season is over and the 2027 feed answers 404; switch the url and set running in spring. Cities: place-cities.json maps Meriwether Cider to Garden City, YMCA Christmas Run to Boise, and Buckhorn Vineyards to Eagle (no Buckhorn events are in the data now). The city lookup ignores a page's <nav> and <header>, where Boise Mom's menu says "Boise, ID". Meridian Library District stays ruled out (robots.txt) and Emmett's library calendar is a JavaScript Wix widget, which is why each shows about one event.
- **Auctions and Estate Sales (2026-11-09):** a 13th category, `auctions-estate-sales`, with its own chip, shown only while it has an upcoming event (layouts/home.html now builds the category chips from the events in the build, as it does the City list; chips sort by id, so this one is second). Three sources run with the new `sales` adapter (docs/sources.md#sales): downs-auction (iCal), corbett-auctions (home page cards, live onsite only, HiBid never followed), and on-the-water-estate-sales (the UPCOMING SALES lines). None has a terms or legal page (sitemaps and links checked), and robots.txt allows each page; Corbett asks for Crawl-delay 10. The rules: in-person only ("online" anywhere in the title or text, or no place, drops it), the covered cities only (Mountain Home included, by the user's choice), and only title, company, city, times, and link stored. The registry statuses awaiting-reply, needs-contact, declined, blocked-by-terms, online-only, defunct, and out-of-scope, the fields type, contact, outreach, lastChecked, and optOut, and the top-level `doNotIngest` list are new (sources.md#removing-a-company-donotingest). 65 estate and auction companies and sites are recorded (the 3 running and 62 planned); the existing entries were updated in place with their earlier findings kept in notes. EstateSales.org and Corbett are awaiting replies; EstateSales.NET declined and is on doNotIngest. tags.json has an `estate-sale` tag, and the tag-count test now allows 81. This supersedes the Estate Sales (2026-11-08) bullet below.
- **2026-11-09, later:** the visitor log is live (D1 `weekendboise-log`, bound as `LOG_DB` in website/wrangler.jsonc; rows land and `Get-VisitorLog.ps1` reads them), and the home page footer now says the site keeps a private 90-day log of visits and searches with the IP address and approximate location. The scrape adapter's jsonld mode warns "no event links on the list page" when a list page with an `eventLinkPattern` matches nothing, so a bot block served with status 200 (as RunSignup's looks from GitHub's runners) shows in the email's Warnings instead of as a quiet 0-event success.
- **Meetup (2026-11-09):** 19 more slugs probed from the user's list of 87 (the other 68 were already in sources.json). 12 now run: Boise Investor Group, Toastmasters District 15, Healthy & Fun Choices, Idaho Hikers & Backpackers, Idaho Sierra Club, Idaho Real Estate Masterminds, Boise Note Closers Group, Zoom Room Dog Training, Property Deal Network, Recovery Dharma Boise, Strive Networking, and Treasure Valley Needle Arts (so 180 groups run, 70 events in their feeds on 2026-11-09). Ruled out: 4 private groups (403), 2 second slugs for groups already running (level-up-lounge-meridian is boranloungecoffee-meridian with the same 10 events; shus-idaho-running-company-meetup is idaho-running-company-meetup), ttrpg-in-parma (its events are in Parma, which the site does not cover), and meetup-boise-real-estate-investors-meetup-group (the group is gone; its feed answers 404). Also from the 2026-11-09 ingest review: eventbrite-emmett has answered 405 to GitHub's runners every night since the raw file began, runsignup-treasure-valley has reported 0 events every night since it was switched on (29 race links from a home connection, none from the runners), and idaho-steelheads answered 405 once after working the evening before. All three load from a home connection, so they are candidates for `local: true`.
- **Meetup:** 168 groups run as `meetup-<group>` sources (adapter `meetup`, see [sources.md](sources.md#meetup)); 33 private groups are ruled out. They add about 12 minutes to ingest. On 2026-11-06, 80 idea and investigating sources were probed: 12 now run, 12 are ready, and the rest have notes on what blocks them, including the adapter code that would open several.
- **2026-11-07 probe:** 20 more suggestions probed (races, bike races, venues, parks, theaters). Race to Robie Creek and RunSignup (races within 50 miles of Boise, first 30 results) now run. Ready but held: MarathonGuide, Running.life and RaceUp (date-only copies of RunSignup races), Idaho Bike Racing (SWICA; needs a title or place filter and midnight-to-midnight read as all-day), Shrine Social Club (cards mode must read a time split by tags and single-quoted links), and CWI (a 10-day student calendar; the user decides). Each entry's notes say what blocks it. The Meetup adapter now strips Markdown from descriptions. Later the same day, when the list was suggested again: Shrine Social Club and CWI now run (scrape cards mode drops tags inside a time and reads single-quoted links), and Recycled Minds Comedy (improv at The Creative Space, Garden City) was added. The rest stay as their notes say. A third batch (Middleton, Marsing, Owyhee County, Sunnyslope wineries) added idaho-wine-commission (tribe, which now honors `excludeTitlePattern`), middleton-chamber (replacing the parked-domain entry), and owyhee-county; the other suggestions are ruled-out entries saying why.
- **Valley County (2026-11-08):** a new city value, `Valley County`, is one location for McCall, Cascade, Donnelly, Tamarack, Lake Fork, Yellow Pine, New Meadows (Adams County), and Riggins (Idaho County); the last two are grouped with it on purpose. `Resolve-TvCity` maps the town names to it, the ZIP clues cover the towns, and layouts/home.html pins it last in the City drop-down, below Other. Running: brundage-mountain, tamarack-resort, donnelly-library, salmon-river-chamber, cascade-chamber, city-of-mccall (meetings and youth basketball skipped), and mccall-winter-carnival (Visit McCall's carnival page, read with the new cards option `yearFromTitle`). About 82 events. Donnelly Library and Tamarack are Events Calendar sites set to UTC+0, so tribe and ics now honor `localTimeAsUtc`. Visit McCall now runs too, with the new `eventastic` adapter (one admin-ajax POST a night; weekly events listed per date; 56 events on 2026-11-08), and `Invoke-TvRequest` takes `-Method Post -Form`. Held, with notes: Valley County's own site (evoGov, list built by JavaScript), Visit North Central Idaho (1 local event, needs a text filter), City of Riggins (meetings only). Ruled out: City of Donnelly (calendar is an image). Patch and BSPR stay blocked.
- **City list, Star, Weiser, and Payette (2026-11-08):** layouts/home.html now builds the City options at build time and lists only cities with at least one upcoming event (presentation only: every running source still runs nightly, and a city comes back once it has an event; the rule is also in the sources.json `_comment`). Weiser runs signal-american (about 3 events); Payette runs idvs-payette (the American Legion #33 breakfast, monthly). Star runs star-chamber with the new `sveltekit` scrape mode, which reads the calendar staridahochamber.com embeds as SvelteKit page data through `ConvertFrom-TvJsLiteral` (lib/Scrape.ps1; it parses without running anything, and splits the text into tokens in one pass because offset regex matches cost time in proportion to the whole 400 KB page). That took Star from 2 to about 364 upcoming events, mostly weekly Star Library programs. Held: fiddlers-contest (configured as cards on the home page banner, but the site answers 403 to the ingest client while curl gets 200, so it waits for the site's permission), Payette Chamber (Wild Apricot, no events and no dated feed). Ruled out: Apple Blossom Festival (domain gone), City of Payette (agendas only), Visit Southwest Idaho (no event listing).
- **Estate Sales (2026-11-08):** probed for a 13th category, `estate-sales`, which was then dropped until a source exists. To add it back, put it in categories.json (last, so its chip is last), both schemas' category enums, the classification order in Schema.ps1 (ahead of markets-shopping), sizes.json (M), site.css, and tags.json (an `estate-sale` tag: estate sale, estate liquidation; garage and yard sales stay out; the tag-count test allows at most 80), and give the estate entries in sources.json that category. Probed: EstateSales.NET (terms forbid automated collection), EstateSale.com (Incapsula challenge), GarageSaleFinder (terms forbid scraping; its KML export is a saved list) and the local companies (their sites embed the EstateSales.org or EstateSales.NET widget, or list nothing) are ruled out. EstateSales.org is ruled out too: its terms (read by the site owner, since robots.txt disallows /terms) forbid automated access and aggregation without written permission, with liquidated damages. So every candidate is closed, and the category has no source; a source needs written permission from EstateSales.org or EstateSales.NET. The EstateSales.org entry's notes still describe its card markup. When a reader is built, model a sale as one event from the first day's opening to the last day's close, as other multi-day events are, pass PriceMin 0 (item prices in the description must not set the cost tier), and take the city from the listing's "City, ID ZIP".
- **Local sources (2026-11-07):** a source with `local: true` is skipped by the nightly ingest (its last fetch is kept) and run from the user's PC with `Invoke-LocalIngest.ps1`, whose push starts refine. The scheduled Sunday ingest emails a reminder to `REPORT_EMAIL`. Visual Arts Collective is the first, running again this way. The ingest email no longer has a "No events" section; sources with 0 events are at the end of "Succeeded".
- **File ownership:** no file is written by both. `data/schema/` is hand-edited and neither workflow commits it.
- **Rerunning refine by hand:** Actions > refine > Run workflow (optionally skip the link check), or `./ingestion/scripts/Invoke-Refine.ps1 -SkipLinkCheck` locally. It fetches no source and is safe to repeat, so rule changes can be tried without another ingest. `Invoke-Ingest.ps1 -CleanupOnly` is gone; refine replaces it.
- **Scheduling:** only ingest has a cron. `ingestion/scripts/Test-BoiseHour.ps1 -Hour 0` is its daylight-saving gate. Refine is chained with `workflow_run`, and `ingestion/scripts/Test-IngestRan.ps1` skips the ingest run whose job the gate skipped, so refine runs once a night. Both workflows share the concurrency group `data`.
- **Prices:** adapters work out `priceMin` (cheapest adult ticket) and pass it to `New-TvEvent`, which derives `costTier` with `Get-CostTier` (breakpoints $15 and $40 in `lib/Cost.ps1`) and removes any sentence with a price, so no price is ever stored. There are no guessed tiers; `costGuess` and `data/schema/costs.json` are gone. Rules: [cost-tiers.md](cost-tiers.md).
- **Link check:** only 500, 502, 503, and 504 count as a temporary failure now. Other 5xx codes (TicketWeb answers scripts with 506 or 530) count as blocked and never unlink an event.

## 2026-11-04: moved back to GitHub, new layout

The project returned to one public GitHub repo (rhundhausen/weekendboise, named tv-events until 2026-11-05) on 2026-11-04. The sections below describe the Azure DevOps period and are kept for history; where they conflict with this section, this section wins.

Layout:

- `.github/workflows/` replaces `pipelines/`. `ingest.yml` runs nightly at midnight Boise time (changed from 10:00 UTC on 2026-11-05) or by hand with a `source` input; `test.yml` runs Pester on push and PR. Secrets are repository secrets with the same names as before.
- `data/` is the contract between ingestion and the website: `events.json`, `archive/YYYY-MM.json` (was top-level `archive/`), and the `schema/` lookup tables (categories, tags, sizes, venue aliases).
- `ingestion/` holds `scripts/`, `tests/`, `schema/` (the JSON Schemas), `sources.json`, and `.env.example.ps1`. Scripts resolve `data/` one level above the ingestion root. Run from the repo root: `./ingestion/scripts/Invoke-Ingest.ps1 -NoWrite`, `Invoke-Pester -Path ./ingestion/tests`.
- `website/` is the Hugo site (not built yet). It mounts `../data` rather than having ingestion write into it.
- `docs/` is unchanged.

Secrets: `.env.ps1` and `.secrets.local.md` are gitignored and were not copied from the Azure DevOps repo. The repo is public; never commit them.

Reminders:

- **Visual Arts Collective.** Paused (`investigating`) on 2026-11-05 because its newest event pages time out from GitHub Actions runners but load from a home connection. Once a basic website is up, email booking@visualartscollective.com with the plan and ask them to allow the bot from GitHub's servers. Details are in the source's `notes` in `ingestion/sources.json`.

State of the project on 2026-11-03, written when it moved from GitHub to a private Azure DevOps repo. Read this first in a new session. [schema.md](schema.md), [sources.md](sources.md), and [source-status.md](source-status.md) cover the details.

## Where things stand

Phase 1 (ingestion) is built and pushed to Azure DevOps. The test pipeline runs on every push, and the ingest pipeline has run once by hand and committed data.

- `sources.json` holds every source, 112 entries: 36 running (7 ICS, 7 tribe, 13 Ticketmaster as 12 venues plus metro-wide, 7 scrape, 1 cityofboise, 1 RSS), 5 ready, 22 investigating, 30 ideas, 19 ruled out. The Ford Idaho Center RSS feed was added on 2026-11-03. The separate `data/sources.json` registry was merged into it on 2026-11-03.
- Eventbrite, SeatGeek, and Songkick adapters are built and disabled. They have no credentials and have never run live; their tests use hand-written fixtures. Bandsintown is built and needs an approved app id. `boise-id-events` works but is left at `ready` on purpose: it is a ticket-listing network that repeats Ticketmaster.
- Last dry run (2026-11-03): 35 of 35 sources succeeded, 2,589 upcoming events, 475 past, 0 warnings. Each run writes `out/run.json` with per-source counts, errors, and warnings.
- 327 Pester tests pass on Pester 6.0.0.
- `data/events.json` holds 1,991 events, committed by the pipeline's data commit on 2026-11-03. Local runs are `-NoWrite`; load for real only when the user asks.
- Reports: `docs/ingest-report.md` and `.docx` (12 pages) are current and cover every source, including ideas and ruled-out sites. `docs/source-status.md` and `.docx` are superseded by it and stale.
- Review CSV from the last run: `out/events-review-final.csv` (`out/` is gitignored).

## Secret files

These hold secrets. Since the move to a private repo they are committed, by the user's choice; anyone with read access to the repo can see them:

- `.env.ps1`: sets `TICKETMASTER_KEY` and the other keys. Dot-source it before running: `. ./.env.ps1`.
- `.secrets.local.md`: the user's keys and per-site login notes.

## Moving to Azure DevOps

GitHub-specific pieces that need replacing or editing:

| Item | Change |
| --- | --- |
| `.github/workflows/ingest.yml` | Becomes an Azure Pipelines YAML with a nightly schedule (10:00 UTC) and a manual run with an optional `source` parameter |
| `.github/workflows/test.yml` | Becomes a pipeline that runs `Invoke-Pester -CI` on push and PR |
| Secrets | Pipeline secret variables or a variable group. Secret variables are not exposed to scripts automatically; map each one in `env:` (`TICKETMASTER_KEY: $(TICKETMASTER_KEY)`) |
| `scripts/Publish-Data.ps1` | Commits and pushes as "WeekendBoise bot". The build service identity needs Contribute permission on the repo, and the checkout step needs `persistCredentials: true`. `[skip ci]` in the message works in Azure Repos too. Change the noreply.github.com email |
| User-Agent in `scripts/lib/Http.ps1` and `tests/lib/Http.Tests.ps1` | Decided 2026-11-03: keep the GitHub URL for now, and switch to a contact page on the user's future Cloudflare site once it exists. Keep the product token (now `WeekendBoise`, renamed from `tv-events` on 2026-11-05) so robots.txt rules still match |
| `$id` in `schema/*.schema.json` | GitHub URLs. Only identifiers, but update for consistency |
| `README.md` | "GitHub setup" section and the Action wording |
| Hugo site | Phase 2 plan assumed GitHub Pages. Pick a host that can read a private repo (Azure Static Web Apps fits) |

## Ground rules

- PowerShell 7, 2-space indents, LF line endings in JSON output.
- Secrets come from environment variables only. Never read them from files in the repo.
- 1 second between paged requests. Each adapter fails on its own without stopping the run.
- Times in `America/Boise`, ISO 8601 with offset.
- Store minimal data: no images, no full descriptions, no ticket prices, descriptions at most 300 characters.
- No scraping that evades bot controls. Check `robots.txt` before any request, including manual probes. Honor Crawl-delay; a delay over 60 seconds fails the source.
- No en-dashes or em-dashes anywhere (user's global rule).
- Word documents: build with `C:\Users\rhund\.claude\tools\word\md2docx.py`, verify by rendering with `docx2pdf.ps1`, never regenerate one the user has edited by hand.
- Commit or push only when asked.

## Open decisions

1. **Same-day showings.** The id hashes the date, not the time, so a matinee and an evening show merge. Decide before data is published, because changing it changes every id.
2. **Real load.** Whether and when to replace `data/events.json`.
3. **Terms of use** for the 5 scraped sites, before anything is public.

## Known problems

- Duplicates with very different titles don't merge (BSU basketball listings, Boise State Theatre Arts' A Christmas Carol).
- Venue-based size estimates are blunt: every ExtraMile event is XL.
- Indian Creek Plaza ice skating is tagged `christmas-lights`.
- Reindeer Games shows midnight to 4 AM; that is the publisher's data.
- Scrapers can break silently when a site changes and return zero events without an error.
- Songkick's endpoint (`metro_areas/{id}/calendar.json`) is unverified.

## Things already ruled out

`sources.json` holds every source, including ideas and ruled-out sites; ingest runs only `status: running`. Check it before probing any site: `ruled-out` entries say why (refused automated requests, robots.txt disallows the feed, not in Idaho), and `investigating` entries say what was already tried. [sources.md](sources.md#ideas-and-the-status-lifecycle) explains the statuses.
