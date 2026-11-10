# Development

This page is for working on WeekendBoise. If you run a site and found this repo through the `WeekendBoise` user agent, see the [README](../README.md) instead.

Treasure Valley event aggregator. A nightly GitHub Actions workflow pulls events from venue, team, and community sources around Boise, Meridian, Nampa, Caldwell, and Eagle, and merges them into a single flat file. A Hugo site in `website/` publishes the result, deployed by Cloudflare on every push to `main`.

## How it works

1. `ingestion/sources.json` lists each source and the adapter that reads it (ICS feed, Meetup group feed, The Events Calendar REST API, RSS, the City of Boise API, a ticketing API, or, for sites with no feed, a `robots.txt`-respecting scraper). [ingest-report.md](ingest-report.md) shows every source, its state, and the last run's results.
2. **Ingest** (`ingestion/scripts/Invoke-Ingest.ps1`, midnight Boise time) runs every adapter, normalizes each event to the common schema, and stores what each source returned in `data/raw-events.json`, one entry per source. It does nothing else.
3. **Refine** (`ingestion/scripts/Invoke-Refine.ps1`, started when ingest finishes, even if ingest failed) reads the raw file, dedupes across sources, fills in cities, moves old cost fields to `costTier`, looks up the city of events still stored as Other by reading their pages, checks event links, and writes `data/events.json` (upcoming only), `data/archive/YYYY-MM.json` (past events), `data/links.json`, `data/city-lookup.json`, and `data/meta.json`. It never fetches a source, so it can be rerun by hand as often as needed.
4. Each workflow commits only the files it owns. Refine's commit deploys the site.

**File ownership.** No file is written by both stages:

| File | Written by |
| --- | --- |
| `data/raw-events.json` | ingest |
| `data/events.json`, `data/archive/`, `data/links.json`, `data/city-lookup.json`, `data/meta.json` | refine |
| `data/schema/` | people, by hand |

The raw file holds `asOf` (the scheduled midnight, or the time a manual run started) and, per source, its last good fetch: `{ "asOf": "...", "sources": { "<name>": { "fetchedAt": "...", "events": [...] } } }`. A source that fails keeps its last good entry, and a one-source run replaces only that source's entry and keeps `asOf`, so refine always sees every source. Refine copies `asOf` into `data/meta.json` as `lastIngest`, which is what the site's header shows. Events in the raw file are already normalized by the adapters (id, category, tags, size, `costTier` from the price the source gave, and a description with prices removed), because prices must never be stored; refine does everything after. Cost tier rules: [cost-tiers.md](cost-tiers.md).

## Repo layout

```
.github/workflows/    ingest.yml (midnight fetch), refine.yml (after ingest), test.yml (Pester)
data/                 the contract between ingestion and the website
  raw-events.json     what each source returned, written by ingest, read by refine
  events.json         upcoming events
  archive/            past events by month
  links.json          link check state
  city-lookup.json    the cities the city lookup found, by event page
  meta.json           the time of the last ingest, shown in the site's header
  schema/             lookup tables: categories, tags, sizes, venue aliases
ingestion/
  scripts/            Invoke-Ingest, Invoke-Refine, Publish-Data, Save-RunLogs, Send-Report, Send-LocalReminder, Invoke-LocalIngest, Test-BoiseHour, Test-IngestRan, Test-Sources, Test-Schema
    adapters/         one script per adapter type
    lib/              shared library
  tests/              Pester tests and fixtures
  schema/             JSON Schemas for events and sources
  sources.json        every source: running, waiting, ideas, ruled out
  .env.example.ps1    template for local API keys
website/              Hugo site, see website/README.md
docs/                 schema, source reference, reports
```

## Running locally

Requires PowerShell 7.4 or later and Pester 6.0.0. Run everything from the repo root.

```powershell
. ./ingestion/.env.ps1                                       # load API keys, see below
./ingestion/scripts/Test-Sources.ps1                         # validate sources.json
./ingestion/scripts/Test-Schema.ps1                          # validate stored events
./ingestion/scripts/Invoke-Ingest.ps1 -NoWrite               # fetch and report, don't write the raw file
./ingestion/scripts/Invoke-Ingest.ps1                        # fetch every source into data/raw-events.json
./ingestion/scripts/Invoke-Ingest.ps1 -Source idaho-steelheads   # one source, merged into the raw file
./ingestion/scripts/Invoke-LocalIngest.ps1                   # the local sources only, then commit and push (weekly)
./ingestion/scripts/Invoke-Refine.ps1 -SkipLinkCheck -SkipCityLookup   # raw file to the site's files, no network at all
./ingestion/scripts/Invoke-Refine.ps1                        # the same, with the city lookup and link check
./ingestion/scripts/Invoke-Refine.ps1 -NoWrite               # see refine's counts, write nothing
Invoke-Pester -Path ./ingestion/tests                        # run the tests
hugo server -s website                                       # the site, at http://localhost:1313
```

