# The ingest and refine summary emails: built from out/run.json, out/refine.json, and
# out/links.json, and sent with the Resend API. Each report is a list of sections, rendered
# once as plain text and once as HTML so mail clients can pick.

function Format-TvReportTime {
  # An ISO UTC time as Boise time, such as "Nov 7, 2026 12:00:05 AM MST".
  param([string]$Value)

  if (-not $Value) { return '' }
  $utc = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
  $zone = [TimeZoneInfo]::FindSystemTimeZoneById('America/Boise')
  $local = [TimeZoneInfo]::ConvertTimeFromUtc($utc, $zone)
  $abbreviation = if ($zone.IsDaylightSavingTime($local)) { 'MDT' } else { 'MST' }
  "$($local.ToString('MMM d, yyyy h:mm:ss tt', [Globalization.CultureInfo]::InvariantCulture)) $abbreviation"
}

function Format-TvDuration {
  # The time between two ISO times, such as "5m 27s".
  param([string]$Start, [string]$Finish)

  if (-not $Start -or -not $Finish) { return '' }
  $span = [DateTimeOffset]::Parse($Finish, [Globalization.CultureInfo]::InvariantCulture) - [DateTimeOffset]::Parse($Start, [Globalization.CultureInfo]::InvariantCulture)
  if ($span.TotalHours -ge 1) { return '{0}h {1}m' -f [int][Math]::Floor($span.TotalHours), $span.Minutes }
  if ($span.TotalMinutes -ge 1) { return '{0}m {1}s' -f [int][Math]::Floor($span.TotalMinutes), $span.Seconds }
  '{0}s' -f [int]$span.TotalSeconds
}

function New-TvReportSection {
  # Kind is 'pairs' (label and value) or 'table'. Rows are arrays of cells. A cell that is a
  # hashtable with Url renders as a link in HTML. Groups, when given, are sub-headings, each
  # with its own rows.
  param(
    [string]$Title,
    [string]$Kind = 'table',
    [object[]]$Rows = @(),
    [string]$Note,
    [object[]]$Groups = @()
  )
  [pscustomobject]@{ Title = $Title; Kind = $Kind; Rows = @($Rows); Note = $Note; Groups = @($Groups) }
}

function ConvertTo-TvReportText {
  param([string]$Heading, [object[]]$Sections)

  $cellText = { param($cell) if ($cell -is [hashtable]) { "$($cell.Text)" } else { "$cell" } }
  $rowsText = {
    param($section, $rows)
    foreach ($row in $rows) {
      $cells = @($row | ForEach-Object { & $cellText $_ })
      if ($section.Kind -eq 'pairs') { '  {0,-22} {1}' -f $cells[0], $cells[1] }
      elseif ($cells.Count -eq 2) { '  {0,-40} {1}' -f $cells[0], $cells[1] }
      else { '  ' + ($cells -join '  |  ') }
    }
  }

  $lines = [Collections.Generic.List[string]]::new()
  $lines.Add($Heading)
  foreach ($section in $Sections) {
    $lines.Add('')
    $lines.Add("== $($section.Title) ==")
    if ($section.Note) { $lines.Add("  $($section.Note)") }
    foreach ($line in (& $rowsText $section $section.Rows)) { $lines.Add($line) }
    foreach ($group in $section.Groups) {
      $lines.Add("  -- $($group.Title)")
      foreach ($line in (& $rowsText $section $group.Rows)) { $lines.Add("  $line") }
    }
  }
  ($lines -join "`n") + "`n"
}

