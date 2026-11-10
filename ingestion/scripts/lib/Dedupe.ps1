# Cross-source deduplication.

. "$PSScriptRoot/Schema.ps1"

function Get-JaroWinkler {
  [CmdletBinding()]
  [OutputType([double])]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$First,
    [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Second
  )

  if ($First -ceq $Second) { return [double]1 }
  if (-not $First -or -not $Second) { return [double]0 }

  $window = [Math]::Max([Math]::Max($First.Length, $Second.Length) / 2 - 1, 0)
  $window = [Math]::Floor($window)
  $firstMatched = [bool[]]::new($First.Length)
  $secondMatched = [bool[]]::new($Second.Length)

  $matchCount = 0
  for ($i = 0; $i -lt $First.Length; $i++) {
    $from = [Math]::Max($i - $window, 0)
    $to = [Math]::Min($i + $window, $Second.Length - 1)
    for ($j = $from; $j -le $to; $j++) {
      if (-not $secondMatched[$j] -and $First[$i] -ceq $Second[$j]) {
        $firstMatched[$i] = $true
        $secondMatched[$j] = $true
        $matchCount++
        break
      }
    }
  }
  if ($matchCount -eq 0) { return [double]0 }

  $transpositions = 0
  $k = 0
  for ($i = 0; $i -lt $First.Length; $i++) {
    if (-not $firstMatched[$i]) { continue }
    while (-not $secondMatched[$k]) { $k++ }
    if ($First[$i] -cne $Second[$k]) { $transpositions++ }
    $k++
  }

  $m = [double]$matchCount
  $jaro = ($m / $First.Length + $m / $Second.Length + ($m - [Math]::Floor($transpositions / 2)) / $m) / 3

  $prefix = 0
  $limit = [Math]::Min(4, [Math]::Min($First.Length, $Second.Length))
  while ($prefix -lt $limit -and $First[$prefix] -ceq $Second[$prefix]) { $prefix++ }

  [double]($jaro + $prefix * 0.1 * (1 - $jaro))
}

$script:CanceledPattern = '(?i)\b(cancell?ed)\b'

# Words that say nothing about which event it is, and short forms that sources spell both ways.
$script:TitleStopWords = [Collections.Generic.HashSet[string]]::new([string[]]@(
    'a', 'an', 'and', 'at', 'by', 'event', 'feat', 'featuring', 'for', 'ft', 'game', 'in', 'live', 'night', 'of',
    'on', 'presents', 'show', 'the', 'to', 'tour', 'v', 'vs', 'w', 'with'
  ))
$script:TitleExpansions = @{
  bsu = 'boise state university'
  nnu = 'northwest nazarene university'
}

function Test-TvCanceledTitle {
  # True for titles like "CANCELED - Play and Learn" or "CANCELLED Ping-Pong Club".
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Title)

  $Title -match $script:CanceledPattern
}

function Get-TvMatchTitle {
  # The normalized title with any "canceled" marker removed, so a cancellation still matches its listing.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Title)

  ((Get-NormalizedTitle $Title) -replace '\bcancell?ed\b', ' ' -replace '\s+', ' ').Trim()
}

function Get-TvTitleWords {
  # The distinct words that identify an event, from a title already passed through Get-TvMatchTitle.
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$MatchTitle)

  $words = [Collections.Generic.HashSet[string]]::new()
  foreach ($word in ($MatchTitle -split ' ')) {
    if (-not $word) { continue }
    $parts = if ($script:TitleExpansions.ContainsKey($word)) { $script:TitleExpansions[$word] -split ' ' } else { @($word) }
    foreach ($part in $parts) {
      if (-not $script:TitleStopWords.Contains($part)) { $null = $words.Add($part) }
    }
  }
  , $words
}

