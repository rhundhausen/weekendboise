# The eventbrite, seatgeek, and songkick fixtures are hand-written from the documented response
# shapes, not real responses, because no credentials were available. These tests prove the
# adapters match those shapes, not that the live APIs do.

BeforeAll {
  $script:repo = Join-Path $PSScriptRoot '..' '..'
  $script:fetchedAt = '2026-11-02T10:00:00Z'

  . (Join-Path $repo 'scripts' 'lib' 'Schema.ps1')

  function New-TestSource {
    param([string]$Adapter, [hashtable]$Extra = @{})
    $source = [ordered]@{
      name = "test-$Adapter"; displayName = 'Test'; adapter = $Adapter; url = 'https://api.test/v1/'; category = 'community-civic'
      city = 'Other'; venue = 'Various'; venueKey = 'various'; enabled = $true
    }
    foreach ($key in $Extra.Keys) { $source[$key] = $Extra[$key] }
    [pscustomobject]$source
  }

  function Invoke-Adapter {
    param([string]$Adapter, [object]$Source, [string]$Fixture)
    $text = Get-Content (Join-Path $repo 'tests' 'fixtures' $Fixture) -Raw
    @(& (Join-Path $repo 'scripts' 'adapters' "$Adapter.ps1") -Source $Source -FetchedAt $fetchedAt -Response $text)
  }

  function New-FakeResponse {
    param([int]$Status, [string]$Body = '')
    [pscustomobject]@{
      StatusCode       = $Status
      RawContentStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Body))
    }
  }
}

Describe 'eventbrite adapter' {
  BeforeAll {
    $source = New-TestSource 'eventbrite' @{ inferCategory = $true }
    $events = Invoke-Adapter 'eventbrite' $source 'eventbrite/example-organization.json'
  }

  It 'skips online and cancelled events' {
    $events.Count | Should -Be 1
  }

  It 'reads an event in Boise time' {
    $events[0].title | Should -Be 'Example Pottery Workshop'
    $events[0].start | Should -Be '2026-11-14T10:00:00-07:00'
    $events[0].end | Should -Be '2026-11-14T12:00:00-07:00'
    $events[0].venueKey | Should -Be 'the-olympic'
    $events[0].city | Should -Be 'Boise'
  }

  It 'classifies the event and keeps the price out' {
    $events[0].category | Should -Be 'learning-business'
    $events[0].size | Should -Be 'S'
    $events[0].description | Should -Not -Match '\$\d'
  }

  It 'fails clearly without a token' {
    $saved = $env:EVENTBRITE_TOKEN
    $env:EVENTBRITE_TOKEN = $null
    try {
      { & (Join-Path $repo 'scripts/adapters/eventbrite.ps1') -Source $source -FetchedAt $fetchedAt } | Should -Throw '*EVENTBRITE_TOKEN is not set*'
    } finally {
      $env:EVENTBRITE_TOKEN = $saved
    }
  }

  It 'fails clearly with no ids to read' {
    $saved = $env:EVENTBRITE_TOKEN
    $env:EVENTBRITE_TOKEN = 'test'
    try {
      { & (Join-Path $repo 'scripts/adapters/eventbrite.ps1') -Source $source -FetchedAt $fetchedAt } | Should -Throw '*organizationIds or venueIds*'
    } finally {
      $env:EVENTBRITE_TOKEN = $saved
    }
  }

  It 'sends the token as a header and follows continuation' {
    $saved = $env:EVENTBRITE_TOKEN
    $env:EVENTBRITE_TOKEN = 'SECRET'
    $global:TvApiRequests = [System.Collections.Generic.List[object]]::new()
    try {
      Mock Invoke-WebRequest {
        $global:TvApiRequests.Add([pscustomobject]@{ Uri = "$Uri"; Auth = $Headers.Authorization })
        if ($global:TvApiRequests.Count -eq 1) {
          New-FakeResponse 200 '{"pagination":{"has_more_items":true,"continuation":"NEXT"},"events":[]}'
        } else {
          New-FakeResponse 200 '{"pagination":{"has_more_items":false},"events":[]}'
        }
      }
      Mock Start-Sleep {}
      $listed = New-TestSource 'eventbrite' @{ organizationIds = @('123') }
      $null = & (Join-Path $repo 'scripts/adapters/eventbrite.ps1') -Source $listed -FetchedAt $fetchedAt
      $global:TvApiRequests.Count | Should -Be 2
      $global:TvApiRequests[0].Uri | Should -BeLike 'https://api.test/v1/organizations/123/events/*'
      $global:TvApiRequests[0].Uri | Should -Not -Match 'SECRET'
      $global:TvApiRequests[0].Auth | Should -Be 'Bearer SECRET'
      $global:TvApiRequests[1].Uri | Should -Match 'continuation=NEXT'
    } finally {
      $env:EVENTBRITE_TOKEN = $saved
      Remove-Variable -Name TvApiRequests -Scope Global -ErrorAction SilentlyContinue
    }
  }
}

