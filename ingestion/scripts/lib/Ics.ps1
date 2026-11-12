# Minimal iCalendar (RFC 5545) reader: VEVENT blocks only.

. "$PSScriptRoot/Schema.ps1"

function ConvertFrom-IcsText {
  # Undoes RFC 5545 text escaping in one pass, so an escaped backslash can't start a new escape.
  param([string]$Text)

  [regex]::Replace($Text, '\\([\\,;nN])', {
      param($match)
      $char = $match.Groups[1].Value
      if ($char -ieq 'n') { "`n" } else { $char }
    })
}

function ConvertFrom-IcsDate {
  # Returns @{ Value; AllDay } with Value in the same form as an event start.
  param(
    [string]$Value,
    [hashtable]$Parameters
  )

  $invariant = [Globalization.CultureInfo]::InvariantCulture
  $none = [Globalization.DateTimeStyles]::None

  if ($Parameters['VALUE'] -eq 'DATE' -or $Value -match '^\d{8}$') {
    $date = [DateTime]::ParseExact($Value.Substring(0, 8), 'yyyyMMdd', $invariant, $none)
    return @{ Value = $date.ToString('yyyy-MM-dd', $invariant); AllDay = $true }
  }

  $local = [DateTime]::ParseExact($Value.TrimEnd('Z'), "yyyyMMdd'T'HHmmss", $invariant, $none)
  if ($Value.EndsWith('Z')) {
    return @{ Value = ConvertTo-BoiseTime ([DateTime]::SpecifyKind($local, [DateTimeKind]::Utc)); AllDay = $false }
  }

  $zone = $Parameters['TZID']
  if ($zone) {
    try {
      $null = [TimeZoneInfo]::FindSystemTimeZoneById($zone)
    } catch {
      Write-Warning "Unknown TZID '$zone', treating the time as America/Boise"
      $zone = $null
    }
  }
  @{ Value = ConvertTo-BoiseTime $local $zone; AllDay = $false }
}

function ConvertFrom-Ics {
  <#
  .SYNOPSIS
    Parses iCalendar text into one object per VEVENT.
  .DESCRIPTION
    Handles line folding, DTSTART;VALUE=DATE, DTSTART;TZID=, the UTC Z suffix, and escaped text.
    RRULE is ignored with a warning, so a recurring event yields only its first occurrence.
    Start and End are in the same form as an event's start: ISO 8601 with the Boise offset, or
    YYYY-MM-DD when AllDay is true. An all-day End is inclusive, and is omitted for a single day.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
    [AllowEmptyString()]
    [string]$Text
  )

  process {
    $unfolded = $Text -replace '\r?\n[ \t]', ''
    $lineRegex = '^(?<name>[A-Za-z0-9-]+)(?<params>(;[A-Za-z0-9-]+=("[^"]*"|[^;:"]*))*):(?<value>.*)$'
    $current = $null

    foreach ($line in ($unfolded -split '\r?\n')) {
      if ($line -eq 'BEGIN:VEVENT') {
        $current = @{}
        continue
      }
      if ($null -eq $current) { continue }

      if ($line -eq 'END:VEVENT') {
        $start = if ($current['DTSTART']) { ConvertFrom-IcsDate $current['DTSTART'].Value $current['DTSTART'].Parameters }
        if (-not $start) {
          Write-Warning "Skipping VEVENT with no DTSTART: $($current['SUMMARY'].Value)"
          $current = $null
          continue
        }

        $end = if ($current['DTEND']) { ConvertFrom-IcsDate $current['DTEND'].Value $current['DTEND'].Parameters }
        $endValue = if ($end) { $end.Value }
        if ($end -and $start.AllDay -and $end.AllDay) {
          # DTEND is exclusive for all-day events.
          $endValue = ([DateTime]::ParseExact($end.Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)).AddDays(-1).ToString('yyyy-MM-dd')
          if ($endValue -le $start.Value) { $endValue = $null }
        }

        $summary = ConvertFrom-IcsText $current['SUMMARY'].Value
        # Trumba feeds (CWI) give each event's page as X-TRUMBA-LINK instead of URL.
        $urlProperty = if ($current['URL']) { $current['URL'] } else { $current['X-TRUMBA-LINK'] }
        if ($current.ContainsKey('RRULE')) {
          Write-Warning "Ignoring RRULE on '$summary', using its first occurrence only"
        }

        [pscustomobject]@{
          Uid         = ConvertFrom-IcsText $current['UID'].Value
          Summary     = $summary
          Description = ConvertFrom-IcsText $current['DESCRIPTION'].Value
          Location    = ConvertFrom-IcsText $current['LOCATION'].Value
          Url         = ConvertFrom-IcsText $urlProperty.Value
          Categories  = ConvertFrom-IcsText $current['CATEGORIES'].Value
          Status      = $current['STATUS'].Value
          Start       = $start.Value
          End         = $endValue
          AllDay      = $start.AllDay
        }
        $current = $null
        continue
      }

      $match = [regex]::Match($line, $lineRegex)
      if (-not $match.Success) { continue }

      $parameters = @{}
      foreach ($parameter in ($match.Groups['params'].Value -split ';' | Where-Object { $_ })) {
        $pair = $parameter -split '=', 2
        $parameters[$pair[0].ToUpperInvariant()] = $pair[1].Trim('"')
      }
      $current[$match.Groups['name'].Value.ToUpperInvariant()] = @{ Value = $match.Groups['value'].Value; Parameters = $parameters }
    }
  }
}
