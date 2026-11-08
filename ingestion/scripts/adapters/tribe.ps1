#Requires -Version 7.4
<#
.SYNOPSIS
  Reads upcoming events from a WordPress site running The Events Calendar.
.PARAMETER Source
  One entry from sources.json.
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

function Get-TribePage {
  $today = (ConvertTo-BoiseTime $FetchedAt).Substring(0, 10)
  $page = 1
  $totalPages = 1
  do {
    if ($page -gt 1) { Start-Sleep -Seconds 1 }
    $result = Invoke-TvRequest "$($Source.url)?per_page=50&start_date=$today&page=$page"
    $totalPages = [int]$result.total_pages
    $result
    $page++
  } while ($page -le $totalPages)
}

$pages = if ($Response) { $Response | ForEach-Object { ConvertFrom-TvJson $_ } } else { Get-TribePage }

foreach ($item in ($pages | ForEach-Object { $_.events } | Where-Object { $_ })) {
  try {
    $title = ConvertTo-PlainText $item.title
    if ($Source.excludeTitlePattern -and $title -match $Source.excludeTitlePattern) { continue }
    $allDay = [bool]$item.all_day
    if ($allDay) {
      $start = $item.start_date.Substring(0, 10)
      $end = $item.end_date.Substring(0, 10)
      if ($end -le $start) { $end = $null }
    } elseif ($Source.localTimeAsUtc) {
      # A site set to UTC+0 writes Boise wall-clock time in every field, so read start_date as local.
      $invariant = [Globalization.CultureInfo]::InvariantCulture
      $start = ConvertTo-BoiseTime ([DateTime]::ParseExact($item.start_date, 'yyyy-MM-dd HH:mm:ss', $invariant))
      $end = ConvertTo-BoiseTime ([DateTime]::ParseExact($item.end_date, 'yyyy-MM-dd HH:mm:ss', $invariant))
      if ($end -eq $start) { $end = $null }
    } else {
      # The utc_ fields are always UTC. The timezone field can be a label like UTC+0.
      $start = ConvertTo-BoiseTime "$($item.utc_start_date)Z"
      $end = ConvertTo-BoiseTime "$($item.utc_end_date)Z"
      if ($end -eq $start) { $end = $null }
    }

    # venue is an object when set, and an empty array when not. fixedVenue is for sites that
    # list rooms or buildings as venues, which would split one show and miss its usual key.
    $venue = if (-not $Source.fixedVenue -and $item.venue -is [pscustomobject]) { $item.venue }
    $name = if ($venue) { ConvertTo-PlainText $venue.venue }
    $city = Resolve-TvCity $venue.city
    if (-not $city) { $city = $Source.city }

    $url = $item.url
    New-TvEvent -Title $title -Start $start -End $end -AllDay:$allDay `
      -Venue ($name ? $name : $Source.venue) -VenueKey ($name ? (Get-VenueKey $name) : $Source.venueKey) -City $city `
      -Category $Source.category -InferCategory:([bool]$Source.inferCategory) -Labels @($item.categories.name) -Url $url -Description $item.description `
      -PriceMin (ConvertFrom-TvPriceText (ConvertTo-PlainText $item.cost)) -Sources @(@{ name = $Source.name; url = $url; fetchedAt = $FetchedAt })
  } catch {
    Write-Warning "$($Source.name): skipping '$($item.title)': $_"
  }
}
