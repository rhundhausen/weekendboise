# Event schema

`data/events.json` is an array of events, sorted by `start` then `id`. `data/archive/YYYY-MM.json` uses the same shape for past events, filed by the month of `start`. The JSON Schema is `ingestion/schema/event.schema.json`.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `id` | string | yes | Stable hash, see below |
| `title` | string | yes | Plain text |
| `start` | string | yes | ISO 8601 with the Boise offset, or `YYYY-MM-DD` when `allDay` is true |
| `end` | string | no | Same format as `start`. Omitted when unknown. An all-day `end` is the last day, inclusive |
| `allDay` | boolean | no | Defaults to false |
| `venue` | string | yes | Display name |
| `venueKey` | string | yes | Lowercase slug, for example `extramile-arena` |
| `city` | string | no | `Boise`, `Meridian`, `Nampa`, `Caldwell`, `Eagle`, `Garden City`, `Kuna`, `Star`, `Emmett`, `Marsing`, `Middleton`, `Mountain Home`, `Payette`, `Weiser`, `Valley County`, or `Other` |
| `category` | string | yes | One id from `data/schema/categories.json` |
| `tags` | array | no | Zero or more ids from `data/schema/tags.json` |
| `size` | string | no | Estimated crowd: `S`, `M`, `L`, or `XL`. A guess, see below |
| `costTier` | string | no | `free`, `$`, `$$`, or `$$$`, from the cheapest adult ticket. Left out when the price is unknown. See below |
| `url` | string | yes | Canonical event page, from the source with the best `priority` |
| `description` | string | no | Plain text, at most 300 characters |
| `linkBroken` | boolean | no | Set by the nightly link check when `url` is gone and no other source's link works. See below |
| `sources` | array | no | One entry per source that reported the event |

Each `sources` entry has:

| Field | Type | Notes |
| --- | --- | --- |
| `name` | string | Source name from `sources.json` |
| `url` | string | The event page that source reported |
| `fetchedAt` | string | UTC time this source first reported the event. It doesn't change on later runs, which keeps nightly diffs small |

Stored data stays minimal because event data belongs to the publishers: no images, no full descriptions, and no ticket prices. A sentence containing a dollar amount is removed from `description`. A rough cost tier is stored instead of the price.

## Cost tiers

The rules are in [cost-tiers.md](cost-tiers.md): free is $0, and the breakpoints (`$CostTierBreakpoints` in `ingestion/scripts/lib/Cost.ps1`, $15 and $40 as of 2026-11-06) split `$`, `$$`, and `$$$`. `Get-CostTier` is the only function that turns a price into a tier. The site shows `Free`, `$`, `$$`, or `$$$` and leaves unknown blank.

The price (`priceMin`, the cheapest adult ticket, face value) comes from, in order, and is never stored:

1. The source's price data: Ticketmaster `priceRanges` (face value ranges before ranges that include fees), the tribe and calendarapp `cost` text (`ConvertFrom-TvPriceText`), schema.org `offers` (a price of 0 is ignored there, since sites use it as a placeholder), SeatGeek `lowest_price`, and the Eventbrite event page.
2. The `free-admission` tag, which means 0.
3. The description's price text, read before its price sentences are removed. In prose only phrases like "free admission" count as free.

When duplicates merge, the best source keeps its own `costTier`, and a duplicate's fills in when the best source has none. Nothing is guessed: an event with no price is unknown. Events stored before 2026-11-06 carried `cost` and `costGuess`; refine moves them to `costTier` (see cost-tiers.md, Backfill).

## Link check

`data/links.json` holds the state of the nightly link check: one entry per link with `verdict` (`ok`, `broken`, `blocked`, `transient`, or `skipped`), the last HTTP `status`, an `error` kind (`dns`, `refused`, `timeout`, `error`), `checkedAt`, `brokenSince`, and `failures` (transient failures in a row). See `docs/development.md`.

## Categories and tags

Every event has one primary category and any number of tags. Tags cross categories: a free family Christmas concert is `holiday-seasonal`, tagged `concert`, `free-admission`, and `family-friendly`.

`data/schema/categories.json` holds the 12 categories. Their ids are also enums in both schemas, and a test keeps all three in step.

`data/schema/tags.json` holds the tags:

| Field | Required | Notes |
| --- | --- | --- |
| `id` | yes | Slug. Keep the file sorted by id |
| `label` | yes | Display name |
| `category` | no | The category this tag points to. Leave it out for tags that describe the audience or the price, like `kids` |
| `keywords` | yes | Words to find in event text. Lowercase with no punctuation, because text is normalized before matching: `new years eve`, not `New Year's Eve` |
| `sourceLabels` | no | Publisher labels that mean this tag, matched against the whole label |

