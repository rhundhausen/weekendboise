# Finds the city of events stored as Other by reading their pages: the event's own page, then the
# organizer's site its "Website" link points to. Refine runs it after Resolve-TvOtherCity, which
# only reads the event's own text. Results are kept in data/city-lookup.json, so a page is read
# again only when its answer is old.

. "$PSScriptRoot/Http.ps1"
. "$PSScriptRoot/Scrape.ps1"
. "$PSScriptRoot/Cities.ps1"

# Sites that never say where one event is: social networks that refuse scripts, and chains
# whose event pages cover every store.
$script:TvCityLookupSkipHosts = @(
  'facebook.com', 'fb.me', 'instagram.com', 'x.com', 'twitter.com', 'tiktok.com', 'youtube.com',
  'homedepot.com', 'lowes.com', 'jcpenney.com', 'michaels.com', 'barnesandnoble.com',
  'eventbrite.com', 'linktr.ee', 'docs.google.com', 'forms.gle'
)

function Find-TvAddressCity {
  <#
  .SYNOPSIS
    The one city a page's addresses name, or $null.
  .DESCRIPTION
    Counts "City, ID" and "City, Idaho" for the schema's cities, Idaho ZIP codes after the state,
    and the addressLocality of schema.org Event locations. A bare city name in prose doesn't
    count. A page that names two or more cities gives $null, because it can't say which.
  #>
  [CmdletBinding()]
  param([Parameter(Position = 0)][AllowEmptyString()][string]$Html)

  if (-not $Html) { return $null }
  $found = [Collections.Generic.HashSet[string]]::new()

  foreach ($node in @(Get-TvJsonLdEvent $Html)) {
    foreach ($location in @($node.location)) {
      $locality = if ($location.address -is [string]) { '' } else { "$($location.address.addressLocality)" }
      $city = Resolve-TvCity $locality
      if ($city -and $city -ne 'Other') { $null = $found.Add($city) }
    }
  }

  # Menus and page headers name other cities ("Guide to Moving to Boise, ID" in Boise Mom's menu),
  # not the event's, so they are left out. Footers stay: an organizer's own address is often there.
  $text = $Html -replace '(?is)<(script|style|nav|header)\b[^>]*>.*?</\1>', ' ' -replace '<[^>]+>', ' '
  $text = [Net.WebUtility]::HtmlDecode($text) -replace '\s+', ' '
  $names = (Get-TvCityNames | ForEach-Object { [regex]::Escape($_) }) -join '|'
  foreach ($match in [regex]::Matches($text, "(?i)\b($names)\s*,?\s+(ID|Idaho)\b")) {
    $null = $found.Add((Get-TvCityNames | Where-Object { $_ -eq $match.Groups[1].Value } | Select-Object -First 1))
  }
  foreach ($match in [regex]::Matches($text, '\b(?:ID|Idaho)\s+(83\d{3})\b')) {
    $city = $script:TvZipCities[$match.Groups[1].Value]
    if ($city) { $null = $found.Add($city) }
  }

  if ($found.Count -eq 1) { @($found)[0] } else { $null }
}

function Get-TvEventWebsite {
  # The "Website" link of a The Events Calendar event page, or $null.
  param([Parameter(Position = 0)][AllowEmptyString()][string]$Html)

  $match = [regex]::Match("$Html", '(?s)class="tribe-events-event-url[^"]*"[^>]*>\s*<a [^>]*href="([^"]+)"')
  if ($match.Success) { [Net.WebUtility]::HtmlDecode($match.Groups[1].Value) }
}

