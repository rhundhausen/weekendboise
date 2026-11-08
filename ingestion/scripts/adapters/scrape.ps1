#Requires -Version 7.4
<#
.SYNOPSIS
  Reads events from a site's HTML, for sites with no API or feed.
.DESCRIPTION
  Every request is checked against the site's robots.txt, and a disallowed request is never
  sent. A 403 or a challenge page fails the source: this adapter never works around bot
  controls. Requests are at least 1 second apart, or the site's Crawl-delay if longer. A
  Crawl-delay over 60 seconds fails the source, so one site can't stall the run.

  With scrapeMode jsonld, events come from schema.org data on the page, or on each page
  linked by eventLinkPattern. With scrapeMode cards, they come from HTML blocks matched by
  itemPattern, read with datePattern, titlePattern, and timePattern. With scrapeMode
  calendarapp, they come from the event JSON that City of Boise calendar pages embed in the
  data-config attribute of #calendar-app. With scrapeMode civicplus, they come from a CivicPlus
  city calendar (Calendar.aspx), one month per page. With scrapeMode chambermaster, they come from
  a ChamberMaster or GrowthZone chamber calendar: the month pages list the events, and each
  event's iCal file gives its details. See docs/sources.md.
.PARAMETER Source
  One entry from sources.json.
.PARAMETER FetchedAt
  UTC timestamp recorded on each event.
.PARAMETER Response
  HTML to parse instead of fetching: the list page, then each linked page in order. Used by tests.
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

$listUri = [uri]$Source.url
$today = (ConvertTo-BoiseTime $FetchedAt).Substring(0, 10)
$script:robots = ''
$script:delay = 1
$script:requests = 0

if (-not $Response) {
  try {
    $script:robots = Invoke-TvRequest "$($listUri.GetLeftPart('Authority'))/robots.txt" -Raw
  } catch {
    # No robots.txt means no restrictions. Any other failure means we can't tell, so stop.
    if ("$_" -notmatch 'HTTP 404') { throw }
  }
  $script:delay = [Math]::Max(1, [int](Get-TvRobotsGroup $script:robots).Delay)
  if ($script:delay -gt 60) {
    # Waiting would stall the nightly run, and ignoring the delay isn't an option.
    throw "$($Source.name): robots.txt asks for $($script:delay) seconds between requests"
  }
}

function Get-ScrapePage {
  param([uri]$Uri)

  $requested = $Uri.PathAndQuery
  if (-not (Test-TvRobotsAllowed $script:robots $requested)) {
    throw "$($Source.name): robots.txt disallows $requested"
  }
  if ($script:requests -gt 0) { Start-Sleep -Seconds $script:delay }
  $script:requests++
  Invoke-TvRequest $Uri.AbsoluteUri -Raw
}

function ConvertFrom-ScrapeDate {
  # Returns the value in event form, or $null if it can't be read.
  param([string]$Value)

  if (-not $Value) { return $null }
  if ($Value -match '^\d{4}-\d{2}-\d{2}$') { return @{ Value = $Value; AllDay = $true } }

  $parsed = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
    return $null
  }

  if ($Source.localTimeAsUtc) {
    # Modern Events Calendar writes Boise wall-clock time as if it were UTC, then shifts it.
    $wall = [DateTime]::SpecifyKind($parsed.UtcDateTime, [DateTimeKind]::Unspecified)
    return @{ Value = ConvertTo-BoiseTime $wall; AllDay = $false }
  }
  @{ Value = ConvertTo-BoiseTime $parsed; AllDay = $false }
}

