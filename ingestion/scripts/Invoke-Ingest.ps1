#Requires -Version 7.4
<#
.SYNOPSIS
  Fetches every running source and writes data/raw-events.json. Stage 1 of 2.
.DESCRIPTION
  Runs the entries in sources.json whose status is running, and stores what each adapter returned
  in the raw file, one entry per source. That is all it does: merging, cost guesses, cities, the
  link check, and the files the site reads are Invoke-Refine.ps1's job, which the refine workflow runs as soon as ingest finishes.

  One broken source logs a warning and keeps its last good entry in the raw file, so refine still
  sees its events. The run exits non-zero only if zero sources succeed, and then writes nothing.
  Each run writes run.json to OutDir: per source, the count, status, error, and warnings.

  The raw file's asOf is the time the site shows as the last update. Refine copies it into
  data/meta.json.
.PARAMETER Source
  Run only this source, by name. Any configured entry can be run this way, whatever its status.
  Its entry in the raw file is replaced and every other entry, and asOf, are left as they are.
.PARAMETER OutDir
  Where per-source raw output goes, as <name>.json, plus run.json.
.PARAMETER Local
  Run only the running sources marked local: sites that turn away GitHub's servers but load from a
  home connection. A normal run skips them and keeps their last fetch. Like -Source, it replaces
  only their entries and keeps asOf. Invoke-LocalIngest.ps1 wraps it.
.PARAMETER NoWrite
  Fetch and report, but don't write the raw file.
.PARAMETER AsOf
  The UTC time to record as asOf, as yyyy-MM-ddTHH:mm:ssZ. The nightly workflow passes the
  scheduled midnight, because GitHub often starts scheduled runs late. Defaults to the time the
  run started. A -Source run keeps the raw file's asOf. Event fetchedAt times always use the real
  time.
.PARAMETER RawPath
  The raw file. Defaults to data/raw-events.json.
.PARAMETER SourcesPath
  The sources file. Defaults to sources.json in the ingestion root. Used by tests.
.PARAMETER AdapterDir
  Where the adapter scripts are. Used by tests.
#>
[CmdletBinding()]
param(
  [string]$Source,
  [string]$OutDir = './out',
  [switch]$NoWrite,
  [switch]$Local,
  [ValidatePattern('^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')][string]$AsOf,
  [string]$RawPath = (Join-Path $PSScriptRoot '..' '..' 'data' 'raw-events.json'),
  [string]$SourcesPath = (Join-Path $PSScriptRoot '..' 'sources.json'),
  [string]$AdapterDir = (Join-Path $PSScriptRoot 'adapters')
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'Raw.ps1')

$rawFile = [IO.Path]::GetFullPath($RawPath, $PWD.Path)
$outPath = [IO.Path]::GetFullPath($OutDir, $PWD.Path)

$global:LASTEXITCODE = 0
& (Join-Path $PSScriptRoot 'Test-Sources.ps1') -Path $SourcesPath
if ($LASTEXITCODE -ne 0) { exit 1 }

$allSources = @((Get-Content -LiteralPath $SourcesPath -Raw | ConvertFrom-TvJson).sources)
$running = @($allSources | Where-Object { $_.status -eq 'running' })

$selected = if ($Source) {
  @($allSources | Where-Object { $_.name -and $_.name -eq $Source })
} else {
  # Local sources run only with -Local, from a home connection; a normal run keeps their last fetch.
  @($running | Where-Object { [bool]$_.local -eq [bool]$Local })
}
foreach ($entry in $selected | Where-Object { $_.status -ne 'running' }) {
  Write-Warning "$($entry.name): status is $($entry.status ? $entry.status : 'idea'), running it because it was asked for by name"
}
if ($selected.Count -eq 0) {
  Write-Host "No source to run$($Source ? " named '$Source'" : '')"
  exit 1
}

$now = [DateTimeOffset]::UtcNow
$fetchedAt = $now.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
$results = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $selected) {
  $timer = [Diagnostics.Stopwatch]::StartNew()
  $status = 'ok'
  $events = @()
  $errorText = $null
  $adapterWarnings = $null
  try {
    $events = @(& (Join-Path $AdapterDir "$($entry.adapter).ps1") -Source $entry -FetchedAt $fetchedAt -WarningVariable adapterWarnings)
    Write-TvEventFile (Join-Path $outPath "$($entry.name).json") $events
  } catch {
    $status = 'failed'
    $events = @()
    $errorText = Hide-TvSecret "$_"
    Write-Warning "$($entry.name): $errorText"
  }
  $results.Add([pscustomobject]@{
      Name     = $entry.name
      Fetched  = $events.Count
      Status   = $status
      Duration = '{0:n1}s' -f $timer.Elapsed.TotalSeconds
      Warnings = @($adapterWarnings | ForEach-Object { Hide-TvSecret "$_" })
      Error    = $errorText
      Events   = $events
    })
}

$null = New-Item -ItemType Directory -Force -Path $outPath
$stamp = { [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
$writeLog = { [IO.File]::WriteAllText((Join-Path $outPath 'run.json'), (($log | ConvertTo-Json -Depth 5) -replace "`r`n", "`n") + "`n") }
# startedAt and finishedAt are for the report email. The raw file totals are added at the end.
$log = [ordered]@{
  startedAt  = $fetchedAt
  finishedAt = & $stamp
  fetchedAt  = $fetchedAt
  noWrite    = [bool]$NoWrite
  sources   = @($results | ForEach-Object {
      [ordered]@{
        name     = $_.Name
        status   = $_.Status
        fetched  = $_.Fetched
        duration = $_.Duration
        error    = $_.Error
        warnings = @($_.Warnings)
      }
    })
}
& $writeLog

$display = @(@{ Name = 'Source'; Expression = { $_.Name } }, 'Fetched', 'Status', 'Duration', @{ Name = 'Warnings'; Expression = { @($_.Warnings).Count } })
$results | Format-Table $display | Out-String | Write-Host
$failed = @($results | Where-Object Status -ne 'ok').Count
if ($failed -eq $results.Count) {
  Write-Host 'No source succeeded, so the raw file is left as it was'
  exit 1
}

$previous = Read-TvRawFile $rawFile
$asOfValue = if (($Source -or $Local) -and $previous) { $previous.asOf } elseif ($AsOf) { $AsOf } else { $fetchedAt }
$keep = @(@($running | ForEach-Object name) + @($selected | ForEach-Object name) | Select-Object -Unique)
$raw = Update-TvRawFile $previous -Results $results -Keep $keep -AsOf $asOfValue -FetchedAt $fetchedAt
if (-not $NoWrite) { Write-TvRawFile $rawFile $raw }

$stored = @(Get-TvRawEvents $raw).Count
$log.finishedAt = & $stamp
$log.asOf = $asOfValue
$log.rawSources = @($raw.sources.PSObject.Properties).Count
$log.rawEvents = $stored
& $writeLog
Write-Host "$($results.Count - $failed) of $($results.Count) sources succeeded, raw file holds $(@($raw.sources.PSObject.Properties).Count) sources and $stored events, asOf $asOfValue$($NoWrite ? ' (not written)' : '')"
exit 0
