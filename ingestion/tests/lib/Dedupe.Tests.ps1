BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/Dedupe.ps1"

  function New-TestEvent {
    param(
      [string]$Title = 'Boise Philharmonic Season Opener',
      [string]$Start = '2026-11-14T19:30:00-07:00',
      [string]$End,
      [string]$City = 'Boise',
      [string]$Venue = 'Morrison Center',
      [string]$Source = 'a',
      [string]$Url = "https://$Source.test/e",
      [string]$Description,
      [string]$FetchedAt = '2026-11-01T10:00:00Z',
      [switch]$AllDay
    )
    New-TvEvent -Title $Title -Start $Start -End $End -City $City -Venue $Venue -Category 'music' -Url $Url -Description $Description -AllDay:$AllDay `
      -Sources @(@{ name = $Source; url = $Url; fetchedAt = $FetchedAt })
  }
}

Describe 'Get-JaroWinkler' {
  It 'scores <first> and <second>' -ForEach @(
    @{ first = 'MARTHA'; second = 'MARHTA'; want = 0.9611 }
    @{ first = 'DIXON'; second = 'DICKSONX'; want = 0.8133 }
    @{ first = 'DWAYNE'; second = 'DUANE'; want = 0.84 }
    @{ first = 'same'; second = 'same'; want = 1 }
    @{ first = 'abc'; second = 'xyz'; want = 0 }
    @{ first = ''; second = 'abc'; want = 0 }
  ) {
    Get-JaroWinkler $first $second | Should -BeLessOrEqual ($want + 0.0001)
    Get-JaroWinkler $first $second | Should -BeGreaterOrEqual ($want - 0.0001)
  }

  It 'is case sensitive' {
    Get-JaroWinkler 'ABC' 'abc' | Should -Be 0
  }
}

Describe 'Merge-TvEvents' {
  It 'merges events with the same id' {
    $merged = @(Merge-TvEvents @((New-TestEvent -Source a), (New-TestEvent -Source b)))
    $merged.Count | Should -Be 1
    $merged[0].sources.name | Should -Be @('a', 'b')
  }

  It 'merges similar titles at the same venue within 30 minutes' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Title 'Boise Philharmonic Season Opener' -Source a)
        (New-TestEvent -Title 'Boise Philharmonic Season Openers' -Start '2026-11-14T20:00:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 1
  }

  It 'keeps events 31 minutes apart' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Title 'Boise Philharmonic Season Opener' -Source a)
        (New-TestEvent -Title 'Boise Philharmonic Season Openers' -Start '2026-11-14T20:01:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 2
  }

  It 'merges across midnight' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Title 'New Years Eve Countdown Party' -Start '2026-12-31T23:50:00-07:00' -Source a)
        (New-TestEvent -Title 'New Years Eve Countdown Parties' -Start '2027-01-01T00:10:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 1
  }

  It 'keeps similar titles at different venues' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Title 'Boise Philharmonic Season Opener' -Venue 'Morrison Center')
        (New-TestEvent -Title 'Boise Philharmonic Season Openers' -Venue 'Egyptian Theatre')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps different titles at the same time and venue' {
    $merged = @(Merge-TvEvents @((New-TestEvent -Title 'Comedy Night'), (New-TestEvent -Title 'Ballet Idaho Nutcracker')))
    $merged.Count | Should -Be 2
  }

  It 'keeps the longest description' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Source a -Description 'Short')
        (New-TestEvent -Source b -Description 'A much longer description')
      ) -Priorities @{ a = 1; b = 99 })
    $merged[0].description | Should -Be 'A much longer description'
  }

  It 'adds a description the preferred source lacks' {
    $merged = @(Merge-TvEvents @((New-TestEvent -Source a), (New-TestEvent -Source b -Description 'Only here')) -Priorities @{ a = 1; b = 99 })
    $merged[0].description | Should -Be 'Only here'
  }

  It 'prefers the url from the lowest priority number, whatever the input order' {
    $first = New-TestEvent -Source a
    $second = New-TestEvent -Source b
    (Merge-TvEvents @($first, $second) -Priorities @{ a = 10; b = 90 }).url | Should -Be 'https://a.test/e'
    (Merge-TvEvents @($second, $first) -Priorities @{ a = 10; b = 90 }).url | Should -Be 'https://a.test/e'
    (Merge-TvEvents @($first, $second) -Priorities @{ a = 90; b = 10 }).url | Should -Be 'https://b.test/e'
  }

  It 'breaks a priority tie by input order, however many reports there are' {
    # 100 equal-priority reports of one show mixed in with 200 other events. Sort-Object without
    # -Stable reorders ties in a list like this, and a later source's url won.
    $reports = @(1..300 | ForEach-Object {
        if ($_ % 3 -eq 0) { New-TestEvent -Source ('s{0:d3}' -f $_) }
        else { New-TestEvent -Title "Other Show $_" -Venue "Hall $_" -Source x }
      })
    $show = $reports[2].id
    (@(Merge-TvEvents $reports) | Where-Object id -eq $show).url | Should -Be 'https://s003.test/e'
    [array]::Reverse($reports)
    (@(Merge-TvEvents $reports) | Where-Object id -eq $show).url | Should -Be 'https://s300.test/e'
  }

  It 'treats a missing priority as 50' {
    (Merge-TvEvents @((New-TestEvent -Source a), (New-TestEvent -Source b)) -Priorities @{ b = 40 }).url | Should -Be 'https://b.test/e'
    (Merge-TvEvents @((New-TestEvent -Source a), (New-TestEvent -Source b)) -Priorities @{ b = 60 }).url | Should -Be 'https://a.test/e'
  }

  It 'unions sources with one entry per name and the earliest fetchedAt' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Source a -FetchedAt '2026-11-02T10:00:00Z')
        (New-TestEvent -Source a -FetchedAt '2026-11-01T10:00:00Z')
        (New-TestEvent -Source b)
      ))
    @($merged[0].sources).Count | Should -Be 2
    ($merged[0].sources | Where-Object name -eq 'a').fetchedAt | Should -Be '2026-11-01T10:00:00Z'
  }

  It 'merges three reports that chain together' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Source a)
        (New-TestEvent -Title 'Boise Philharmonic Season Openers' -Source b)
        (New-TestEvent -Source c)
      ))
    $merged.Count | Should -Be 1
    @($merged[0].sources).Count | Should -Be 3
  }

  It 'does not change its input' {
    $first = New-TestEvent -Source a
    $null = Merge-TvEvents @($first, (New-TestEvent -Source b -Description 'More'))
    @($first.sources).Count | Should -Be 1
    $first.PSObject.Properties.Name | Should -Not -Contain 'description'
  }

  It 'unions tags' {
    $first = New-TestEvent -Title 'Trivia Night' -Source a
    $second = New-TestEvent -Title 'Trivia Night' -Description 'Great for kids' -Source b
    @((Merge-TvEvents @($first, $second))[0].tags) | Should -Be @('kids', 'trivia')
  }

  It 'keeps a merged event valid when one report is all-day and one is timed' {
    $allDay = New-TestEvent -Start '2026-11-14' -AllDay -Source a
    $timed = New-TvEvent -Title 'Boise Philharmonic Season Opener' -Start '2026-11-14T10:00:00-07:00' -End '2026-11-14T16:00:00-07:00' `
      -Venue 'Morrison Center' -Category 'music' -Url 'https://b.test/e' -Sources @(@{ name = 'b'; url = 'https://b.test/e'; fetchedAt = '2026-11-01T10:00:00Z' })
    foreach ($priorities in @{ a = 1; b = 2 }, @{ a = 2; b = 1 }) {
      $merged = @(Merge-TvEvents @($allDay, $timed) -Priorities $priorities)
      $merged.Count | Should -Be 1
      Test-TvEvent $merged[0] | Should -BeTrue
    }
  }

  It 'handles all-day events' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Start '2026-11-14' -AllDay -Source a)
        (New-TestEvent -Start '2026-11-14' -AllDay -Source b)
      ))
    $merged.Count | Should -Be 1
  }

  It 'returns nothing for no events' {
    @(Merge-TvEvents @()).Count | Should -Be 0
  }
}

