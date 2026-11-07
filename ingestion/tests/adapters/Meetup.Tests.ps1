BeforeAll {
  $script:repo = Join-Path $PSScriptRoot '..' '..'
  $script:adapter = Join-Path $repo 'scripts' 'adapters' 'meetup.ps1'
  $script:fetchedAt = '2026-11-06T10:00:00Z'
  . (Join-Path $repo 'scripts' 'lib' 'Raw.ps1')

  $script:source = [pscustomobject]@{
    name = 'meetup-board-games'; displayName = 'Adult Board Game Night (Meetup)'; adapter = 'meetup'; status = 'running'
    url = 'https://www.meetup.com/adult-board-game-night/events/ical/'; category = 'nightlife-social'; inferCategory = $true
    city = 'Boise'; venue = 'Adult Board Game Night'; venueKey = 'meetup-board-games'
  }

  function New-VEvent([string]$Id, [string]$Start, [string]$Summary, [string]$Status = 'CONFIRMED') {
    @(
      'BEGIN:VEVENT'
      "UID:event_$Id@meetup.com"
      "DTSTART;TZID=America/Denver:$Start"
      "SUMMARY:$Summary"
      'DESCRIPTION:Adult Board Game Night\nBring a game\, or play one of ours.'
      "URL;VALUE=URI:https://www.meetup.com/adult-board-game-night/events/$Id/"
      "STATUS:$Status"
      'END:VEVENT'
    ) -join "`r`n"
  }

  function New-Page([string]$Place, [string]$City, [string]$Mode = 'Offline') {
    $node = @{
      '@context' = 'https://schema.org'; '@type' = 'Event'; name = 'x'; startDate = '2026-11-11T18:00:00-07:00'
      eventAttendanceMode = "https://schema.org/${Mode}EventAttendanceMode"
      location = @{ '@type' = 'Place'; name = $Place; address = @{ '@type' = 'PostalAddress'; addressLocality = $City; addressRegion = 'ID' } }
    } | ConvertTo-Json -Depth 5
    "<html><head><script type=`"application/ld+json`">$node</script></head><body>event</body></html>"
  }

  $script:feed = @(
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Meetup//Meetup Calendar 1.0//EN', 'X-WR-CALNAME:Adult Board Game Night'
    (New-VEvent '1' '20261111T180000' 'Meridian Board Game Night @ Yogurtz!')
    (New-VEvent '2' '20261101T180000' 'Last Week')
    (New-VEvent '3' '20261112T180000' 'Called Off' 'CANCELLED')
    (New-VEvent '4' '20261113T180000' 'Online Game Night')
    (New-VEvent '5' '20261114T180000' 'Portland Trip')
    (New-VEvent '6' '20261115T180000' 'Known Night')
    'END:VCALENDAR'
  ) -join "`r`n"

  # Event 6 is already in the raw file from an earlier night, so its page is not read again.
  $script:rawPath = Join-Path $TestDrive 'raw-events.json'
  $known = New-TvEvent -Title 'Known Night' -Start '2026-11-15T18:00:00-07:00' -Venue 'Eagle Library' -City 'Eagle' -Category 'nightlife-social' `
    -Url 'https://www.meetup.com/adult-board-game-night/events/6/' -Sources @(@{ name = 'meetup-board-games'; url = 'https://www.meetup.com/adult-board-game-night/events/6/'; fetchedAt = '2026-11-05T10:00:00Z' })
  $raw = Update-TvRawFile $null -Results @([pscustomobject]@{ Name = 'meetup-board-games'; Status = 'ok'; Events = @($known) }) -Keep @('meetup-board-games') -AsOf '2026-11-05T07:00:00Z' -FetchedAt '2026-11-05T10:00:00Z'
  Write-TvRawFile $rawPath $raw

  # Pages in the order the adapter should ask for them: only events 1, 4, and 5.
  $script:pages = @((New-Page 'Yogurtz Grill' 'Meridian'), (New-Page 'Online event' '' 'Online'), (New-Page 'Powell''s' 'Portland'))
  $script:events = @(& $adapter -Source $source -FetchedAt $fetchedAt -Response (@($feed) + $pages) -RawPath $rawPath -WarningAction SilentlyContinue)
}

Describe 'meetup adapter' {
  It 'keeps in-area events and drops past, canceled, online, and out-of-area ones' {
    @($events.title | Sort-Object) | Should -Be @('Known Night', 'Meridian Board Game Night @ Yogurtz!')
  }

  It 'takes the venue and city from the event page' {
    $e = $events | Where-Object title -like 'Meridian*'
    $e.venue | Should -Be 'Yogurtz Grill'
    $e.city | Should -Be 'Meridian'
    $e.start | Should -Be '2026-11-11T18:00:00-07:00'
    $e.url | Should -Be 'https://www.meetup.com/adult-board-game-night/events/1/'
  }

  It 'reuses the venue and city already in the raw file, without reading the page again' {
    $e = $events | Where-Object title -eq 'Known Night'
    $e.venue | Should -Be 'Eagle Library'
    $e.city | Should -Be 'Eagle'
  }

  It 'tags each event with the group''s source name' {
    @($events | ForEach-Object { $_.sources[0].name } | Select-Object -Unique) | Should -Be @('meetup-board-games')
  }

  It 'drops the group name Meetup puts at the start of each description' {
    ($events | Where-Object title -like 'Meridian*').description | Should -BeLike 'Bring a game, or play one of ours.*'
  }

  It 'skips an event whose page can''t be read, and keeps the rest' {
    $short = @(& $adapter -Source $source -FetchedAt $fetchedAt -Response @($feed, (New-Page 'Yogurtz Grill' 'Meridian')) -RawPath $rawPath -WarningAction SilentlyContinue)
    @($short.title | Sort-Object) | Should -Be @('Known Night', 'Meridian Board Game Night @ Yogurtz!')
  }

  It 'fails when the response is not a calendar' {
    { & $adapter -Source $source -FetchedAt $fetchedAt -Response '<html>sign in</html>' -RawPath $rawPath } | Should -Throw '*not an iCalendar feed*'
  }

  It 'removes Markdown from the description' {
    # Meetup writes descriptions in Markdown and escapes punctuation, then the feed escapes the backslashes.
    $markdown = @(
      'BEGIN:VCALENDAR', 'VERSION:2.0', 'X-WR-CALNAME:Adult Board Game Night'
      'BEGIN:VEVENT', 'UID:event_6@meetup.com', 'DTSTART;TZID=America/Denver:20261115T180000', 'SUMMARY:Known Night'
      'DESCRIPTION:Adult Board Game Night\n**Wednesday\\, November 18 \| 5:30 PM** at 10 Barrel Brewing Co\. We''ve all had *that* client\!'
      'URL;VALUE=URI:https://www.meetup.com/adult-board-game-night/events/6/', 'END:VEVENT', 'END:VCALENDAR'
    ) -join "`r`n"
    $e = @(& $adapter -Source $source -FetchedAt $fetchedAt -Response @($markdown) -RawPath $rawPath)[0]
    $e.description | Should -BeExactly 'Wednesday, November 18 | 5:30 PM at 10 Barrel Brewing Co. We''ve all had that client!'
  }
}
