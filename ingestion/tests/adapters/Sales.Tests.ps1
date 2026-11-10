BeforeAll {
  $script:adapter = Join-Path $PSScriptRoot '..' '..' 'scripts' 'adapters' 'sales.ps1'
  $script:fetchedAt = '2026-11-09T07:00:00Z'

  function New-SaleSource {
    param([string]$Mode, [string]$Name, [string]$Url, [string]$Venue)
    [pscustomobject]@{
      name = $Name; displayName = $Venue; adapter = 'sales'; salesMode = $Mode; url = $Url
      category = 'auctions-estate-sales'; city = 'Boise'; venue = $Venue; venueKey = $Name
    }
  }

  # Runs the adapter on one response and returns the events, keeping the drop counts it reports.
  function Invoke-Sales {
    param([pscustomobject]$Source, [string]$Text)
    $output = & $adapter -Source $Source -FetchedAt $fetchedAt -Response @($Text) -Verbose 4>&1
    $script:summary = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object Message) -join "`n"
    @($output | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] })
  }
}

Describe 'sales adapter, ics mode (Downs Auction)' {
  BeforeAll {
    $source = New-SaleSource 'ics' 'downs-auction' 'https://downs.test/events/list/?ical=1' 'Downs Auction'
    $feed = @'
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261111
DTEND;VALUE=DATE:20261112
UID:1@downs.test
SUMMARY:431 W Edwards Ave\, Nampa\, ID
DESCRIPTION:431 W Edwards Ave\, Nampa\, ID\nAbsolute Real Estate Auction\nWednesday\, November 11th\, 2026 at 2 pm\nLOCATION: 431 W Edwards Ave\, Nampa\, ID 83686\nCall Dusty (208)555-0100 with any questions.
URL:https://downs.test/event/431-w-edwards-ave-nampa-id/
CATEGORIES:Real Estate,Real Estate Auction
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261111
DTEND;VALUE=DATE:20261112
UID:2@downs.test
SUMMARY:Brewer Incredible Online Estate Auction
DESCRIPTION:November 11th\, 2026 at 5 pm\n 431 W Edwards Ave\, Nampa\, ID\nClick Here to Bid
URL:https://downs.test/event/brewer/
CATEGORIES:Estate Auction,Online
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261114
UID:3@downs.test
SUMMARY:Farm Equipment Auction
DESCRIPTION:Saturday\, November 14th\, 2026 at 10 am\nLOCATION: 123 Main St\, Parma\, ID 83660
URL:https://downs.test/event/farm/
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261121
UID:4@downs.test
SUMMARY:Coin Auction
DESCRIPTION:Saturday November 21st at 1 pm. Place to be announced.
URL:https://downs.test/event/coins/
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261118
UID:5@downs.test
SUMMARY:999 Airbase Rd\, Mountain Home\, ID
DESCRIPTION:999 Airbase Rd\, Mountain Home\, ID\nReal Estate Auction\nWednesday November 18th\, 2026 at 2 pm\nLOCATION: 999 Airbase Rd\, Mountain Home\, ID 83647
URL:https://downs.test/event/999-airbase-rd/
CATEGORIES:Commercial,Real Estate
END:VEVENT
END:VCALENDAR
'@
    $script:kept = Invoke-Sales $source $feed
    $script:downsSummary = $script:summary
  }

  It 'keeps the in-person auctions in covered cities' {
    $kept.Count | Should -Be 2
    $kept[0].city | Should -Be 'Nampa'
    $kept[1].city | Should -Be 'Mountain Home'
  }

  It 'names an auction listed by street address by its kind and city, so no address is stored' {
    $kept[0].title | Should -Be 'Absolute Real Estate Auction in Nampa'
    $kept[1].title | Should -Be 'Real Estate Auction in Mountain Home'
  }

  It 'reads the start time from the description' {
    $kept[0].start | Should -Be '2026-11-11T14:00:00-07:00'
    $kept[0].allDay | Should -BeFalse
  }

  It 'stores only the title, company, city, times, and link' {
    $kept[0].venue | Should -Be 'Downs Auction'
    $kept[0].url | Should -Be 'https://downs.test/event/431-w-edwards-ave-nampa-id/'
    $kept[0].category | Should -Be 'auctions-estate-sales'
    $kept[0].PSObject.Properties.Name | Should -Not -Contain 'description'
    # The link is the site's own event page, whose slug can hold the street; nothing else may.
    ($kept | Select-Object -Property * -ExcludeProperty url, sources | ConvertTo-Json -Depth 5) | Should -Not -Match 'Edwards|Airbase|555-0100'
  }

  It 'reports what the in-person rule and the city filter dropped' {
    $downsSummary | Should -Match 'kept 2'
    $downsSummary | Should -Match '2 dropped by the in-person rule'
    $downsSummary | Should -Match '1 dropped by the city filter'
  }
}

