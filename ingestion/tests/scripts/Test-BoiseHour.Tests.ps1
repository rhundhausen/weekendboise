BeforeAll {
  $script:gate = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Test-BoiseHour.ps1'
  $script:winter = [DateTime]::new(2026, 12, 1)
  $script:summer = [DateTime]::new(2026, 7, 1)
}

Describe 'Test-BoiseHour' {
  BeforeEach {
    $script:savedOutput = $env:GITHUB_OUTPUT
    $env:GITHUB_OUTPUT = ''
  }

  AfterEach {
    $env:GITHUB_OUTPUT = $script:savedOutput
  }

  It 'hour <hour> on <season> with cron <cron> runs: <want>' -ForEach @(
    # Ingest, midnight: 07:00 UTC in winter (MST), 06:00 UTC in summer (MDT).
    @{ hour = 0; season = 'winter'; cron = '0 6 * * *'; want = $false }
    @{ hour = 0; season = 'winter'; cron = '0 7 * * *'; want = $true }
    @{ hour = 0; season = 'summer'; cron = '0 6 * * *'; want = $true }
    @{ hour = 0; season = 'summer'; cron = '0 7 * * *'; want = $false }
    # Another hour, 1 AM: 08:00 UTC in winter, 07:00 UTC in summer.
    @{ hour = 1; season = 'winter'; cron = '0 7 * * *'; want = $false }
    @{ hour = 1; season = 'winter'; cron = '0 8 * * *'; want = $true }
    @{ hour = 1; season = 'summer'; cron = '0 7 * * *'; want = $true }
    @{ hour = 1; season = 'summer'; cron = '0 8 * * *'; want = $false }
    # Additional ingest, 11:30 PM: 06:30 UTC in winter, 05:30 UTC in summer.
    @{ hour = 23; season = 'winter'; cron = '30 5 * * *'; want = $false }
    @{ hour = 23; season = 'winter'; cron = '30 6 * * *'; want = $true }
    @{ hour = 23; season = 'summer'; cron = '30 5 * * *'; want = $true }
    @{ hour = 23; season = 'summer'; cron = '30 6 * * *'; want = $false }
  ) {
    $today = if ($season -eq 'winter') { $winter } else { $summer }
    $result = & $gate -Hour $hour -EventName schedule -Schedule $cron -Today $today
    $result.Run | Should -Be $want
  }

  It 'passes on the scheduled time, not the clock' {
    $result = & $gate -Hour 0 -EventName schedule -Schedule '0 7 * * *' -Today $winter
    $result.At | Should -BeExactly '2026-12-01T07:00:00Z'
  }

  It 'always runs a manual run, with no scheduled time' {
    $result = & $gate -Hour 0 -EventName workflow_dispatch -Today $winter
    $result.Run | Should -BeTrue
    $result.At | Should -BeNullOrEmpty
  }

  It 'writes run and at to GITHUB_OUTPUT' {
    $env:GITHUB_OUTPUT = Join-Path $TestDrive 'output.txt'
    $null = & $gate -Hour 1 -EventName schedule -Schedule '0 8 * * *' -Today $winter
    Get-Content $env:GITHUB_OUTPUT | Should -Be @('at=2026-12-01T08:00:00Z', 'run=true')
  }

  It 'fails on a schedule it cannot read' {
    { & $gate -Hour 0 -EventName schedule -Schedule 'nonsense' -Today $winter } | Should -Throw '*cron*'
  }
}
