#Requires -Version 7.4
<#
.SYNOPSIS
  Turns data/raw-events.json into the files the site reads. Stage 2 of 2.
.DESCRIPTION
  Reads the raw file Invoke-Ingest.ps1 wrote and makes no request to any event source. It:

  - merges every source's events with the stored events.json: duplicates collapse to the
    best-priority source, canceled events are dropped, and each event and source keeps its first
    fetchedAt. Past events stay so they can be archived. A running source with no entry in the
    raw file keeps its stored upcoming events;
  - fills in cities for events stored as Other when their own text says where they are
    (Resolve-TvOtherCity), and moves events stored before cost tiers changed to costTier
    (Update-TvLegacyCost);
  - for upcoming events still stored as Other, reads the event page and the organizer site its
    Website link points to (lib/CityLookup.ps1), unless -SkipCityLookup, remembering what it
    found in city-lookup.json;
  - re-cleans every archive month the same way, and appends past events to it;
  - runs the link check (lib/Links.ps1), unless -SkipLinkCheck, and marks events whose link is
    gone with linkBroken;
  - writes events.json, archive/YYYY-MM.json, links.json, city-lookup.json, and meta.json (the raw
    file's asOf, as lastIngest) next to OutputPath, and refine.json and links.json to OutDir.

  Running it again over the same raw file is safe, so it can be rerun by hand as the rules change.
.PARAMETER InputPath
  The raw file. Defaults to data/raw-events.json.
.PARAMETER OutputPath
  The events file to write. archive/, links.json, and meta.json are written in the same folder.
  Defaults to data/events.json.
.PARAMETER SkipLinkCheck
  Make no link requests. Known link results from links.json still apply. -NoWrite implies it.
.PARAMETER SkipCityLookup
  Read no pages to find cities. Cities already in city-lookup.json still apply. -NoWrite implies it.
.PARAMETER CityBudgetSeconds
  How long the city lookup may spend making requests. Pages left over wait for a later run.
.PARAMETER NoWrite
  Do everything and report, but write nothing to the data folder.
.PARAMETER OutDir
  Where refine.json and links.json go.
.PARAMETER Days
  Drop events starting more than this many days out.
.PARAMETER LinkBudgetSeconds
  How long the link check may spend making requests. Links left over wait for a later run.
.PARAMETER SourcesPath
  The sources file, for priorities and which sources are running. Used by tests.
.PARAMETER Now
  The time to sort past from upcoming by. Defaults to now. Used by tests.
#>
[CmdletBinding()]
param(
  [string]$InputPath = (Join-Path $PSScriptRoot '..' '..' 'data' 'raw-events.json'),
  [string]$OutputPath = (Join-Path $PSScriptRoot '..' '..' 'data' 'events.json'),
  [switch]$SkipLinkCheck,
  [switch]$SkipCityLookup,
  [switch]$NoWrite,
  [string]$OutDir = './out',
  [int]$Days = 180,
  [int]$LinkBudgetSeconds = 900,
  [int]$CityBudgetSeconds = 180,
  [string]$SourcesPath = (Join-Path $PSScriptRoot '..' 'sources.json'),
  [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
)

$ErrorActionPreference = 'Stop'
$stamp = { [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
$startedAt = & $stamp

. (Join-Path $PSScriptRoot 'lib' 'Raw.ps1')
. (Join-Path $PSScriptRoot 'lib' 'Cities.ps1')
. (Join-Path $PSScriptRoot 'lib' 'Links.ps1')
. (Join-Path $PSScriptRoot 'lib' 'CityLookup.ps1')

$rawFile = [IO.Path]::GetFullPath($InputPath, $PWD.Path)
$dataPath = [IO.Path]::GetFullPath($OutputPath, $PWD.Path)
$dataDir = Split-Path -Parent $dataPath
$archiveDir = Join-Path $dataDir 'archive'
$linksPath = Join-Path $dataDir 'links.json'
$cityLookupPath = Join-Path $dataDir 'city-lookup.json'
$metaPath = Join-Path $dataDir 'meta.json'
$outPath = [IO.Path]::GetFullPath($OutDir, $PWD.Path)

$raw = Read-TvRawFile $rawFile
if (-not $raw) {
  throw "No raw file at $rawFile. Run the ingest workflow (or Invoke-Ingest.ps1) first: refine only works from what ingest stored."
}
$allSources = @((Get-Content -LiteralPath $SourcesPath -Raw | ConvertFrom-TvJson).sources)
$refreshed = @($raw.sources.PSObject.Properties.Name)
$rawEvents = @(Get-TvRawEvents $raw -Order @($allSources | ForEach-Object name | Where-Object { $_ }))
Write-Host "Raw file: asOf $($raw.asOf), $($refreshed.Count) sources, $($rawEvents.Count) events"

$running = @($allSources | Where-Object { $_.status -eq 'running' } | ForEach-Object name)
$priorities = @{}
foreach ($entry in $allSources) {
  if ($null -ne $entry.priority) { $priorities[$entry.name] = $entry.priority }
}

$existing = @(Read-TvEventFile $dataPath)
$carried = @(Get-CarriedTvEvents $existing -Refreshed $refreshed -Enabled $running -Now $Now)
# Events stored before the cost tier change carry cost and costGuess; move them to costTier
# before the merge compares tiers. A no-op once every stored file has been rewritten.
$legacyCosts = Update-TvLegacyCost (@($rawEvents) + $carried)
# An aggregator's "Various locations" event whose title names a known venue ("... at Zoo Boise")
# takes that venue first, so it can merge with the venue's own listing.
$titleVenues = Resolve-TvTitleVenue (@($rawEvents) + $carried)
$merged = @(Merge-TvEvents (@($rawEvents) + $carried) -Priorities $priorities -DropCanceled)
Restore-TvFetchedAt $merged $existing

$months = @(if (Test-Path -LiteralPath $archiveDir) { Get-ChildItem -LiteralPath $archiveDir -Filter '*.json' | Sort-Object Name })
$archived = @($months | ForEach-Object { Read-TvEventFile $_.FullName })
$cityFixes = Resolve-TvOtherCity $merged -Known $archived

# Each event was valid when built, so a failure here is a merge bug. Never store one.
$merged = @($merged | Where-Object {
    $valid = Test-TvEvent $_
    if (-not $valid) { Write-Warning "Dropping invalid event after merge: $($_.id) '$($_.title)'" }
    $valid
  })

$horizon = $Now.AddDays($Days)
$past = @($merged | Where-Object { Test-TvEventPast $_ $Now })
$upcoming = @(Sort-TvEvents @($merged | Where-Object { -not (Test-TvEventPast $_ $Now) -and (Get-TvEventInstant $_.start) -le $horizon }))

# Re-clean the archive with the current rules, so a rule change reaches past months too.
$archiveBefore = 0
$archiveAfter = 0
foreach ($file in $months) {
  $stored = @(Read-TvEventFile $file.FullName)
  $monthCosts = Update-TvLegacyCost $stored
  $cleaned = @(Merge-TvEvents $stored -Priorities $priorities -DropCanceled)
  $monthCities = Resolve-TvOtherCity $cleaned -Known $archived
  $cityFixes += $monthCities
  $legacyCosts += $monthCosts
  $archiveBefore += $stored.Count
  $archiveAfter += $cleaned.Count
  if (-not $NoWrite -and ($cleaned.Count -ne $stored.Count -or $monthCities -gt 0 -or $monthCosts -gt 0)) {
    Restore-TvFetchedAt $cleaned $stored
    Write-TvEventFile $file.FullName @(Sort-TvEvents $cleaned)
  }
}

# Find cities for upcoming events still stored as Other by reading their pages. Like the link
# check, a failure only warns, and known cities still apply when no requests are made.
$cityState = Read-TvCityLookupState $cityLookupPath
$cityBudget = if ($SkipCityLookup -or $NoWrite) { 0 } else { $CityBudgetSeconds }
$lookup = try {
  Invoke-TvCityLookup $upcoming -State $cityState -Now $Now -BudgetSeconds $cityBudget
} catch {
  Write-Warning "City lookup failed, events keep their stored cities: $_"
  [pscustomobject]@{ State = $cityState; Others = 0; Pages = 0; Requests = 0; Found = 0; Errors = @("$_") }
}

# Check the links that are due, then mark every upcoming event from what is known.
$linkState = Read-TvLinkState $linksPath
$linkBudget = if ($SkipLinkCheck -or $NoWrite) { 0 } else { $LinkBudgetSeconds }
# A link check failure must not cost the night's events, so it only warns.
$links = try {
  Invoke-TvLinkCheck $upcoming -State $linkState -Now $Now -BudgetSeconds $linkBudget
} catch {
  Write-Warning "Link check failed, events keep their stored link flags: $_"
  [pscustomobject]@{ State = $linkState; Checked = @(); Broken = @() }
}

if (-not $NoWrite) {
  Add-TvArchive $archiveDir $past -Priorities $priorities
  Write-TvEventFile $dataPath $upcoming
  Write-TvLinkState $linksPath $links.State
  Write-TvCityLookupState $cityLookupPath $lookup.State
  # Read by the website for its "as of" time: the time ingest ran for, not the time refine ran.
  # The cost tier breakpoints too, so the site's legend comes from the same config block as the tiers.
  $meta = [ordered]@{
    lastIngest          = $raw.asOf
    costTierBreakpoints = [ordered]@{ low = $script:CostTierBreakpoints.Low; high = $script:CostTierBreakpoints.High }
  }
  [IO.File]::WriteAllText($metaPath, (($meta | ConvertTo-Json) -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
}

$null = New-Item -ItemType Directory -Force -Path $outPath
[IO.File]::WriteAllText((Join-Path $outPath 'links.json'), (([ordered]@{ checked = @($links.Checked); broken = @($links.Broken) } | ConvertTo-Json -Depth 4) -replace "`r`n", "`n") + "`n")
$countBy = {
  param([string]$Property)
  $counts = [ordered]@{}
  $upcoming | Group-Object $Property | Sort-Object Count -Descending | ForEach-Object { $counts[$_.Name] = $_.Count }
  $counts
}
$published = [ordered]@{}
foreach ($name in $refreshed) { $published[$name] = @($upcoming | Where-Object { $name -in @($_.sources.name) }).Count }
$report = [ordered]@{
  # startedAt and finishedAt are clock times for the report email; refinedAt is -Now.
  startedAt     = $startedAt
  finishedAt    = & $stamp
  asOf          = $raw.asOf
  refinedAt     = $Now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
  noWrite       = [bool]$NoWrite
  skipLinkCheck = [bool]($SkipLinkCheck -or $NoWrite)
  rawSources    = $refreshed.Count
  rawEvents     = $rawEvents.Count
  upcoming    = $upcoming.Count
  past        = $past.Count
  cityFixes   = $cityFixes
  titleVenues = $titleVenues
  cityLookup  = [ordered]@{
    skipped  = [bool]($SkipCityLookup -or $NoWrite)
    others   = $lookup.Others
    pages    = $lookup.Pages
    requests = $lookup.Requests
    found    = $lookup.Found
    errors   = @($lookup.Errors)
  }
  # Upcoming events per tier, so each run's email shows what the breakpoints do.
  costTiers   = Get-TvCostTierCounts $upcoming
  legacyCosts = $legacyCosts
  categories  = & $countBy 'category'
  sizes       = & $countBy 'size'
  links       = [ordered]@{
    checked   = @($links.Checked).Count
    broken    = @($links.Broken).Count
    newBroken = @($links.Broken | Where-Object new).Count
  }
  sources     = $published
}
[IO.File]::WriteAllText((Join-Path $outPath 'refine.json'), (($report | ConvertTo-Json -Depth 5) -replace "`r`n", "`n") + "`n")
if ($env:GITHUB_STEP_SUMMARY) {
  Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value (ConvertTo-TvLinkSummary $links.Broken -Checked $links.Checked.Count)
}

Write-Host "Refine: $($upcoming.Count) upcoming, $($past.Count) past to the archive (archive $archiveBefore -> $archiveAfter before this run's additions), $cityFixes cities filled in, $titleVenues venues read from titles, $legacyCosts events moved to costTier, $($links.Checked.Count) links checked, $($links.Broken.Count) broken ($(@($links.Broken | Where-Object new).Count) new)$($NoWrite ? ' (not written)' : '')"