Describe 'Test-TvSameTitleWords' {
  It '<first> and <second> match: <want>' -ForEach @(
    @{ first = 'Jo Koy'; second = 'Jo Koy (12 and Over)'; want = $true }
    @{ first = 'Jo Koy'; second = 'Jo Koy - Koy Meets World Tour'; want = $true }
    @{ first = "BSU Women's Basketball Game"; second = "Boise State University Women's Basketball vs Portland State - Trivia Friday"; want = $true }
    @{ first = 'JSTJR'; second = 'JSTJR, EZA, Elijah Andres'; want = $true }
    @{ first = 'Family Storytime'; second = 'Toddler Storytime'; want = $false }
    @{ first = 'Senior Recital: Natalie Li, saxophone'; second = 'Senior Recital: Eddie Rudser, clarinet'; want = $false }
    @{ first = 'The Show'; second = 'Live Tour'; want = $false }
  ) {
    $a = Get-TvTitleWords (Get-TvMatchTitle $first)
    $b = Get-TvTitleWords (Get-TvMatchTitle $second)
    Test-TvSameTitleWords $a $b | Should -Be $want
  }
}

Describe 'Merge-TvEvents same-minute rule' {
  It 'merges different titles for one show from different sources' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Title 'Jo Koy' -Venue 'Ford Idaho Center Arena' -Start '2026-11-07T20:00:00-07:00' -Source a)
        (New-TestEvent -Title 'Jo Koy (12 and Over)' -Venue 'Ford Idaho Center Arena' -Start '2026-11-07T20:00:00-07:00' -Source b)
        (New-TestEvent -Title 'Jo Koy - Koy Meets World Tour' -Venue 'Ford Idaho Center Arena' -Start '2026-11-07T20:00:00-07:00' -Source c)
      ) -Priorities @{ b = 10 })
    $merged.Count | Should -Be 1
    $merged[0].title | Should -Be 'Jo Koy (12 and Over)'
    $merged[0].sources.name | Should -Be @('a', 'b', 'c')
  }

  It 'merges a short-form title with the full one' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Title "Boise State University Women's Basketball vs Portland State - Trivia Friday" -Venue 'ExtraMile Arena' -Start '2026-11-06T18:30:00-07:00' -Source athletics)
        (New-TestEvent -Title "BSU Women's Basketball Game" -Venue 'ExtraMile Arena' -Start '2026-11-06T18:30:00-07:00' -Source mom)
      ) -Priorities @{ athletics = 10; mom = 40 })
    $merged.Count | Should -Be 1
    $merged[0].title | Should -BeLike 'Boise State University*'
  }

  It 'keeps them apart when the start differs by a minute or more' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Title 'Jo Koy' -Venue 'Ford Idaho Center Arena' -Start '2026-11-07T20:00:00-07:00' -Source a)
        (New-TestEvent -Title 'Jo Koy Late Show Extra' -Venue 'Ford Idaho Center Arena' -Start '2026-11-07T20:15:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps two listings from the same source' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Title 'Storytime' -Venue 'Boise Public Library' -Start '2026-11-05T10:30:00-07:00' -Source library -Url 'https://library.test/1')
        (New-TestEvent -Title 'Toddler Storytime' -Venue 'Boise Public Library' -Start '2026-11-05T10:30:00-07:00' -Source library -Url 'https://library.test/2')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps different titles at different venues' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Title 'Jo Koy' -Venue 'Ford Idaho Center Arena' -Start '2026-11-07T20:00:00-07:00' -Source a)
        (New-TestEvent -Title 'Jo Koy (12 and Over)' -Venue 'ExtraMile Arena' -Start '2026-11-07T20:00:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 2
  }
}