Describe 'seatgeek adapter' {
  BeforeAll {
    $source = New-TestSource 'seatgeek' @{ latlong = '43.6150,-116.2023'; radius = 40 }
    $events = Invoke-Adapter 'seatgeek' $source 'seatgeek/example-area.json'
  }

  It 'keeps only Idaho venues' {
    $events.Count | Should -Be 2
    $events.title | Should -Not -Contain 'Example Oregon Show'
  }

  It 'reads the cost tier from the lowest price' {
    ($events | Where-Object title -eq 'Example Band').costTier | Should -BeExactly '$$$'
  }

  It 'reads an event in Boise time and maps its type' {
    $events[0].start | Should -Be '2026-11-14T20:00:00-07:00'
    $events[0].category | Should -Be 'music'
    $events[0].city | Should -Be 'Boise'
  }

  It 'treats the 3:30 AM placeholder as a date with no time' {
    $events[1].allDay | Should -BeTrue
    $events[1].start | Should -Be '2026-11-16'
    $events[1].category | Should -Be 'performing-arts'
  }

  It 'stores no price' {
    ($events[0] | ConvertTo-Json -Depth 6) | Should -Not -Match 'lowest_price'
  }

  It 'fails clearly without a client id' {
    $saved = $env:SEATGEEK_CLIENT_ID
    $env:SEATGEEK_CLIENT_ID = $null
    try {
      { & (Join-Path $repo 'scripts/adapters/seatgeek.ps1') -Source $source -FetchedAt $fetchedAt } | Should -Throw '*SEATGEEK_CLIENT_ID is not set*'
    } finally {
      $env:SEATGEEK_CLIENT_ID = $saved
    }
  }
}