function New-ScrapeEvent {
  param(
    [string]$Title,
    [string]$Start,
    [string]$End,
    [bool]$AllDay,
    [string]$VenueName,
    [string]$CityText,
    [string]$Url,
    [string]$Description,
    [AllowNull()][Nullable[decimal]]$PriceMin
  )

  $name = if ($Source.fixedVenue) { '' } else { ConvertTo-PlainText $VenueName }
  $city = $null
  foreach ($part in ((ConvertTo-PlainText $CityText) -split ',')) {
    $city = Resolve-TvCity ($part -replace '\s+ID(\s+\d{5})?$', '')
    if ($city) { break }
  }

  New-TvEvent -Title $Title -Start $Start -End $End -AllDay:$AllDay `
    -Venue ($name ? $name : $Source.venue) -VenueKey ($name ? (Get-VenueKey $name) : $Source.venueKey) `
    -City ($city ? $city : $Source.city) -Category $Source.category -InferCategory:([bool]$Source.inferCategory) `
    -Url $Url -Description $Description -PriceMin $PriceMin -Sources @(@{ name = $Source.name; url = $Url; fetchedAt = $FetchedAt })
}

function Get-JsonLdPriceMin {
  # The lowest price in schema.org offers, or $null. A price of 0 is ignored: sites put it in as
  # a placeholder (Bluebird lists a $39 show at 0), so only isAccessibleForFree counts as free.
  param([object]$Node)

  if ($Node.isAccessibleForFree -eq $true -or "$($Node.isAccessibleForFree)" -eq 'true') { return [decimal]0 }
  $prices = @(@($Node.offers) | ForEach-Object { $_.price; $_.lowPrice } | ForEach-Object {
      $value = [decimal]0
      if ([decimal]::TryParse(("$_" -replace '[$,]', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and $value -gt 0) { $value }
    })
  if ($prices.Count -eq 0) { return $null }
  ($prices | Measure-Object -Minimum).Minimum
}

function Read-JsonLdEvent {
  param(
    [object]$Node,
    [string]$PageUrl
  )

  if ("$($Node.eventStatus)" -match 'Cancelled') { return }

  $start = ConvertFrom-ScrapeDate $Node.startDate
  if (-not $start) { throw "unreadable startDate '$($Node.startDate)'" }
  $end = ConvertFrom-ScrapeDate $Node.endDate
  $endValue = if ($end -and $end.AllDay -eq $start.AllDay -and $end.Value -gt $start.Value) { $end.Value }

  # Page titles often end with the site name, such as "Brewfest - Indian Creek Plaza".
  $separators = "$([char]0x2013)$([char]0x2014)-"
  $title = (ConvertTo-PlainText $Node.name) -replace " [$separators] $([regex]::Escape($Source.displayName))$", ''
  if ($Source.excludeTitlePattern -and $title -match $Source.excludeTitlePattern) { return }

  # WordPress shortcodes such as [post_title] leak into some sites' descriptions unexpanded.
  $description = ((ConvertTo-PlainText $Node.description) -replace '\[[a-z]+(?:_[a-z0-9]+)+\]', '' -replace '\s+', ' ').Trim()
  if ($Source.excludeDescriptionPattern -and $description -match $Source.excludeDescriptionPattern) { return }

  $offers = @($Node.offers) | Select-Object -First 1
  $url = if ($PageUrl) { $PageUrl } elseif ($Node.url) { $Node.url } elseif ($offers.url) { $offers.url } else { $Source.url }

  $location = @($Node.location) | Select-Object -First 1
  $address = $location.address
  $cityText = if ($address -is [pscustomobject]) { "$($address.addressLocality)" } else { "$address" }

  New-ScrapeEvent -Title $title -Start $start.Value -End $endValue -AllDay $start.AllDay `
    -VenueName $location.name -CityText $cityText -Url ([System.Net.WebUtility]::HtmlDecode($url)) -Description $description `
    -PriceMin (Get-JsonLdPriceMin $Node)
}

function Read-JsonLdSource {
  $html = if ($Response) { $Response[0] } else { Get-ScrapePage $listUri }

  if (-not $Source.eventLinkPattern) {
    foreach ($node in (Get-TvJsonLdEvent $html)) {
      try {
        Read-JsonLdEvent $node ''
      } catch {
        Write-Warning "$($Source.name): skipping '$($node.name)': $_"
      }
    }
    return
  }

  $links = @([regex]::Matches($html, $Source.eventLinkPattern) | ForEach-Object Value | Select-Object -Unique | ForEach-Object {
      [uri]::new($listUri, [System.Net.WebUtility]::HtmlDecode($_)).AbsoluteUri
    } | Select-Object -Unique)

  # Skip dates already gone when the link shows them, so a long archive isn't re-read nightly.
  $links = @($links | Where-Object {
      $date = [regex]::Match($_, '/(\d{4})/(\d{1,2})/(\d{1,2})/')
      -not $date.Success -or ('{0}-{1:00}-{2:00}' -f $date.Groups[1].Value, [int]$date.Groups[2].Value, [int]$date.Groups[3].Value) -ge $today
    })

  $limit = if ($Source.maxPages) { [int]$Source.maxPages } else { 40 }
  if ($links.Count -gt $limit) {
    Write-Warning "$($Source.name): $($links.Count) event pages, reading the first $limit"
    $links = @($links | Select-Object -First $limit)
  }

  for ($i = 0; $i -lt $links.Count; $i++) {
    try {
      $page = if ($Response) { $Response[$i + 1] } else { Get-ScrapePage ([uri]$links[$i]) }
      foreach ($node in @(Get-TvJsonLdEvent "$page" | Select-Object -First 1)) {
        Read-JsonLdEvent $node $links[$i]
      }
    } catch {
      # A disallowed page stops the run for this source. A single bad page does not.
      if ("$_" -match 'robots.txt disallows') { throw }
      Write-Warning "$($Source.name): skipping $($links[$i]): $_"
    }
  }
}

function ConvertFrom-ClockTime {
  # Reads a time such as "3:00 pm", "3pm", or "10:30 a.m." as minutes after midnight, or $null.
  param([string]$Value)

  $m = [regex]::Match("$Value", '(?i)^\s*(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s*m\.?\s*$')
  if (-not $m.Success) { return $null }
  $hour = [int]$m.Groups[1].Value % 12
  if ($m.Groups[3].Value -match '(?i)p') { $hour += 12 }
  $minute = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 }
  $hour * 60 + $minute
}

function Read-CardsSource {
  # A card holds one or more dates (month and day, no year), a title, and a link. The default
  # patterns read Boise Centre's markup; datePattern, titlePattern, and timePattern override them.
  $html = if ($Response) { $Response[0] } else { Get-ScrapePage $listUri }
  $invariant = [Globalization.CultureInfo]::InvariantCulture
  $now = [DateTime]::ParseExact($today, 'yyyy-MM-dd', $invariant)
  $datePattern = if ($Source.datePattern) { $Source.datePattern } else { '(?is)class="month">\s*(?<month>\w+)\s*<.*?class="day">\s*(?<day>\d+)\s*<' }
  $titlePattern = if ($Source.titlePattern) { $Source.titlePattern } else { '(?is)<h[1-6][^>]*>(?<title>.*?)</h[1-6]>' }

  foreach ($card in [regex]::Matches($html, $Source.itemPattern)) {
    try {
      $text = $card.Value
      $title = ConvertTo-PlainText ([regex]::Match($text, $titlePattern).Groups['title'].Value)
      if (-not $title) { throw 'no title on the card' }
      if ($Source.excludeTitlePattern -and $title -match $Source.excludeTitlePattern) { continue }
      $url = [regex]::Match($text, "href=([`"'])([^`"']+)\1").Groups[2].Value

      # Most cards show no year: a date more than 2 months back is next year's. A datePattern
      # with a year group reads a numeric date as is. With yearFromTitle, a year in the title
      # ("Winter Carnival 2027") is the first date's year, and a later date before it is the next year's.
      $titleYear = if ($Source.yearFromTitle -and $title -match '\b(20\d\d)\b') { [int]$Matches[1] }
      $dates = @([regex]::Matches($text, $datePattern) | ForEach-Object {
          if ($_.Groups['year'].Success) {
            # The month can be a number or a name ("June", "Jun").
            $monthValue = $_.Groups['month'].Value
            $monthNumber = if ($monthValue -match '^\d+$') { [int]$monthValue } else { [DateTime]::ParseExact($monthValue.Substring(0, [Math]::Min(3, $monthValue.Length)), 'MMM', $invariant).Month }
            return [DateTime]::new([int]$_.Groups['year'].Value, $monthNumber, [int]$_.Groups['day'].Value).ToString('yyyy-MM-dd', $invariant)
          }
          $monthText = $_.Groups['month'].Value
          $month = $monthText.Substring(0, [Math]::Min(3, $monthText.Length))
          $year = if ($titleYear) { $titleYear } else { $now.Year }
          $date = [DateTime]::ParseExact("$year $month $([int]$_.Groups['day'].Value)", 'yyyy MMM d', $invariant)
          if (-not $titleYear -and $date -lt $now.AddMonths(-2)) { $date = $date.AddYears(1) }
          $date.ToString('yyyy-MM-dd', $invariant)
        })
      if ($titleYear) {
        for ($d = 1; $d -lt $dates.Count; $d++) {
          if ($dates[$d] -lt $dates[0]) { $dates[$d] = ([DateTime]::ParseExact($dates[$d], 'yyyy-MM-dd', $invariant)).AddYears(1).ToString('yyyy-MM-dd', $invariant) }
        }
      }
      if ($dates.Count -eq 0) { throw 'no date on the card' }

      $link = if ($url) { [uri]::new($listUri, [System.Net.WebUtility]::HtmlDecode($url)).AbsoluteUri } else { $Source.url }

      $time = if ($Source.timePattern) { [regex]::Match($text, $Source.timePattern) }
      # Tags inside a time ("8<span>pm</span>") are dropped before it is read.
      $startMinutes = if ($time -and $time.Success) { ConvertFrom-ClockTime ($time.Groups['start'].Value -replace '<[^>]*>', '') }
      if ($null -ne $startMinutes) {
        # A timed event: the first date at the start time, ending the same day if an end time is given.
        $day = [DateTime]::ParseExact($dates[0], 'yyyy-MM-dd', $invariant)
        $start = ConvertTo-BoiseTime $day.AddMinutes($startMinutes)
        $endMinutes = ConvertFrom-ClockTime ($time.Groups['end'].Value -replace '<[^>]*>', '')
        $end = if ($null -ne $endMinutes -and $endMinutes -gt $startMinutes) { ConvertTo-BoiseTime $day.AddMinutes($endMinutes) }
        New-ScrapeEvent -Title $title -Start $start -End $end -AllDay $false -Url $link
        continue
      }

      $end = if ($dates.Count -gt 1 -and $dates[1] -gt $dates[0]) { $dates[1] }
      New-ScrapeEvent -Title $title -Start $dates[0] -End $end -AllDay $true -Url $link
    } catch {
      Write-Warning "$($Source.name): skipping a card: $_"
    }
  }
}

