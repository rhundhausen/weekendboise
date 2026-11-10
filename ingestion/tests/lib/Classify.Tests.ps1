BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/Schema.ps1"

  $root = Join-Path $PSScriptRoot '..' '..'
  $repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
  $script:categories = @(Get-Content (Join-Path $repoRoot 'data/schema/categories.json') -Raw | ConvertFrom-Json)
  $script:tags = @(Get-Content (Join-Path $repoRoot 'data/schema/tags.json') -Raw | ConvertFrom-Json)
  $script:eventSchema = Get-Content (Join-Path $root 'schema/event.schema.json') -Raw | ConvertFrom-Json
  $script:sourceSchema = Get-Content (Join-Path $root 'schema/sources.schema.json') -Raw | ConvertFrom-Json
  $script:sources = (Get-Content (Join-Path $root 'sources.json') -Raw | ConvertFrom-Json).sources
}

Describe 'categories.json' {
  It 'has the 13 ids, in the specified order' {
    $categories.id | Should -Be @(
      'music', 'performing-arts', 'sports', 'festivals', 'holiday-seasonal', 'arts-culture',
      'markets-shopping', 'food-drink', 'outdoors-recreation', 'community-civic', 'learning-business', 'nightlife-social',
      'auctions-estate-sales'
    )
  }

  It 'gives every entry a label, description, and includes' {
    foreach ($category in $categories) {
      $category.label | Should -Not -BeNullOrEmpty
      $category.description | Should -Not -BeNullOrEmpty
      @($category.includes).Count | Should -BeGreaterThan 0
    }
  }

  It 'matches the enum in both schemas, sorted' {
    $sorted = [string[]]@($categories.id)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $eventSchema.properties.category.enum | Should -Be $sorted
    $sourceSchema.'$defs'.source.properties.category.enum | Should -Be $sorted
  }
}

