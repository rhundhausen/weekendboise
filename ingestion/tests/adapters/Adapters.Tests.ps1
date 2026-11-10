BeforeAll {
  $script:repo = Join-Path $PSScriptRoot '..' '..'
  $script:sources = (Get-Content (Join-Path $repo 'sources.json') -Raw | ConvertFrom-Json).sources
  $script:fetchedAt = '2026-11-02T10:00:00Z'

  . (Join-Path $repo 'scripts' 'lib' 'Schema.ps1')

  function Invoke-Adapter {
    param([string]$Adapter, [object]$Source, [string]$Fixture)
    $text = Get-Content (Join-Path $repo 'tests' 'fixtures' $Fixture) -Raw
    @(& (Join-Path $repo 'scripts' 'adapters' "$Adapter.ps1") -Source $Source -FetchedAt $fetchedAt -Response $text)
  }

  function Get-TestSource {
    param([string]$Name)
    $sources | Where-Object name -eq $Name
  }
}

Describe 'ics adapter' {
  BeforeAll {
    $source = Get-TestSource 'boise-state-athletics'
    $events = Invoke-Adapter 'ics' $source 'ics/boise-state-athletics.ics'
  }

  It 'keeps home events and drops away games' {
    (Get-Content (Join-Path $repo 'tests/fixtures/ics/boise-state-athletics.ics') -Raw) -match 'BEGIN:VEVENT' | Should -BeTrue
    $events.Count | Should -Be 17
    $events.venue | Should -Not -Contain 'San Francisco'
  }

  It 'keeps every event when the source has no filter' {
    $open = $source | Select-Object * -ExcludeProperty locationFilter
    (Invoke-Adapter 'ics' $open 'ics/boise-state-athletics.ics').Count | Should -Be 30
  }

  It 'reads a timed event' {
    $event = $events[0]
    $event.id | Should -Be 'ed06aeb0c5ee'
    $event.title | Should -Be "Boise State University Women's Volleyball vs Texas State"
    $event.start | Should -Be '2026-10-03T12:00:00-06:00'
    $event.end | Should -Be '2026-10-03T14:00:00-06:00'
    $event.venue | Should -Be 'Bronco Gym'
    $event.venueKey | Should -Be 'bronco-gym'
    $event.city | Should -Be 'Boise'
    $event.category | Should -Be 'sports'
  }

  It 'strips the result prefix from titles' {
    $events.title | Where-Object { $_ -match '^\[' } | Should -BeNullOrEmpty
  }

  It 'reads an all-day event' {
    $event = $events | Where-Object id -eq '83a166861b6b'
    $event.allDay | Should -BeTrue
    $event.start | Should -Be '2026-10-05'
  }

  It 'decodes the url and records the source' {
    $event = $events[0]
    $event.url | Should -Be 'https://admin.broncosports.com/calendar.aspx?game_id=23062&sport_id=19'
    $event.sources[0].name | Should -Be 'boise-state-athletics'
    $event.sources[0].fetchedAt | Should -Be $fetchedAt
  }

  It 'rejects a response that is not a calendar' {
    $path = Join-Path $repo 'scripts' 'adapters' 'ics.ps1'
    { & $path -Source $source -FetchedAt $fetchedAt -Response '<html>maintenance</html>' } | Should -Throw '*not an iCalendar feed*'
  }
}