function ConvertFrom-CalendarAppTime {
  # The calendar app writes Boise wall-clock time as "yyyy-MM-dd HH:mm", or a bare date for all-day.
  param([string]$Value)

  if ($Value -match '^\d{4}-\d{2}-\d{2}$') { return @{ Value = $Value; AllDay = $true } }
  $parsed = [DateTime]::MinValue
  if (-not [DateTime]::TryParseExact($Value, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
    return $null
  }
  @{ Value = ConvertTo-BoiseTime $parsed; AllDay = $false }
}

function Read-CalendarAppSource {
  # City of Boise calendar pages (boiseartsandhistory.org) embed every event as JSON in one attribute.
  # Use start and end, not startDate: startDate carries a Z on some events and not others.
  $html = if ($Response) { $Response[0] } else { Get-ScrapePage $listUri }
  $match = [regex]::Match($html, '(?s)id="calendar-app"[^>]*?data-config=''(?<json>\{.*?\})''')
  if (-not $match.Success) { throw "$($Source.name): no #calendar-app data-config on the page" }
  $config = ConvertFrom-TvJson ([System.Net.WebUtility]::HtmlDecode($match.Groups['json'].Value))

  foreach ($property in @($config.contentItems.PSObject.Properties)) {
    $item = $property.Value.cal
    try {
      $start = ConvertFrom-CalendarAppTime $item.start
      if (-not $start) { throw "unreadable start '$($item.start)'" }
      $end = ConvertFrom-CalendarAppTime $item.end
      $endValue = if ($end -and -not $item.hideEndDate -and $end.AllDay -eq $start.AllDay -and $end.Value -gt $start.Value) { $end.Value }

      # The page keeps a year of history. Past events aren't news, and reading them would backfill the archive.
      $lastDay = if ($endValue) { $endValue.Substring(0, 10) } else { $start.Value.Substring(0, 10) }
      if ($lastDay -lt $today) { continue }

      # Locations read "Spaulding Ranch (3805 N Cole Road)": the venue, then its address.
      $venueName = ("$($item.location)" -replace '\s*\(.*\)\s*$', '').Trim()
      if ($venueName -eq 'None') { $venueName = '' }
      $title = if ($item.title) { $item.title } else { $item.name }
      $url = if ($item.eventUrl) { [uri]::new($listUri, [System.Net.WebUtility]::HtmlDecode($item.eventUrl)).AbsoluteUri } else { $Source.url }

      New-ScrapeEvent -Title $title -Start $start.Value -End $endValue -AllDay $start.AllDay `
        -VenueName $venueName -CityText '' -Url $url -Description $item.bodyText -PriceMin (ConvertFrom-TvPriceText $item.cost)
    } catch {
      Write-Warning "$($Source.name): skipping '$($item.title)': $_"
    }
  }
}

function Read-CivicPlusSource {
  # CivicPlus city calendars (Calendar.aspx) list one month per page: a title, a date line, and
  # usually hidden schema.org microdata with the place. Their iCalendar export is disallowed by
  # robots.txt on every site seen, so this reads the list for this month and the next
  # maxPages - 1 months (default 3 in all).
  $months = if ($Source.maxPages) { [int]$Source.maxPages } else { 3 }
  $invariant = [Globalization.CultureInfo]::InvariantCulture
  $first = [DateTime]::ParseExact($today, 'yyyy-MM-dd', $invariant)
  $seen = [Collections.Generic.HashSet[string]]::new()

  for ($i = 0; $i -lt $months; $i++) {
    $month = $first.AddMonths($i)
    $html = if ($Response) { $Response[$i] } else {
      $query = if ($i -eq 0) { '' } else { "?month=$($month.Month)&year=$($month.Year)&day=1" }
      Get-ScrapePage ([uri]::new($listUri, "$($listUri.AbsolutePath)$query"))
    }
    if (-not $html) { break }

    foreach ($item in [regex]::Matches($html, '(?s)<li>\s*<h3>.*?</li>')) {
      $text = $item.Value
      $title = ''
      try {
        # The title and date line are always shown; the microdata is missing on some events.
        $title = ConvertTo-PlainText ([regex]::Match($text, '(?s)<h3>.*?<span>(?<v>.*?)</span>').Groups['v'].Value)
        if (-not $title) { throw 'no title' }
        if ($Source.excludeTitlePattern -and $title -match $Source.excludeTitlePattern) { continue }
        $body = [regex]::Match($text, '(?s)itemtype="http://schema\.org/Event">(?<body>.*)$').Groups['body'].Value

        # The date line reads "November 6, 2026, All Day", "November 10, 2026, 6:30 PM - 8:00 PM",
        # or, for several days, "November 6, 2026 - November 8, 2026".
        $when = (ConvertTo-PlainText ([regex]::Match($text, '(?s)class="date">(?<v>.*?)</div>').Groups['v'].Value)) -replace '\s+', ' '
        $line = [regex]::Match($when, '(?i)^(?<date>[A-Z]+ \d{1,2}, \d{4})(?:,? (?<from>\d{1,2}:\d{2} [AP]M))?(?: ?- ?(?:(?<endDate>[A-Z]+ \d{1,2}, \d{4}),? ?)?(?<to>\d{1,2}:\d{2} [AP]M)?)?')
        if (-not $line.Success) { throw "unreadable date '$when'" }
        $day = [DateTime]::ParseExact($line.Groups['date'].Value, 'MMMM d, yyyy', $invariant)
        $lastDay = if ($line.Groups['endDate'].Success) { [DateTime]::ParseExact($line.Groups['endDate'].Value, 'MMMM d, yyyy', $invariant) } else { $day }
        if ($lastDay.ToString('yyyy-MM-dd', $invariant) -lt $today) { continue }

        $startMinutes = if ($line.Groups['from'].Success) { ConvertFrom-ClockTime $line.Groups['from'].Value }
        $endMinutes = if ($line.Groups['to'].Success) { ConvertFrom-ClockTime $line.Groups['to'].Value }
        $allDay = $null -eq $startMinutes
        $end = $null
        if ($allDay) {
          $start = $day.ToString('yyyy-MM-dd', $invariant)
          if ($lastDay -gt $day) { $end = $lastDay.ToString('yyyy-MM-dd', $invariant) }
        } else {
          $start = ConvertTo-BoiseTime $day.AddMinutes($startMinutes)
          if ($null -ne $endMinutes) {
            $endAt = $lastDay.AddMinutes($endMinutes)
            if ($endAt -gt $day.AddMinutes($startMinutes)) { $end = ConvertTo-BoiseTime $endAt }
          }
        }

        $eid = [regex]::Match($text, 'Calendar\.aspx\?EID=(?<id>\d+)').Groups['id'].Value
        if (-not $seen.Add("$eid|$start")) { continue }
        $url = if ($eid) { [uri]::new($listUri, "/Calendar.aspx?EID=$eid").AbsoluteUri } else { $Source.url }

        # The place name is often the placeholder "Event Location", or a sentence instead of a name.
        $place = [regex]::Match($body, '(?s)itemtype="http://schema\.org/Place">\s*<span itemprop="name">(?<v>.*?)</span>').Groups['v'].Value
        $venueName = ConvertTo-PlainText $place
        if ($venueName -eq 'Event Location' -or $venueName.Length -gt 60) { $venueName = '' }
        $cityText = ConvertTo-PlainText ([regex]::Match($body, 'itemprop="addressLocality">(?<v>[^<]*)<').Groups['v'].Value)
        $description = [regex]::Match($body, '(?s)itemprop="description">(?<v>.*?)</p>').Groups['v'].Value

        New-ScrapeEvent -Title $title -Start $start -End $end -AllDay $allDay `
          -VenueName $venueName -CityText $cityText -Url $url -Description $description
      } catch {
        Write-Warning "$($Source.name): skipping '$title': $_"
      }
    }
  }
}

