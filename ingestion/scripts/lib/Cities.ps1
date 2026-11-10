# Fills in the city for events stored as Other, from clues in their own text.

. "$PSScriptRoot/Schema.ps1"

# Idaho ZIP codes for the cities in the schema. 83714 is mostly Garden City.
$script:TvZipCities = @{
  '83605' = 'Caldwell'; '83607' = 'Caldwell'
  '83616' = 'Eagle'
  '83617' = 'Emmett'
  '83634' = 'Kuna'
  '83639' = 'Marsing'
  '83642' = 'Meridian'; '83646' = 'Meridian'; '83680' = 'Meridian'
  '83644' = 'Middleton'
  '83647' = 'Mountain Home'; '83648' = 'Mountain Home'
  '83651' = 'Nampa'; '83653' = 'Nampa'; '83686' = 'Nampa'; '83687' = 'Nampa'
  '83661' = 'Payette'
  '83669' = 'Star'
  '83672' = 'Weiser'
  '83714' = 'Garden City'
  # Valley County is one location for all its towns: McCall, Cascade, Donnelly, Lake Fork, and
  # Yellow Pine. New Meadows (83654, Adams County) and Riggins (83549, Idaho County) are outside
  # Valley County but are grouped with it on purpose.
  '83638' = 'Valley County'; '83611' = 'Valley County'; '83615' = 'Valley County'
  '83635' = 'Valley County'; '83677' = 'Valley County'
  '83654' = 'Valley County'; '83549' = 'Valley County'
}
foreach ($zip in 83701..83799) {
  if (-not $script:TvZipCities.ContainsKey("$zip")) { $script:TvZipCities["$zip"] = 'Boise' }
}

# Cities whose names are also everyday words or surnames ("star", "Emmett Till", "Payette River").
# These are trusted only from a ZIP code or a "City, ID" pattern, never from a bare word.
$script:TvAmbiguousCities = @('Star', 'Payette', 'Emmett', 'Middleton', 'Weiser')

function Get-TvCityNames {
  # Every city in the event schema except Other, longest first so "Garden City" wins over shorter names.
  $schema = Join-Path $PSScriptRoot '..' '..' 'schema' 'event.schema.json'
  if (-not $script:TvCityNames) {
    $enum = (Get-Content -LiteralPath $schema -Raw | ConvertFrom-Json).properties.city.enum
    $script:TvCityNames = @($enum | Where-Object { $_ -ne 'Other' } | Sort-Object Length -Descending)
  }
  $script:TvCityNames
}

function Get-TvPlaceCities {
  # data/schema/place-cities.json, loaded once.
  if (-not $script:TvPlaceCities) {
    $path = Join-Path $PSScriptRoot '..' '..' '..' 'data' 'schema' 'place-cities.json'
    $script:TvPlaceCities = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
  }
  $script:TvPlaceCities
}

function Remove-TvNonPlace {
  # Blanks out names that contain a city but aren't places in it, such as Boise Cascade.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowEmptyString()][string]$Text)

  foreach ($name in @((Get-TvPlaceCities).ignore)) {
    $Text = $Text -replace ('(?i)\b' + [regex]::Escape($name) + '\b'), ' '
  }
  $Text
}

function Find-TvPlace {
  # Cities of the known places named in the text.
  [CmdletBinding()]
  param([AllowEmptyString()][string]$Text)

  $places = (Get-TvPlaceCities).places
  @($places.Keys | Where-Object { $Text -match ('(?i)\b' + [regex]::Escape($_) + '(?!\w)') } | ForEach-Object { $places[$_] } | Select-Object -Unique)
}

function Find-TvCityWord {
  # Distinct cities named as whole words in the text, optionally only when followed by ", ID" or ", Idaho".
  [CmdletBinding()]
  param(
    [AllowEmptyString()][string]$Text,
    [switch]$WithState,
    [switch]$Unambiguous,
    [string]$Before = ''
  )

  if (-not $Text) { return @() }
  $found = [Collections.Generic.List[string]]::new()
  foreach ($city in (Get-TvCityNames)) {
    if ($Unambiguous -and $city -in $script:TvAmbiguousCities) { continue }
    $pattern = '(?i)' + $Before + '\b' + [regex]::Escape($city) + '\b' + ($WithState ? ',?\s+(ID|Idaho)\b' : '(?!\w)')
    if ($Text -match $pattern -and -not $found.Contains($city)) { $found.Add($city) }
  }
  $found.ToArray()
}