How matching works:

- A tag with a `category` needs a match in the title or the publisher's labels, such as tribe categories or Ticketmaster genres. Descriptions mention too many unrelated things to trust.
- A tag with no `category` can also match the description.
- By default an event takes its source's `category`. With `inferCategory` on the source, it takes the category its tags point to, and the source's `category` is the fallback.
- When tags point to several categories, a title match beats a label. After that, the order in `Get-TvClassification` decides: holiday first, because a Christmas concert is a holiday event.

Matching is by keyword, so some events are misfiled. An event whose title is only an artist's name gets no tag unless the publisher labels it.

## Titles

A title in all capitals ("OLD BOISE MODEL RAILROAD") is changed to title case ("Old Boise Model Railroad"). Acronyms stay capitalized: words with no vowels (DJ, CSL), Roman numerals, and the words listed in `data/schema/title-case.json`, which also gives exact spellings (McCall) and the small words kept lowercase (of, the, in). A title with any lowercase letter, or of one word (often a band's own styling, such as KREAM), is left alone. The `id` is computed from the lowercased title, so it does not change. The code is `ConvertTo-TvTitleCase` in `ingestion/scripts/lib/Schema.ps1`.

## Venues

Sources spell a venue in different ways: Ticketmaster has `Neurolux Lounge` and `Knitting Factory - Boise`, and aggregators have `Extra Mile Arena`. Those would count as separate venues and block merging, so `data/schema/venue-aliases.json` maps each spelling to one `venueKey` and name. It applies to every source, before the `id` is computed. To fix a split venue, add a line there. No code changes are needed.

Some sources, mostly Boise Mom, give no city, so their events fall back to `Other`. After merging, refine looks for the city in the event's own venue, title, and description, from strongest clue to weakest: an Idaho ZIP code, "City, ID", "(City)" in the title, a city in the venue name, a known place, a venue other sources place in one city, "in" or "downtown" before a city, then a city named in the title or description. A clue that names two cities is ambiguous and leaves `Other`. Star, Payette, Emmett, Middleton, and Weiser are also everyday words or surnames, so they count only from a ZIP code or "City, ID". Known places (the Basque Block, Warhawk Air Museum) and names to ignore (Boise Cascade, Boise Hawks) are in `data/schema/place-cities.json`; add a line there to teach it a place. Only the city changes, so the `id` stays the same. The code is `Resolve-TvOtherCity` in `ingestion/scripts/lib/Cities.ps1`, and every refine run applies it to stored data, including the archive.

## Size

`size` is a best guess at the crowd, not a count. No source reports attendance.

| Size | Crowd |
| --- | --- |
| `S` | Under 100 |
| `M` | 100 to 999 |
| `L` | 1,000 to 4,999 |
| `XL` | 5,000 or more |

The first rule that applies wins, using `data/schema/sizes.json`:

1. A small-format tag in `smallTags`, like `workshop`, gives `S`, even at a big venue.
2. The venue's usual crowd in `venues`. These come from approximate capacities.
3. The largest size among the event's tags in `tags`.
4. The category's usual size in `categories`.

The venue rule treats every event there alike, so a women's basketball game at ExtraMile Arena gets the same `XL` as a sold-out concert. To improve a guess, edit `sizes.json`. No code changes are needed.

## id

The first 12 hex characters of:

```
sha1(lowercase(normalizedTitle + "|" + startDate + "|" + venueKey))
```

`normalizedTitle` is lowercase, with diacritics and apostrophes removed and other punctuation reduced to single spaces. `startDate` is the `YYYY-MM-DD` part of `start`.

The hash uses the date, not the time, so two showings of one title at one venue on the same day share an id and merge into one event.

## Duplicates

Two events are the same if their ids match, or if their normalized titles have Jaro-Winkler similarity above 0.9, they start within 30 minutes, and `venueKey` matches. Two multi-day events from different sources are also the same, whatever their venue and start time, if their normalized titles match and they share a known city and start day, since sources often disagree on a festival's opening time and building. When merging, the longest description is kept, the url comes from the source with the lowest `priority`, and `sources` is unioned.

## Lifecycle

An event moves to the archive once it has ended, or once it has started if it has no `end`. An all-day event stays upcoming through its last day. Events starting more than 180 days out are left out until they're inside that window.

A source that refreshes successfully replaces its stored upcoming events, so an event the publisher removed disappears. A source that fails keeps its stored events until a later run refreshes them.
