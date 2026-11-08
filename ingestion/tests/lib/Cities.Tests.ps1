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