function Get-TvCityClue {
  <#
  .SYNOPSIS
    Infers an event's city from its venue, title, and description, or returns $null.
  .DESCRIPTION
    Tries clues from strongest to weakest and stops at the first that names cities:
    1. an Idaho ZIP code in the venue or description
    2. "City, ID" or "City, Idaho" anywhere, or "(City)" in the title
    3. a city name in the venue
    4. a known place from data/schema/place-cities.json, such as the Basque Block
    5. the venue's city, when other events place that venueKey in one city
    6. "in", "downtown", or "at" before a city name in the title or description
    7. a city name in the title
    8. a city name in the description
    A clue that names more than one city is ambiguous and ends the search with no answer.
    Star, Payette, Emmett, Middleton, and Weiser count only from clues 1 and 2. Names in the
    ignore list there, such as Boise Cascade, are not read as a city.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][object]$Event,
    [hashtable]$VenueCities = @{}
  )

  $venue = Remove-TvNonPlace "$($Event.venue)"
  $title = Remove-TvNonPlace "$($Event.title)"
  $description = Remove-TvNonPlace "$($Event.description)"
  $all = "$venue`n$title`n$description"

  # Each step runs only if the ones before it found nothing.
  $steps = @(
    { @([regex]::Matches("$venue`n$description", '\b83[567]\d\d\b') | ForEach-Object { $script:TvZipCities[$_.Value] }) }
    { @(Find-TvCityWord $all -WithState) + @(Find-TvCityWord $title -Before '\(\s*' | Where-Object { $title -match ('(?i)\(\s*' + [regex]::Escape($_) + '\s*\)') }) }
    { Find-TvCityWord $venue -Unambiguous }
    { Find-TvPlace $all }
    { @(if ($VenueCities.ContainsKey("$($Event.venueKey)")) { $VenueCities["$($Event.venueKey)"] }) }
    { Find-TvCityWord "$title`n$description" -Unambiguous -Before '\b(in|downtown|at)\s+(the\s+)?' }
    { Find-TvCityWord $title -Unambiguous }
    { Find-TvCityWord $description -Unambiguous }
  )
  foreach ($step in $steps) {
    $cities = @(& $step | Where-Object { $_ } | Select-Object -Unique)
    if ($cities.Count -eq 1) { return $cities[0] }
    if ($cities.Count -gt 1) { return $null }
  }
  $null
}

function Get-TvVenueCities {
  # venueKey to city, for venues that events with a real city place in exactly one city.
  # A venue that also appears with city Other is a placeholder ("Various Treasure Valley locations"),
  # not a place, so it is left out even when a merge gave one of its events a city.
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events)

  $seen = @{}
  $placeholders = [Collections.Generic.HashSet[string]]::new()
  foreach ($event in $Events) {
    if (-not $event.venueKey) { continue }
    if (-not $event.city -or $event.city -eq 'Other') { $null = $placeholders.Add($event.venueKey); continue }
    if (-not $seen.ContainsKey($event.venueKey)) { $seen[$event.venueKey] = [Collections.Generic.HashSet[string]]::new() }
    $null = $seen[$event.venueKey].Add($event.city)
  }
  $map = @{}
  foreach ($key in $seen.Keys) {
    if ($seen[$key].Count -eq 1 -and -not $placeholders.Contains($key)) { $map[$key] = @($seen[$key])[0] }
  }
  $map
}

function Resolve-TvOtherCity {
  <#
  .SYNOPSIS
    Sets the city on events stored as Other when their text says where they are. Returns how many changed.
  .DESCRIPTION
    Only the city changes. The id is built from title, date, and venue, so it stays the same.
  .PARAMETER Known
    Extra events to learn venue cities from, such as the archive. The Events are always used.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events,
    [AllowEmptyCollection()][object[]]$Known = @()
  )

  $venueCities = Get-TvVenueCities (@($Events) + @($Known))
  $changed = 0
  foreach ($event in $Events) {
    if ($event.city -and $event.city -ne 'Other') { continue }
    $city = Get-TvCityClue $event -VenueCities $venueCities
    if ($city) {
      $event | Add-Member -NotePropertyName city -NotePropertyValue $city -Force
      $changed++
    }
  }
  $changed
}