Describe 'tribe adapter' {
  BeforeAll {
    $events = Invoke-Adapter 'tribe' (Get-TestSource 'mike-brown-group') 'tribe/mike-brown-group.json'
  }

  It 'reads every event' {
    $events.Count | Should -Be 20
  }

  It 'reads a timed event' {
    $event = $events[0]
    $event.id | Should -Be '0012de5d8722'
    $event.title | Should -Be 'Kyle Gordon'
    $event.start | Should -Be '2026-11-01T19:00:00-07:00'
    $event.venue | Should -Be 'Shrine Social Club'
    $event.city | Should -Be 'Boise'
    $event.category | Should -Be 'music'
    $event.url | Should -Be 'https://www.mikebrowngroup.com/event/kyle-gordon/'
  }

  It 'tags events from the publisher''s labels' {
    @($events[0].tags) | Should -Contain 'concert'
  }

  It 'drops an end that only repeats the start' {
    $events[0].PSObject.Properties.Name | Should -Not -Contain 'end'
  }

  It 'reads an all-day event labeled UTC+0 as a plain date' {
    $event = $events | Where-Object id -eq '88580065474a'
    $event.allDay | Should -BeTrue
    $event.start | Should -Be '2026-11-06'
    $event.venue | Should -Be 'Liberty Hall'
  }

  It 'keeps ticket prices out of descriptions' {
    $events.description | Where-Object { $_ -match '\$\d' } | Should -BeNullOrEmpty
  }

  It 'reads the cost tier from the cost text' {
    ($events | Where-Object title -eq 'Kyle Gordon').costTier | Should -BeExactly '$$'
    $page = '{"total_pages":1,"events":[{"title":"Priced Show","all_day":false,"utc_start_date":"2026-11-15 02:00:00","utc_end_date":"2026-11-15 04:00:00","url":"https://x.test/e","description":"","cost":"$120 - $250","venue":[]}]}'
    $path = Join-Path $repo 'scripts' 'adapters' 'tribe.ps1'
    (& $path -Source (Get-TestSource 'mike-brown-group') -FetchedAt $fetchedAt -Response $page).costTier | Should -BeExactly '$$$'
  }

  It 'uses the fallback venue when an event has none' {
    $page = '{"total_pages":1,"events":[{"title":"No Venue","all_day":false,"utc_start_date":"2026-11-15 02:00:00","utc_end_date":"2026-11-15 04:00:00","url":"https://x.test/e","description":"","venue":[]}]}'
    $path = Join-Path $repo 'scripts' 'adapters' 'tribe.ps1'
    $event = & $path -Source (Get-TestSource 'mike-brown-group') -FetchedAt $fetchedAt -Response $page
    $event.venue | Should -Be 'Various Treasure Valley locations'
    $event.venueKey | Should -Be 'various-treasure-valley'
    $event.city | Should -Be 'Other'
    $event.start | Should -Be '2026-11-14T19:00:00-07:00'
  }
}

Describe 'tribe adapter with fixedVenue' {
  It 'ignores the venue the event reports' {
    $page = '{"total_pages":1,"events":[{"title":"Show","all_day":false,"utc_start_date":"2026-11-15 02:00:00","utc_end_date":"2026-11-15 04:00:00","url":"https://x.test/e","description":"","venue":{"venue":"South Expo Building","city":"Boise"}}]}'
    $path = Join-Path $repo 'scripts' 'adapters' 'tribe.ps1'
    $event = & $path -Source (Get-TestSource 'expo-idaho') -FetchedAt $fetchedAt -Response $page
    $event.venue | Should -Be 'Expo Idaho'
    $event.venueKey | Should -Be 'expo-idaho'
    $event.city | Should -Be 'Garden City'
    $event.size | Should -Be 'L'
  }
}

Describe 'tribe adapter with excludeTitlePattern' {
  It 'skips events whose title matches' {
    $page = '{"total_pages":1,"events":[{"title":"Rolling Hills &#8211; Happy Hour","all_day":true,"start_date":"2026-11-12 08:00:00","end_date":"2026-11-12 17:00:00","url":"https://x.test/a","description":"","venue":[]},{"title":"Sawtooth Winery &#8211; Pop-Up Music","all_day":false,"utc_start_date":"2026-11-27 20:00:00","utc_end_date":"2026-11-27 23:00:00","url":"https://x.test/b","description":"","venue":[]},{"title":"Telaya Wine Co &#8211; Holiday Wreath Making","all_day":true,"start_date":"2026-11-29 08:00:00","end_date":"2026-11-29 17:00:00","url":"https://x.test/c","description":"","venue":[]}]}'
    $path = Join-Path $repo 'scripts' 'adapters' 'tribe.ps1'
    $events = @(& $path -Source (Get-TestSource 'idaho-wine-commission') -FetchedAt $fetchedAt -Response $page)
    $events.Count | Should -Be 1
    # Telaya's own calendar is read by telaya-wine, so its Wine Commission copies are skipped too.
    $events[0].title | Should -BeLike 'Sawtooth Winery*Pop-Up Music'
    $events[0].venueKey | Should -Be 'idaho-wineries'
  }
}

