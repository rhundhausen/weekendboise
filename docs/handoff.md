# Handoff

## 2026-11-06: ingest split into ingest and refine

The nightly run is now two workflows, refine starting when ingest finishes. Where this conflicts with the sections below, this section wins; [development.md](development.md#nightly-workflows) has the details.

- **Ingest** (`ingest.yml`, midnight Boise time, `Invoke-Ingest.ps1`) only fetches. It writes `data/raw-events.json`: `asOf` plus each source's last good fetch. A failed source keeps its last entry; a one-source run (`source` input) replaces only that entry and keeps `asOf`. It commits that file alone, with `[skip ci]`. It is the only workflow given the API key secrets.
- **Refine** (`refine.yml`, `Invoke-Refine.ps1`) starts each time an ingest run finishes, whether ingest succeeded or failed, and reads the committed raw file and does everything else: merge and dedupe, canceled events, cities, moving old cost fields to `costTier`, the archive, and the link check. It also reads the pages of events stored as Other to find their city (`lib/CityLookup.ps1`, remembered in `data/city-lookup.json`). It writes and commits `data/events.json`, `data/archive/`, `data/links.json`, `data/city-lookup.json`, and `data/meta.json` (`lastIngest` copied from the raw file's `asOf`), which deploys the site. It uses no source API keys and fails clearly if the raw file is missing.
- **Report emails:** both workflows end with a `report` job (`Save-RunLogs.ps1`, `Send-Report.ps1`, `lib/Report.ps1`) that runs after the main job, even when it failed, and emails a summary through Resend with the run output and the job logs attached.
- **Meetup:** 168 groups run as `meetup-<group>` sources (adapter `meetup`, see [sources.md](sources.md#meetup)); 33 private groups are ruled out. They add about 12 minutes to ingest. On 2026-11-06, 80 idea and investigating sources were probed: 12 now run, 12 are ready, and the rest have notes on what blocks them, including the adapter code that would open several.
- **2026-11-07 probe:** 20 more suggestions probed (races, bike races, venues, parks, theaters). Race to Robie Creek and RunSignup (races within 50 miles of Boise, first 30 results) now run. Ready but held: MarathonGuide, Running.life and RaceUp (date-only copies of RunSignup races), Idaho Bike Racing (SWICA; needs a title or place filter and midnight-to-midnight read as all-day), Shrine Social Club (cards mode must read a time split by tags and single-quoted links), and CWI (a 10-day student calendar; the user decides). Each entry's notes say what blocks it. The Meetup adapter now strips Markdown from descriptions. Later the same day, when the list was suggested again: Shrine Social Club and CWI now run (scrape cards mode drops tags inside a time and reads single-quoted links), and Recycled Minds Comedy (improv at The Creative Space, Garden City) was added. The rest stay as their notes say. A third batch (Middleton, Marsing, Owyhee County, Sunnyslope wineries) added idaho-wine-commission (tribe, which now honors `excludeTitlePattern`), middleton-chamber (replacing the parked-domain entry), and owyhee-county; the other suggestions are ruled-out entries saying why.
- **Valley County (2026-11-08):** a new city value, `Valley County`, is one location for McCall, Cascade, Donnelly, Tamarack, Lake Fork, Yellow Pine, New Meadows (Adams County), and Riggins (Idaho County); the last two are grouped with it on purpose. `Resolve-TvCity` maps the town names to it, the ZIP clues cover the towns, and app.js pins it last in the City drop-down (`LAST`), below Other. Running: brundage-mountain, tamarack-resort, donnelly-library, salmon-river-chamber, cascade-chamber, city-of-mccall (meetings and youth basketball skipped), and mccall-winter-carnival (Visit McCall's carnival page, read with the new cards option `yearFromTitle`). About 82 events. Donnelly Library and Tamarack are Events Calendar sites set to UTC+0, so tribe and ics now honor `localTimeAsUtc`. Visit McCall now runs too, with the new `eventastic` adapter (one admin-ajax POST a night; weekly events listed per date; 56 events on 2026-11-08), and `Invoke-TvRequest` takes `-Method Post -Form`. Held, with notes: Valley County's own site (evoGov, list built by JavaScript), Visit North Central Idaho (1 local event, needs a text filter), City of Riggins (meetings only). Ruled out: City of Donnelly (calendar is an image). Patch and BSPR stay blocked.
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