function Get-TvEventPlaceText {
  # The parts of an event page that describe this event's place: the venue block of a The Events
  # Calendar page, and schema.org Event data. Never the whole page, whose footer often names the
  # listing site's own city.
  param([AllowEmptyString()][string]$Html)

  $parts = [Collections.Generic.List[string]]::new()
  foreach ($match in [regex]::Matches("$Html", '(?s)class="tribe-events-meta-group tribe-events-meta-group-venue".*?(?=class="tribe-events-meta-group |<footer|</body|$)')) {
    $parts.Add("<div $($match.Value)</div>")
  }
  foreach ($match in [regex]::Matches("$Html", '(?is)<script[^>]*application/ld\+json[^>]*>.*?</script>')) {
    $parts.Add($match.Value)
  }
  $parts -join "`n"
}

function Test-TvSkipHost {
  param([uri]$Uri)

  $hostName = $Uri.Host.ToLowerInvariant() -replace '^www\.', ''
  foreach ($skip in $script:TvCityLookupSkipHosts) {
    if ($hostName -eq $skip -or $hostName.EndsWith(".$skip")) { return $true }
  }
  $false
}

function Invoke-TvCityLookup {
  <#
  .SYNOPSIS
    Sets the city on upcoming events stored as Other by reading their pages. Returns the state
    and counts.
  .DESCRIPTION
    For each event link that is due, it reads the event page. The venue block or schema.org data
    there wins. Otherwise it follows the page's Website link and reads the organizer's page, then
    that site's home page, and takes the city if exactly one is named (Find-TvAddressCity).

    A link is due when it has no entry, 30 days after a city was found, and 7 days after none was.
    A remembered city is applied without a request. Each host's robots.txt is read once per run
    and a disallowed page is never requested; requests to one host are at least MinDelaySeconds
    apart, or the host's Crawl-delay. Sites on the skip list (social networks, chain stores) are
    never requested. Entries no event has used for 30 days are dropped.
  .PARAMETER State
    Event URL to entry (city, website, checkedAt), from data/city-lookup.json. Updated in place.
  .PARAMETER Fetch
    Returns a page's HTML for a URL, or throws. Defaults to Invoke-TvRequest. Used by tests.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events,
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][DateTimeOffset]$Now,
    [int]$BudgetSeconds = 180,
    [double]$MinDelaySeconds = 1,
    [scriptblock]$Fetch = { param([string]$Url) Invoke-TvRequest $Url -Raw }
  )

  $invariant = [Globalization.CultureInfo]::InvariantCulture
  $nowText = $Now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
  $timer = [Diagnostics.Stopwatch]::StartNew()
  $robots = @{}
  $delays = @{}
  $lastRequest = @{}
  $pages = @{}
  $counts = @{ Pages = 0; Requests = 0; Found = 0; Errors = [Collections.Generic.List[string]]::new() }

  $outOfTime = { $timer.Elapsed.TotalSeconds -ge $BudgetSeconds }

  $get = {
    # A page's HTML, '' when it can't or mustn't be read. Cached for the run.
    param([string]$Url)
    if ($pages.ContainsKey($Url)) { return $pages[$Url] }
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin 'http', 'https') { return '' }
    if (Test-TvSkipHost $uri) { return '' }
    $origin = $uri.GetLeftPart('Authority')
    $wait = {
      if ($lastRequest.ContainsKey($origin)) {
        $gap = $delays[$origin] * 1000 - ($timer.ElapsedMilliseconds - $lastRequest[$origin])
        if ($gap -gt 0) { Start-Sleep -Milliseconds ([int]$gap) }
      }
      $lastRequest[$origin] = $timer.ElapsedMilliseconds
      $counts.Requests++
    }
    if (-not $robots.ContainsKey($origin)) {
      if (& $outOfTime) { return '' }
      $delays[$origin] = $MinDelaySeconds
      & $wait
      $robots[$origin] = try { & $Fetch "$origin/robots.txt" } catch {
        # No robots.txt means no rules. Anything else means we can't tell, so the host is left alone.
        if ("$_" -match 'HTTP 40[14]|HTTP 410') { '' } else { $null }
      }
      if ($null -ne $robots[$origin]) { $delays[$origin] = [Math]::Max($MinDelaySeconds, [double](Get-TvRobotsGroup $robots[$origin]).Delay) }
    }
    $rules = $robots[$origin]
    $path = $uri.GetLeftPart('Query')
    if ($null -eq $rules -or $delays[$origin] -gt 60 -or -not (Test-TvRobotsAllowed $rules ([uri]$path).PathAndQuery) -or (& $outOfTime)) {
      return ''
    }
    & $wait
    $html = try { "$(& $Fetch $path)" } catch {
      $counts.Errors.Add("$path : $_")
      $null
    }
    $pages[$Url] = $html
    $html
  }

  $due = {
    param($entry)
    if (-not $entry) { return $true }
    $at = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse("$($entry.checkedAt)", $invariant, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at)) { return $true }
    $limit = if ($entry.city) { 30 } else { 7 }
    ($Now - $at).TotalDays -ge $limit
  }

  $others = @($Events | Where-Object { $_.url -and (-not $_.city -or $_.city -eq 'Other') })
  foreach ($url in @($others | ForEach-Object url | Select-Object -Unique)) {
    if (-not (& $due $State[$url]) -or (& $outOfTime)) { continue }
    $page = & $get $url
    if ($null -eq $page) { continue }
    if (-not $page) { continue }
    $counts.Pages++

    $entry = [ordered]@{}
    $city = Find-TvAddressCity (Get-TvEventPlaceText $page)
    $website = Get-TvEventWebsite $page
    if ($website) { $entry.website = $website }
    if (-not $city -and $website) {
      $city = Find-TvAddressCity "$(& $get $website)"
      $siteUri = $null
      if (-not $city -and [uri]::TryCreate($website, [UriKind]::Absolute, [ref]$siteUri) -and $siteUri.AbsolutePath -ne '/') {
        $city = Find-TvAddressCity "$(& $get "$($siteUri.GetLeftPart('Authority'))/")"
      }
    }
    if ($city) { $entry.city = $city }
    $entry.checkedAt = $nowText
    $State[$url] = $entry
  }

  foreach ($event in $others) {
    $city = $State[$event.url].city
    if ($city) {
      $event.city = $city
      $counts.Found++
    }
  }

  # Forget pages nothing has used for 30 days.
  $used = [Collections.Generic.HashSet[string]]::new([string[]]@($Events | ForEach-Object { "$($_.url)" }))
  foreach ($url in @($State.Keys)) {
    if ($used.Contains($url)) { continue }
    $at = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse("$($State[$url].checkedAt)", $invariant, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at) -or ($Now - $at).TotalDays -ge 30) {
      $State.Remove($url)
    }
  }

  [pscustomobject]@{
    State    = $State
    Others   = $others.Count
    Pages    = $counts.Pages
    Requests = $counts.Requests
    Found    = $counts.Found
    Errors   = @($counts.Errors)
  }
}

function Read-TvCityLookupState {
  # data/city-lookup.json as a hashtable of URL to entry, empty when the file is missing.
  param([Parameter(Mandatory)][string]$Path)

  $state = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return $state }
  $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -DateKind String
  foreach ($property in @($parsed.PSObject.Properties)) {
    $entry = [ordered]@{}
    foreach ($field in $property.Value.PSObject.Properties) { $entry[$field.Name] = "$($field.Value)" }
    $state[$property.Name] = $entry
  }
  $state
}

function Write-TvCityLookupState {
  # Sorted by URL, LF line endings, no BOM, so nightly diffs stay small.
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$State)

  $sorted = [ordered]@{}
  foreach ($url in ($State.Keys | Sort-Object)) {
    $entry = [ordered]@{}
    foreach ($name in 'city', 'website', 'checkedAt') { if ($State[$url][$name]) { $entry[$name] = $State[$url][$name] } }
    $sorted[$url] = $entry
  }
  $json = (($sorted | ConvertTo-Json -Depth 4) -replace "`r`n", "`n") + "`n"
  [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}