Refine drops events any source titles as canceled, and dedupes across sources (see `Merge-TvEvents` in `ingestion/scripts/lib/Dedupe.ps1`). It re-cleans every archive month with the same rules, so rerunning it applies a rule change everywhere without fetching anything; add `-NoWrite` to see the counts first. Both scripts take `-InputPath`/`-OutputPath` (refine) or `-RawPath` (ingest) to work on copies outside `data/`.

### City lookup

Some events reach refine with the city Other, nearly all from Boise Mom listings with no venue. After the text-based fill-in, refine reads their pages to find the city (`ingestion/scripts/lib/CityLookup.ps1`).

- **How:** it reads the event page and uses its venue block or schema.org location if it has one, never the whole page: Boise Mom's footer says "Boise, ID" on every page. Otherwise it follows the page's "Website" link to the organizer's page, then that site's home page. It takes a city only when the page names exactly one, as "City, ID", "City, Idaho", or an Idaho ZIP code after the state; a page that names two (Meriwether Cider writes "Boise, ID 83714", a Garden City ZIP code) leaves the event as Other.
- **What it skips:** social networks and chain stores (Facebook, Instagram, Home Depot, Lowe's, JCPenney, and others in `$script:TvCityLookupSkipHosts`) are never requested, because their pages can't say which store or place.
- **Politeness:** the same rules as the link check: robots.txt first, a disallowed page is never requested, 1 second between requests to a host or its Crawl-delay, and at most `-CityBudgetSeconds` (default 180) per run.
- **Memory:** results go in `data/city-lookup.json` by event page, with the organizer link and the time checked. A found city is reused for 30 days and a miss is retried after 7, so most nights need few requests. On 2026-11-06 the first run placed 36 of 72 events (26 at the Garden City library) with 95 requests in about 2 minutes.
- **Skipping it:** `-SkipCityLookup`, or the "Skip the city lookup" box on a manual refine run, makes no requests but still applies the cities already found.

### Link check

After the merge, refine checks the event links that are due (`ingestion/scripts/lib/Links.ps1`), so nobody clicks through to a page that's gone.

- **What breaks a link:** 404 and 410 break it the first night. Timeouts, 500, 502, 503, 504, a host that doesn't resolve, and refused connections break it only on 2 nights in a row. Every other 4xx (401, 403, 406, 429 and so on), every other 5xx (TicketWeb answers scripts with 506 or 530 while the page works in a browser), odd codes like 999, and errors that can't be placed never do, because they're a site turning away scripts (Ticketmaster answers 401), not a missing page. A host that is down is caught even though its robots.txt request fails first. Redirects are followed the way a browser follows them, including from https to http.
- **When links are checked:** a link is checked the first night it appears, again 7 days after it last worked, and every night while it's failing, so a page that comes back gets its link back. Soonest events go first, within `-LinkBudgetSeconds` (default 900). Links left over count as working until a later night reaches them.
- **Politeness:** requests use the project User-Agent and follow each host's robots.txt; a disallowed path is never requested. Requests to one host are at least 1 second apart, or the host's Crawl-delay.
- **What a visitor sees:** an event whose link is broken first tries its other sources' links that are known to work. If none does, it gets `linkBroken: true`, and the site shows the title as plain text with the hover text "Information not available".
- **Where to look:** each refine lists every link it checked in `out/links.json` and adds counts to `out/refine.json`. The refine run's GitHub Actions summary has a "Broken links" section grouped by source, new breaks first. The state is `data/links.json`, committed by refine.
- **Limits:** `-NoWrite` and `-SkipLinkCheck` make no link requests but still apply what `data/links.json` already knows.

API keys are read from environment variables only. Copy `ingestion/.env.example.ps1` to `ingestion/.env.ps1` and fill in real values. `.env.ps1` and `.secrets.local.md` are gitignored; this repo is public, so never commit them. Sources whose key is missing fail with a warning and the rest still run. Only ingest needs source keys; refine uses none, and both use the Resend key only to email their report. Raw per-source output and `run.json` (ingest) and `refine.json` and `links.json` (refine) go to `out/`, which is also gitignored.

## Nightly workflows

- **When:** `.github/workflows/ingest.yml` runs at midnight Boise time on the default branch. Cron is UTC and daylight saving moves Boise between UTC-6 and UTC-7, so it schedules both candidate UTC hours (06:00 and 07:00) and a first job, `ingestion/scripts/Test-BoiseHour.ps1 -Hour 0`, skips the one that isn't midnight in Boise that day. `.github/workflows/refine.yml` has no cron: it starts with `workflow_run` each time an ingest run on `main` completes, scheduled or manual, **whether ingest succeeded or failed**, so past events still move to the archive and links still get checked when every source is down. Its first job, `ingestion/scripts/Test-IngestRan.ps1`, reads the ingest run's jobs through the GitHub API and skips the run whose ingest job was skipped (the cron line that wasn't midnight), so refine runs once a night. Both share the concurrency group `data`, so a manual refine waits for a running ingest rather than racing it.
- **The header time:** GitHub often starts scheduled runs late, so a scheduled ingest passes `-AsOf` with the scheduled midnight and the site's header reads 12:00 AM; a manual full ingest records the time it ran, and a one-source ingest keeps the time already there. Refine copies it unchanged.
- **Ingest** fetches, uploads `out/` as the `out` artifact, then `Publish-Data.ps1` commits `data/raw-events.json` alone, with `[skip ci]` so Cloudflare doesn't deploy a commit the site doesn't read. Run it by hand from Actions > ingest > Run workflow, with an optional `source` input to fetch one source.
- **Refine** checks out the head of `main`, so it sees the raw file ingest just committed, logs the raw file's `asOf` and source count, and fails with a clear message if there is no raw file. It doesn't depend on ingest succeeding: it uses whatever raw file is committed. It uploads `out/` as the `refine-out` artifact, then commits `data/events.json`, `data/archive/`, `data/links.json`, `data/city-lookup.json`, and `data/meta.json` without `[skip ci]`, which deploys the site. **To rerun it by hand** (after changing a merge or city rule): Actions > refine > Run workflow, optionally ticking "Skip the link check" or "Skip the city lookup". No source is fetched.
- Both commit as "WeekendBoise bot" and push to the branch the run started on. If someone pushed to that branch during the run (refine takes 15 minutes or more), the push is rejected as out of date; `Publish-Data.ps1` then replays its commit on top of the new branch head and pushes again, up to 3 tries. That is safe because each workflow commits only its own data files. If someone changed those same files, it stops with a clear error instead of overwriting them, and the workflow can be rerun. The test workflow doesn't run on those commits, because GitHub never starts workflows from a push made with the workflow's `GITHUB_TOKEN`.
- **Deploying:** Cloudflare Workers Builds is connected to this repo as the `weekendboise` Worker, with `website/` as its root. `website/wrangler.jsonc` runs `build.sh`, which installs Hugo and builds the site, then the build output in `website/public` is deployed. Every push to `main` deploys, including refine's data commit. A deploy shows as the "Workers Builds: weekendboise" check on the commit in GitHub. Cloudflare skips any commit whose message contains `[skip ci]`, so leave it out of commits that should reach the site. The site doesn't read `data/raw-events.json` or `data/city-lookup.json`: `website/hugo.toml` leaves them out of the data mount.
- **Local sources:** some sites turn away or time out on GitHub's servers (which run in Azure) but load from a home connection. Their entries in `sources.json` have `local: true`. The nightly ingest skips them and keeps their last fetch in the raw file, so their events stay on the site. `Invoke-LocalIngest.ps1`, run from a PC about once a week, pulls, runs `Invoke-Ingest.ps1 -Local` (only those sources; the raw file's `asOf` is kept), commits `data/raw-events.json`, and pushes. That push starts refine through its `push` trigger on `data/raw-events.json`, so the commit has no `[skip ci]` (GitHub would skip refine too); the nightly ingest's own push never fires that trigger, because pushes made with `GITHUB_TOKEN` start no workflows. The scheduled ingest at midnight Sunday, Boise time, emails a reminder (`Send-LocalReminder.ps1`) listing each local source's last fetch and the command to run. Weekly is enough: these are venue calendars that post shows weeks ahead.
- `.github/workflows/test.yml` runs the Pester tests on every push and pull request and uploads `testResults.xml`.

- **Report emails:** each workflow ends with a `report` job that runs after the main job, even when it failed. It is a separate job because GitHub serves a job's log only once that job has finished. It downloads the main job's artifact, saves the finished jobs' logs with `ingestion/scripts/Save-RunLogs.ps1` (needs `actions: read`), and `ingestion/scripts/Send-Report.ps1` builds a summary and sends it with the Resend API to `REPORT_EMAIL`.
  - **Ingest's email:** start, finish, and duration; sources that failed, with their page and error (such as `HTTP 405`); warnings; events per source, most first, so sources that returned 0 are at the end (Meetup groups also get one summary line); the sources not running yet (ready, investigating, ideas); and the ruled-out sources with the reason for each.
  - **Refine's email:** the same basics, the raw file totals, upcoming and archived counts, cities filled in, link check counts, broken links grouped by source (new ones marked), and events by category and source.
  - **Attachments:** each email attaches two zips: the run's `out/` folder, named like its artifact (`out.zip` for ingest, `refine-out.zip` for refine), and the GitHub Actions logs of the run's finished jobs (`ingest-logs.zip` or `refine-logs.zip`), the same text as the run's page shows. Together they stay under 28 MB; a zip that doesn't fit is left off and the email says so (Resend allows 40 MB per email, and base64 adds a third).
  - **Resend:** weekendboise.com is verified in Resend and `RESEND_API_KEY` is scoped to it. The emails come from `WeekendBoise Reports <reports@weekendboise.com>`, set in `Send-TvReport` (`lib/Report.ps1`), with `reply_to` set to `REPORT_EMAIL`, so a reply reaches you rather than the unmonitored reports@ address. A failed send fails the step.
  - **Weekly local reminder:** the ingest `report` job's last step, `Send-LocalReminder.ps1`, sends only on the scheduled Sunday run and only when a running source is marked local. Preview it with `./ingestion/scripts/Send-LocalReminder.ps1 -Force -PreviewPath ./out/reminder` (it emails only when both secrets are set).
  - **Previewing locally:** `./ingestion/scripts/Send-Report.ps1 -Kind ingest -PreviewPath ./out/report` writes `out/report.txt` and `.html`, and sends nothing unless both secrets are set as environment variables.

Create these repository secrets (Settings > Secrets and variables > Actions). Only `TICKETMASTER_KEY` and `GOOGLE_CALENDAR_API_KEY` are needed for sources today; the other API keys are for sources that are built but not running yet. An unset secret reaches the scripts as empty. Only the ingest step gets the API keys; both workflows' email steps get `RESEND_API_KEY` and `REPORT_EMAIL`, which is kept as a secret so the address stays out of this public repo.

| Secret | Used by |
| --- | --- |
| `TICKETMASTER_KEY` | Ticketmaster (running) |
| `GOOGLE_CALENDAR_API_KEY` | Google Calendar sources (running): a Google Cloud API key with the Calendar API enabled, restricted to that API |
| `BANDSINTOWN_APP_ID` | Bandsintown (needs an approved app id) |
| `EVENTBRITE_TOKEN` | Eventbrite (disabled) |
| `SEATGEEK_CLIENT_ID` | SeatGeek (disabled) |
| `SONGKICK_API_KEY` | Songkick (disabled) |
| `RESEND_API_KEY` | The report emails, both workflows |
| `REPORT_EMAIL` | Where the report emails go, both workflows |

First-time setup in the GitHub UI is in [github-setup.md](github-setup.md).

## Adding a source

Add an entry to `ingestion/sources.json`. An idea needs only a `displayName`; a source ingest runs needs a `name`, its adapter's fields, and `status: running`. If an existing adapter fits (most WordPress event calendars and ICS feeds do), that's all. See [sources.md](sources.md) for each adapter's fields and how to find a feed. Otherwise add a script under `ingestion/scripts/adapters/` that emits events in the [common schema](schema.md), plus a fixture under `ingestion/tests/fixtures/`.

Prefer official APIs and published feeds over scraping. Adapters identify themselves in the User-Agent and keep request rates low.

## Status

Ingestion, the nightly ingest and refine workflows, the report emails, and the website are built. The site still has the TESTING ONLY `?period=day|sunset|night` switch in `website/layouts/baseof.html`, to remove before launch.

## Built with

Designed and built with [Claude Code](https://claude.com/claude-code) and [Claude](https://claude.ai). The source list, architecture, and adapters were developed collaboratively; mistakes are mine.

## License

[Unlicense](../LICENSE). Event data belongs to the venues and organizers who publish it.