Describe 'eventastic adapter' {
  BeforeAll {
    # Visit McCall's admin-ajax answer of 2026-11-08, trimmed to the fields the adapter reads.
    # fetchedAt is 2026-11-02, so the window is 2026-11-02 through 2027-05-01.
    $source = Get-TestSource 'visit-mccall'
    $events = Invoke-Adapter 'eventastic' $source 'eventastic/visit-mccall.json'
  }

  It 'reads a one-day event with its time, venue, and page' {
    $breakfast = @($events | Where-Object title -eq 'Fall Membership Breakfast')
    $breakfast.Count | Should -Be 1
    $breakfast[0].start | Should -Be '2026-11-19T08:30:00-07:00'
    $breakfast[0].end | Should -Be '2026-11-19T10:30:00-07:00'
    $breakfast[0].venue | Should -Be 'Evergreen Hotel'
    $breakfast[0].city | Should -Be 'Valley County'
    $breakfast[0].url | Should -Be 'https://visitmccall.org/event/fall-membership-breakfast-2/'
  }

  It 'lists a weekly event once per date in the window' {
    $singo = @($events | Where-Object title -eq 'Friday Night Singo Game' | Sort-Object start)
    @($singo.start) | Should -Be @('2026-11-06T17:30:00-07:00', '2026-11-13T17:30:00-07:00', '2026-11-20T17:30:00-07:00', '2026-11-27T17:30:00-07:00')
    $singo[0].end | Should -Be '2026-11-06T19:00:00-07:00'
    @($singo.id | Select-Object -Unique).Count | Should -Be 4
  }

  It 'files Tamarack, Donnelly, and McCall events under Valley County' {
    @($events.city | Select-Object -Unique) | Should -Be @('Valley County')
  }

  It 'keeps dates inside the window' {
    @($events | Where-Object { $_.start.Substring(0, 10) -lt '2026-11-02' -or $_.start.Substring(0, 10) -gt '2027-05-01' }).Count | Should -Be 0
    @($events | Where-Object title -eq 'Trivia Tuesdays at Seven Devils').Count | Should -Be 26
  }

  It 'decodes titles' {
    @($events | Where-Object title -like 'Broken Horn*Thursday Trivia').Count | Should -BeGreaterThan 0
    @($events | Where-Object title -match '&#') | Should -BeNullOrEmpty
  }
}

Describe 'tribe adapter with localTimeAsUtc' {
  It 'reads a site set to UTC+0 as Boise wall-clock time' {
    # Donnelly Library's site is set to UTC+0, so 4 PM local comes back as 16:00 in both fields.
    $page = '{"total_pages":1,"events":[{"title":"Festival of Trees","all_day":false,"start_date":"2026-11-27 16:00:00","end_date":"2026-11-27 19:00:00","utc_start_date":"2026-11-27 16:00:00","utc_end_date":"2026-11-27 19:00:00","timezone":"UTC+0","url":"https://x.test/a","description":"","venue":[]}]}'
    $path = Join-Path $repo 'scripts' 'adapters' 'tribe.ps1'
    $events = @(& $path -Source (Get-TestSource 'donnelly-library') -FetchedAt $fetchedAt -Response $page)
    $events[0].start | Should -Be '2026-11-27T16:00:00-07:00'
    $events[0].end | Should -Be '2026-11-27T19:00:00-07:00'
    $events[0].city | Should -Be 'Valley County'
  }
}

