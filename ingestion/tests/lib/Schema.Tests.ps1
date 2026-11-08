BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/Schema.ps1"

  function New-TestEvent {
    param([hashtable]$Overrides = @{})
    $arguments = @{
      Title    = 'Test Show'
      Start    = '2026-11-14T19:30:00-07:00'
      Venue    = 'ExtraMile Arena'
      Url      = 'https://example.test/show'
      City     = 'Boise'
      Category = 'music'
      Sources  = @(@{ name = 'a'; url = 'https://example.test/show'; fetchedAt = '2026-11-01T10:00:00Z' })
    }
    foreach ($key in $Overrides.Keys) { $arguments[$key] = $Overrides[$key] }
    New-TvEvent @arguments
  }
}

Describe 'ConvertTo-BoiseTime' {
  It 'uses the standard offset in winter' {
    ConvertTo-BoiseTime '2026-11-14T19:30:00' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'uses the daylight offset in summer' {
    ConvertTo-BoiseTime '2026-07-04T21:00:00' | Should -Be '2026-07-04T21:00:00-06:00'
  }

  It 'converts a UTC string' {
    ConvertTo-BoiseTime '2026-11-15T02:30:00Z' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'converts a string with an explicit offset' {
    ConvertTo-BoiseTime '2026-11-14T21:30:00-05:00' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'reads a zoneless string in the source time zone' {
    ConvertTo-BoiseTime '2026-11-14T21:30:00' 'America/New_York' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'ignores the source time zone when the value has an offset' {
    ConvertTo-BoiseTime '2026-11-15T02:30:00Z' 'America/New_York' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'reads an unspecified DateTime in the source time zone' {
    $value = [DateTime]::new(2026, 11, 14, 21, 30, 0, [DateTimeKind]::Unspecified)
    ConvertTo-BoiseTime $value 'America/New_York' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'converts a UTC DateTime' {
    $value = [DateTime]::new(2026, 11, 15, 2, 30, 0, [DateTimeKind]::Utc)
    ConvertTo-BoiseTime $value | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'converts a DateTimeOffset' {
    $value = [DateTimeOffset]::new(2026, 11, 15, 2, 30, 0, [TimeSpan]::Zero)
    ConvertTo-BoiseTime $value | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'moves the date when the conversion crosses midnight' {
    ConvertTo-BoiseTime '2026-10-30T01:00:00Z' | Should -Be '2026-10-29T19:00:00-06:00'
  }

  It 'gives each side of the fall DST change its own offset' {
    ConvertTo-BoiseTime '2026-11-01T07:30:00Z' | Should -Be '2026-11-01T01:30:00-06:00'
    ConvertTo-BoiseTime '2026-11-01T08:30:00Z' | Should -Be '2026-11-01T01:30:00-07:00'
  }
}

Describe 'Get-VenueKey' {
  It 'slugifies <name>' -ForEach @(
    @{ name = 'ExtraMile Arena'; want = 'extramile-arena' }
    @{ name = "Bardenay's  Pub"; want = 'bardenays-pub' }
    @{ name = 'Rock & Roll Hall'; want = 'rock-and-roll-hall' }
    @{ name = 'Café Olé!'; want = 'cafe-ole' }
    @{ name = '  --Trim Me-- '; want = 'trim-me' }
  ) {
    Get-VenueKey $name | Should -Be $want
  }
}

Describe 'Get-NormalizedTitle' {
  It 'ignores case, punctuation, and spacing' {
    Get-NormalizedTitle "Olivia O'Brien: The  PIXIE Tour!" | Should -Be 'olivia obrien the pixie tour'
  }

  It 'treats curly and straight apostrophes alike' {
    Get-NormalizedTitle "O$([char]0x2019)Brien" | Should -Be (Get-NormalizedTitle "O'Brien")
  }
}

Describe 'Resolve-TvCity' {
  It 'maps <name> to <want>' -ForEach @(
    @{ name = 'boise'; want = 'Boise' }
    @{ name = 'Valley County'; want = 'Valley County' }
    @{ name = 'McCall'; want = 'Valley County' }
    @{ name = 'Cascade'; want = 'Valley County' }
    @{ name = 'Donnelly'; want = 'Valley County' }
    @{ name = 'New Meadows'; want = 'Valley County' }
    @{ name = 'Riggins'; want = 'Valley County' }
  ) {
    Resolve-TvCity $name | Should -Be $want
  }

  It 'returns nothing for a place outside the list' {
    Resolve-TvCity 'White Bird' | Should -BeNullOrEmpty
  }
}

Describe 'ConvertFrom-TvLocation' {
  BeforeAll {
    $source = [pscustomobject]@{ venue = 'Boise State University'; venueKey = 'boise-state-university'; city = 'Other' }
  }

  It 'reads <location>' -ForEach @(
    @{ location = 'Boise, Idaho, ExtraMile Arena'; venue = 'ExtraMile Arena'; key = 'extramile-arena'; city = 'Boise' }
    @{ location = 'Idaho Central Arena, Boise, Idaho'; venue = 'Idaho Central Arena'; key = 'idaho-central-arena'; city = 'Boise' }
    @{ location = 'Caldwell, ID, J.A. Albertson Activities Center'; venue = 'J.A. Albertson Activities Center'; key = 'j-a-albertson-activities-center'; city = 'Caldwell' }
    @{ location = 'Morrison Center for the Performing Arts (MORR), Recital Hall, C200'; venue = 'Morrison Center for the Performing Arts'; key = 'morrison-center-for-the-performing-arts'; city = 'Other' }
    @{ location = '123 Main St, Garden City, ID 83714'; venue = '123 Main St'; key = '123-main-st'; city = 'Garden City' }
    @{ location = 'Seven Devils Taphouse, 740 Village Dr., Donnelly, ID, 83615, United States'; venue = 'Seven Devils Taphouse'; key = 'seven-devils-taphouse'; city = 'Valley County' }
    @{ location = 'MAC Snow Front Base Area, 3890 Goose Lake Road, McCall, ID, 83638'; venue = 'MAC Snow Front Base Area'; key = 'mac-snow-front-base-area'; city = 'Valley County' }
  ) {
    $result = ConvertFrom-TvLocation $location -Source $source
    $result.Venue | Should -Be $venue
    $result.VenueKey | Should -Be $key
    $result.City | Should -Be $city
  }

  It 'falls back when only a city is given' {
    $result = ConvertFrom-TvLocation 'Boise, Idaho' -Source $source
    $result.Venue | Should -Be 'Boise State University'
    $result.VenueKey | Should -Be 'boise-state-university'
    $result.City | Should -Be 'Boise'
  }

  It 'falls back when the location is empty' {
    (ConvertFrom-TvLocation '' -Source $source).Venue | Should -Be 'Boise State University'
  }
}

Describe 'New-TvEvent' {
  It 'computes the documented id' {
    $seed = 'test show|2026-11-14|extramile-arena'
    $hash = [Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($seed))
    $want = [Convert]::ToHexString($hash).Substring(0, 12).ToLowerInvariant()
    (New-TestEvent).id | Should -Be $want
  }

  It 'gives the same id across punctuation and case' {
    (New-TestEvent @{ Title = 'TEST SHOW!' }).id | Should -Be (New-TestEvent).id
  }

  It 'gives a different id on a different date' {
    (New-TestEvent @{ Start = '2026-11-15T19:30:00-07:00' }).id | Should -Not -Be (New-TestEvent).id
  }

  It 'derives venueKey from the venue' {
    (New-TestEvent).venueKey | Should -Be 'extramile-arena'
  }

  It 'keeps an explicit venueKey' {
    (New-TestEvent @{ VenueKey = 'custom-key' }).venueKey | Should -Be 'custom-key'
  }

  It 'defaults allDay to false and omits empty optional fields' {
    $event = New-TestEvent
    $event.allDay | Should -BeFalse
    $event.PSObject.Properties.Name | Should -Not -Contain 'end'
    $event.PSObject.Properties.Name | Should -Not -Contain 'description'
  }

  It 'builds an all-day event' {
    $event = New-TestEvent @{ Start = '2026-11-14'; AllDay = $true }
    $event.allDay | Should -BeTrue
    $event.start | Should -Be '2026-11-14'
  }

  It 'strips markup from the description' {
    (New-TestEvent @{ Description = '<p>Fish &amp; chips</p>' }).description | Should -Be 'Fish & chips'
  }

  It 'drops sentences with a ticket price' {
    $text = 'Doors at 7 PM. Tickets $32.75 on DICE, fees included. All ages!'
    (New-TestEvent @{ Description = $text }).description | Should -Be 'Doors at 7 PM. All ages!'
  }

  It 'omits a description that was only a price' {
    (New-TestEvent @{ Description = 'Tickets are $20' }).PSObject.Properties.Name | Should -Not -Contain 'description'
  }

  It 'truncates the description to 300 characters' {
    $event = New-TestEvent @{ Description = 'x' * 500 }
    $event.description.Length | Should -Be 300
    $event.description | Should -BeLike '*...'
  }

  It 'keeps a sources array with a single entry' {
    $event = New-TestEvent
    @($event.sources).Count | Should -Be 1
    (ConvertTo-Json $event -Depth 6) | Should -Match '"sources": \['
  }

  It 'rejects a timed event with no offset' {
    { New-TestEvent @{ Start = '2026-11-14T19:30:00' } } | Should -Throw '*schema*'
  }

  It 'rejects an all-day event with a time' {
    { New-TestEvent @{ Start = '2026-11-14T19:30:00-07:00'; AllDay = $true } } | Should -Throw '*schema*'
  }

  It 'rejects a city outside the enum' {
    { New-TestEvent @{ City = 'Twin Falls' } } | Should -Throw '*schema*'
  }
}

Describe 'Test-TvEvent' {
  It 'accepts a built event' {
    Test-TvEvent (New-TestEvent) | Should -BeTrue
  }

  It 'rejects an event with extra fields' {
    $event = New-TestEvent
    $event | Add-Member -NotePropertyName image -NotePropertyValue 'https://example.test/i.png'
    Test-TvEvent $event | Should -BeFalse
  }
}