Describe 'sales adapter, corbett mode' {
  BeforeAll {
    $source = New-SaleSource 'corbett' 'corbett-auctions' 'https://corbett.test/' 'Corbett Auctions & Appraisals'
    function Card {
      param([string]$Href, [string]$Type, [string[]]$Texts, [string]$Title, [string[]]$Paragraphs, [string]$Place)
      $spans = ($Texts | ForEach-Object { "<span class=`"elementor-heading-title elementor-size-default`">$_</span>" }) -join ' '
      $ps = ($Paragraphs | ForEach-Object { "<p class=`"elementor-heading-title elementor-size-default`">$_</p>" }) -join ' '
      # The place comes last, in a span after the description paragraphs, as on the site.
      $where = if ($Place) { "<span class=`"elementor-heading-title elementor-size-default`">$Place</span>" }
      "<div role=`"listitem`" class=`"e-loop-item auction_type-$Type`"><a class=`"x`" href=`"$Href`"><img src=`"a.jpg`"> $spans <h3 class=`"elementor-heading-title elementor-size-default`">$Title</h3> $ps $where</a></div>"
    }
    $page = @(
      '<html><body><div class="hero">'
      (Card 'https://corbett.test/auction/old-sale/' 'estate' @('Oct', '3', 'Saturday, 10:00 am', 'Live onsite') 'Past Live Onsite Auction' @() 'Nampa, ID')
      '</div><div id="upcoming"><div class="elementor-heading-title">Upcoming auctions</div>'
      (Card 'https://www.auctiontime.test/listing/1' 'online' @('Nov', '11', '<span>Online</span>', 'Live now', 'Wednesday, 12:56 pm', 'Online bidding') 'Online Auction &#8211; Baler' @('Ends Wed, Nov 11') 'Online &#183; HiBid')
      (Card 'https://corbett.test/auction/nampa-live-onsite-auction-10270-duck-ln/' 'estate' @('Nov', '14', 'Estate', 'In 5 days', 'Saturday', 'Saturday, 10:00 am', 'Live onsite') 'Nampa, ID Live Onsite Auction &#8211; Silver &amp; Guns' @('Silver, guns and a tractor.') 'Nampa, ID')
      (Card 'https://corbett.test/auction/10207-duck-ln-nampa-id/' 'real-estate' @('Nov', '14', 'Real Estate', 'Saturday, 12:00 pm', 'Live onsite') '2,789 SF Home &amp; Shop &#8211; Nampa, ID' @('Live onsite auction.', 'Minimum bid $699,000') 'Nampa, ID')
      (Card 'https://corbett.test/auction/machine-shop/' 'estate' @('Nov', '21', 'Saturday, 10:00 am', 'Live onsite') 'Machine Shop' @('CNCs and a metal shop.') 'Address to be posted')
      (Card 'https://corbett.test/auction/garden-valley/' 'real-estate' @('Nov', '28', 'Saturday, 11:00 am', 'Live onsite') 'Lot &amp; Home' @() 'Garden Valley, ID')
      (Card 'https://corbett.hibid.test/catalog/1/comics' 'online' @('Dec', '15', 'Tuesday, 7:00 pm', 'Online bidding') 'Online Comic Book Auction' @('Ends Tue, Dec 15') 'Online &#183; HiBid')
      (Card 'https://corbett.test/auction/january/' 'estate' @('Jan', '9', 'Saturday, 9:00 am', 'Live onsite') 'Caldwell Live Onsite Auction' @() 'Caldwell, ID')
      '<div role="listitem" class="e-loop-item"><a href="https://corbett.hibid.test/email/subscribe">Get alerts</a></div>'
      '</div></body></html>'
    ) -join "`n"
    $script:kept = Invoke-Sales $source $page
    $script:corbettSummary = $script:summary
  }

  It 'keeps only the live onsite auctions in covered cities, from the upcoming list' {
    @($kept.title) | Should -Be @("Nampa, ID Live Onsite Auction $([char]0x2013) Silver & Guns", "2,789 SF Home & Shop $([char]0x2013) Nampa, ID", 'Caldwell Live Onsite Auction')
  }

  It 'reads the date and time, and guesses the year as the next one with that date' {
    $kept[0].start | Should -Be '2026-11-14T10:00:00-07:00'
    $kept[2].start | Should -Be '2027-01-09T09:00:00-07:00'
  }

  It 'links each auction to its page on the site and stores no description or price' {
    $kept[0].url | Should -Be 'https://corbett.test/auction/nampa-live-onsite-auction-10270-duck-ln/'
    $kept[0].city | Should -Be 'Nampa'
    $kept[0].venue | Should -Be 'Corbett Auctions & Appraisals'
    $kept[1].PSObject.Properties.Name | Should -Not -Contain 'description'
    $kept[1].PSObject.Properties.Name | Should -Not -Contain 'costTier'
  }

  It 'reports what the in-person rule and the city filter dropped' {
    $corbettSummary | Should -Match 'kept 3'
    $corbettSummary | Should -Match '3 dropped by the in-person rule'
    $corbettSummary | Should -Match '1 dropped by the city filter'
  }
}

Describe 'sales adapter, onthewater mode' {
  BeforeAll {
    $source = New-SaleSource 'onthewater' 'on-the-water-estate-sales' 'https://otw.test/estatesales' 'On The Water Estate Sales'
    $page = @'
<html><body><main>
<h1>UPCOMING EVENTS</h1>
<p>UPCOMING SALES</p><p>Ballance Living Estate Sale November 21-22 Boise</p><p>Downsizing Sale January 8&#8211;9 Nampa</p><p>Farm Estate Sale December 5 Parma</p><p>Call (208) 555-0100 to book today.</p>
<p><strong>Hello, Everyone!</strong></p><p>Join us November 21&#8211;22 for a Curated Vintage Living Estate Sale in Boise!</p>
<p><strong>Saturday, November 21 | 9:00 AM &#8211; 2:00 PM</strong> Numbers will be handed out beginning at 8:00 AM</p>
<p><strong>Sunday, November 22 | 9:00 AM &#8211; 1:00 PM</strong></p>
<h4>Location</h4><p> Middleton, ID 83644</p>
</main></body></html>
'@
    $script:kept = Invoke-Sales $source $page
    $script:otwSummary = $script:summary
  }

  It 'keeps each upcoming sale in a covered city' {
    @($kept.title) | Should -Be @('Ballance Living Estate Sale', 'Downsizing Sale')
    @($kept.city) | Should -Be @('Boise', 'Nampa')
  }

  It 'runs a sale from the first day''s opening to the last day''s close' {
    $kept[0].start | Should -Be '2026-11-21T09:00:00-07:00'
    $kept[0].end | Should -Be '2026-11-22T13:00:00-07:00'
  }

  It 'makes a sale with no hours all-day, in the next year with those dates' {
    $kept[1].allDay | Should -BeTrue
    $kept[1].start | Should -Be '2027-01-08'
    $kept[1].end | Should -Be '2027-01-09'
  }

  It 'links each sale to the sales page' {
    $kept[0].url | Should -Be 'https://otw.test/estatesales'
    $kept[0].venue | Should -Be 'On The Water Estate Sales'
  }

  It 'reports what the city filter dropped' {
    $otwSummary | Should -Match 'kept 2'
    $otwSummary | Should -Match '0 dropped by the in-person rule'
    $otwSummary | Should -Match '1 dropped by the city filter'
  }
}

Describe 'Get-TvSaleVerdict' {
  BeforeAll { . "$PSScriptRoot/../../scripts/lib/Sales.ps1" }

  It 'drops anything that says online, in any case' {
    Get-TvSaleVerdict -Title 'Estate Auction' -Text 'Bid ONLINE now' -HasPlace $true -City 'Boise' | Should -Be 'in-person'
  }

  It 'drops a sale with no place' {
    Get-TvSaleVerdict -Title 'Estate Auction' -Text '' -HasPlace $false -City $null | Should -Be 'in-person'
  }

  It 'drops a place outside the covered cities' {
    Get-TvSaleVerdict -Title 'Estate Auction' -Text '' -HasPlace $true -City $null | Should -Be 'city'
  }

  It 'keeps an in-person sale in a covered city' {
    Get-TvSaleVerdict -Title 'Estate Auction' -Text '' -HasPlace $true -City 'Valley County' | Should -Be 'keep'
  }
}

Describe 'Get-TvNextDate' {
  BeforeAll { . "$PSScriptRoot/../../scripts/lib/Sales.ps1" }

  It 'uses this year for a date ahead or just past' {
    Get-TvNextDate -Month 'Nov' -Day 21 -Today ([datetime]'2026-11-09') | Should -Be '2026-11-21'
    Get-TvNextDate -Month 'November' -Day 2 -Today ([datetime]'2026-11-09') | Should -Be '2026-11-02'
  }

  It 'uses next year for a date more than six months gone' {
    Get-TvNextDate -Month 'Jan' -Day 9 -Today ([datetime]'2026-11-09') | Should -Be '2027-01-09'
  }
}
