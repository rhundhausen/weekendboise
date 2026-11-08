# Sources

`ingestion/sources.json` lists every source: the ones ingest runs, configured ones waiting on credentials, ideas, and sites already ruled out. Ingest runs only entries whose `status` is `running`. It is hand-edited: keep entries sorted by `displayName`, ignoring case. Run `./ingestion/scripts/Test-Sources.ps1` from the repo root after editing.

**Check it before probing any site.** See [Status lifecycle](#status-lifecycle) below.

## Common fields

An idea needs only `displayName`. An entry with a `name` is a configured source and needs every field marked "configured".

| Field | Required | Notes |
| --- | --- | --- |
| `displayName` | always | The place, organization, or site. Unique, ignoring case |
| `status` | no | `idea` (the default when missing), `investigating`, `feed-found`, `ready`, `running`, or `ruled-out`. Ingest runs only `running` |
| `reason` | `ruled-out` | Why it was ruled out |
| `name` | `running` | Unique slug, also the per-source output file name. Setting it makes the entry a configured source |
| `adapter` | configured, `ready` | `cityofboise`, `eventastic`, `ics`, `rss`, `tribe`, `ticketmaster`, `eventbrite`, `eventbrite-search`, `seatgeek`, `songkick`, `bandsintown`, or `scrape`. `other` is allowed on ideas that need a new adapter, never on a configured entry |
| `url` | configured, `feed-found`, `ready` | Feed or API endpoint, or the site for an idea |
| `category` | configured | An id from `data/schema/categories.json`, used for this source's events. With `inferCategory`, it's the fallback |
| `inferCategory` | no | `true` chooses each event's category from its tags. Use it for sources that mix many kinds of event. See [schema.md](schema.md#categories-and-tags) |
| `city` | configured | Fallback city. Use `Other` for aggregators |
| `venue` | configured | Fallback venue display name |
| `venueKey` | configured | Fallback venue slug |
| `priority` | no | Integer, default 50, lower is better. When sources report the same event, the url comes from the lowest number. Official sources use 20 and aggregators use 80 |
| `local` | no | `true` for a site that turns away or times out on GitHub's servers but loads from a home connection. The nightly ingest skips it and keeps its last fetch; `Invoke-LocalIngest.ps1` runs it from a PC, and the Sunday ingest emails a weekly reminder. See [development.md](development.md#nightly-workflows) |
| `robotsChecked`, `termsChecked` | no | `YYYY-MM-DD`. The outcome goes in `notes`, or in `reason` if it ruled the site out |
| `organizer` | no | Free text |
| `notes` | no | Free text. For ideas, what was tried and found |

`venue`, `venueKey`, and `city` are fallbacks. When an event reports its own location, that wins. The exception is `ticketmaster`, which always uses the entry's values so a venue's key matches the key other sources use for it.

Unknown fields fail validation, so a typo can't silently turn a setting off. A new adapter field must also be added to `ingestion/schema/sources.schema.json`.

## Per-adapter fields

### ics

| Field | Required | Notes |
| --- | --- | --- |
| `locationFilter` | no | Regex. Only events whose `LOCATION` matches are kept. Athletics feeds use it to remove away games |

`url` is the ICS feed. `RRULE` isn't expanded yet: a recurring event yields its first occurrence and logs a warning.

### meetup

One entry per Meetup group, named `meetup-<group slug>` (lowercase, underscores as hyphens), with `url` set to `https://www.meetup.com/<group slug>/events/ical/`. Meetup's feed has each event's title, times, description, and link, but no `LOCATION`, so for each new event the adapter reads its Meetup page once, whose schema.org data gives the venue, the city, and whether the event is online. Online events and events whose city isn't one this site covers are dropped. Events already in `data/raw-events.json` from an earlier night reuse the venue and city stored there, so only new events cost a request; a page that can't be read drops that event for the night with a warning. Canceled and past events are skipped before any page is read, and the group's name is removed from the start of each description.

robots.txt allows the iCal feeds and event pages (it disallows Meetup's atom, rss, and xml feeds). It is read once per run for every Meetup source, and requests to meetup.com are at least 1 second apart across all of them. A private group's feed answers 403; those are `ruled-out`, never worked around. `venue`, `venueKey`, and `city` are fallbacks only. The ingest email sums the groups up in one "Meetup groups" line, since a group with nothing scheduled is normal.

### tribe

| Field | Required | Notes |
| --- | --- | --- |
| `fixedVenue` | no | `true` uses the entry's venue for every event. Use it when a site lists rooms or buildings as venues, like Expo Idaho |
| `excludeTitlePattern` | no | Regex. Matching titles are skipped, such as the Idaho Wine Commission's weekly happy hours |
| `localTimeAsUtc` | no | `true` for a site set to UTC+0 (as Donnelly Library is), whose `utc_start_date` is really Boise wall-clock time. Reads `start_date` as local instead |

`url` is the REST events endpoint, ending in `/wp-json/tribe/events/v1/events`. The site's event categories feed tag matching.

### eventastic

For WordPress sites running the Eventastic plugin by Madden Media (Visit McCall; Visit Nampa uses it too). `url` is the site's events page. The calendar on that page fills itself by posting `action=get_events_date_ordered` with `start_date` and `end_date` to `/wp-admin/admin-ajax.php`; the adapter checks robots.txt for that path and makes the same request once, for today through the next 180 days. A weekly event lists its dates in `pattern_dates`, and each one becomes its own event; any other event runs from `start_date` to `end_date`. Times are like "5:30 pm"; an event without one is all-day. The venue is the event's venue term, or the entry's venue when it has none, and `meta.city` sets the city when it is a known one. `excludeTitlePattern` (regex) skips matching titles. The `?ical=1` trick for The Events Calendar does not work on these sites: it returns the HTML page.

### ticketmaster

| Field | Required | Notes |
| --- | --- | --- |
| `venueId` | one of these | Discovery API venue id. Reads one venue, and uses the entry's venue |
| `latlong`, `radius` | one of these | Center as `lat,lon`, and radius in miles. Reads an area, and uses each event's venue |
| `excludeVenueIds` | no | Venues another source covers |
| `excludeSegments` | no | Whole segments to skip, such as `Sports` |
| `excludeTitlePattern` | no | Regex. Matching titles are skipped, for listings that aren't events and games a team feed covers |

`url` is `https://app.ticketmaster.com/discovery/v2/events.json`. Requires the `TICKETMASTER_KEY` environment variable. Category comes from the Ticketmaster segment, and the entry's `category` applies when the segment has no mapping. Segment and genre names also feed tag matching. The API stops at 1,000 results for one search.

### eventbrite

| Field | Required | Notes |
| --- | --- | --- |
| `organizationIds` | one of these | Organizations to read |
| `venueIds` | one of these | Venues to read |

`url` is `https://www.eventbriteapi.com/v3`. Requires the `EVENTBRITE_TOKEN` environment variable. Online and cancelled events are skipped. Disabled: built from the documented response and never run live.

### eventbrite-search

`url` is an Eventbrite browse page, such as `https://www.eventbrite.com/d/id--emmett/events/`. No key is needed. Events come from the page's `window.__SERVER_DATA__` JSON (`buckets[].events[]`), with start and end in the event's own zone. Online events, cancelled events, and events with no address or an address outside Idaho are skipped. A "near Emmett" page covers the wider valley, so venue and city come from each event. The listing has no prices, so each kept event's page is read once a run for its schema.org offers, which set the cost tier; a lowest price of 0 there means free. Requests follow robots.txt and are at least 1 second apart. To add another town, add an entry with that town's browse page.

### seatgeek

| Field | Required | Notes |
| --- | --- | --- |
| `latlong`, `radius` | yes | Center as `lat,lon`, and radius in miles |

`url` is `https://api.seatgeek.com/2/events`. Requires the `SEATGEEK_CLIENT_ID` environment variable. Only Idaho venues are kept. The lowest price sets the cost tier; the price itself is not stored. Disabled: built from the documented response and never run live.

### songkick

| Field | Required | Notes |
| --- | --- | --- |
| `metroAreaId` | yes | Metro area id. It's the number in a Songkick metro page URL |

`url` is `https://api.songkick.com/api/3.0`. Requires the `SONGKICK_API_KEY` environment variable. Disabled: never run live, and the official docs could not be confirmed, so check the endpoint and field names against a real response before enabling it.

### bandsintown

| Field | Required | Notes |
| --- | --- | --- |
| `artistOrVenue` | yes | Name to look up. The API is keyed by artist |

`url` is `https://rest.bandsintown.com`. Requires the `BANDSINTOWN_APP_ID` environment variable. Only Idaho dates are kept.

No source uses this adapter yet, and it has never run against the live API. Its test fixture is written by hand from the documented response shape. See "Not yet working".

### scrape

The last resort, for sites with no API or feed. Check for a feed first: a working feed is always better.

| Field | Required | Notes |
| --- | --- | --- |
| `scrapeMode` | yes | `jsonld`, `cards`, `calendarapp`, `civicplus`, `chambermaster`, or `sveltekit`, see below |
| `eventLinkPattern` | no | `jsonld`: regex for event links on the list page. Each linked page is read. Without it, the list page itself is read |
| `maxPages` | no | `jsonld`: most event pages to read in one run. Defaults to 40. `civicplus` and `chambermaster`: months to read, starting with this one. Defaults to 3 |
| `itemPattern` | `cards` | Regex matching one event's HTML block |
| `datePattern` | no | `cards`: regex with named groups `month` and `day`, matched inside a card. Defaults to `month` and `day` spans. Add a `year` group to read the year as given: a numeric date, such as `date=2026-11-14` in a link (The Little Gym), or a month name with the year elsewhere in the card (Fiddlers' Contest) |
| `yearFromTitle` | no | `cards`: `true` takes the year of the dates from a year in the card title, such as "Winter Carnival 2027", instead of guessing it from the month (McCall Winter Carnival). A later date before the first is the next year's |
| `titlePattern` | no | `cards`: regex with a named group `title`. Defaults to the first heading |
| `timePattern` | no | `cards`: regex with named groups `start` and optional `end`, such as `3:00 pm`. Without a match, the event is all-day |
| `localTimeAsUtc` | no | `true` corrects sites that write local time as UTC |
| `fixedVenue` | no | `true` uses the entry's venue for every event |
| `excludeTitlePattern` | no | `jsonld`, `cards`, `civicplus`, `chambermaster`, and `sveltekit`: regex. Matching titles are skipped, such as meetings and closures |
| `excludeDescriptionPattern` | no | `jsonld`: regex, matched against the description as plain text with WordPress shortcodes such as `[post_title]` removed. Matching events are skipped. Bluebird Social uses it to skip food trucks, whose descriptions are only shortcodes |

`url` is the list page.

- **`jsonld`** reads schema.org `Event` data embedded in the page. This is the preferred mode, because the site publishes it for machines and it survives a redesign.
- **`cards`** reads HTML blocks: dates with no year, a title, a link, and optionally a time. It breaks when the site's markup changes, so use it only when `jsonld` isn't possible. `jump-boise` shows the pattern fields.
- **`calendarapp`** reads the event JSON that City of Boise calendar pages (boiseartsandhistory.org) embed in the `data-config` attribute of `#calendar-app`. It reads the `start` and `end` fields, which are Boise wall-clock time, and skips past events.
- **`civicplus`** reads a CivicPlus city calendar (`Calendar.aspx`, as on staridaho.org and kunacity.id.gov). `url` is the `Calendar.aspx` page. Each month is its own page (`?month=12&year=2026&day=1`), so one run makes `maxPages` requests at the site's crawl delay. It reads each event's title and date line ("November 10, 2026, 6:30 PM - 8:00 PM", "All Day", or a range of dates), and the hidden schema.org microdata for the place, city, and description when it's there. The placeholder place "Event Location" falls back to the entry's venue. CivicPlus sites disallow their iCalendar export and RSS.aspx in robots.txt, which is why this reads the HTML. City calendars are mostly meetings and closures, so set `excludeTitlePattern`.
- **`chambermaster`** reads a ChamberMaster or GrowthZone chamber calendar (as on business.emmettidaho.com). `url` is the `/events/calendar/` page. Later months are `/events/calendar/YYYY-MM-01`. Each month page lists every day's events as links to `/events/details/<slug>-<id>`, and a multi-day event is listed on every day. Titles are filtered with `excludeTitlePattern` and past events are skipped on the list, before anything else is fetched. Each remaining event is read from its iCal file at `/events/ical/<slug>-<id>.ics`, at most 150 a run. The location reads "Name 123 Street City, ID": the name ends at the house number, and a location with no name falls back to the entry's venue. Chamber calendars carry many weekly church services and classes, so set `excludeTitlePattern`.
- **`sveltekit`** reads a SvelteKit chamber site that serves its ChamberMaster calendar as page data (as on staridahochamber.com/events), in one request. The page's `kit.start(...)` call lists `data` for each page node, written as a JavaScript function whose arguments stand in for repeated values; `ConvertFrom-TvJsLiteral` (lib/Scrape.ps1) reads it without running anything. The events node has `events` (Id, Name, Description, StartTime, EndTime, IsAllDay, Slug, in Boise wall-clock time) and `eventDetails` (EventLocation). Each event links to `/events/details/<slug>-<id>`. The venue comes from "(@ Star Library)" in the title, which is then dropped from the title, or "@ Helina Marie's", which stays; otherwise from the location's first line when a street line follows it, else the entry's venue. The city comes from the location, else the entry's city. Set `excludeTitlePattern` for chamber business.

### cityofboise

Reads `/umbraco/api/events/events`, the JSON API behind cityofboise.org/events, 10 events a page, 1 second apart, starting today. Times are Boise wall-clock time. Events titled "Canceled - ..." are skipped. No extra fields.

### rss

Reads an RSS 2.0 feed that uses the RSS event module (`ev:` namespace), which carbonhouse venue sites publish at `/events/rss`. Items need `ev:startdate`; items without one, like news posts, are skipped. `ev:enddate` gives a multi-day end, and `ev:type` is passed on as a publisher label for classification. Times in the feed are UTC.

| Field | Required | Meaning |
| --- | --- | --- |
| `venuePrefix` | no | Put in front of each item's `ev:location` to make the venue, so "Arena" becomes "Ford Idaho Center Arena" |
| `fixedVenue` | no | `true` uses the entry's venue for every event |
| `excludeTitlePattern` | no | Regex. Matching titles are skipped |

### ics: fixedVenue

`fixedVenue: true` on an `ics` entry uses the entry's venue for every event. The library LibCal feeds need it, because their `LOCATION` names rooms ("Children's Area"), not the building. `excludeTitlePattern` (regex) skips matching titles, such as library closures and board meetings. `localTimeAsUtc: true` is for Events Calendar sites set to UTC+0 (Tamarack Resort): their `?ical=1` feed labels Boise wall-clock time `TZID=UTC`, which would make every timed event 7 hours early.

Compare scraped times with what the site displays before enabling a source. Modern Events Calendar sites write local time as if it were UTC, which makes every event 7 hours early. Idaho History, Visit Boise, and Bluebird Social need `localTimeAsUtc`.

The adapter's rules, enforced in code and covered by tests:

- It reads `robots.txt` first, and checks every URL against it. A disallowed URL is never requested.
- If `robots.txt` can't be read, other than a 404, the source fails.
- A 403 or a challenge page fails the source. It never retries around one or changes its identity. A site that refuses us stays out.
- Requests are at least 1 second apart, or the site's `Crawl-delay` if that's longer.
- A `Crawl-delay` over 60 seconds fails the source, so one site can't stall the run. The delay is never ignored.

## Finding an ICS feed

1. Look for a "Subscribe" or "Add to calendar" link on the schedule page. A `webcal://` link is the feed: replace `webcal` with `https`.
2. Search the page source for `.ics`. The Idaho Steelheads links are in the schedule page's HTML.
3. Try the URL patterns for common platforms:
   - SIDEARM athletics sites: `/calendar.ashx/calendar.ics`
   - Localist calendars: `/calendar.ics`, which accepts `?event_types[]=<id>`. List the ids at `/api/2/events/filters`
   - The Events Calendar: `/events/?ical=1`, though the REST endpoint below gives more data

Check that the response is `text/calendar` and contains `BEGIN:VEVENT`. Read the site's `robots.txt` before trying a URL pattern.

## Finding a tribe endpoint

Request `/wp-json/tribe/events/v1/events?per_page=1` on the site:

- HTTP 200 with JSON and an `X-TEC-Total` header: it works. Add `start_date=2026-01-01` to see past events, since a seasonal site can report zero upcoming.
- HTTP 404 with `rest_no_route`: WordPress, but not this plugin.
- HTML: the site isn't exposing this API.

Use the host the site redirects to. For example, the Idaho Botanical Garden only works on `www`.

## Looking up a Ticketmaster venue id

```powershell
. ./ingestion/.env.ps1
$url = "https://app.ticketmaster.com/discovery/v2/venues.json?stateCode=ID&keyword=Knitting%20Factory&apikey=$env:TICKETMASTER_KEY"
(Invoke-RestMethod $url)._embedded.venues | Select-Object id, name, @{ n = 'city'; e = { $_.city.name } }, @{ n = 'upcoming'; e = { $_.upcomingEvents._total } }
```

A venue can have several ids. Use the one with upcoming events. A venue with its own source must also be added to `excludeVenueIds` on `ticketmaster-metro`, or its events are fetched twice.

## Ticketing platforms

Most Treasure Valley events are sold through these platforms. Ranked by usefulness to this project.

| Platform | Role in Treasure Valley | Known local venues/orgs | Public API | Ingest approach | Priority |
| --- | --- | --- | --- | --- | --- |
| Ticketmaster | Primary seller for major venues | Boise State Athletics, ExtraMile Arena, Morrison Center, Ford Idaho Center, Idaho Central Arena (Steelheads) | Yes, Discovery API | Discovery API with geo filter | High |
| Eventbrite | Default for self-service community events, classes, fundraisers, small venues | The Olympic | Limited. Location search removed in 2019 | API by venue or organizer id | High |
| Etix | Clubs, fairs, performing arts orgs | Knitting Factory nationally | No general public API | Scrape venue pages | Medium |
| SeatGeek | Resale plus some primary | Knitting Factory shows, Boise State resale | Yes | API with geo filter | Medium |
| StubHub | Resale only | Boise State football, arena concerts | Partner API only | None planned. Resale duplicates primary listings | Low |
| AXS | AEG promoter shows | Revolution Concert House, Idaho Center | No | Scrape | Low |
| Ticketweb | Ticketmaster's club arm | Knitting Factory Boise (primary seller) | Via Ticketmaster | Covered by the Ticketmaster API | Low |
| Showclix | Festivals, haunted attractions, holiday light shows, pumpkin patches | Seasonal attractions | No | Scrape per event page | Medium (seasonal coverage) |
| Tix, TicketLeap, Brown Paper Tickets | Long tail for community theater, small comedy, church events | Boise Little Theater, Stage Coach | No | Scrape, or RSS where available | Low |
| Venue-native systems | Tessitura, Boise State athletics portal, city Parks and Rec registration | Boise Phil, Ballet Idaho, Opera Idaho | No | Scrape per venue | Medium |

## Aggregators (non-selling)

| Platform | Role in Treasure Valley | Known local venues/orgs | Public API | Ingest approach | Priority |
| --- | --- | --- | --- | --- | --- |
| Songkick | Indexes nearly every music venue in the metro and links out to the seller | Metro-wide music venues | Yes, by application. Access unconfirmed | API with metro area filter | High |

Songkick covers the first seven ticketing platforms for music without scraping.

## Ingest order

Start with the four public APIs (Ticketmaster, Eventbrite, SeatGeek, Songkick), then Showclix and Etix scrapes for seasonal and club coverage, then the long tail.

Ticketmaster is `running`. Eventbrite, SeatGeek, and Songkick are configured and `ready` until they have credentials. Scraping must follow the project rule: no evading bot controls, so a site that refuses requests stays out. The sites that already have are `ruled-out` in `sources.json`.

### API status

Checked 2026-11-02.

| API | Status |
| --- | --- |
| Ticketmaster | Working in this project, by venue and across the metro area. A key is free |
| Eventbrite | `GET /v3/events/search/` was shut down on 2019-12-12. Events can only be listed by venue or organization, so this needs a hand-kept list of ids. Adapter built, no token yet |
| SeatGeek | Documented geo filter with `lat`, `lon`, and `range`. Adapter built, no `client_id` yet, so not tested |
| Songkick | The docs still ask developers to apply for a key. Secondary sources say hobby access has closed or is paid. Unconfirmed. Adapter built, no key yet |

## Ideas and the status lifecycle

Ideas, candidates, and ruled-out sites live in `sources.json` with the running sources, so there is one place to check and nothing to keep in step. A `ruled-out` entry's `reason` says why; don't re-probe those, and never work around a refusal. They need the publisher's permission or a different feed. An `investigating` entry's `notes` say what was tried, so the next probe can try something else.

### Adding an idea

An entry is valid with nothing but a displayName:

```json
{ "displayName": "Egyptian Theatre" }
```

Add it to `sources`, keep the list sorted by `displayName`, and run `./ingestion/scripts/Test-Sources.ps1`. Fill in the rest as you learn it.

### Status lifecycle

| Status | Means | Needs |
| --- | --- | --- |
| `idea` | Someone thought of it. Nothing checked | `displayName` |
| `investigating` | Probed, nothing usable found yet. `notes` say what was tried | `displayName` |
| `feed-found` | A feed, endpoint, or venue id exists | `url` |
| `ready` | Adapter known; waiting on credentials, terms, or a decision | `url`, `adapter` |
| `running` | Ingest reads it every night | `name` and the full configuration |
| `ruled-out` | Don't re-probe | `reason` |

To start running an idea, give it a `name` and its adapter's fields, set `status` to `running`, and keep its `notes`: they are the record of how the source was found. To try a configured source without running it nightly, leave it `ready` and run `Invoke-Ingest.ps1 -Source <name> -NoWrite`.

### Validation

`Test-Sources.ps1` checks each entry on its own. It runs at the start of every ingest.

- A problem in a `running` entry, a duplicate `name`, or a file that doesn't parse fails the run, because ingest can't run safely.
- A problem in any other entry, or two displayNames that differ only in case, is a warning. A half-written idea never stops the nightly run.
- Unknown fields are a problem everywhere, so a typo can't silently turn a setting off.

### Platform notes

- Showclix, TicketLeap, and Tix sell tickets for individual organizers, so there is no local list to read. Add an organizer as its own idea instead.
- Squarespace sites: `robots.txt` disallows the `format=ical` and `format=json` URLs, so `scrape` reads event pages instead.
