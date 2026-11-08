#Requires -Version 7.4
<#
.SYNOPSIS
  Emails the weekly reminder to run the local sources from a home connection. Run from the repo root.
.DESCRIPTION
  Some sites turn away or time out on GitHub's servers but load from a home connection. Those
  sources are marked local in sources.json; the nightly ingest skips them and keeps their last
  fetch. The scheduled ingest at midnight Sunday, Boise time, calls this script, which emails
  REPORT_EMAIL a reminder with each local source's last fetch and how to run
  Invoke-LocalIngest.ps1. Any other run, or a week with no local sources, sends nothing.

  Like Send-Report.ps1, the address and key come from environment variables (repository
  secrets), so the address stays out of this public repo.
.PARAMETER At
  The run's scheduled time in UTC. Defaults to SCHEDULED_AT, then the current time.
.PARAMETER Trigger
  What started the run. Only schedule sends. Defaults to EVENT.
.PARAMETER Force
  Send whatever the day and trigger, to try it out.
.PARAMETER PreviewPath
  Also write the email to <PreviewPath>.txt and <PreviewPath>.html.
#>
[CmdletBinding()]
param(
  [string]$At = $(if ($env:SCHEDULED_AT) { $env:SCHEDULED_AT } else { [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }),
  [string]$Trigger = $env:EVENT,
  [switch]$Force,
  [string]$RunUrl = $env:RUN_URL,
  [string]$SourcesPath = (Join-Path $PSScriptRoot '..' 'sources.json'),
  [string]$RawPath = (Join-Path $PSScriptRoot '..' '..' 'data' 'raw-events.json'),
  [string]$PreviewPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib' 'Report.ps1')
. (Join-Path $PSScriptRoot 'lib' 'Raw.ps1')

if (-not $Force -and ($Trigger -ne 'schedule' -or -not (Test-TvReminderDay $At))) {
  Write-Host 'Not the scheduled Sunday run, so no local ingest reminder'
  exit 0
}

$sources = @((Get-Content -LiteralPath $SourcesPath -Raw | ConvertFrom-Json -DateKind String).sources)
if (-not @($sources | Where-Object { $_.status -eq 'running' -and $_.local }).Count) {
  Write-Host 'No running local sources, so no reminder'
  exit 0
}
$raw = Read-TvRawFile ([IO.Path]::GetFullPath($RawPath, $PWD.Path))
$reminder = New-TvLocalReminder -Sources $sources -Raw $raw -RunUrl $RunUrl

if ($PreviewPath) {
  [IO.File]::WriteAllText("$PreviewPath.txt", $reminder.Text)
  [IO.File]::WriteAllText("$PreviewPath.html", $reminder.Html)
  Write-Host "Reminder preview: $PreviewPath.txt and $PreviewPath.html"
}

if (-not $env:RESEND_API_KEY -or -not $env:REPORT_EMAIL) {
  Write-Warning 'RESEND_API_KEY or REPORT_EMAIL is not set, so the reminder was not emailed'
  exit 0
}
$sent = Send-TvReport -Report $reminder -To $env:REPORT_EMAIL -ApiKey $env:RESEND_API_KEY
Write-Host "Emailed '$($reminder.Subject)' (Resend id $($sent.id))"
