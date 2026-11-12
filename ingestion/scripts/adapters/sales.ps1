#Requires -Version 7.4
<#
.SYNOPSIS
  Reads auctions and estate sales, for the Auctions and Estate Sales category.
.DESCRIPTION
  One request a night per source (plus robots.txt), checked against robots.txt and spaced by its
  Crawl-delay. No link on the page is followed. Every mode applies the same rules (lib/Sales.ps1):

  - In-person only. Anything whose title or text says "online", and anything with no street
    address or place, is dropped (the in-person rule).
  - No real estate: auctions of a house or land are dropped (Downs' Real Estate category,
    Corbett's Real Estate cards, or "real estate" in a title), unless the source sets
    keepRealEstate for live real estate auctions held at the property.
  - Only the cities the site already covers are kept (the city filter).
  - Only the title, the company (as the venue), the city, start and end, and the link to the
    event on the company's site are stored. No address, photos, description, contact details,
    or price.

  How many events each rule dropped is written with Write-Verbose.

  salesMode:
  - ics: an Events Calendar iCal export (Downs Auction). The start time comes from the description
    ("at 2 pm"), since the feed gives dates only. Its real estate auctions are titled by street
    address, and are dropped by the real estate rule unless the source sets keepRealEstate.
  - corbett: the upcoming auctions on corbettauctions.com's home page (an Elementor loop grid
    after id="upcoming"). Only cards marked live onsite whose link stays on the company's site are
    kept; online lots, which link to HiBid or another bidding site, are dropped without following.
  - onthewater: the UPCOMING SALES lines on onthewaterestatesales.com/estatesales ("Ballance Living
    Estate Sale November 21-22 Boise"), dates without a year read as their next occurrence. A sale
    runs from the first day's opening to the last day's close when the page lists hours for those
    days ("Saturday, November 21 | 9:00 AM - 2:00 PM"), and is all-day otherwise. Its link is the
    sales page, which is all the site has.
  - file: a JSON array in the site's event format, read from the repository file named by path
    (EstateSales.NET, data/events-additional.json, which ingest-additional writes nightly with the
    site's permission). Nothing is fetched. The town comes from "Town, ID" in each venue, else its
    city. Markdown emphasis and any title part with a price are removed, and the description is
    read only for the in-person rule.
.PARAMETER Source
  One entry from sources.json.
.PARAMETER FetchedAt
  UTC timestamp recorded on each event.
.PARAMETER Response
  The feed or page to parse instead of fetching. Used by tests.
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
. "$PSScriptRoot/../lib/Ics.ps1"
. "$PSScriptRoot/../lib/Sales.ps1"

$today = [datetime]::ParseExact((ConvertTo-BoiseTime $FetchedAt).Substring(0, 10), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$months = 'Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?'
$clock = '\d{1,2}(?::\d{2})?\s*[AaPp]\.?\s*[Mm]\b\.?'
$dropped = @{ 'in-person' = 0; 'real-estate' = 0; city = 0 }
$kept = 0

function Get-SalesText {
  # The source's page, after checking robots.txt and waiting out its Crawl-delay.
  if ($Response) { return $Response[0] }

  # File mode reads a file in the repository that the site's own data is delivered to; nothing is fetched.
  if ($Source.salesMode -eq 'file') {
    $file = Join-Path $PSScriptRoot '..' '..' '..' $Source.path
    if (-not (Test-Path -LiteralPath $file)) { throw "$($Source.name): $($Source.path) does not exist" }
    return Get-Content -LiteralPath $file -Raw
  }

  $uri = [uri]$Source.url
  $robots = try { Invoke-TvRequest "$($uri.GetLeftPart('Authority'))/robots.txt" -Raw } catch {
    # No robots.txt means no restrictions. Any other failure means we can't tell, so stop.
    if ("$_" -match 'HTTP 404') { '' } else { throw }
  }
  if (-not (Test-TvRobotsAllowed $robots $uri.PathAndQuery)) { throw "$($Source.name): robots.txt disallows $($uri.PathAndQuery)" }
  $delay = [Math]::Max(1, [int](Get-TvRobotsGroup $robots).Delay)
  if ($delay -gt 60) { throw "$($Source.name): robots.txt asks for $delay seconds between requests" }
  Start-Sleep -Seconds $delay
  Invoke-TvRequest $uri.AbsoluteUri -Raw
}

function Add-Sale {
  # Applies the in-person rule, the real estate rule, and the city filter, then emits the event or
  # counts the drop.
  param([string]$Title, [string]$Text, [string]$Town, [hashtable]$Event, [switch]$RealEstate)

  $city = if ($Town) { Resolve-TvCity $Town }
  $verdict = Get-TvSaleVerdict -Title $Title -Text $Text -HasPlace ([bool]$Town) -City $city -RealEstate ([bool]$RealEstate -and -not $Source.keepRealEstate)
  if ($verdict -ne 'keep') {
    $script:dropped[$verdict]++
    $why = switch ($verdict) { 'city' { "the city filter ($Town)" } 'real-estate' { 'the real estate rule' } default { 'the in-person rule' } }
    Write-Verbose "$($Source.name): '$Title' dropped by $why"
    return
  }
  try {
    New-TvSaleEvent -Source $Source -FetchedAt $FetchedAt -City $city @Event
    $script:kept++
  } catch {
    Write-Warning "$($Source.name): skipping '$Title': $_"
  }
}

function Read-IcsSales {
  param([string]$Text)

  if ($Text -notmatch 'BEGIN:VCALENDAR') { throw "$($Source.name): response is not an iCalendar feed" }
  foreach ($item in (ConvertFrom-Ics $Text)) {
    if ($item.Status -eq 'CANCELLED') { continue }
    $title = ConvertTo-PlainText $item.Summary
    $lines = @($item.Description -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $locationLine = ($lines | Where-Object { $_ -match '^LOCATION:\s*(.+)$' } | Select-Object -First 1) -replace '^LOCATION:\s*', ''
    $town = Find-TvSaleTown (@($item.Location, $locationLine, $title, $lines[0]) -join "`n")

    $event = @{ Url = if ($item.Url) { $item.Url } else { $Source.url } }
    $at = [regex]::Match($item.Description, "(?i)\bat\s+(?<t>$clock)")
    $start = if ($item.AllDay -and $at.Success) { ConvertTo-TvSaleTime $item.Start $at.Groups['t'].Value }
    if ($start) {
      $event.Start = $start
    } else {
      $event.Start = $item.Start
      if ($item.End) { $event.End = $item.End }
      $event.AllDay = [bool]$item.AllDay
    }

    # A title that is a street address is a real estate listing, which the real estate rule drops.
    $event.Title = $title
    Add-Sale -Title $title -Text "$($item.Description)`n$($item.Categories)" -Town $town -Event $event `
      -RealEstate:($item.Categories -match '(?i)\breal estate\b' -or $title -match '^\d+\s+\S')
  }
}

function Read-CorbettSales {
  param([string]$Text)

  $at = $Text.IndexOf('id="upcoming"')
  if ($at -lt 0) { throw "$($Source.name): no upcoming auctions section (id=""upcoming"") on the page" }
  $siteHost = ([uri]$Source.url).Host -replace '^www\.', ''

  foreach ($card in ($Text.Substring($at) -split '<div role="listitem"' | Select-Object -Skip 1)) {
    $href = [regex]::Match($card, 'href="([^"]+)"').Groups[1].Value
    $parts = @([regex]::Matches($card, '(?s)<(?<tag>span|h3|p|div)\b[^>]*class="elementor-heading-title[^"]*"[^>]*>(?<body>.*?)</\k<tag>>') | ForEach-Object {
        [pscustomobject]@{ Tag = $_.Groups['tag'].Value; Text = ConvertTo-PlainText $_.Groups['body'].Value }
      })
    $texts = @($parts.Text)
    $monthAt = [Array]::FindIndex([string[]]$texts, [Predicate[string]] { param($t) $t -match "^(?:$months)\.?$" })
    if ($monthAt -lt 0 -or $monthAt + 1 -ge $texts.Count -or $texts[$monthAt + 1] -notmatch '^\d{1,2}$') { continue }

    # The title is the card's h3. After it come the description lines, and last the place
    # ("Nampa, ID", or "Address to be posted" before the address is public).
    $titleAt = [Array]::FindIndex([object[]]$parts, [Predicate[object]] { param($p) $p.Tag -eq 'h3' })
    if ($titleAt -lt 0 -or $titleAt + 1 -ge $parts.Count) { continue }
    $title = $parts[$titleAt].Text
    $after = @($texts | Select-Object -Skip ($titleAt + 1))
    $place = $after[-1]
    $details = @($after | Select-Object -SkipLast 1)
    $town = Find-TvSaleTown $place

    $linkHost = if ($href -match '^https?://([^/:?#]+)') { $Matches[1].ToLowerInvariant() -replace '^www\.', '' }
    $onsite = $texts -match '(?i)^(live\s+)?on-?site$'
    if (-not $onsite -or $linkHost -ne $siteHost) {
      # Online bidding, or a lot on HiBid or another bidding site: never followed.
      $script:dropped['in-person']++
      Write-Verbose "$($Source.name): '$title' dropped by the in-person rule (not live onsite)"
      continue
    }

    $date = Get-TvNextDate -Month $texts[$monthAt] -Day ([int]$texts[$monthAt + 1]) -Today $today
    $time = $texts | Where-Object { $_ -match "^\w+day,\s*(?<t>$clock)$" } | Select-Object -First 1
    $start = if ($time) { ConvertTo-TvSaleTime $date ($time -replace '^\w+day,\s*', '') }
    $event = @{ Title = $title; Url = $href; Start = $start ?? $date; AllDay = -not $start }
    # The card's type label ("Estate", "Real Estate") comes before the title.
    $realEstate = @($texts | Select-Object -First $titleAt) -contains 'Real Estate' -or $card -match 'auction_type-real-estate'
    Add-Sale -Title $title -Text ($details -join "`n") -Town $town -Event $event -RealEstate:$realEstate
  }
}

function Read-OnTheWaterSales {
  param([string]$Text)

  $blocks = @(($Text -split '(?i)</p>|<br\s*/?>|</h\d>|</li>') | ForEach-Object { ConvertTo-PlainText $_ } | Where-Object { $_ })
  $heading = [Array]::FindIndex([string[]]$blocks, [Predicate[string]] { param($b) $b -match '^(?i)upcoming sales$' })
  if ($heading -lt 0) { throw "$($Source.name): no UPCOMING SALES heading on the page" }

  # Opening and closing times by date, from lines such as "Saturday, November 21 | 9:00 AM - 2:00 PM".
  $hours = @{}
  # A hyphen, an en dash (0x2013), an em dash (0x2014), or "to".
  $dash = "(?:-|$([char]0x2013)|$([char]0x2014)|to)"
  foreach ($match in [regex]::Matches(($blocks -join "`n"), "(?i)\b(?:mon|tues|wednes|thurs|fri|satur|sun)day,?\s+(?<m>$months)\.?\s+(?<d>\d{1,2})(?:st|nd|rd|th)?\s*[|:,]?\s*(?<open>$clock)\s*$dash\s*(?<close>$clock)")) {
    $day = Get-TvNextDate -Month $match.Groups['m'].Value -Day ([int]$match.Groups['d'].Value) -Today $today
    $hours[$day] = @{ Open = $match.Groups['open'].Value; Close = $match.Groups['close'].Value }
  }

  $salePattern = "^(?<title>.+?)\s+(?<m1>$months)\.?\s+(?<d1>\d{1,2})(?:st|nd|rd|th)?(?:\s*(?:$dash|&|and)\s*(?:(?<m2>$months)\.?\s+)?(?<d2>\d{1,2})(?:st|nd|rd|th)?)?,?\s+(?:in\s+)?(?<place>[A-Z][A-Za-z .']*?)\s*$"
  foreach ($line in ($blocks | Select-Object -Skip ($heading + 1))) {
    $sale = [regex]::Match($line, $salePattern)
    if (-not $sale.Success) { break }

    $first = Get-TvNextDate -Month $sale.Groups['m1'].Value -Day ([int]$sale.Groups['d1'].Value) -Today $today
    $last = $first
    if ($sale.Groups['d2'].Success) {
      $month2 = if ($sale.Groups['m2'].Success) { $sale.Groups['m2'].Value } else { $sale.Groups['m1'].Value }
      $last = Get-TvNextDate -Month $month2 -Day ([int]$sale.Groups['d2'].Value) -Today $today
      if ($last -lt $first) { $last = ([datetime]$last).AddYears(1).ToString('yyyy-MM-dd') }
    }

    $title = $sale.Groups['title'].Value.Trim()
    $event = @{ Title = $title; Url = $Source.url }
    if ($hours[$first]) {
      $event.Start = ConvertTo-TvSaleTime $first $hours[$first].Open
      $closing = $hours[$last] ?? ($last -eq $first ? $hours[$first] : $null)
      if ($closing) { $event.End = ConvertTo-TvSaleTime $last $closing.Close }
    } else {
      $event.Start = $first
      $event.AllDay = $true
      if ($last -ne $first) { $event.End = $last }
    }
    Add-Sale -Title $title -Text $line -Town $sale.Groups['place'].Value.Trim() -Event $event
  }
}

function Read-FileSales {
  # A JSON array of events in the site's event format (title, start, end, allDay, venue, city, url,
  # description). Only what the other modes keep is passed on; the description is read for the
  # in-person rule and then dropped.
  param([string]$Text)

  $items = try { @($Text | ConvertFrom-TvJson) } catch { throw "$($Source.name): $($Source.path) is not valid JSON: $_" }
  foreach ($item in $items) {
    if (-not $item.title -or -not $item.start) {
      Write-Warning "$($Source.name): skipping an entry with no title or start"
      continue
    }
    # Markdown emphasis ("**MOVING SALE**") is not part of the title.
    $title = ((ConvertTo-PlainText "$($item.title)") -replace '\*\*|__|(?<!\w)[*_](?=\S)|(?<=\S)[*_](?!\w)', '' -replace '\s+', ' ').Trim()
    # No prices are stored, so a title part with one ("Moving Sale - Everything $1 Each!") is dropped.
    $dash = "\s+[-$([char]0x2013)$([char]0x2014)]\s+|\s*[|:]\s*"
    $parts = @($title -split $dash | Where-Object { $_ -and $_ -notmatch '\$\s?\d' })
    if ($title -match '\$\s?\d') {
      $title = if ($parts) { $parts -join ' - ' } else { ($title -replace '[^.!?]*\$\s?\d[^.!?]*[.!?]?', '').Trim() }
    }
    $town = Find-TvSaleTown "$($item.venue)"
    if (-not $town) { $town = "$($item.city)".Trim() }
    $event = @{ Title = $title; Start = "$($item.start)"; Url = if ($item.url) { "$($item.url)" } else { $Source.url } }
    if ($item.end -and "$($item.end)" -ne "$($item.start)") { $event.End = "$($item.end)" }
    if ($item.allDay) { $event.AllDay = $true }
    Add-Sale -Title $title -Text "$($item.description)" -Town $town -Event $event
  }
}

$text = Get-SalesText
switch ($Source.salesMode) {
  'ics' { Read-IcsSales $text }
  'corbett' { Read-CorbettSales $text }
  'onthewater' { Read-OnTheWaterSales $text }
  'file' { Read-FileSales $text }
  default { throw "$($Source.name): unknown salesMode '$($Source.salesMode)'" }
}
Write-Verbose "$($Source.name): kept $kept, $($dropped['in-person']) dropped by the in-person rule, $($dropped['real-estate']) dropped as real estate, $($dropped.city) dropped by the city filter"