Describe 'googlecalendar adapter' {
  # Two pages in the Calendar API v3 events.list shape (singleEvents=true), hand-written with
  # made-up ids: one case per rule.
  BeforeAll {
    $script:gcSource = New-TestSource 'googlecalendar' @{
      calendarId = 'examplelibrary@gmail.com'; url = 'https://example-library.test/calendar/'
      category = 'learning-business'; inferCategory = $true; city = 'Middleton'
      venue = 'Example Library'; venueKey = 'example-library'
      excludeTitles = @('Friends of the Library')
      venueAliases = [pscustomobject]@{ 'Example Library Annex' = 'Example Library'; 'Example Library Main' = 'Example Library' }
    }
    $pages = @('page1.json', 'page2.json') | ForEach-Object { Get-Content (Join-Path $repo 'tests' 'fixtures' 'googlecalendar' $_) -Raw }
    $script:gcEvents = @(& (Join-Path $repo 'scripts/adapters/googlecalendar.ps1') -Source $gcSource -FetchedAt $fetchedAt -Response $pages)
    function script:Get-GcEvent([string]$Title) { @($gcEvents | Where-Object title -eq $Title) }
  }

  It 'keeps the four real events across both pages' {
    $gcEvents.Count | Should -Be 4
    @($gcEvents.title | Sort-Object -Unique) | Should -Be @('Holiday Craft Fair', 'Pottery Workshop', 'Storytime')
  }

  It 'skips an event whose status is cancelled' {
    $gcEvents.title | Should -Not -Contain 'Lego Club'
  }

  It 'skips titles that start with CANCELED or CANCELLED, in any case' {
    $gcEvents.title | Should -Not -Match 'Teen Night|Book Club'
  }

  It 'skips the default excluded titles' {
    $gcEvents.title | Should -Not -Match 'closed|Council'
  }

  It "skips the calendar's own excluded titles" {
    $gcEvents.title | Should -Not -Contain 'Friends of the Library'
  }

  It 'reads a timed event in Boise time and strips HTML from its description' {
    $story = (Get-GcEvent 'Storytime')[0]
    $story.start | Should -Be '2026-11-12T10:30:00-07:00'
    $story.end | Should -Be '2026-11-12T11:15:00-07:00'
    $story.allDay | Should -BeFalse
    $story.description | Should -Be 'Songs & stories for ages 0-5'
  }

  It 'reads an all-day event with an inclusive end date' {
    $fair = (Get-GcEvent 'Holiday Craft Fair')[0]
    $fair.allDay | Should -BeTrue
    $fair.start | Should -Be '2026-12-05'
    $fair.end | Should -Be '2026-12-06'
  }

  It 'uses the default venue and city when the location is blank' {
    $story = (Get-GcEvent 'Storytime')[0]
    $story.venue | Should -Be 'Example Library'
    $story.venueKey | Should -Be 'example-library'
    $story.city | Should -Be 'Middleton'
  }

  It 'collapses aliased locations to the canonical venue, ignoring case' {
    (Get-GcEvent 'Holiday Craft Fair')[0].venueKey | Should -Be 'example-library'
    (Get-GcEvent 'Storytime')[1].venueKey | Should -Be 'example-library'
  }

  It 'reads any other location as venue and city' {
    $pottery = (Get-GcEvent 'Pottery Workshop')[0]
    $pottery.venue | Should -Be 'Middleton Community Center'
    $pottery.city | Should -Be 'Middleton'
  }

  It "links each event to its Google Calendar page under the library's source name" {
    $story = (Get-GcEvent 'Storytime')[0]
    $story.url | Should -Be 'https://www.google.com/calendar/event?eid=c3Rvcnl0aW1l'
    $story.sources[0].name | Should -Be 'test-googlecalendar'
    $story.sources[0].url | Should -Be $story.url
  }

  It 'keeps one copy of an event id and start listed twice, and each instance of a repeat' {
    @(Get-GcEvent 'Storytime').start | Should -Be @('2026-11-12T10:30:00-07:00', '2026-11-19T10:30:00-07:00')
  }

  It 'fails clearly without an API key' {
    $saved = $env:GOOGLE_CALENDAR_API_KEY
    $env:GOOGLE_CALENDAR_API_KEY = $null
    try {
      { & (Join-Path $repo 'scripts/adapters/googlecalendar.ps1') -Source $gcSource -FetchedAt $fetchedAt } | Should -Throw '*GOOGLE_CALENDAR_API_KEY is not set*'
    } finally {
      $env:GOOGLE_CALENDAR_API_KEY = $saved
    }
  }

  It 'asks for expanded instances over the next 90 days in Mountain time, and pages' {
    $saved = $env:GOOGLE_CALENDAR_API_KEY
    $env:GOOGLE_CALENDAR_API_KEY = 'SECRET'
    $global:TvApiRequests = [System.Collections.Generic.List[object]]::new()
    try {
      Mock Invoke-WebRequest {
        $global:TvApiRequests.Add(([uri]$Uri).AbsoluteUri)
        if ($global:TvApiRequests.Count -eq 1) { New-FakeResponse 200 '{"items":[],"nextPageToken":"NEXT TOKEN"}' }
        else { New-FakeResponse 200 '{"items":[]}' }
      }
      $null = & (Join-Path $repo 'scripts/adapters/googlecalendar.ps1') -Source $gcSource -FetchedAt $fetchedAt
      $global:TvApiRequests.Count | Should -Be 2
      $first = $global:TvApiRequests[0]
      $first | Should -BeLike 'https://www.googleapis.com/calendar/v3/calendars/examplelibrary%40gmail.com/events?*'
      $first | Should -Match 'singleEvents=true'
      $first | Should -Match 'orderBy=startTime'
      $first | Should -Match 'timeZone=America%2FDenver'
      $first | Should -Match 'key=SECRET'
      $query = [System.Web.HttpUtility]::ParseQueryString(([uri]$first).Query)
      $from = [DateTimeOffset]::Parse($query['timeMin'], [Globalization.CultureInfo]::InvariantCulture)
      $to = [DateTimeOffset]::Parse($query['timeMax'], [Globalization.CultureInfo]::InvariantCulture)
      ($to - $from).TotalDays | Should -Be 90
      [Math]::Abs(([DateTimeOffset]::UtcNow - $from).TotalMinutes) | Should -BeLessThan 5
      $global:TvApiRequests[1] | Should -Match 'pageToken=NEXT%20TOKEN'
    } finally {
      $env:GOOGLE_CALENDAR_API_KEY = $saved
      Remove-Variable -Name TvApiRequests -Scope Global -ErrorAction SilentlyContinue
    }
  }

  It 'explains HTTP <status> as a calendar that is not public or a wrong id, without the key' -ForEach @(
    @{ status = 403 }
    @{ status = 404 }
  ) {
    $saved = $env:GOOGLE_CALENDAR_API_KEY
    $env:GOOGLE_CALENDAR_API_KEY = 'SECRET'
    try {
      Mock Invoke-WebRequest { New-FakeResponse $status '{"error":{}}' }
      $thrown = $null
      try { & (Join-Path $repo 'scripts/adapters/googlecalendar.ps1') -Source $gcSource -FetchedAt $fetchedAt } catch { $thrown = "$_" }
      $thrown | Should -BeLike "*examplelibrary@gmail.com*not public or the calendar ID is wrong*HTTP $status*"
      $thrown | Should -Not -Match 'SECRET'
    } finally {
      $env:GOOGLE_CALENDAR_API_KEY = $saved
    }
  }
}