Describe 'ticketmaster adapter' {
  BeforeAll {
    $source = Get-TestSource 'ford-idaho-center-arena'
    $events = Invoke-Adapter 'ticketmaster' $source 'ticketmaster/ford-idaho-center-arena.json'
  }

  It 'reads every event' {
    $events.Count | Should -Be 17
  }

  It 'reads an event' {
    $event = $events[0]
    $event.id | Should -Be '4d53c7ab3237'
    $event.title | Should -Be 'Jo Koy (12 and Over)'
    $event.start | Should -Be '2026-11-07T20:00:00-07:00'
    $event.url | Should -Be 'https://www.ticketmaster.com/event/Z7r9jZ1A7PePd'
  }

  It 'reads the cost tier from the lowest price range' {
    $page = Get-Content (Join-Path $repo 'tests/fixtures/ticketmaster/ford-idaho-center-arena.json') -Raw | ConvertFrom-Json
    $first = $page._embedded.events[0]
    $first | Add-Member -NotePropertyName priceRanges -NotePropertyValue @(@{ type = 'standard'; min = 129.5; max = 300 }, @{ type = 'resale'; min = 49.5; max = 90 })
    $path = Join-Path $repo 'scripts' 'adapters' 'ticketmaster.ps1'
    $priced = @(& $path -Source $source -FetchedAt $fetchedAt -Response ($page | ConvertTo-Json -Depth 20))
    $priced[0].costTier | Should -BeExactly '$$$'
    $events[0].PSObject.Properties.Name | Should -Not -Contain 'costTier'
  }

  It 'takes the venue from the source entry' {
    ($events.venueKey | Sort-Object -Unique) | Should -Be 'ford-idaho-center-arena'
    ($events.city | Sort-Object -Unique) | Should -Be 'Nampa'
  }

  It 'maps Ticketmaster segments to categories' {
    @($events | Where-Object category -eq 'sports').Count | Should -Be 10
    @($events | Where-Object category -eq 'music').Count | Should -Be 6
    @($events | Where-Object category -eq 'performing-arts').Count | Should -Be 1
  }

  It 'skips cancelled and test events' {
    $page = '{"page":{"totalPages":1},"_embedded":{"events":[
      {"name":"Gone","url":"https://x.test/1","test":false,"dates":{"start":{"dateTime":"2026-11-15T02:00:00Z"},"status":{"code":"cancelled"}}},
      {"name":"Test","url":"https://x.test/2","test":true,"dates":{"start":{"dateTime":"2026-11-15T02:00:00Z"},"status":{"code":"onsale"}}}
    ]}}'
    $path = Join-Path $repo 'scripts' 'adapters' 'ticketmaster.ps1'
    @(& $path -Source $source -FetchedAt $fetchedAt -Response $page).Count | Should -Be 0
  }

  It 'makes an event with no time all-day' {
    $page = '{"page":{"totalPages":1},"_embedded":{"events":[
      {"name":"TBA","url":"https://x.test/1","test":false,"dates":{"start":{"localDate":"2026-11-15","timeTBA":true},"status":{"code":"onsale"}}}
    ]}}'
    $path = Join-Path $repo 'scripts' 'adapters' 'ticketmaster.ps1'
    $event = & $path -Source $source -FetchedAt $fetchedAt -Response $page
    $event.allDay | Should -BeTrue
    $event.start | Should -Be '2026-11-15'
  }

  It 'returns nothing for a venue with no events' {
    $path = Join-Path $repo 'scripts' 'adapters' 'ticketmaster.ps1'
    @(& $path -Source $source -FetchedAt $fetchedAt -Response '{"page":{"totalPages":0}}').Count | Should -Be 0
  }

  It 'fails clearly without a key' {
    $saved = $env:TICKETMASTER_KEY
    $env:TICKETMASTER_KEY = $null
    try {
      $path = Join-Path $repo 'scripts' 'adapters' 'ticketmaster.ps1'
      { & $path -Source $source -FetchedAt $fetchedAt } | Should -Throw '*TICKETMASTER_KEY is not set*'
    } finally {
      $env:TICKETMASTER_KEY = $saved
    }
  }
}

Describe 'bandsintown adapter' {
  # The fixture is hand-written, not a real response. See docs/sources.md.
  BeforeAll {
    $source = [pscustomobject]@{
      name = 'example-artist'; adapter = 'bandsintown'; url = 'https://rest.bandsintown.com'; category = 'music'
      city = 'Other'; venue = 'Various'; venueKey = 'various'; enabled = $true; artistOrVenue = 'Example Band'
    }
    $events = Invoke-Adapter 'bandsintown' $source 'bandsintown/example-artist.json'
  }

  It 'keeps only Idaho dates' {
    $events.Count | Should -Be 2
    $events.city | Should -Not -Contain 'Portland'
  }

  It 'reads an event' {
    $events[0].title | Should -Be 'Example Band at Neurolux'
    $events[0].start | Should -Be '2026-11-14T20:00:00-07:00'
    $events[0].venueKey | Should -Be 'neurolux'
    $events[0].city | Should -Be 'Boise'
  }

  It 'builds a title from the lineup when there is none' {
    $events[1].title | Should -Be 'Example Band, Opening Act at The Olympic'
  }

  It 'fails clearly without an app id' {
    $saved = $env:BANDSINTOWN_APP_ID
    $env:BANDSINTOWN_APP_ID = $null
    try {
      $path = Join-Path $repo 'scripts' 'adapters' 'bandsintown.ps1'
      { & $path -Source $source -FetchedAt $fetchedAt } | Should -Throw '*BANDSINTOWN_APP_ID is not set*'
    } finally {
      $env:BANDSINTOWN_APP_ID = $saved
    }
  }
}