function Resolve-TvTitleVenue {
  <#
  .SYNOPSIS
    Gives an event at a placeholder venue the venue its title names. Returns how many changed.
  .DESCRIPTION
    Aggregators list many events under one placeholder ("Various Treasure Valley locations",
    city Other) while the title names the place: "$3 Admission Day at Zoo Boise", "1st Sunday
    Brunch | Meriwether Cider". When the title ends in a known venue after "|", "@", a spaced
    dash, "at", or "at the", the event takes that venue's name, key, and city, and its id and size
    are rebuilt to match. After "|", "@", or a dash the venue is also dropped from the title, as
    New-TvEvent does; after "at" the title reads naturally and stays. Known venues are those other
    events place in exactly one city (Get-TvVenueCities), and the places in
    data/schema/place-cities.json. Anything else is left alone, since the words may name an event
    ("at Canyon County Festival of Trees", "| Dog Winter Photo Sessions"), not a place. Run it
    before Merge-TvEvents, so the event can merge with the venue's own listing.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events)

  $venueCities = Get-TvVenueCities $Events
  $names = @{}
  foreach ($event in $Events) {
    if ($event.venueKey -and $venueCities.ContainsKey($event.venueKey) -and -not $names.ContainsKey($event.venueKey)) {
      $names[$event.venueKey] = $event.venue
    }
  }

  $placeholders = @{}
  foreach ($event in $Events) {
    if ($event.venueKey -and -not $venueCities.ContainsKey($event.venueKey)) { $placeholders[$event.venueKey] = $true }
  }
  $places = (Get-TvPlaceCities).places
  foreach ($place in $places.Keys) {
    $key = Get-VenueKey $place
    if (-not $venueCities.ContainsKey($key)) {
      $venueCities[$key] = $places[$place]
      $names[$key] = $place
    }
  }

  $separator = "\s*[|@]\s*|\s+(?:-|$([char]0x2013)|$([char]0x2014))\s+"
  $changed = 0
  foreach ($event in $Events) {
    if (-not $placeholders.ContainsKey("$($event.venueKey)")) { continue }
    if ($event.city -and $event.city -ne 'Other') { continue }
    $title = "$($event.title)"
    $key = $null
    $rest = $null
    foreach ($pattern in @("^(?<rest>.+)(?:$separator)(?<the>)(?<venue>[^|@]+?)\s*[!.]?$", '^(?<keep>.+\sat\s+(?<the>the\s+)?(?<venue>.+?))\s*[!.]?$')) {
      $match = [regex]::Match($title, $pattern, 'IgnoreCase')
      if (-not $match.Success) { continue }
      $named = $match.Groups['venue'].Value
      # A bare city ("| Caldwell") says where, not at what venue.
      if (Resolve-TvCity $named.Trim()) { continue }
      foreach ($candidate in @("$($match.Groups['the'].Value)$named", $named)) {
        $try = Get-VenueKey $candidate
        $alias = Resolve-TvVenueAlias $try
        if ($alias) { $try = $alias.key }
        if ($venueCities.ContainsKey($try) -and -not $placeholders.ContainsKey($try)) { $key = $try; break }
      }
      if ($key) {
        if ($match.Groups['rest'].Success -and $match.Groups['rest'].Value.Trim().Length -ge 3) { $rest = $match.Groups['rest'].Value.Trim() }
        break
      }
    }
    if (-not $key) { continue }

    if ($rest) { $event | Add-Member -NotePropertyName title -NotePropertyValue $rest -Force }
    $event | Add-Member -NotePropertyName venue -NotePropertyValue $names[$key] -Force
    $event | Add-Member -NotePropertyName venueKey -NotePropertyValue $key -Force
    $event | Add-Member -NotePropertyName city -NotePropertyValue $venueCities[$key] -Force
    $event | Add-Member -NotePropertyName id -NotePropertyValue (Get-TvEventId $event.title $event.start $key) -Force
    $event | Add-Member -NotePropertyName size -NotePropertyValue (Get-TvEventSize -VenueKey $key -Category $event.category -Tags @($event.tags)) -Force
    $changed++
  }
  $changed
}