function ConvertTo-TvReportHtml {
  param([string]$Heading, [object[]]$Sections)

  $encode = { param($text) [Net.WebUtility]::HtmlEncode("$text") }
  $cellHtml = {
    param($cell)
    if ($cell -is [hashtable] -and $cell.Url) { "<a href=`"$(& $encode $cell.Url)`">$(& $encode $cell.Text)</a>" }
    elseif ($cell -is [hashtable]) { & $encode $cell.Text }
    else { & $encode $cell }
  }
  $table = {
    param($section, $rows)
    if (@($rows).Count -eq 0) { return '' }
    $body = foreach ($row in $rows) {
      $cells = @($row | ForEach-Object { & $cellHtml $_ })
      if ($section.Kind -eq 'pairs') { "<tr><th align=`"left`" style=`"padding:2px 12px 2px 0`">$($cells[0])</th><td>$($cells[1])</td></tr>" }
      else { '<tr>' + (($cells | ForEach-Object { "<td style=`"padding:2px 12px 2px 0;vertical-align:top`">$_</td>" }) -join '') + '</tr>' }
    }
    "<table style=`"border-collapse:collapse;font-size:14px`">$($body -join '')</table>"
  }

  $parts = [Collections.Generic.List[string]]::new()
  $parts.Add("<div style=`"font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222`"><h1 style=`"font-size:20px`">$(& $encode $Heading)</h1>")
  foreach ($section in $Sections) {
    $parts.Add("<h2 style=`"font-size:16px;margin:18px 0 6px`">$(& $encode $section.Title)</h2>")
    if ($section.Note) { $parts.Add("<p style=`"margin:4px 0`">$(& $encode $section.Note)</p>") }
    $parts.Add((& $table $section $section.Rows))
    foreach ($group in $section.Groups) {
      $parts.Add("<h3 style=`"font-size:14px;margin:10px 0 4px`">$(& $encode $group.Title)</h3>")
      $parts.Add((& $table $section $group.Rows))
    }
  }
  $parts.Add('</div>')
  $parts -join "`n"
}

function Get-TvSourceLabel {
  # "Display Name (name)", or the name alone when the source isn't known.
  param([string]$Name, [object[]]$Sources)

  $entry = $Sources | Where-Object { $_.name -eq $Name } | Select-Object -First 1
  if ($entry -and $entry.displayName) { "$($entry.displayName) ($Name)" } else { $Name }
}

function Get-TvWaitingSections {
  # The sources that don't run yet, by status, so the report shows what's left to build.
  param([object[]]$Sources)

  $shorten = { param($text) $text = "$text"; if ($text.Length -gt 160) { $text.Substring(0, 157) + '...' } else { $text } }
  $group = {
    # One sub-heading per status: name (linked) and the notes, or the reason for ruled-out ones.
    param([string]$Status, [string]$Title, [string]$Meaning)
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Sources | Where-Object { "$($_.status)" -eq $Status } | Sort-Object displayName)) {
      $detail = if ($Status -eq 'ruled-out') { "$($entry.reason)" } else { & $shorten $entry.notes }
      $rows.Add(@(@{ Text = "$($entry.displayName)"; Url = "$($entry.url)" }, $detail))
    }
    [pscustomobject]@{ Title = "$Title ($($rows.Count)): $Meaning"; Rows = $rows.ToArray(); Count = $rows.Count }
  }
  $ready = & $group 'ready' 'Ready' 'built and tested, not switched on yet'
  $investigating = & $group 'investigating' 'Investigating' 'looked at, but something stands in the way (pages that need JavaScript, blocked scripts, no feed); the notes say what was tried'
  $ideas = & $group '' 'Ideas' 'suggested, not looked at yet'
  $ruledOut = & $group 'ruled-out' 'Ruled out' 'will not be used, for the reason given'
  New-TvReportSection -Title "Not running: $($ready.Count) ready, $($investigating.Count) investigating, $($ideas.Count) ideas, $($ruledOut.Count) ruled out" -Groups @($ready, $investigating, $ideas, $ruledOut)
}

function New-TvIngestReport {
  <#
  .SYNOPSIS
    The ingest summary email: Subject, Text, and Html.
  .PARAMETER Run
    out/run.json, or $null when ingest stopped before writing it.
  .PARAMETER Sources
    Every entry in sources.json.
  .PARAMETER Context
    Outcome (the job status), RunUrl, Trigger, and Source (a one-source run).
  #>
  [CmdletBinding()]
  param(
    [AllowNull()][object]$Run,
    [object[]]$Sources = @(),
    [hashtable]$Context = @{}
  )

  $failedPrefix = if ($Context.Outcome -and $Context.Outcome -ne 'success') { ' FAILED' } else { '' }
  $runLink = @{ Text = "$($Context.RunUrl)"; Url = "$($Context.RunUrl)" }

  if (-not $Run) {
    $sections = @(
      New-TvReportSection -Title 'What happened' -Kind pairs -Rows @(
        , @('Result:', 'Ingest stopped before it wrote run.json, so no source results are available.')
        , @('Attached:', ($Context.Attachment ? "$($Context.Attachment)" : 'none'))
        , @('Workflow run:', $runLink)
      )
    )
    $heading = 'WeekendBoise Ingest FAILED: no run.json'
    return @{ Subject = $heading; Text = ConvertTo-TvReportText $heading $sections; Html = ConvertTo-TvReportHtml $heading $sections }
  }

  $results = @($Run.sources)
  $ok = @($results | Where-Object status -eq 'ok')
  $failed = @($results | Where-Object status -ne 'ok')
  $events = ($results | Measure-Object fetched -Sum).Sum
  $subject = "WeekendBoise Ingest$($failedPrefix): $($ok.Count) of $($results.Count) sources ok, $events events$($failed.Count ? ", $($failed.Count) failed" : '')"
  $pageOf = { param($name) $entry = $Sources | Where-Object name -eq $name | Select-Object -First 1; "$($entry.url)" }

  $trigger = "$($Context.Trigger)"
  if ($Context.Source) { $trigger = "$trigger, source $($Context.Source) only" }
  # run.json files from before startedAt existed have only fetchedAt, the same moment.
  $started = if ($Run.startedAt) { $Run.startedAt } else { $Run.fetchedAt }
  $basics = @(
    , @('Result:', ($Context.Outcome ? "$($Context.Outcome)" : 'unknown'))
    , @('Trigger:', $trigger)
    , @('Started:', (Format-TvReportTime $started))
    , @('Finished:', (Format-TvReportTime $Run.finishedAt))
    , @('Duration:', (Format-TvDuration $started $Run.finishedAt))
    , @('Sources:', "$($ok.Count) ok, $($failed.Count) failed, $events events fetched")
  )
  # Meetup groups are many and often have nothing scheduled, which is normal, so they get one line.
  $meetupNames = @($Sources | Where-Object adapter -eq 'meetup' | ForEach-Object name)
  $meetup = @($results | Where-Object { $_.name -in $meetupNames })
  if ($meetup.Count) {
    $meetupOk = @($meetup | Where-Object status -eq 'ok')
    $basics += , @('Meetup groups:', "$($meetupOk.Count) ok, $(@($meetupOk | Where-Object { $_.fetched -gt 0 }).Count) with events, $(($meetup | Measure-Object fetched -Sum).Sum) events")
  }
  if ($null -ne $Run.rawEvents) {
    $basics += , @('Raw file:', "$($Run.rawSources) sources, $($Run.rawEvents) events, as of $(Format-TvReportTime $Run.asOf)$($Run.noWrite ? ' (not written)' : '')")
  }
  if ($Context.Attachment) { $basics += , @('Attached:', "$($Context.Attachment)") }
  $basics += , @('Workflow run:', $runLink)

  $sections = [Collections.Generic.List[object]]::new()
  $sections.Add((New-TvReportSection -Title 'Run' -Kind pairs -Rows $basics))
  $sections.Add((New-TvReportSection -Title "Failed ($($failed.Count))" -Note ($failed.Count ? 'A failed source keeps its last good events in the raw file.' : 'None.') -Rows @(
        $failed | ForEach-Object { , @((Get-TvSourceLabel $_.name $Sources), @{ Text = (& $pageOf $_.name); Url = (& $pageOf $_.name) }, "$($_.error)") }
      )))
  $warned = @($results | Where-Object { @($_.warnings).Count -gt 0 })
  $sections.Add((New-TvReportSection -Title "Warnings ($(($warned | ForEach-Object { @($_.warnings).Count } | Measure-Object -Sum).Sum ?? 0))" -Note ($warned.Count ? '' : 'None.') -Groups @(
        $warned | ForEach-Object { [pscustomobject]@{ Title = (Get-TvSourceLabel $_.name $Sources); Rows = @($_.warnings | ForEach-Object { , @("$_") }) } }
      )))
  # Most events first, so the sources that returned 0 are at the end. A scraper whose site changed
  # looks like one of those.
  $sections.Add((New-TvReportSection -Title "Succeeded ($($ok.Count))" -Rows @(
        $ok | Sort-Object { -[int]$_.fetched } | ForEach-Object { , @(@{ Text = (Get-TvSourceLabel $_.name $Sources); Url = (& $pageOf $_.name) }, "$($_.fetched) events", "$($_.duration)") }
      )))
  $sections.Add((Get-TvWaitingSections $Sources))

  @{ Subject = $subject; Text = ConvertTo-TvReportText $subject $sections; Html = ConvertTo-TvReportHtml $subject $sections }
}

function New-TvRefineReport {
  <#
  .SYNOPSIS
    The refine summary email: Subject, Text, and Html.
  .PARAMETER Refine
    out/refine.json, or $null when refine stopped before writing it.
  .PARAMETER Links
    out/links.json: checked and broken.
  .PARAMETER Sources
    Every entry in sources.json.
  .PARAMETER Context
    Outcome (the job status), RunUrl, and Trigger.
  #>
  [CmdletBinding()]
  param(
    [AllowNull()][object]$Refine,
    [AllowNull()][object]$Links,
    [object[]]$Sources = @(),
    [hashtable]$Context = @{}
  )

  $failedPrefix = if ($Context.Outcome -and $Context.Outcome -ne 'success') { ' FAILED' } else { '' }
  $runLink = @{ Text = "$($Context.RunUrl)"; Url = "$($Context.RunUrl)" }

  if (-not $Refine) {
    $sections = @(
      New-TvReportSection -Title 'What happened' -Kind pairs -Rows @(
        , @('Result:', 'Refine stopped before it wrote refine.json. The site was not updated.')
        , @('Attached:', ($Context.Attachment ? "$($Context.Attachment)" : 'none'))
        , @('Workflow run:', $runLink)
      )
    )
    $heading = 'WeekendBoise Refine FAILED: no refine.json'
    return @{ Subject = $heading; Text = ConvertTo-TvReportText $heading $sections; Html = ConvertTo-TvReportHtml $heading $sections }
  }

  $subject = "WeekendBoise Refine$($failedPrefix): $($Refine.upcoming) upcoming, $($Refine.links.broken) broken links ($($Refine.links.newBroken) new)"
  $linkLine = if ($Refine.skipLinkCheck) { 'Link check skipped; known link results still applied' } else { "$($Refine.links.checked)" }
  $lookup = $Refine.cityLookup
  $lookupLine = if (-not $lookup) { 'not run' }
  elseif ($lookup.skipped) { "skipped; $($lookup.found) of $($lookup.others) Other events placed from earlier lookups" }
  else { "$($lookup.found) of $($lookup.others) Other events placed, $($lookup.pages) pages read" }
  $basics = @(
    , @('Result:', ($Context.Outcome ? "$($Context.Outcome)" : 'unknown'))
    , @('Trigger:', "$($Context.Trigger)")
    , @('Started:', (Format-TvReportTime $Refine.startedAt))
    , @('Finished:', (Format-TvReportTime $Refine.finishedAt))
    , @('Duration:', (Format-TvDuration $Refine.startedAt $Refine.finishedAt))
    , @('Raw file:', "$($Refine.rawSources) sources, $($Refine.rawEvents) events, as of $(Format-TvReportTime $Refine.asOf)")
    , @('Upcoming published:', "$($Refine.upcoming)")
    , @('Moved to archive:', "$($Refine.past)")
    , @('Cities filled in:', "$($Refine.cityFixes)")
    , @('City lookup:', $lookupLine)
    , @('Cost tiers:', ($Refine.costTiers ? "Free $($Refine.costTiers.free), `$ $($Refine.costTiers.'$'), `$`$ $($Refine.costTiers.'$$'), `$`$`$ $($Refine.costTiers.'$$$'), unknown $($Refine.costTiers.unknown)" : 'not counted'))
    , @('Links checked:', $linkLine)
    , @('Broken links:', "$($Refine.links.broken) ($($Refine.links.newBroken) new)")
  )
  if ($Context.Attachment) { $basics += , @('Attached:', "$($Context.Attachment)") }
  $basics += , @('Workflow run:', $runLink)

  $sections = [Collections.Generic.List[object]]::new()
  $sections.Add((New-TvReportSection -Title 'Run' -Kind pairs -Rows $basics))
  $broken = @($Links.broken)
  $sections.Add((New-TvReportSection -Title "Broken links ($($broken.Count))" -Note ($broken.Count ? 'These events show their title as plain text on the site. NEW means it broke tonight.' : 'None.') -Groups @(
        $broken | Group-Object sources | Sort-Object Name | ForEach-Object {
          [pscustomobject]@{
            Title = "$(Get-TvSourceLabel $_.Name $Sources): $($_.Count)"
            Rows  = @($_.Group | Sort-Object @{ e = { -not $_.new } }, start | ForEach-Object {
                , @("$($_.new ? 'NEW ' : '')$($_.title)".Trim(), "$("$($_.start)".Substring(0, 10))", @{ Text = "$($_.url)"; Url = "$($_.url)" }, "$($_.reason)")
              })
          }
        }
      )))
  $lookupErrors = @($lookup.errors | Where-Object { $_ })
  if ($lookupErrors.Count) {
    $sections.Add((New-TvReportSection -Title "City lookup errors ($($lookupErrors.Count))" -Note 'Pages the city lookup could not read. Their events keep their last known city and are tried again next run.' -Rows @(
          $lookupErrors | ForEach-Object { , @("$_") }
        )))
  }
  $sections.Add((New-TvReportSection -Title 'Upcoming events by category' -Rows @(
        $Refine.categories.PSObject.Properties | ForEach-Object { , @("$($_.Name)", "$($_.Value)") }
      )))
  $sections.Add((New-TvReportSection -Title 'Upcoming events by source' -Note 'An event that several sources list counts for each.' -Rows @(
        $Refine.sources.PSObject.Properties | Sort-Object { -[int]$_.Value } | ForEach-Object { , @((Get-TvSourceLabel $_.Name $Sources), "$($_.Value)") }
      )))

  @{ Subject = $subject; Text = ConvertTo-TvReportText $subject $sections; Html = ConvertTo-TvReportHtml $subject $sections }
}

function Test-TvReminderDay {
  # True when the given UTC time is a Sunday in Boise: the Sunday midnight ingest sends the reminder.
  param([Parameter(Mandatory)][string]$At)

  $utc = [DateTimeOffset]::Parse($At, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
  $local = [TimeZoneInfo]::ConvertTimeFromUtc($utc, [TimeZoneInfo]::FindSystemTimeZoneById('America/Boise'))
  $local.DayOfWeek -eq [DayOfWeek]::Sunday
}

function New-TvLocalReminder {
  <#
  .SYNOPSIS
    The weekly email asking for a local ingest run: Subject, Text, and Html.
  .PARAMETER Sources
    Every entry in sources.json. Only running sources marked local are listed.
  .PARAMETER Raw
    data/raw-events.json, for each local source's last fetch.
  #>
  [CmdletBinding()]
  param(
    [object[]]$Sources = @(),
    [AllowNull()][object]$Raw,
    [string]$RunUrl
  )

  $local = @($Sources | Where-Object { $_.status -eq 'running' -and $_.local } | Sort-Object displayName)
  $subject = "WeekendBoise: run the local ingest this week ($($local.Count) source$($local.Count -eq 1 ? '' : 's'))"
  $rows = [Collections.Generic.List[object]]::new()
  foreach ($entry in $local) {
    $stored = if ($Raw -and $Raw.sources.PSObject.Properties[$entry.name]) { $Raw.sources.($entry.name) }
    $last = if ($stored) { "last fetched $(Format-TvReportTime $stored.fetchedAt)" } else { 'never fetched' }
    $count = if ($stored) { "$(@($stored.events).Count) events" } else { '0 events' }
    $rows.Add(@(@{ Text = (Get-TvSourceLabel $entry.name $Sources); Url = "$($entry.url)" }, $last, $count))
  }
  $actions = 'https://github.com/rhundhausen/weekendboise/actions/workflows/refine.yml'
  $sections = @(
    New-TvReportSection -Title 'What this is for' -Rows @(
      , @("Some sites turn away or time out on requests from GitHub's servers, which run in Microsoft Azure, but load fine from a home connection.")
      , @('The nightly ingest skips these local sources and keeps the events they returned last time, so their listings stay on the site.')
      , @('Running them from your PC once a week picks up their new and changed events. Nothing breaks if you skip a week.')
    )
    New-TvReportSection -Title "Local sources ($($local.Count))" -Rows $rows.ToArray()
    New-TvReportSection -Title 'How to run it' -Rows @(
      , @('1. Open PowerShell 7 in your weekendboise folder.')
      , @('2. Run: ./ingestion/scripts/Invoke-LocalIngest.ps1')
      , @('3. It pulls, runs the local sources, commits data/raw-events.json, and pushes. It takes a minute or two.')
      , @('4. The push starts the refine workflow, which updates the site a few minutes later.')
      , @(@{ Text = "Refine runs: $actions"; Url = $actions })
      , @('If a source fails from home too, the run says so; its last events stay on the site.')
    )
  )
  if ($RunUrl) { $sections += New-TvReportSection -Title 'Sent by' -Kind pairs -Rows @(, @('Ingest run:', @{ Text = $RunUrl; Url = $RunUrl })) }

  @{ Subject = $subject; Text = ConvertTo-TvReportText $subject $sections; Html = ConvertTo-TvReportHtml $subject $sections }
}

function Send-TvReport {
  <#
  .SYNOPSIS
    Sends a report with the Resend API. Returns Resend's response, which has the email id.
  .PARAMETER From
    weekendboise.com is verified in Resend, and the API key is scoped to it.
  .PARAMETER To
    One or more addresses, separated by commas or semicolons. Replies go to the same addresses.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Report,
    [Parameter(Mandatory)][string]$To,
    [Parameter(Mandatory)][string]$ApiKey,
    [string]$From = 'WeekendBoise Reports <reports@weekendboise.com>',
    # Files to attach, each sent base64-encoded under its own name. Resend allows 40 MB per email.
    [string[]]$Attachment
  )

  $recipients = @($To -split '[,;]' | ForEach-Object Trim | Where-Object { $_ })
  $message = [ordered]@{
    from     = $From
    to       = $recipients
    # reports@ has no mailbox, so a reply goes to REPORT_EMAIL instead.
    reply_to = $recipients
    subject  = $Report.Subject
    html     = $Report.Html
    text     = $Report.Text
  }
  $files = @($Attachment | Where-Object { $_ })
  if ($files.Count) {
    $message.attachments = @($files | ForEach-Object {
        @{
          filename = [IO.Path]::GetFileName($_)
          content  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_))
        }
      })
  }
  $body = $message | ConvertTo-Json -Depth 4
  Invoke-RestMethod -Uri 'https://api.resend.com/emails' -Method Post -ContentType 'application/json' `
    -Headers @{ Authorization = "Bearer $ApiKey" } -Body $body -TimeoutSec 30
}
