# WeekendBoise

WeekendBoise is an automated reader of public event calendars in Idaho's Treasure Valley (Boise, Meridian, Nampa, Eagle, Caldwell, Garden City, Kuna, Star and nearby). It collects upcoming events into one non-commercial calendar, published at [weekendboise.com](https://weekendboise.com).

This page is for site owners who see the WeekendBoise bot in their logs.

## Identifying the bot

Requests come with this User-Agent:

    WeekendBoise/1.0 (+https://github.com/rhundhausen/weekendboise)

## How it behaves

- Runs once a day, at midnight Boise time.
- Reads only public sources: calendar feeds (ICS, including public Meetup group calendars), WordPress event APIs, the City of Boise events API, official APIs such as Ticketmaster's, and a few public calendar pages.
- May also open a single event's own page: to find the venue and city when a feed leaves them out, and to check now and then that a listed link still works. Each page is requested once and the result remembered, so repeat requests are rare.
- Calendar and event pages are checked against robots.txt on every run, including Crawl-delay, and a disallowed page is never requested.
- Feeds and APIs are checked against the site's robots.txt and terms when they are added as a source.
- Waits at least 1 second between paged requests.
- Never logs in, never bypasses paywalls or bot protection, and never disguises itself as a browser.

## What it keeps

For each event: title, date and time, venue, city, category, and a link back to the original listing. Descriptions are trimmed to a short summary.

It does not keep images, full descriptions, ticket prices, or personal information. Every listing links back to your page, so readers end up on your site.

## Opting out

The surest way is to **open an issue** in this repository naming the site you'd like removed. Your site will be taken off the source list and its events removed within a few days.

You can also block the bot in robots.txt:

    User-agent: WeekendBoise
    Disallow: /

This stops page reading on the next run. If your site is read through a calendar feed or API, please open an issue as well, so that source is removed too.

## Getting listed

Run a venue, organization, or calendar in the Treasure Valley that isn't listed? **Open an issue** in this repository with a link to your public events page. Listing is free.

Any of these makes your events easiest to read, and most calendar tools already provide one:

- A calendar feed (ICS or iCal subscribe link)
- WordPress with The Events Calendar plugin
- Event pages with schema.org Event data, which many event plugins add for search engines
- An RSS feed of events

A plain web page works too, as long as robots.txt allows it.

## Contact

Questions, corrections, or concerns: open an issue in this repository.

## For developers

This repo holds only WeekendBoise's own files: `city.json` (the city's facts), `ingestion/sources.json` (its sources; the core's [docs/sources.md](https://github.com/rhundhausen/weekend/blob/main/docs/sources.md) describes the format), `data/` (events, archive, and the city's lookup tables in `data/schema/`), and the site's icons and Cloudflare config in `website/`. The code, the site's theme, and the workflows are the shared core, [rhundhausen/weekend](https://github.com/rhundhausen/weekend), which this repo's workflows and Cloudflare build fetch from its `main` branch.

To work on it locally, check out the core next to this repo (`../weekend`) and run its scripts from here, for example `../weekend/ingestion/scripts/Test-Sources.ps1`, or build the site with `bash ../../weekend/website/build.sh` from `website/`. How the core is built, tested, and run: its `docs/development.md`.

## License

The code is released into the public domain under the [Unlicense](LICENSE). Event data belongs to the venues and organizers who publish it.
