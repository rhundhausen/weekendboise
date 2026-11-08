#Requires -Version 7.4
<#
.SYNOPSIS
  Reads events from a WordPress site running the Eventastic plugin (Madden Media), such as Visit McCall.
.DESCRIPTION
  The calendar page fills itself by posting action=get_events_date_ordered with a start and end
  date to /wp-admin/admin-ajax.php. This makes the same request once, for today through the next
  180 days, after checking robots.txt. The answer's event_objects hold each event: title, dates,
  times ("5:30 pm"), venue terms, address, city, categories, price, and its page (permalink).

  A weekly event lists its dates in pattern_dates; each date in the window becomes its own event.
  Any other event is one event from start_date to end_date. An event with no start time is all-day.
.PARAMETER Source
  One entry from sources.json. url is the site's events page; the request goes to the same site.
.PARAMETER FetchedAt
  UTC timestamp recorded on each event.
.PARAMETER Response
  The admin-ajax JSON to parse instead of fetching. Used by tests.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][pscustomobject]$Source,
  [Parameter(Mandatory)][string]$FetchedAt,
  [string[]]$Response
)

. "$PSScriptRoot/../lib/Schema.ps1"
. "$PSScriptRoot/../lib/Http.ps1"
. "$PSScriptRoot/../lib/Scrape.ps1"

$invariant = [Globalization.CultureInfo]::InvariantCulture
$today = (ConvertTo-BoiseTime $FetchedAt).Substring(0, 10)
$last = [DateTime]::ParseExact($today, 'yyyy-MM-dd', $invariant).AddDays(180).ToString('yyyy-MM-dd', $invariant)

function Get-EventasticPage {
  $site = ([uri]$Source.url).GetLeftPart('Authority')
  $path = '/wp-admin/admin-ajax.php'
  $robots = ''
  try {
    $robots = Invoke-TvRequest "$site/robots.txt" -Raw
  } catch {
    # No robots.txt means no restrictions. Any other failure means we can't tell, so stop.
    if ("$_" -notmatch 'HTTP 404') { throw }
  }
  if (-not (Test-TvRobotsAllowed $robots $path)) { throw "$($Source.name): robots.txt disallows $path" }

  # The same fields the site's own calendar sends.
  $body = @{
    action         = 'get_events_date_ordered'
    use_categories = 'true'
    layoutStyle    = 'integrated'
    start_date     = $today
    end_date       = $last
    image_size     = 'thumbnail'
  }
  Invoke-TvRequest "$site$path" -Method Post -Form $body
}

function ConvertFrom-EventasticTime {
  # "5:30 pm" or "11 am" as minutes after midnight, or $null.
  param([string]$Value)

  if ($Value -notmatch '^\s*(?<h>\d{1,2})(?::(?<m>\d{2}))?\s*(?<ap>[ap])\.?m\.?\s*$') { return $null }
  $hour = [int]$Matches.h % 12
  if ($Matches.ap -eq 'p') { $hour += 12 }
  $hour * 60 + ($Matches.m ? [int]$Matches.m : 0)
}

function Get-EventasticInstant {
  param([string]$Date, [int]$Minutes)
  ConvertTo-BoiseTime ([DateTime]::ParseExact($Date, 'yyyy-MM-dd', $invariant).AddMinutes($Minutes))
}

$page = if ($Response) { ConvertFrom-TvJson $Response[0] } else { Get-EventasticPage }

foreach ($item in @($page.event_objects.PSObject.Properties.Value)) {
  try {
    if ($item.post_status -and $item.post_status -ne 'publish') { continue }
    $title = ConvertTo-PlainText $item.post_title
    if ($Source.excludeTitlePattern -and $title -match $Source.excludeTitlePattern) { continue }
    $meta = $item.meta

    $venueName = @($meta.thisVenues | Where-Object { $_ -and $_.name } | ForEach-Object { ConvertTo-PlainText $_.name })[0]
    $city = Resolve-TvCity $meta.city
    if (-not $city) { $city = $Source.city }
    $labels = @($meta.thisCategories | Where-Object { $_ } | ForEach-Object { ConvertTo-PlainText $_.name })
    $url = if ($item.permalink) { $item.permalink } else { $Source.url }
    $price = if ($meta.price) { ConvertFrom-TvPriceText (ConvertTo-PlainText $meta.price) }

    $startMinutes = ConvertFrom-EventasticTime $meta.start_time
    $endMinutes = ConvertFrom-EventasticTime $meta.end_time

    # Each occurrence as a start date and an end date.
    $patternDates = @($meta.pattern_dates | Where-Object { $_ })
    $spans = if ($patternDates.Count -gt 0) {
      @($patternDates | ForEach-Object { , @($_, $_) })
    } else {
      $end = if ($meta.end_date -and $meta.end_date -gt $meta.start_date) { $meta.end_date } else { $meta.start_date }
      , @(, @($meta.start_date, $end))
    }

    foreach ($span in $spans) {
      $first, $final = $span
      # Keep occurrences still running today and starting within the window.
      if ($final -lt $today -or $first -gt $last) { continue }

      $common = @{
        Title = $title; Venue = ($venueName ? $venueName : $Source.venue); VenueKey = ($venueName ? (Get-VenueKey $venueName) : $Source.venueKey)
        City = $city; Category = $Source.category; InferCategory = [bool]$Source.inferCategory; Labels = $labels
        Url = $url; Description = $item.post_content; PriceMin = $price
        Sources = @(@{ name = $Source.name; url = $url; fetchedAt = $FetchedAt })
      }
      if ($null -eq $startMinutes) {
        New-TvEvent @common -Start $first -End ($final -gt $first ? $final : $null) -AllDay
      } else {
        $end = if ($null -ne $endMinutes -and ($final -gt $first -or $endMinutes -gt $startMinutes)) { Get-EventasticInstant $final $endMinutes }
        New-TvEvent @common -Start (Get-EventasticInstant $first $startMinutes) -End $end
      }
    }
  } catch {
    Write-Warning "$($Source.name): skipping '$($item.post_title)': $_"
  }
}