function ConvertFrom-ChamberMasterLocation {
  # Locations read "Emmett Public Library 275 S Hayes Ave Emmett, ID 83617": the name, then the
  # street address, then the city. The name ends where the house number starts.
  param([string]$Location)

  # A location that starts with the house number has no name, so the source venue is used.
  $text = ($Location -replace '\s+', ' ').Trim()
  $match = [regex]::Match($text, '^(?:(?<name>.*?)\s+)?\d+\s+(?<street>.*?)(?:,\s*(?:ID|Idaho)\b.*)?$')
  $name = if ($match.Success) { $match.Groups['name'].Value } else { ($text -split ',')[0] }
  $street = if ($match.Success) { $match.Groups['street'].Value } else { $text }

  # The city is the last one or two words of the address part.
  $words = @($street -split ' ' | Where-Object { $_ })
  $city = $null
  foreach ($count in 2, 1) {
    if ($words.Count -ge $count) {
      $city = Resolve-TvCity (($words | Select-Object -Last $count) -join ' ')
      if ($city) { break }
    }
  }
  @{ Venue = $name.Trim(' ', ','); City = $city }
}

function Read-ChamberMasterSource {
  # The month page (/events/calendar/YYYY-MM-01) lists each day's events as links to
  # /events/details/<slug>-<id>, and a multi-day event is listed on every day. Titles are filtered
  # and past events skipped (by their last listed day) before any iCal file is fetched. Each event's
  # details come from its iCal file at /events/ical/<slug>-<id>.ics. With -Response: the month
  # page, then each event's iCal text in list order.
  $months = if ($Source.maxPages) { [int]$Source.maxPages } else { 3 }
  $invariant = [Globalization.CultureInfo]::InvariantCulture
  $first = [DateTime]::ParseExact($today.Substring(0, 7) + '-01', 'yyyy-MM-dd', $invariant)
  $lastDay = [ordered]@{}
  $titles = @{}

  for ($i = 0; $i -lt $months; $i++) {
    $html = if ($Response) { if ($i -eq 0) { $Response[0] } } else {
      $path = if ($i -eq 0) { $listUri.AbsolutePath } else { '/events/calendar/' + $first.AddMonths($i).ToString('yyyy-MM-dd', $invariant) }
      Get-ScrapePage ([uri]::new($listUri, $path))
    }
    if (-not $html) { break }

    $day = ''
    $pattern = '/events/index/(?<day>\d{4}-\d{2}-\d{2})"|<a href="[^"]*/events/details/(?<id>[a-z0-9-]+-\d+)(?:\?[^"]*)?"[^>]*>(?<title>[^<]*)</a>'
    foreach ($m in [regex]::Matches($html, $pattern)) {
      if ($m.Groups['day'].Success) { $day = $m.Groups['day'].Value; continue }
      $title = ConvertTo-PlainText $m.Groups['title'].Value
      if ($Source.excludeTitlePattern -and $title -match $Source.excludeTitlePattern) { continue }
      $id = $m.Groups['id'].Value
      if (-not $lastDay.Contains($id) -or $day -gt $lastDay[$id]) { $lastDay[$id] = $day }
      $titles[$id] = $title
    }
  }

  $ids = @($lastDay.Keys | Where-Object { $lastDay[$_] -ge $today })
  $limit = 150
  if ($ids.Count -gt $limit) {
    Write-Warning "$($Source.name): $($ids.Count) events, reading the first $limit"
    $ids = @($ids | Select-Object -First $limit)
  }

  for ($n = 0; $n -lt $ids.Count; $n++) {
    $id = $ids[$n]
    try {
      $text = if ($Response) { $Response[$n + 1] } else { Get-ScrapePage ([uri]::new($listUri, "/events/ical/$id.ics")) }
      $item = @(ConvertFrom-Ics "$text") | Select-Object -First 1
      if (-not $item) { throw 'no event in the iCal file' }
      if ($item.Status -eq 'CANCELLED') { continue }
      $place = ConvertFrom-ChamberMasterLocation $item.Location
      $url = if ($item.Url) { $item.Url } else { [uri]::new($listUri, "/events/details/$id").AbsoluteUri }
      New-ScrapeEvent -Title $item.Summary -Start $item.Start -End $item.End -AllDay $item.AllDay `
        -VenueName $place.Venue -CityText "$($place.City)" -Url $url -Description $item.Description
    } catch {
      if ("$_" -match 'robots.txt disallows') { throw }
      Write-Warning "$($Source.name): skipping '$($titles[$id])': $_"
    }
  }
}

switch ($Source.scrapeMode) {
  'jsonld' { Read-JsonLdSource }
  'cards' { Read-CardsSource }
  'calendarapp' { Read-CalendarAppSource }
  'civicplus' { Read-CivicPlusSource }
  'chambermaster' { Read-ChamberMasterSource }
  default { throw "$($Source.name): unknown scrapeMode '$($Source.scrapeMode)'" }
}
