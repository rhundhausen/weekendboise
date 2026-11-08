BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/Http.ps1"

  function New-FakeResponse {
    param([int]$Status, [string]$Body = '')
    [pscustomobject]@{
      StatusCode       = $Status
      RawContentStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Body))
    }
  }
}

Describe 'ConvertFrom-TvJson' {
  It 'leaves ISO 8601 strings as strings' {
    $result = ConvertFrom-TvJson '{"start":"2026-11-14T19:30:00-07:00"}'
    $result.start | Should -BeOfType [string]
    $result.start | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'keeps arrays of one and of none as arrays' {
    $result = ConvertFrom-TvJson '{"one":[{"a":1}],"none":[]}'
    @($result.one).Count | Should -Be 1
    $result.one[0].a | Should -Be 1
    @($result.none).Count | Should -Be 0
  }

  It 'keeps arrays nested in arrays' {
    (ConvertFrom-TvJson '{"a":[[1,2],[3]]}').a[0].Count | Should -Be 2
  }

  It 'reads a top-level array' {
    @(ConvertFrom-TvJson '[{"a":1},{"a":2}]').Count | Should -Be 2
  }

  It 'reads booleans and null' {
    $result = ConvertFrom-TvJson '{"yes":true,"no":false,"nothing":null}'
    $result.yes | Should -BeTrue
    $result.no | Should -BeFalse
    $result.nothing | Should -BeNullOrEmpty
  }
}

Describe 'Hide-TvSecret' {
  It 'masks <name>' -ForEach @(
    @{ name = 'apikey'; text = 'https://x.test/e?size=1&apikey=SECRET&page=2'; want = 'https://x.test/e?size=1&apikey=***&page=2' }
    @{ name = 'app_id'; text = 'https://x.test/e?app_id=SECRET'; want = 'https://x.test/e?app_id=***' }
  ) {
    Hide-TvSecret $text | Should -Be $want
  }
}

Describe 'Invoke-TvRequest' {
  It 'sends the project User-Agent and parses JSON' {
    Mock Invoke-WebRequest { New-FakeResponse 200 '{"a":1}' }
    (Invoke-TvRequest 'https://x.test/').a | Should -Be 1
    Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $UserAgent -eq 'WeekendBoise/1.0 (+https://github.com/rhundhausen/weekendboise)' }
  }

  It 'returns text with -Raw' {
    Mock Invoke-WebRequest { New-FakeResponse 200 'BEGIN:VCALENDAR' }
    Invoke-TvRequest 'https://x.test/' -Raw | Should -Be 'BEGIN:VCALENDAR'
  }

  It 'sends a form POST when given a method and form' {
    # Built inline: inside this mock $Body is the request's form, which New-FakeResponse's
    # own -Body parameter would collide with.
    Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; RawContentStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"a":3}')) } }
    (Invoke-TvRequest 'https://x.test/ajax' -Method Post -Form @{ action = 'list' }).a | Should -Be 3
    Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' -and $Body.action -eq 'list' }
  }

  It 'decodes UTF-8' {
    Mock Invoke-WebRequest { New-FakeResponse 200 'Café' }
    Invoke-TvRequest 'https://x.test/' -Raw | Should -Be 'Café'
  }

  It 'retries once on 5xx and returns the second response' {
    $script:calls = 0
    Mock Invoke-WebRequest {
      $script:calls++
      if ($script:calls -eq 1) { New-FakeResponse 503 } else { New-FakeResponse 200 '{"a":2}' }
    }
    (Invoke-TvRequest 'https://x.test/' -RetryDelaySeconds 0 -WarningAction SilentlyContinue).a | Should -Be 2
    Should -Invoke Invoke-WebRequest -Times 2 -Exactly
  }

  It 'gives up after the retry' {
    Mock Invoke-WebRequest { New-FakeResponse 500 }
    { Invoke-TvRequest 'https://x.test/' -RetryDelaySeconds 0 -WarningAction SilentlyContinue } | Should -Throw '*HTTP 500*'
    Should -Invoke Invoke-WebRequest -Times 2 -Exactly
  }

  It 'does not retry on 4xx' {
    Mock Invoke-WebRequest { New-FakeResponse 404 }
    { Invoke-TvRequest 'https://x.test/' } | Should -Throw '*HTTP 404*'
    Should -Invoke Invoke-WebRequest -Times 1 -Exactly
  }

  It 'keeps credentials out of the error' {
    Mock Invoke-WebRequest { New-FakeResponse 401 }
    { Invoke-TvRequest 'https://x.test/?apikey=SECRET' } | Should -Throw '*apikey=`*`*`**'
    try { Invoke-TvRequest 'https://x.test/?apikey=SECRET' } catch { "$_" | Should -Not -Match 'SECRET' }
  }
}