Describe 'Merge-TvEvents multi-day rule' {
  BeforeAll {
    # Two sources for one festival: one reports the wrong opening time and another building.
    function New-Festival {
      param([string]$Source, [string]$Start, [string]$Venue, [string]$City = 'Nampa', [string]$End = '2026-11-30T17:00:00-07:00', [string]$Title = 'Canyon County Festival of Trees')
      New-TestEvent -Title $Title -Start $Start -End $End -Venue $Venue -City $City -Source $Source -Url "https://$Source.test/trees"
    }
  }

  It 'merges one multi-day event that two sources list at different times and buildings' {
    $merged = @(Merge-TvEvents @(
        (New-Festival -Source venue -Start '2026-11-27T06:30:00-07:00' -Venue 'Ford Idaho Center Horse Park')
        (New-Festival -Source agency -Start '2026-11-27T12:00:00-07:00' -Venue 'Ford Idaho Center Arena')
      ) -Priorities @{ venue = 20 })
    $merged.Count | Should -Be 1
    $merged[0].url | Should -Be 'https://venue.test/trees'
    $merged[0].sources.name | Should -Be @('agency', 'venue')
  }

  It 'keeps them apart in different cities' {
    $merged = @(Merge-TvEvents @(
        (New-Festival -Source venue -Start '2026-11-27T06:30:00-07:00' -Venue 'Ford Idaho Center Arena')
        (New-Festival -Source agency -Start '2026-11-27T12:00:00-07:00' -Venue 'Expo Idaho' -City 'Garden City')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps them apart when the city is unknown' {
    $merged = @(Merge-TvEvents @(
        (New-Festival -Source venue -Start '2026-11-27T06:30:00-07:00' -Venue 'Hall A' -City 'Other')
        (New-Festival -Source agency -Start '2026-11-27T12:00:00-07:00' -Venue 'Hall B' -City 'Other')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps them apart when they start on different days' {
    $merged = @(Merge-TvEvents @(
        (New-Festival -Source venue -Start '2026-11-27T12:00:00-07:00' -Venue 'Ford Idaho Center Arena')
        (New-Festival -Source agency -Start '2026-11-28T12:00:00-07:00' -Venue 'Ford Idaho Center Horse Park')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps them apart when the titles differ' {
    $merged = @(Merge-TvEvents @(
        (New-Festival -Source venue -Start '2026-11-27T06:30:00-07:00' -Venue 'Ford Idaho Center Horse Park')
        (New-Festival -Source agency -Start '2026-11-27T12:00:00-07:00' -Venue 'Ford Idaho Center Arena' -Title 'Canyon County Festival of Lights')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps one-day events with the same title at different venues' {
    $merged = @(Merge-TvEvents @(
        (New-Festival -Source a -Start '2026-11-27T10:00:00-07:00' -End '2026-11-27T11:00:00-07:00' -Venue 'Library A' -Title 'Story Time')
        (New-Festival -Source b -Start '2026-11-27T14:00:00-07:00' -End '2026-11-27T15:00:00-07:00' -Venue 'Library B' -Title 'Story Time')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps two listings from the same source' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Title 'Holiday Bazaar' -Start '2026-11-27T09:00:00-07:00' -End '2026-11-29T17:00:00-07:00' -Venue 'Hall A' -City 'Nampa' -Source s -Url 'https://s.test/1')
        (New-TestEvent -Title 'Holiday Bazaar' -Start '2026-11-27T10:00:00-07:00' -End '2026-11-29T17:00:00-07:00' -Venue 'Hall B' -City 'Nampa' -Source s -Url 'https://s.test/2')
      ))
    $merged.Count | Should -Be 2
  }
}

Describe 'Merge-TvEvents canceled events' {
  It 'recognizes <title>: <want>' -ForEach @(
    @{ title = 'CANCELED - Play and Learn'; want = $true }
    @{ title = 'CANCELLED Ping-Pong Club'; want = $true }
    @{ title = 'CANCELED-Toddler Storytime'; want = $true }
    @{ title = 'Canceled LEGO Club'; want = $true }
    @{ title = 'Cancel Culture Comedy Hour'; want = $false }
  ) {
    Test-TvCanceledTitle $title | Should -Be $want
  }

  It 'drops a canceled event only with -DropCanceled' {
    $events = @((New-TestEvent -Title 'CANCELED - Play and Learn' -Source a), (New-TestEvent -Title 'Toddler Time' -Start '2026-11-15T10:00:00-07:00' -Source a))
    @(Merge-TvEvents $events).Count | Should -Be 2
    $kept = @(Merge-TvEvents $events -DropCanceled)
    $kept.Count | Should -Be 1
    $kept[0].title | Should -Be 'Toddler Time'
  }

  It 'drops the listing a cancellation from another source matches' {
    $merged = @(Merge-TvEvents @(
        (New-TestEvent -Title 'Play and Learn' -Source mom -Url 'https://mom.test/1')
        (New-TestEvent -Title 'CANCELED - Play and Learn' -Source library -Url 'https://library.test/1')
      ) -Priorities @{ mom = 10; library = 20 } -DropCanceled)
    $merged.Count | Should -Be 0
  }
}