Describe 'fixtures' {
  It 'stay under 50 events' {
    $root = Join-Path $repo 'tests' 'fixtures'
    ([regex]::Matches((Get-Content (Join-Path $root 'ics/boise-state-athletics.ics') -Raw), 'BEGIN:VEVENT')).Count | Should -BeLessThan 50
    (Get-Content (Join-Path $root 'tribe/mike-brown-group.json') -Raw | ConvertFrom-Json).events.Count | Should -BeLessThan 50
    (Get-Content (Join-Path $root 'ticketmaster/ford-idaho-center-arena.json') -Raw | ConvertFrom-Json)._embedded.events.Count | Should -BeLessThan 50
    ([regex]::Matches((Get-Content (Join-Path $root 'scrape/visit-boise.html') -Raw), '"@type"\s*:\s*"Event"')).Count | Should -BeLessThan 50
  }

  It 'hold no credentials' {
    $root = Join-Path $repo 'tests' 'fixtures'
    Get-ChildItem $root -Recurse -File | Select-String -Pattern '(?i)(apikey|app_id)=' | Should -BeNullOrEmpty
  }
}

Describe 'seeded sources' {
  It 'each adapter exists for every configured source' {
    foreach ($source in $sources | Where-Object name) {
      Test-Path (Join-Path $repo 'scripts' 'adapters' "$($source.adapter).ps1") | Should -BeTrue -Because $source.name
    }
  }

  It 'runs only entries whose status is running, and every one is configured' {
    $running = @($sources | Where-Object status -eq 'running')
    $running.Count | Should -BeGreaterThan 0
    $running | Where-Object { -not $_.name } | Should -BeNullOrEmpty
  }
}

Describe 'ics adapter with fixedVenue' {
  It 'uses the source venue instead of the room the feed names' {
    $source = Get-TestSource 'boise-public-library'
    $feed = "BEGIN:VCALENDAR`r`nBEGIN:VEVENT`r`nUID:1`r`nSUMMARY:Read to a Therapy Dog`r`nDTSTART:20261110T230000Z`r`nDTEND:20261111T000000Z`r`nLOCATION:Catalpa Room\, Sycamore Room\, Library! at Collister - 4724 W. State St. Boise\, ID 83703`r`nEND:VEVENT`r`nEND:VCALENDAR`r`n"
    $event = & (Join-Path $repo 'scripts' 'adapters' 'ics.ps1') -Source $source -FetchedAt $fetchedAt -Response $feed
    $event.venueKey | Should -Be 'boise-public-library'
    $event.venue | Should -Be 'Boise Public Library'
    $event.city | Should -Be 'Boise'
    $event.start | Should -Be '2026-11-10T16:00:00-07:00'
  }
}

Describe 'ics adapter with localTimeAsUtc' {
  BeforeAll {
    $source = Get-TestSource 'tamarack-resort'
    $feed = "BEGIN:VCALENDAR`r`nBEGIN:VEVENT`r`nUID:1`r`nSUMMARY:Shred Shed 2026`r`nDTSTART;TZID=UTC:20261114T100000`r`nDTEND;TZID=UTC:20261114T150000`r`nEND:VEVENT`r`nBEGIN:VEVENT`r`nUID:2`r`nSUMMARY:Tuesday Trivia`r`nDTSTART;TZID=UTC:20251209T173000`r`nDTEND;TZID=UTC:20270406T190000`r`nEND:VEVENT`r`nEND:VCALENDAR`r`n"
    $events = @(& (Join-Path $repo 'scripts' 'adapters' 'ics.ps1') -Source $source -FetchedAt $fetchedAt -Response $feed)
  }

  It 'reads a site that labels Boise wall-clock time as UTC' {
    # Tamarack shows Shred Shed at 10:00 AM; its feed says 10:00 UTC.
    $events[0].start | Should -Be '2026-11-14T10:00:00-07:00'
    $events[0].end | Should -Be '2026-11-14T15:00:00-07:00'
    $events[0].city | Should -Be 'Valley County'
  }

  It 'skips the weekly series the feed lists as one event spanning months' {
    $events.Count | Should -Be 1
  }
}

