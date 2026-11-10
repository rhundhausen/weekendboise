BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/Cities.ps1"

  function New-OtherEvent {
    param([string]$Title = 'Holiday Bazaar', [string]$Venue = 'Various Treasure Valley locations', [string]$Description = '', [string]$City = 'Other', [string]$VenueKey = 'various-treasure-valley')
    [pscustomobject]@{ title = $Title; venue = $Venue; venueKey = $VenueKey; city = $City; description = $Description }
  }
}

Describe 'Get-TvCityClue' {
  It 'finds <want> in "<title>" / "<venue>" / "<description>"' -ForEach @(
    @{ title = 'Paella on the Patio'; venue = 'Various Treasure Valley locations'; description = 'On the Basque Block at 608 W Grove St, Boise, ID 83702'; want = 'Boise' }
    @{ title = 'Holiday Boutique'; venue = 'eagle, ID'; description = ''; want = 'Eagle' }
    @{ title = 'Craft Fair'; venue = 'Various'; description = 'At the hall, 123 Main St 83646'; want = 'Meridian' }
    @{ title = 'Breakfast with Santa | Caldwell YMCA'; venue = 'Various'; description = ''; want = 'Caldwell' }
    @{ title = 'KidStrong Meridian | Parents Night Out'; venue = 'Various'; description = ''; want = 'Meridian' }
    @{ title = 'Holiday Magic on Main Street (Emmett)'; venue = 'Various'; description = ''; want = 'Emmett' }
    @{ title = 'Tree Lighting'; venue = 'Various'; description = 'Held at the Star, Idaho city hall'; want = 'Star' }
    @{ title = 'Veterans Breakfast | Warhawk Air Museum'; venue = 'Various'; description = ''; want = 'Nampa' }
    @{ title = 'Old Town Lights'; venue = 'Various'; description = 'Join us in downtown Nampa for the lights'; want = 'Nampa' }
    @{ title = 'Movie Night'; venue = 'Various'; description = 'A family movie at the West Boise YMCA'; want = 'Boise' }
    @{ title = 'Winter Carnival'; venue = 'Various'; description = 'Downtown, 216 E Park St 83638'; want = 'Valley County' }
    @{ title = 'Tree Lighting'; venue = 'Various'; description = 'Main Street, 83549'; want = 'Valley County' }
  ) {
    Get-TvCityClue (New-OtherEvent -Title $title -Venue $venue -Description $description) | Should -Be $want
  }

  It 'returns nothing for <case>' -ForEach @(
    @{ case = 'no clue at all'; title = 'Home Depot Kids Workshop'; description = 'Workshops run the first Saturday of each month' }
    @{ case = 'two cities at the same strength'; title = 'Holiday Lights Tour'; description = 'Buses leave from Boise and Nampa' }
    @{ case = 'a company named after a city'; title = 'Free Christmas Movie'; description = 'The movies Boise Cascade once provided for our community' }
    @{ case = 'a bare ambiguous word'; title = 'Star Party'; description = 'Look at every star in the sky with Emmett and the astronomy club' }
  ) {
    Get-TvCityClue (New-OtherEvent -Title $title -Description $description) | Should -BeNullOrEmpty
  }

  It 'uses a venue that other events place in one city' {
    $map = @{ 'franz-witte' = 'Boise' }
    Get-TvCityClue (New-OtherEvent -Title 'Wreath Workshop' -Venue 'FW' -VenueKey 'franz-witte') -VenueCities $map | Should -Be 'Boise'
  }

  It 'prefers a ZIP code over a city named in the title' {
    Get-TvCityClue (New-OtherEvent -Title 'Boise Bazaar' -Description 'At the fairgrounds, Caldwell ID 83605') | Should -Be 'Caldwell'
  }
}

Describe 'Get-TvVenueCities' {
  It 'leaves out a placeholder venue that also appears as Other' {
    $map = Get-TvVenueCities @(
      (New-OtherEvent -City 'Boise')
      (New-OtherEvent -City 'Other')
      (New-OtherEvent -VenueKey 'morrison-center' -City 'Boise')
    )
    $map.ContainsKey('various-treasure-valley') | Should -BeFalse
    $map['morrison-center'] | Should -Be 'Boise'
  }

  It 'leaves out a venue placed in two cities' {
    $map = Get-TvVenueCities @((New-OtherEvent -VenueKey 'ymca' -City 'Boise'), (New-OtherEvent -VenueKey 'ymca' -City 'Caldwell'))
    $map.ContainsKey('ymca') | Should -BeFalse
  }
}

Describe 'Resolve-TvOtherCity' {
  It 'changes only events stored as Other and counts them' {
    $events = @(
      (New-OtherEvent -Title 'Hawaiian Bingo | Caldwell YMCA')
      (New-OtherEvent -Title 'Home Depot Kids Workshop')
      (New-OtherEvent -Title 'Nampa Tree Lighting' -City 'Boise' -VenueKey 'city-hall')
    )
    Resolve-TvOtherCity $events | Should -Be 1
    $events.city | Should -Be @('Caldwell', 'Other', 'Boise')
  }
}