Describe 'tags.json' {
  It 'has 60 to 81 tags' {
    $tags.Count | Should -BeGreaterOrEqual 60
    $tags.Count | Should -BeLessOrEqual 81
  }

  It 'is sorted, with unique slug ids' {
    $sorted = [string[]]@($tags.id)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $tags.id | Should -Be $sorted
    ($tags.id | Select-Object -Unique).Count | Should -Be $tags.Count
    $tags.id | Where-Object { $_ -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$' } | Should -BeNullOrEmpty
  }

  It 'includes the examples in the spec' {
    foreach ($id in 'concert', 'comedy', 'rodeo', 'farmers-market', 'christmas-lights', 'haunted-house', 'fireworks',
      'film', 'trivia', 'hike', 'volunteer', 'workshop', 'meetup', 'kids', 'free-admission') {
      $tags.id | Should -Contain $id
    }
  }

  It 'points only at real categories' {
    $tags | Where-Object { $_.category -and $_.category -notin $categories.id } | Should -BeNullOrEmpty
  }

  It 'covers every category' {
    foreach ($id in $categories.id) {
      @($tags | Where-Object category -eq $id).Count | Should -BeGreaterThan 0 -Because $id
    }
  }

  It 'uses keywords and sourceLabels in normalized form, or they could never match' {
    foreach ($tag in $tags) {
      @($tag.keywords).Count | Should -BeGreaterThan 0
      foreach ($keyword in (@($tag.keywords) + @($tag.sourceLabels) | Where-Object { $_ })) {
        $keyword | Should -BeExactly (Get-NormalizedTitle $keyword)
      }
    }
  }
}

Describe 'sources.json categories' {
  It 'uses only real categories' {
    # Ideas may not have a category yet; every configured source must.
    $sources | Where-Object { $_.name -or $_.category } | Where-Object category -notin $categories.id | Should -BeNullOrEmpty
  }
}

Describe 'Get-TvClassification' {
  It 'tags and categorizes <title>' -ForEach @(
    @{ title = 'Ballet Idaho presents The Nutcracker'; tag = 'nutcracker'; category = 'holiday-seasonal' }
    @{ title = 'Capital City Public Market Holiday Market'; tag = 'holiday-market'; category = 'holiday-seasonal' }
    @{ title = 'Nampa Farmers Market'; tag = 'farmers-market'; category = 'markets-shopping' }
    @{ title = 'Trivia Night at the Brewery'; tag = 'trivia'; category = 'food-drink' }
    @{ title = 'Guided Walk-In Capitol Tours'; tag = 'tour'; category = 'outdoors-recreation' }
    @{ title = 'Silent Disco on the Plaza'; tag = 'dj-night'; category = 'nightlife-social' }
    @{ title = 'Blood Drive at City Hall'; tag = 'blood-drive'; category = 'community-civic' }
    @{ title = 'Job Fair for Veterans'; tag = 'job-fair'; category = 'learning-business' }
    @{ title = 'Monster Jam'; tag = 'motorsports'; category = 'sports' }
    @{ title = 'Stand-Up Comedy Showcase'; tag = 'comedy'; category = 'performing-arts' }
  ) {
    $result = Get-TvClassification $title
    $result.Tags | Should -Contain $tag
    $result.Category | Should -Be $category
  }

  It 'puts the holiday ahead of the music' {
    (Get-TvClassification 'Christmas Lights Concert').Category | Should -Be 'holiday-seasonal'
  }

  It 'does not take a category or a category tag from the description' {
    $result = Get-TvClassification 'Saturday at the Park' 'Bring a chair for the concert and fireworks'
    $result.Category | Should -BeNullOrEmpty
    @($result.Tags).Count | Should -Be 0
  }

  It 'takes tags with no category from the description' {
    (Get-TvClassification 'Saturday at the Park' 'Great for kids. Free admission.').Tags | Should -Be @('free-admission', 'kids')
  }

  It 'uses publisher labels, decoding entities' {
    $result = Get-TvClassification 'Karina Rykman' -Labels 'Arts &amp; Music'
    $result.Tags | Should -Contain 'concert'
    $result.Category | Should -Be 'music'
  }

  It 'matches labels against keywords too' {
    (Get-TvClassification 'Jo Koy' -Labels 'Arts & Theatre', 'Comedy').Tags | Should -Contain 'comedy'
  }

  It 'requires a whole label to match sourceLabels' {
    (Get-TvClassification 'Show' -Labels 'Free Parking').Tags | Should -Not -Contain 'free-admission'
    (Get-TvClassification 'Show' -Labels 'Free').Tags | Should -Contain 'free-admission'
  }

  It 'lets a title match beat a label' {
    (Get-TvClassification 'Trivia Night' -Labels 'Arts & Music').Category | Should -Be 'food-drink'
  }

  It 'matches across punctuation' {
    (Get-TvClassification "Trick$([char]0x2013)Or$([char]0x2013)Treat at Lakeshore").Tags | Should -Contain 'halloween'
  }

  It 'matches whole words only' {
    (Get-TvClassification 'Marketing Mixer in Fairview').Tags | Should -Not -Contain 'fair'
    (Get-TvClassification 'Zookeeper Talk').Tags | Should -Not -Contain 'zoo'
  }

  It 'finds a tag with no category without choosing one' {
    $result = Get-TvClassification 'Saturday for Kids'
    $result.Tags | Should -Contain 'kids'
    $result.Category | Should -BeNullOrEmpty
  }

  It 'returns no tags for an unmatched title' {
    @((Get-TvClassification 'Kyle Gordon').Tags).Count | Should -Be 0
  }
}

Describe 'sizes.json' {
  BeforeAll {
    $sizes = Get-Content (Join-Path $PSScriptRoot '..' '..' '..' 'data/schema/sizes.json') -Raw | ConvertFrom-Json -AsHashtable
  }

  It 'matches the enum in the schema' {
    ($sizes.levels.id | Sort-Object) | Should -Be ($eventSchema.properties.size.enum | Sort-Object)
  }

  It 'gives every category a size' {
    foreach ($id in $categories.id) {
      $sizes.categories.Keys | Should -Contain $id
    }
  }

  It 'uses only real sizes, tags, and slugs' {
    $levels = $sizes.levels.id
    foreach ($value in (@($sizes.venues.Values) + @($sizes.tags.Values) + @($sizes.categories.Values))) {
      $levels | Should -Contain $value
    }
    foreach ($tag in (@($sizes.tags.Keys) + @($sizes.smallTags))) {
      $tags.id | Should -Contain $tag
    }
    $sizes.venues.Keys | Where-Object { $_ -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$' } | Should -BeNullOrEmpty
  }
}

Describe 'Get-TvEventSize' {
  It 'uses the venue' {
    Get-TvEventSize -VenueKey 'extramile-arena' -Category 'music' | Should -Be 'XL'
    Get-TvEventSize -VenueKey 'neurolux' -Category 'music' | Should -Be 'M'
  }

  It 'lets a small-format tag beat the venue' {
    Get-TvEventSize -VenueKey 'morrison-center' -Category 'arts-culture' -Tags 'workshop' | Should -Be 'S'
  }

  It 'lets the venue beat other tags' {
    Get-TvEventSize -VenueKey 'neurolux' -Category 'music' -Tags 'festival' | Should -Be 'M'
  }

  It 'takes the largest tag at an unknown venue' {
    Get-TvEventSize -VenueKey 'some-park' -Category 'community-civic' -Tags 'concert', 'fair' | Should -Be 'XL'
  }

  It 'falls back to the category' {
    Get-TvEventSize -VenueKey 'some-park' -Category 'festivals' | Should -Be 'L'
    Get-TvEventSize -VenueKey 'some-park' -Category 'community-civic' -Tags 'kids' | Should -Be 'S'
  }
}

Describe 'venue aliases' {
  BeforeAll {
    $aliases = (Get-Content (Join-Path $PSScriptRoot '..' '..' '..' 'data/schema/venue-aliases.json') -Raw | ConvertFrom-Json -AsHashtable).aliases
    $sizes = Get-Content (Join-Path $PSScriptRoot '..' '..' '..' 'data/schema/sizes.json') -Raw | ConvertFrom-Json -AsHashtable
    function New-AtVenue {
      param([string]$Venue)
      New-TvEvent -Title 'Show' -Start '2026-11-14T19:30:00-07:00' -Venue $Venue -Category 'music' -Url 'https://x.test/e'
    }
  }

  It 'uses one key and name for every spelling' {
    (New-AtVenue 'Neurolux Lounge').venueKey | Should -Be 'neurolux'
    (New-AtVenue 'Neurolux Lounge').venue | Should -Be 'Neurolux'
    (New-AtVenue 'Knitting Factory - Boise').venueKey | Should -Be 'knitting-factory'
    (New-AtVenue 'Extra Mile Arena').venueKey | Should -Be 'extramile-arena'
  }

  It 'gives every spelling the same id, so events merge' {
    (New-AtVenue 'Neurolux Lounge').id | Should -Be (New-AtVenue 'Neurolux').id
  }

  It 'leaves other venues alone' {
    (New-AtVenue 'Some New Hall').venueKey | Should -Be 'some-new-hall'
  }

  It 'points at canonical keys, not at other aliases' {
    foreach ($alias in $aliases.Values) {
      $aliases.Keys | Should -Not -Contain $alias.key
    }
  }

  It 'points at venues with a known size' {
    foreach ($alias in $aliases.Values) {
      $sizes.venues.Keys | Should -Contain $alias.key
    }
  }
}

Describe 'New-TvEvent classification' {
  BeforeAll {
    function New-TestEvent {
      param([string]$Title, [switch]$InferCategory)
      New-TvEvent -Title $Title -Start '2026-11-14T19:30:00-07:00' -Venue 'Venue' -Url 'https://x.test/e' `
        -Category 'community-civic' -InferCategory:$InferCategory
    }
  }

  It 'keeps the given category by default, and still tags' {
    $event = New-TestEvent 'Trivia Night'
    $event.category | Should -Be 'community-civic'
    @($event.tags) | Should -Contain 'trivia'
  }

  It 'infers the category when asked' {
    (New-TestEvent 'Trivia Night' -InferCategory).category | Should -Be 'food-drink'
  }

  It 'falls back when nothing matches' {
    (New-TestEvent 'Kyle Gordon' -InferCategory).category | Should -Be 'community-civic'
  }

  It 'writes tags as an array, even for one or none' {
    (New-TestEvent 'Trivia Night' | ConvertTo-Json -Depth 6) | Should -Match '"tags": \['
    (New-TestEvent 'Kyle Gordon' | ConvertTo-Json -Depth 6) | Should -Match '"tags": \['
  }

  It 'estimates a size' {
    (New-TestEvent 'Kyle Gordon').size | Should -Be 'S'
    (New-TestEvent 'Trivia Night' -InferCategory).size | Should -Be 'S'
  }

  It 'rejects an unknown size' {
    $event = (New-TestEvent 'Show') | Select-Object *
    $event.size = 'XXL'
    Test-TvEvent $event | Should -BeFalse
  }

  It 'requires a category' {
    Test-TvEvent ((New-TestEvent 'Show') | Select-Object * -ExcludeProperty category) | Should -BeFalse
  }

  It 'rejects an old category id' {
    { New-TvEvent -Title 'Show' -Start '2026-11-14T19:30:00-07:00' -Venue 'Venue' -Url 'https://x.test/e' -Category 'concerts' } |
      Should -Throw '*schema*'
  }
}

Describe 'Get-TvClassification fallback tags' {
  It 'puts "<title>" in <want>' -ForEach @(
    @{ title = 'Dungeons and Dragons'; labels = @('library'); want = 'nightlife-social' }
    @{ title = 'Dungeons & Dragons'; labels = @('library'); want = 'nightlife-social' }
    @{ title = 'Teen Club: Dungeons and Dragons | Cole & Ustick Library!'; labels = @(); want = 'nightlife-social' }
    @{ title = 'Dungeon Club: Mini Painting'; labels = @('library'); want = 'nightlife-social' }
    @{ title = 'Preschool Storytime'; labels = @('library'); want = 'learning-business' }
    @{ title = 'Teen Club | Hillcrest Library!'; labels = @(); want = 'learning-business' }
    @{ title = 'Fit and Fall Proof'; labels = @('library'); want = 'learning-business' }
  ) {
    (Get-TvClassification $title '' -Labels $labels).Category | Should -Be $want
  }

  It 'still tags a library event as library-program when another tag sets the category' {
    (Get-TvClassification 'Teen Club: Dungeons and Dragons | Cole & Ustick Library!' '').Tags | Should -Contain 'library-program'
  }
}