Describe 'cityofboise adapter' {
  BeforeAll {
    $source = Get-TestSource 'city-of-boise'
    $pages = @('page-0', 'page-1') | ForEach-Object { Get-Content (Join-Path $repo 'tests' 'fixtures' 'cityofboise' "events-$_.json") -Raw }
    $events = @(& (Join-Path $repo 'scripts' 'adapters' 'cityofboise.ps1') -Source $source -FetchedAt $fetchedAt -Response $pages)
  }

  It 'reads every page and skips cancelled events' {
    $events.Count | Should -Be 3
    $events.title | Should -Not -Contain 'Canceled - Ethics Commission'
    $events.title | Should -Not -Contain 'Ethics Commission'
  }

  It 'reads times as Boise wall-clock time' {
    $events[0].title | Should -Be 'Open Space and Clean Water Advisory Committee'
    $events[0].start | Should -Be '2026-11-04T16:00:00-07:00'
    $events[0].end | Should -Be '2026-11-04T17:00:00-07:00'
  }

  It 'takes the venue from the location and falls back to the source venue' {
    $events[0].venueKey | Should -Be 'boise-depot'
    $events[2].venueKey | Should -Be 'boise-city-hall'
  }

  It 'drops an end that is not after the start' {
    $events[2].PSObject.Properties.Name | Should -Not -Contain 'end'
  }

  It 'makes links absolute on the city site' {
    $events[1].url | Should -Be 'https://www.cityofboise.org/events/parks-and-recreation/2026/november/liberty-park-groundbreaking-ceremony/'
  }
}

Describe 'rss adapter' {
  BeforeAll {
    $source = Get-TestSource 'ford-idaho-center'
    $feed = Get-Content (Join-Path $repo 'tests' 'fixtures' 'rss' 'ford-idaho-center.xml') -Raw
    $events = @(& (Join-Path $repo 'scripts' 'adapters' 'rss.ps1') -Source $source -FetchedAt $fetchedAt -Response $feed)
  }

  It 'reads items with ev:startdate and skips items without one' {
    $events.Count | Should -Be 3
    $events.title | Should -Not -Contain 'Parking changes for the season'
  }

  It 'converts UTC times to Boise time and keeps a multi-day end' {
    $events[0].start | Should -Be '2026-11-03T08:00:00-07:00'
    $events[0].end | Should -Be '2026-11-08T08:00:00-07:00'
    $events[1].start | Should -Be '2026-11-07T20:00:00-07:00'
    $events[2].start | Should -Be '2027-05-27T19:30:00-06:00'
  }

  It 'drops an end that is not after the start' {
    $events[1].PSObject.Properties.Name | Should -Not -Contain 'end'
  }

  It 'builds the venue from venuePrefix and ev:location' {
    $events[0].venueKey | Should -Be 'ford-idaho-center-horse-park-and-sports-center'
    $events[0].venue | Should -Be 'Ford Idaho Center Horse Park & Sports Center'
    $events[1].venueKey | Should -Be 'ford-idaho-center-arena'
    $events[2].venueKey | Should -Be 'ford-idaho-center-amphitheater'
  }

  It 'uses ev:type as a publisher label' {
    $events[1].category | Should -Be 'performing-arts'
    $events[2].category | Should -Be 'music'
  }

  It 'uses the item link and strips markup from the description' {
    $events[1].url | Should -Be 'https://www.fordidahocenter.com/events/detail/koy'
    $events[0].description | Should -Not -Match '<'
  }

  It 'uses the entry venue with fixedVenue' {
    $fixed = $source.PSObject.Copy()
    $fixed | Add-Member -NotePropertyName fixedVenue -NotePropertyValue $true -Force
    $one = @(& (Join-Path $repo 'scripts' 'adapters' 'rss.ps1') -Source $fixed -FetchedAt $fetchedAt -Response $feed)[0]
    $one.venueKey | Should -Be 'ford-idaho-center-arena'
  }
}