Describe 'Resolve-TvTitleVenue' {
  BeforeAll {
    function New-Placed {
      param([string]$Title, [string]$Venue, [string]$City, [string]$Source = 'venue-site')
      New-TvEvent -Title $Title -Start '2026-11-12T10:00:00-07:00' -Venue $Venue -City $City -Category 'community-civic' `
        -Url "https://$Source.test/e" -Sources @(@{ name = $Source; url = "https://$Source.test/e"; fetchedAt = '2026-11-01T10:00:00Z' })
    }
    function New-Placeholder {
      param([string]$Title)
      New-TvEvent -Title $Title -Start '2026-11-12T10:00:00-07:00' -Venue 'Various Treasure Valley locations' -VenueKey 'various-treasure-valley' `
        -City 'Other' -Category 'community-civic' -Url 'https://mom.test/e' -Sources @(@{ name = 'mom'; url = 'https://mom.test/e'; fetchedAt = '2026-11-01T10:00:00Z' })
    }
  }

  It 'gives a placeholder-venue event the venue its title names, when another event places it' {
    $zoo = New-Placed '$3 Thursdays' 'Zoo Boise' 'Boise'
    $mom = New-Placeholder '$3 Admission Day at Zoo Boise'
    $events = @($zoo, $mom, (New-Placeholder 'Holiday Bazaar'))
    Resolve-TvTitleVenue $events | Should -Be 1
    $mom.venue | Should -Be 'Zoo Boise'
    $mom.venueKey | Should -Be 'zoo-boise'
    $mom.city | Should -Be 'Boise'
  }

  It 'rebuilds the id and size as New-TvEvent would for that venue' {
    $mom = New-Placeholder '$3 Admission Day at Zoo Boise'
    $null = Resolve-TvTitleVenue @((New-Placed 'Zoo Day' 'Zoo Boise' 'Boise'), $mom)
    $want = New-TvEvent -Title '$3 Admission Day at Zoo Boise' -Start '2026-11-12T10:00:00-07:00' -Venue 'Zoo Boise' -City 'Boise' -Category 'community-civic' `
      -Url 'https://mom.test/e' -Sources @(@{ name = 'mom'; url = 'https://mom.test/e'; fetchedAt = '2026-11-01T10:00:00Z' })
    $mom.id | Should -Be $want.id
    $mom.size | Should -Be $want.size
  }

  It 'reads "at the" followed by the venue too' {
    $mom = New-Placeholder 'Holiday Market at the Old Boise Pioneer Building'
    $null = Resolve-TvTitleVenue @((New-Placed 'Craft Fair' 'Old Boise Pioneer Building' 'Boise'), $mom)
    $mom.venueKey | Should -Be 'old-boise-pioneer-building'
  }

  It 'leaves an event whose named venue no other event places' {
    $mom = New-Placeholder 'Cookies with Santa at Canyon County Festival of Trees'
    Resolve-TvTitleVenue @($mom) | Should -Be 0
    $mom.venueKey | Should -Be 'various-treasure-valley'
    $mom.city | Should -Be 'Other'
  }

  It 'leaves an event that already has a real venue' {
    $show = New-Placed 'Lights at Zoo Boise' 'Idaho Botanical Garden' 'Boise'
    Resolve-TvTitleVenue @((New-Placed 'Zoo Day' 'Zoo Boise' 'Boise'), $show) | Should -Be 0
    $show.venueKey | Should -Be 'idaho-botanical-garden'
  }

  It 'reads a venue after "|", drops it from the title, and knows places from place-cities.json' {
    $mom = New-Placeholder '1st Sunday Brunch | Meriwether Cider'
    Resolve-TvTitleVenue @($mom) | Should -Be 1
    $mom.title | Should -Be '1st Sunday Brunch'
    $mom.venue | Should -Be 'Meriwether Cider'
    $mom.venueKey | Should -Be 'meriwether-cider'
    $mom.city | Should -Be 'Garden City'
  }

  It 'reads a venue after "@" or a spaced dash' {
    $at = New-Placeholder 'Story Time @ Zoo Boise'
    $dash = New-Placeholder 'Penguin Feeding - Zoo Boise'
    $null = Resolve-TvTitleVenue @((New-Placed 'Zoo Day' 'Zoo Boise' 'Boise'), $at, $dash)
    $at.title | Should -Be 'Story Time'
    $dash.title | Should -Be 'Penguin Feeding'
    $dash.venueKey | Should -Be 'zoo-boise'
  }

  It 'rebuilds the id from the shortened title' {
    $mom = New-Placeholder '1st Sunday Brunch | Meriwether Cider'
    $null = Resolve-TvTitleVenue @($mom)
    $mom.id | Should -Be (Get-TvEventId '1st Sunday Brunch' $mom.start 'meriwether-cider')
  }

  It 'leaves text after "|" that is not a known venue' {
    $mom = New-Placeholder 'Holiday Fun | Dog Winter Photo Sessions'
    Resolve-TvTitleVenue @($mom) | Should -Be 0
    $mom.title | Should -Be 'Holiday Fun | Dog Winter Photo Sessions'
  }

  It 'does not take a city name as a venue' {
    $mom = New-Placeholder 'Veterans Day Celebration | Caldwell'
    Resolve-TvTitleVenue @((New-Placed 'Parade' 'Caldwell' 'Caldwell'), $mom) | Should -Be 0
    $mom.title | Should -Be 'Veterans Day Celebration | Caldwell'
  }

  It 'ignores a venue seen in more than one city' {
    $mom = New-Placeholder 'Story Time at Main Library'
    $events = @((New-Placed 'A' 'Main Library' 'Boise'), (New-Placed 'B' 'Main Library' 'Nampa'), $mom)
    Resolve-TvTitleVenue $events | Should -Be 0
  }
}
