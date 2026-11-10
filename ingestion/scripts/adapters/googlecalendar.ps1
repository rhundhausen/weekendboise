#Requires -Version 7.4
<#
.SYNOPSIS
  Reads the next 90 days of a public Google Calendar through the Calendar API v3.
.DESCRIPTION
  Calls events.list with singleEvents=true, so Google expands repeating events and applies
  each instance's changes and exclusions; no RRULE is read here. Requires the
  GOOGLE_CALENDAR_API_KEY environment variable. Without it, or when the calendar answers 403
  or 404, this throws, and Invoke-Ingest marks only this source failed.

  Skipped: cancelled events, titles starting with "Canceled" or "Cancelled" (any case), and
  titles starting with one of $defaultExcludes or the entry's excludeTitles (any case), as well
  as titles matching excludeTitlePattern. A blank location uses the entry's venue and city; a
  location named in venueAliases (its whole text or any comma-separated part, any case) uses
  that canonical venue; any other is read with ConvertFrom-TvLocation.
.PARAMETER Source
  One entry from sources.json, with calendarId.
.PARAMETER FetchedAt
  UTC timestamp recorded on each event.
.PARAMETER Response
  JSON pages to parse instead of fetching. Used by tests.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][pscustomobject]$Source,
  [Parameter(Mandatory)][string]$FetchedAt,
  [string[]]$Response
)

. "$PSScriptRoot/../lib/Schema.ps1"
. "$PSScriptRoot/../lib/Http.ps1"

$apiBase = 'https://www.googleapis.com/calendar/v3/calendars'
$days = 90
$defaultExcludes = @(
  'Library Closed', 'Library closed-', 'City Council Meeting', 'Planning and Zoning Meeting',
  'School Board Meeting', 'Library Board Meeting'
)

function Get-GoogleCalendarPage {
  if (-not $env:GOOGLE_CALENDAR_API_KEY) {
    throw 'GOOGLE_CALENDAR_API_KEY is not set'
  }

  $invariant = [Globalization.CultureInfo]::InvariantCulture
  $now = [DateTimeOffset]::UtcNow
  $query = [ordered]@{
    singleEvents = 'true'
    orderBy      = 'startTime'
    timeMin      = $now.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
    timeMax      = $now.AddDays($days).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
    timeZone     = 'America/Denver'
    maxResults   = '250'
    key          = $env:GOOGLE_CALENDAR_API_KEY
  }
  $pageToken = $null
  do {
    $parts = @($query.Keys | ForEach-Object { "$_=$([uri]::EscapeDataString($query[$_]))" })
    if ($pageToken) { $parts += "pageToken=$([uri]::EscapeDataString($pageToken))" }
    $uri = "$apiBase/$([uri]::EscapeDataString($Source.calendarId))/events?$($parts -join '&')"
    try {
      $page = Invoke-TvRequest $uri
    } catch {
      if ("$_" -match '^HTTP (403|404)\b') {
        throw "Google Calendar $($Source.calendarId) is not public or the calendar ID is wrong (HTTP $($Matches[1]))"
      }
      throw
    }
    $page
    $pageToken = $page.nextPageToken
  } while ($pageToken)
}

function Test-ExcludedTitle([string]$Title) {
  if ($Title -match '(?i)^\s*cancell?ed\b') { return $true }
  foreach ($prefix in (@($defaultExcludes) + @($Source.excludeTitles | Where-Object { $_ }))) {
    if ($Title.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  [bool]($Source.excludeTitlePattern -and $Title -match $Source.excludeTitlePattern)
}

function Resolve-GoogleCalendarVenue([string]$Location) {
  $Location = "$Location".Trim()
  if (-not $Location) {
    return @{ Venue = $Source.venue; VenueKey = $Source.venueKey; City = $Source.city }
  }
  $parts = @($Location) + @($Location -split ',' | ForEach-Object { $_.Trim() })
  foreach ($alias in @($Source.venueAliases.PSObject.Properties | Where-Object { $_ })) {
    if ($parts -contains $alias.Name) {
      $key = if ($alias.Value -eq $Source.venue) { $Source.venueKey } else { Get-VenueKey $alias.Value }
      return @{ Venue = $alias.Value; VenueKey = $key; City = $Source.city }
    }
  }
  ConvertFrom-TvLocation $Location -Source $Source
}

$pages = if ($Response) { $Response | ForEach-Object { ConvertFrom-TvJson $_ } } else { Get-GoogleCalendarPage }
$seen = [Collections.Generic.HashSet[string]]::new()

foreach ($item in ($pages | ForEach-Object { $_.items } | Where-Object { $_ })) {
  if ($item.status -eq 'cancelled') { continue }
  $title = ConvertTo-PlainText $item.summary
  if (-not $title -or (Test-ExcludedTitle $title)) { continue }

  try {
    $allDay = -not $item.start.dateTime
    $start = if ($allDay) { $item.start.date } else { ConvertTo-BoiseTime $item.start.dateTime }
    if (-not $seen.Add("$($item.id)|$start")) { continue }

    $end = $null
    if ($allDay -and $item.end.date) {
      # An all-day end date is exclusive in the API and inclusive in the schema.
      $last = [DateTime]::ParseExact($item.end.date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture).AddDays(-1).ToString('yyyy-MM-dd')
      if ($last -gt $start) { $end = $last }
    } elseif ($item.end.dateTime) {
      $end = ConvertTo-BoiseTime $item.end.dateTime
    }

    $location = Resolve-GoogleCalendarVenue $item.location
    $url = $item.htmlLink ? $item.htmlLink : $Source.url

    New-TvEvent -Title $title -Start $start -End $end -AllDay:$allDay `
      -Venue $location.Venue -VenueKey $location.VenueKey -City $location.City `
      -Category $Source.category -InferCategory:([bool]$Source.inferCategory) -Url $url `
      -Description (ConvertTo-PlainText $item.description) `
      -Sources @(@{ name = $Source.name; url = $url; fetchedAt = $FetchedAt })
  } catch {
    Write-Warning "$($Source.name): skipping '$($item.summary)': $_"
  }
}