function Test-TvSameTitleWords {
  <#
  .SYNOPSIS
    True when two titles name the same event in different words.
  .DESCRIPTION
    Either the shorter title's words all appear in the longer one, or they share at least two words
    and those cover at least 60% of the shorter title. "Jo Koy" matches "Jo Koy (12 and Over)";
    "Family Storytime" does not match "Toddler Storytime".
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$First,
    [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$Second
  )

  $shorter = [Math]::Min($First.Count, $Second.Count)
  if ($shorter -eq 0) { return $false }
  $shared = 0
  foreach ($word in $First) { if ($Second.Contains($word)) { $shared++ } }
  if ($shared -eq $shorter) { return $true }
  ($shared -ge 2) -and ($shared / $shorter -ge 0.6)
}

function Get-TvEventRank {
  # The best (lowest) priority among the sources that reported the event.
  param(
    [object]$Event,
    [hashtable]$Priorities
  )

  $ranks = @($Event.sources | ForEach-Object {
      if ($Priorities.ContainsKey($_.name)) { $Priorities[$_.name] } else { 50 }
    })
  if ($ranks.Count -eq 0) { return 50 }
  ($ranks | Measure-Object -Minimum).Minimum
}

function Merge-TvEvents {
  <#
  .SYNOPSIS
    Collapses events that describe the same thing.
  .DESCRIPTION
    Two events at the same venueKey are the same if:
    - their ids match, or
    - their normalized titles have Jaro-Winkler similarity above 0.9 and they start within 30 minutes, or
    - they start at the same minute, no source reported both, and their titles share their
      identifying words (Test-TvSameTitleWords). This catches "Jo Koy" against
      "Jo Koy - Koy Meets World Tour", and "BSU Women's Basketball Game" against
      "Boise State University Women's Basketball vs Portland State".
    Two multi-day events (ending on a later day than they start) are also the same, at any venueKey
    and start time, if they have the same normalized title, the same known city (not Other), the same
    start day, and no source reported both. Sources disagree on a festival's opening time and
    building more than on a show's ("Festival of Trees" at 6:30 AM in the Horse Park and at noon
    in the Arena), and the title, city, and dates are enough to tell multi-day events apart.
    A "canceled" marker in a title is ignored for matching, so a cancellation finds its listing.

    The event from the best-priority source supplies the url and other fields (between sources
    of equal priority, the one earlier in the input; refine passes them in sources.json order), the longest
    description wins, tags are unioned, and sources are unioned by name. When two reports from one source
    disagree on fetchedAt, the earliest is kept so a re-run doesn't change stored data.
  .PARAMETER Priorities
    Source name to priority. Lower is better, and sources not listed count as 50.
  .PARAMETER DropCanceled
    Leave out every merged event that any source reported as canceled.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]
    [AllowEmptyCollection()]
    [object[]]$Events,

    [hashtable]$Priorities = @{},

    [switch]$DropCanceled
  )

  $ordered = $Events |
    Select-Object @{ n = 'Event'; e = { $_ } }, @{ n = 'Rank'; e = { Get-TvEventRank $_ $Priorities } }, @{ n = 'Instant'; e = { Get-TvEventInstant $_.start } } |
    Sort-Object Rank, Instant, @{ e = { $_.Event.id } } -Stable

  $kept = [System.Collections.Generic.List[object]]::new()
  $byId = @{}
  $bySlot = @{}
  $slotTicks = [TimeSpan]::FromMinutes(30).Ticks
  # Multi-day events by "city|start day|title", for the multi-day rule.
  $byDays = @{}

  foreach ($entry in $ordered) {
    $event = $entry.Event
    $title = Get-TvMatchTitle $event.title
    $words = Get-TvTitleWords $title
    $canceled = Test-TvCanceledTitle $event.title
    $sourceNames = @($event.sources | ForEach-Object name)
    $slot = [Math]::Floor($entry.Instant.UtcTicks / $slotTicks)

    $match = $byId[$event.id]
    if (-not $match) {
      # Anything within 30 minutes lands in this slot or a neighbor, so a busy venue stays cheap.
      $sameMinute = $null
      :search foreach ($neighbor in ($slot - 1), $slot, ($slot + 1)) {
        foreach ($candidate in @($bySlot["$($event.venueKey)|$neighbor"])) {
          if (-not $candidate) { continue }
          $gap = [Math]::Abs(($candidate.Instant - $entry.Instant).TotalMinutes)
          if ($gap -le 30 -and (Get-JaroWinkler $title $candidate.Title) -gt 0.9) {
            $match = $candidate
            break search
          }
          # One source listing two things at the same minute means two things, so only cross-source.
          if (-not $sameMinute -and $gap -lt 1 -and
            -not @($candidate.Event.sources | Where-Object { $_.name -in $sourceNames }) -and
            @($candidate.WordSets | Where-Object { Test-TvSameTitleWords $words $_ })) {
            $sameMinute = $candidate
          }
        }
      }
      if (-not $match) { $match = $sameMinute }
    }

    $daysKey = $null
    if ($event.city -and $event.city -ne 'Other' -and $event.end -and
      $event.end.Substring(0, 10) -gt $event.start.Substring(0, 10)) {
      $daysKey = "$($event.city)|$($event.start.Substring(0, 10))|$title"
      if (-not $match) {
        $match = @($byDays[$daysKey]) | Where-Object {
          $_ -and -not @($_.Event.sources | Where-Object { $_.name -in $sourceNames })
        } | Select-Object -First 1
      }
    }

    if ($match) {
      if ($canceled) { $match.Canceled = $true }
      $match.WordSets.Add($words)
      $target = $match.Event
      if ("$($event.description)".Length -gt "$($target.description)".Length) {
        $target | Add-Member -NotePropertyName description -NotePropertyValue $event.description -Force
      }
      # Real price data from any duplicate beats none. The best source's own tier stays.
      if ($event.costTier -and -not $target.costTier) {
        $target | Add-Member -NotePropertyName costTier -NotePropertyValue $event.costTier -Force
      }
      # A timed end doesn't fit an all-day event, or the other way around.
      if ($event.end -and -not $target.end -and $event.allDay -eq $target.allDay) {
        $target | Add-Member -NotePropertyName end -NotePropertyValue $event.end -Force
      }

      [string[]]$tags = @(@($target.tags) + @($event.tags) | Where-Object { $_ } | Select-Object -Unique)
      [Array]::Sort($tags, [StringComparer]::Ordinal)
      $target.tags = $tags

      $union = @{}
      foreach ($source in (@($target.sources) + @($event.sources))) {
        $seen = $union[$source.name]
        if (-not $seen -or [string]$source.fetchedAt -lt [string]$seen.fetchedAt) {
          $union[$source.name] = $source
        }
      }
      $target.sources = @($union.Keys | Sort-Object | ForEach-Object { $union[$_] })
      $byId[$event.id] = $match
      continue
    }

    $copy = $event | Select-Object *
    $copy.sources = @($event.sources)
    $record = [pscustomobject]@{ Event = $copy; Title = $title; WordSets = [Collections.Generic.List[object]]::new(@(, $words)); Instant = $entry.Instant; Canceled = $canceled }
    $kept.Add($record)
    $byId[$event.id] = $record
    $slotKey = "$($event.venueKey)|$slot"
    if (-not $bySlot.ContainsKey($slotKey)) {
      $bySlot[$slotKey] = [System.Collections.Generic.List[object]]::new()
    }
    $bySlot[$slotKey].Add($record)
    if ($daysKey) {
      if (-not $byDays.ContainsKey($daysKey)) {
        $byDays[$daysKey] = [System.Collections.Generic.List[object]]::new()
      }
      $byDays[$daysKey].Add($record)
    }
  }

  $kept | Where-Object { -not ($DropCanceled -and $_.Canceled) } | ForEach-Object { $_.Event }
}
