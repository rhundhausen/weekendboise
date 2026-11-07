#Requires -Version 7.4
<#
.SYNOPSIS
  Reads one Meetup group's events: its iCal feed, plus each new event's page for where it is.
.DESCRIPTION
  Meetup's feed (https://www.meetup.com/<group>/events/ical/) has the title, times, description,
  and link of each event, but no LOCATION. Each event's page carries schema.org Event data with
  the venue, its city, and whether the event is online. So:

  - Canceled events and events already over are skipped, before any page is read.
  - An event already in data/raw-events.json from an earlier night reuses the venue and city
    stored there, so only new events cost a page request.
  - A new event's page is read once. Online-only events, and events whose city is not one this
    site covers, are dropped. A page that can't be read drops the event for tonight with a
    warning; the next night tries again.

  robots.txt allows /<group>/events/ical/ and event pages (it disallows the atom, rss, and xml
  feeds). It is read once per run for all Meetup sources, and requests to meetup.com are at least
  1 second apart across all of them.
.PARAMETER Source
  One entry from sources.json. Its name is meetup-<group slug>.
.PARAMETER FetchedAt
  UTC timestamp recorded on each event.
.PARAMETER Response
  The feed, then the pages of the new events in feed order, instead of fetching. Used by tests.
.PARAMETER RawPath
  The raw file holding earlier nights' events. Defaults to data/raw-events.json.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][pscustomobject]$Source,
  [Parameter(Mandatory)][string]$FetchedAt,
  [string[]]$Response,
  [string]$RawPath = (Join-Path $PSScriptRoot '..' '..' '..' 'data' 'raw-events.json')
)

. "$PSScriptRoot/../lib/Schema.ps1"
. "$PSScriptRoot/../lib/Http.ps1"
. "$PSScriptRoot/../lib/Ics.ps1"
. "$PSScriptRoot/../lib/Scrape.ps1"
. "$PSScriptRoot/../lib/Raw.ps1"

$responseIndex = 0

function Get-MeetupText {
  # The next test response, or a polite request to meetup.com.
  param([string]$Url)

  if ($Response) {
    $text = if ($script:responseIndex -lt $Response.Count) { $Response[$script:responseIndex] }
    $script:responseIndex++
    if ($null -eq $text) { throw "no response for $Url" }
    return $text
  }

  $uri = [uri]$Url
  if ($null -eq $global:TvMeetupRobots) {
    $global:TvMeetupRobots = try { Invoke-TvRequest "$($uri.GetLeftPart('Authority'))/robots.txt" -Raw } catch {
      if ("$_" -match 'HTTP 404') { '' } else { throw }
    }
  }
  if (-not (Test-TvRobotsAllowed $global:TvMeetupRobots $uri.PathAndQuery)) { throw "robots.txt disallows $($uri.PathAndQuery)" }

  # One clock for every Meetup source in this run, so back-to-back groups stay 1 second apart.
  $delay = [Math]::Max(1, [int](Get-TvRobotsGroup $global:TvMeetupRobots).Delay)
  if ($global:TvMeetupLastRequest) {
    $wait = $delay * 1000 - ([DateTime]::UtcNow - $global:TvMeetupLastRequest).TotalMilliseconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
  }
  $global:TvMeetupLastRequest = [DateTime]::UtcNow
  Invoke-TvRequest $Url -Raw
}

$text = Get-MeetupText $Source.url
if ($text -notmatch 'BEGIN:VCALENDAR') {
  throw "$($Source.name): response is not an iCalendar feed"
}
$groupName = [regex]::Match($text, '(?m)^X-WR-CALNAME:(.+?)\r?$').Groups[1].Value.Trim()

# Where earlier nights placed this group's events, by event URL.
$known = @{}
$raw = Read-TvRawFile $RawPath
if ($raw -and $raw.sources.PSObject.Properties[$Source.name]) {
  foreach ($stored in @($raw.sources.($Source.name).events)) {
    if ($stored.url) { $known["$($stored.url)"] = $stored }
  }
}

$now = [DateTimeOffset]::Parse($FetchedAt, [Globalization.CultureInfo]::InvariantCulture)
foreach ($item in (ConvertFrom-Ics $text)) {
  if ($item.Status -eq 'CANCELLED') { continue }
  $last = if ($item.End) { $item.End } else { $item.Start }
  if ((Get-TvEventInstant $last) -lt $now) { continue }

  $title = ConvertTo-PlainText $item.Summary
  if ($Source.excludeTitlePattern -and $title -match $Source.excludeTitlePattern) { continue }
  $url = [System.Net.WebUtility]::HtmlDecode($item.Url)

  try {
    $stored = $known[$url]
    if ($stored) {
      $venue = $stored.venue
      $venueKey = $stored.venueKey
      $city = $stored.city
    } else {
      $page = Get-MeetupText $url
      $node = @(Get-TvJsonLdEvent $page) | Select-Object -First 1
      if (-not $node) { throw 'no schema.org event data on the page' }
      if ("$($node.eventAttendanceMode)" -match 'OnlineEventAttendanceMode') { continue }
      $location = @($node.location) | Where-Object { "$($_.'@type')" -ne 'VirtualLocation' } | Select-Object -First 1
      $city = Resolve-TvCity "$($location.address.addressLocality)"
      # Only the cities this site covers; anything else, or no place at all, is dropped.
      if (-not $city -or $city -eq 'Other') { continue }
      $venue = ConvertTo-PlainText "$($location.name)"
      if (-not $venue) { $venue = $Source.venue }
      $venueKey = Get-VenueKey $venue
    }

    # Meetup starts each description with the group's name.
    $description = $item.Description
    if ($groupName -and $description.StartsWith($groupName)) { $description = $description.Substring($groupName.Length) }
    # Some groups write in Markdown: drop bold and italic marks and the backslashes that escape punctuation.
    $description = $description -replace '\\([\\`*_{}\[\]()#+\-.!|,:;~<>"''])', '$1' -replace '(?<![\w*])\*{1,3}(?=\S)|(?<=\S)\*{1,3}(?![\w*])', ''

    New-TvEvent -Title $title -Start $item.Start -End $item.End -AllDay:$item.AllDay `
      -Venue $venue -VenueKey $venueKey -City $city `
      -Category $Source.category -InferCategory:([bool]$Source.inferCategory) -Url $url -Description $description.Trim() `
      -Sources @(@{ name = $Source.name; url = $url; fetchedAt = $FetchedAt })
  } catch {
    if ("$_" -match 'robots.txt disallows') { throw }
    Write-Warning "$($Source.name): skipping '$title': $_"
  }
}
