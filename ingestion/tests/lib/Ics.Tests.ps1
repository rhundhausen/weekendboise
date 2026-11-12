BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/Ics.ps1"

  function New-Calendar {
    param([string[]]$Lines)
    (@('BEGIN:VCALENDAR', 'VERSION:2.0', 'BEGIN:VEVENT') + $Lines + @('END:VEVENT', 'END:VCALENDAR')) -join "`r`n"
  }
}

Describe 'ConvertFrom-Ics' {
  It 'reads a TZID start and end' {
    $event = ConvertFrom-Ics (New-Calendar @(
        'SUMMARY:Rush @ Steelheads'
        'DTSTART;TZID=America/Denver:20261104T191000'
        'DTEND;TZID=America/Denver:20261104T221000'
      ))
    $event.Start | Should -Be '2026-11-04T19:10:00-07:00'
    $event.End | Should -Be '2026-11-04T22:10:00-07:00'
    $event.AllDay | Should -BeFalse
  }

  It 'converts a TZID in another zone' {
    (ConvertFrom-Ics (New-Calendar @('DTSTART;TZID=America/New_York:20261104T210000'))).Start | Should -Be '2026-11-04T19:00:00-07:00'
  }

  It 'accepts a quoted TZID' {
    (ConvertFrom-Ics (New-Calendar @('DTSTART;TZID="America/Denver":20261104T191000'))).Start | Should -Be '2026-11-04T19:10:00-07:00'
  }

  It 'reads a UTC start' {
    (ConvertFrom-Ics (New-Calendar @('DTSTART:20261030T010000Z'))).Start | Should -Be '2026-10-29T19:00:00-06:00'
  }

  It 'reads a floating start as Boise time' {
    (ConvertFrom-Ics (New-Calendar @('DTSTART:20261104T191000'))).Start | Should -Be '2026-11-04T19:10:00-07:00'
  }

  It 'falls back to Boise time on an unknown TZID' {
    $event = ConvertFrom-Ics (New-Calendar @('DTSTART;TZID=Not/AZone:20261104T191000')) -WarningVariable warnings -WarningAction SilentlyContinue
    $event.Start | Should -Be '2026-11-04T19:10:00-07:00'
    $warnings | Should -Not -BeNullOrEmpty
  }

  It 'reads an all-day start' {
    $event = ConvertFrom-Ics (New-Calendar @('DTSTART;VALUE=DATE:20261101'))
    $event.Start | Should -Be '2026-11-01'
    $event.AllDay | Should -BeTrue
    $event.End | Should -BeNullOrEmpty
  }

  It 'makes an exclusive all-day end inclusive' {
    $event = ConvertFrom-Ics (New-Calendar @('DTSTART;VALUE=DATE:20261001', 'DTEND;VALUE=DATE:20261004'))
    $event.End | Should -Be '2026-10-03'
  }

  It 'omits the end of a one-day all-day event' {
    (ConvertFrom-Ics (New-Calendar @('DTSTART;VALUE=DATE:20261001', 'DTEND;VALUE=DATE:20261002'))).End | Should -BeNullOrEmpty
  }

  It 'unfolds lines continued with a space or a tab' {
    $event = ConvertFrom-Ics (New-Calendar @('SUMMARY:One long', ' er title', "`there", 'DTSTART:20261030T010000Z'))
    $event.Summary | Should -Be 'One longer titlehere'
  }

  It 'accepts LF line endings' {
    $text = (New-Calendar @('SUMMARY:Show', 'DTSTART:20261030T010000Z')) -replace "`r`n", "`n"
    (ConvertFrom-Ics $text).Summary | Should -Be 'Show'
  }

  It 'unescapes text' {
    $event = ConvertFrom-Ics (New-Calendar @(
        'SUMMARY:Fish\, chips\; peas'
        'DESCRIPTION:Line one\nLine two\NLine three'
        'LOCATION:Boise\, Idaho'
        'DTSTART:20261030T010000Z'
      ))
    $event.Summary | Should -Be 'Fish, chips; peas'
    $event.Description | Should -Be "Line one`nLine two`nLine three"
    $event.Location | Should -Be 'Boise, Idaho'
  }

  It 'keeps an escaped backslash from starting an escape' {
    (ConvertFrom-Ics (New-Calendar @('SUMMARY:C:\\new', 'DTSTART:20261030T010000Z'))).Summary | Should -Be 'C:\new'
  }

  It 'keeps colons in a value' {
    (ConvertFrom-Ics (New-Calendar @('URL;VALUE=URI:https://x.test/a?b=1', 'DTSTART:20261030T010000Z'))).Url | Should -Be 'https://x.test/a?b=1'
  }

  It 'takes a Trumba event link when there is no URL' {
    $lines = @('DTSTART:20261030T010000Z', 'X-TRUMBA-LINK:https://cwi.test/events?trumbaEmbed=view%3Devent%26eventid%3D1')
    (ConvertFrom-Ics (New-Calendar $lines)).Url | Should -Be 'https://cwi.test/events?trumbaEmbed=view%3Devent%26eventid%3D1'
  }

  It 'prefers URL over a Trumba event link' {
    $lines = @('DTSTART:20261030T010000Z', 'URL:https://x.test/a', 'X-TRUMBA-LINK:https://cwi.test/b')
    (ConvertFrom-Ics (New-Calendar $lines)).Url | Should -Be 'https://x.test/a'
  }

  It 'warns on RRULE and keeps the first occurrence' {
    $event = ConvertFrom-Ics (New-Calendar @('SUMMARY:Weekly', 'DTSTART:20261030T010000Z', 'RRULE:FREQ=WEEKLY')) -WarningVariable warnings -WarningAction SilentlyContinue
    @($event).Count | Should -Be 1
    "$warnings" | Should -Match 'RRULE'
  }

  It 'skips a VEVENT with no start' {
    @(ConvertFrom-Ics (New-Calendar @('SUMMARY:Broken')) -WarningAction SilentlyContinue).Count | Should -Be 0
  }

  It 'ignores properties outside VEVENT' {
    $text = "BEGIN:VCALENDAR`r`nSUMMARY:Calendar title`r`nEND:VCALENDAR"
    @(ConvertFrom-Ics $text).Count | Should -Be 0
  }

  It 'reads several events' {
    $text = @(
      'BEGIN:VCALENDAR'
      'BEGIN:VEVENT', 'SUMMARY:One', 'DTSTART:20261030T010000Z', 'END:VEVENT'
      'BEGIN:VEVENT', 'SUMMARY:Two', 'DTSTART:20261031T010000Z', 'END:VEVENT'
      'END:VCALENDAR'
    ) -join "`r`n"
    (ConvertFrom-Ics $text).Summary | Should -Be @('One', 'Two')
  }
}
