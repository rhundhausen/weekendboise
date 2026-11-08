#Requires -Version 7.4
<#
.SYNOPSIS
  Reads events from an ICS feed.
.PARAMETER Source
  One entry from sources.json.
.PARAMETER FetchedAt
  UTC timestamp recorded on each event.
.PARAMETER Response
  Feed text to parse instead of fetching. Used by tests.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][pscustomobject]$Source,
  [Parameter(Mandatory)][string]$FetchedAt,
  [string[]]$Response
)

. "$PSScriptRoot/../lib/Schema.ps1"
. "$PSScriptRoot/../lib/Http.ps1"
. "$PSScriptRoot/../lib/Ics.ps1"

$text = if ($Response) { $Response[0] } else { Invoke-TvRequest $Source.url -Raw }
if ($text -notmatch 'BEGIN:VCALENDAR') {
  throw "$($Source.name): response is not an iCalendar feed"
}

foreach ($item in (ConvertFrom-Ics $text)) {
  if ($item.Status -eq 'CANCELLED') { continue }
  if ($Source.locationFilter -and $item.Location -notmatch $Source.locationFilter) { continue }

  try {
    # SIDEARM feeds prefix played games with the result, such as "[W] ". Dropping it keeps the id stable.
    $title = ConvertTo-PlainText ($item.Summary -replace '^\[[A-Z]\]\s*', '')
    if ($Source.excludeTitlePattern -and $title -match $Source.excludeTitlePattern) { continue }
    $description = if ($item.Description.StartsWith($item.Summary)) { $item.Description.Substring($item.Summary.Length) } else { $item.Description }
    $location = ConvertFrom-TvLocation $item.Location -Source $Source
    if ($Source.fixedVenue) {
      # Library feeds name rooms ("Children's Area"), not the building, which would split one venue.
      $location.Venue = $Source.venue
      $location.VenueKey = $Source.venueKey
    }
    # Some feeds (SIDEARM-style team sites) give a link relative to the site, such as /games/1.
    $url = if ($item.Url) { [uri]::new([uri]$Source.url, [System.Net.WebUtility]::HtmlDecode($item.Url)).AbsoluteUri } else { $Source.url }

    $start = $item.Start
    $end = $item.End
    if ($Source.localTimeAsUtc -and -not $item.AllDay) {
      # Events Calendar sites set to UTC+0 label Boise wall-clock time as UTC. Read the clock as local.
      $start = ConvertTo-BoiseTime ([DateTimeOffset]::Parse($start, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss'))
      if ($end) { $end = ConvertTo-BoiseTime ([DateTimeOffset]::Parse($end, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss')) }
    }

    New-TvEvent -Title $title -Start $start -End $end -AllDay:$item.AllDay `
      -Venue $location.Venue -VenueKey $location.VenueKey -City $location.City `
      -Category $Source.category -InferCategory:([bool]$Source.inferCategory) -Url $url -Description $description `
      -Sources @(@{ name = $Source.name; url = $url; fetchedAt = $FetchedAt })
  } catch {
    Write-Warning "$($Source.name): skipping '$($item.Summary)': $_"
  }
}