Describe 'songkick adapter' {
  BeforeAll {
    $source = New-TestSource 'songkick' @{ metroAreaId = '1' }
    $source.category = 'music'
    $events = Invoke-Adapter 'songkick' $source 'songkick/example-metro.json'
  }

  It 'skips cancelled events' {
    $events.Count | Should -Be 2
  }

  It 'reads an event and trims the venue and date from the title' {
    $events[0].title | Should -Be 'Example Band'
    $events[0].start | Should -Be '2026-11-14T20:00:00-07:00'
    $events[0].venueKey | Should -Be 'neurolux'
    $events[0].city | Should -Be 'Boise'
  }

  It 'treats an event with no time as all-day, and an unknown venue as no venue' {
    $events[1].allDay | Should -BeTrue
    $events[1].start | Should -Be '2026-11-15'
    $events[1].venueKey | Should -Be 'various'
    $events[1].city | Should -Be 'Nampa'
  }

  It 'fails clearly without a key' {
    $saved = $env:SONGKICK_API_KEY
    $env:SONGKICK_API_KEY = $null
    try {
      { & (Join-Path $repo 'scripts/adapters/songkick.ps1') -Source $source -FetchedAt $fetchedAt } | Should -Throw '*SONGKICK_API_KEY is not set*'
    } finally {
      $env:SONGKICK_API_KEY = $saved
    }
  }
}

Describe 'ticketmaster area search' {
  BeforeAll {
    $source = New-TestSource 'ticketmaster' @{
      latlong = '43.6150,-116.2023'; radius = 40; excludeVenueIds = @('skipme'); excludeSegments = @('Sports')
    }
    $page = @'
{"page":{"totalPages":1},"_embedded":{"events":[
  {"name":"Local Show","url":"https://x.test/1","test":false,"dates":{"start":{"dateTime":"2026-11-15T03:00:00Z"},"status":{"code":"onsale"}},
   "classifications":[{"segment":{"name":"Music"},"genre":{"name":"Rock"}}],
   "_embedded":{"venues":[{"id":"keep","name":"The Egyptian Theatre","city":{"name":"Boise"}}]}},
  {"name":"Covered Venue","url":"https://x.test/2","test":false,"dates":{"start":{"dateTime":"2026-11-15T03:00:00Z"},"status":{"code":"onsale"}},
   "classifications":[{"segment":{"name":"Music"}}],
   "_embedded":{"venues":[{"id":"skipme","name":"Arena","city":{"name":"Boise"}}]}},
  {"name":"Covered Sport","url":"https://x.test/3","test":false,"dates":{"start":{"dateTime":"2026-11-15T03:00:00Z"},"status":{"code":"onsale"}},
   "classifications":[{"segment":{"name":"Sports"}}],
   "_embedded":{"venues":[{"id":"keep","name":"The Egyptian Theatre","city":{"name":"Boise"}}]}}
]}}
'@
    $events = @(& (Join-Path $repo 'scripts/adapters/ticketmaster.ps1') -Source $source -FetchedAt $fetchedAt -Response $page)
  }

  It 'drops excluded venues and segments' {
    $events.title | Should -Be 'Local Show'
  }

  It 'drops listings matching excludeTitlePattern' {
    $filtered = $source | Select-Object *
    $filtered | Add-Member -NotePropertyName excludeTitlePattern -NotePropertyValue '(?i)^local' -Force
    @(& (Join-Path $repo 'scripts/adapters/ticketmaster.ps1') -Source $filtered -FetchedAt $fetchedAt -Response $page).Count | Should -Be 0
  }

  It 'takes the venue and city from the event' {
    $events[0].venue | Should -Be 'The Egyptian Theatre'
    $events[0].venueKey | Should -Be 'the-egyptian-theatre'
    $events[0].city | Should -Be 'Boise'
    $events[0].size | Should -Be 'M'
  }
}

Describe 'Hide-TvSecret for the new credentials' {
  BeforeAll {
    . (Join-Path $repo 'scripts/lib/Http.ps1')
  }

  It 'masks <name>' -ForEach @(
    @{ name = 'client_id'; text = 'https://x.test/e?client_id=SECRET&page=1' }
    @{ name = 'token'; text = 'https://x.test/e?token=SECRET' }
  ) {
    Hide-TvSecret $text | Should -Not -Match 'SECRET'
  }
}
