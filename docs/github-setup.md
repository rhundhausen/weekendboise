# GitHub setup

Manual steps in the GitHub UI after the move back from Azure DevOps on 2026-11-04. Do them in order.

## 1. The repository

`rhundhausen/weekendboise` (named `WeekendBoise` until 2026-11-05) already exists. It was recreated on 2026-11-03 and holds 3 commits that only touch `README.md`; the pre-ADO history is not in it. The local clone at `C:\Projects\Data\Repos\GitHub\rhundhausen\WeekendBoise` tracks it, so commit the moved files on top of `main` and push normally. No force push is needed.

If you would rather start from an empty history, delete and recreate the repo instead. Force-pushing over it works too, but it rewrites the 3 README commits.

## 2. Default branch

Settings > General > Default branch: `main`. The nightly schedule only runs on the default branch.

## 3. Enable Actions

Settings > Actions > General:

- Actions permissions: allow all actions, or at least actions created by GitHub (`actions/checkout`, `actions/upload-artifact`).
- Workflow permissions: either setting works, because `ingest.yml` and `refine.yml` ask for `contents: write` themselves. Read and write is not required.

If `main` gets a branch protection rule or ruleset later, allow `github-actions[bot]` to push to it, or the nightly data commit will be rejected.

## 4. Repository secrets

Settings > Secrets and variables > Actions > New repository secret. The names must match exactly:

| Secret | Needed now |
| --- | --- |
| `TICKETMASTER_KEY` | Yes, 13 Ticketmaster sources are running |
| `GOOGLE_CALENDAR_API_KEY` | Yes, for the Google Calendar sources. A Google Cloud API key with the Google Calendar API enabled, restricted to that API |
| `BANDSINTOWN_APP_ID` | No, once an app id is approved |
| `EVENTBRITE_TOKEN` | No, adapter is disabled |
| `SEATGEEK_CLIENT_ID` | No, adapter is disabled |
| `SONGKICK_API_KEY` | No, adapter is disabled |
| `RESEND_API_KEY` | For the report emails. A Resend API key (resend.com > API Keys, "Sending access") |
| `REPORT_EMAIL` | For the report emails. Where they go, and where replies go. One address, or several separated by commas |

The emails come from `WeekendBoise Reports <reports@weekendboise.com>` (weekendboise.com is verified in Resend; `RESEND_API_KEY` is a key scoped to that domain), and replies go to `REPORT_EMAIL`. The sender is set in `ingestion/scripts/lib/Report.ps1`, not in a secret.

A secret you don't create reaches the scripts as empty, and that source fails with a warning while the rest run. Without `RESEND_API_KEY` or `REPORT_EMAIL`, the "Email the report" step warns and sends nothing.

## 5. Prove the data commit with one source

Before the midnight (Boise time) schedule runs on its own:

1. Actions > ingest > Run workflow, branch `main`, source `idaho-steelheads` (or any one running source). Leave the source blank the very first time, so the raw file starts with every source.
2. When it finishes, check:
   - The run is green and the `out` artifact holds `idaho-steelheads.json` and `run.json`.
   - `main` has a new commit by "WeekendBoise bot" titled `data: raw ingest YYYY-MM-DD [skip ci]` that changes only `data/raw-events.json`, and Cloudflare skipped it.
3. Refine starts by itself when ingest finishes (Actions > refine; it can also be run by hand, branch `main`). When it finishes, check:
   - The run is green and its log starts with the raw file's `asOf` and source count.
   - `main` has a new commit titled `data: nightly refine YYYY-MM-DD` that changes only `data/events.json`, `data/archive/`, `data/links.json`, `data/city-lookup.json`, and `data/meta.json`, and its "Workers Builds: weekendboise" check deployed the site.
   - The test workflow did not run for either commit.
4. If a commit step fails with a permission error, recheck step 3.

After that, leave ingest's schedule to run nightly at midnight Boise time; refine follows each ingest run. GitHub turns off scheduled workflows in a public repo after 60 days with no repository activity; the nightly data commits count as activity, so this only matters if ingest stops committing.
