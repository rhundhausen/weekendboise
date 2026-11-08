# Helpers for reading event pages: robots.txt rules, and schema.org data embedded in HTML.

. "$PSScriptRoot/Http.ps1"

function Get-TvRobotsGroup {
  # Returns the rules that apply to us: a group naming WeekendBoise if there is one, otherwise *.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]
    [AllowEmptyString()]
    [string]$Robots
  )

  $groups = [System.Collections.Generic.List[object]]::new()
  $current = $null
  $inAgents = $false

  foreach ($raw in ($Robots -split '\r?\n')) {
    $line = ($raw -replace '#.*$', '').Trim()
    if ($line -notmatch '^(?<key>[A-Za-z-]+)\s*:\s*(?<value>.*)$') { continue }
    $key = $Matches.key.ToLowerInvariant()
    $value = $Matches.value.Trim()

    if ($key -eq 'user-agent') {
      if (-not $inAgents) {
        $current = [pscustomobject]@{ Agents = [System.Collections.Generic.List[string]]::new(); Rules = [System.Collections.Generic.List[object]]::new(); Delay = 0 }
        $groups.Add($current)
      }
      $current.Agents.Add($value.ToLowerInvariant())
      $inAgents = $true
      continue
    }

    $inAgents = $false
    if ($null -eq $current) { continue }
    if ($key -in 'allow', 'disallow' -and $value) {
      $current.Rules.Add([pscustomobject]@{ Allow = ($key -eq 'allow'); Path = $value })
    } elseif ($key -eq 'crawl-delay' -and $value -match '^\d+') {
      $current.Delay = [int]$Matches[0]
    }
  }

  $named = @($groups | Where-Object { $_.Agents -contains 'weekendboise' })
  $selected = if ($named.Count -gt 0) { $named } else { @($groups | Where-Object { $_.Agents -contains '*' }) }
  [pscustomobject]@{
    Rules = @($selected | ForEach-Object { $_.Rules })
    Delay = ($selected | ForEach-Object { $_.Delay } | Measure-Object -Maximum).Maximum
  }
}

function Test-TvRobotsAllowed {
  <#
  .SYNOPSIS
    Tests a path, with its query string, against robots.txt.
  .DESCRIPTION
    Follows RFC 9309: * matches anything, $ anchors the end, the longest matching rule wins, and
    Allow wins a tie. So /*?format=json blocks /calendar?format=json but not /calendar.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory, Position = 0)]
    [AllowEmptyString()]
    [string]$Robots,

    [Parameter(Mandatory, Position = 1)]
    [string]$Path
  )

  $best = $null
  foreach ($rule in (Get-TvRobotsGroup $Robots).Rules) {
    $pattern = '^' + ([regex]::Escape($rule.Path) -replace '\\\*', '.*')
    if ($pattern.EndsWith('\$')) { $pattern = $pattern.Substring(0, $pattern.Length - 2) + '$' }
    if ($Path -notmatch $pattern) { continue }

    $better = -not $best -or $rule.Path.Length -gt $best.Path.Length -or
      ($rule.Path.Length -eq $best.Path.Length -and $rule.Allow -and -not $best.Allow)
    if ($better) { $best = $rule }
  }
  (-not $best) -or $best.Allow
}

function Get-TvJsonLdEvent {
  <#
  .SYNOPSIS
    Returns the schema.org Event objects embedded in a page as JSON-LD.
  .DESCRIPTION
    Handles a single object, an array, and @graph. A block that isn't valid JSON is skipped,
    because many pages carry unrelated broken blocks.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]
    [AllowEmptyString()]
    [string]$Html
  )

  foreach ($block in [regex]::Matches($Html, '(?is)<script[^>]*application/ld\+json[^>]*>(.*?)</script>')) {
    try {
      $parsed = ConvertFrom-TvJson $block.Groups[1].Value.Trim()
    } catch {
      continue
    }

    $nodes = foreach ($item in @($parsed)) {
      if ($item.PSObject.Properties['@graph']) { @($item.'@graph') } else { $item }
    }
    foreach ($node in $nodes) {
      if (@($node.'@type') -match 'Event$') { $node }
    }
  }
}

function ConvertFrom-TvJsLiteral {
  <#
  .SYNOPSIS
    Reads a JavaScript literal, such as the data a SvelteKit page embeds for its first render.
  .DESCRIPTION
    Reads objects (bare or quoted keys), arrays, double- or single-quoted strings, numbers, true,
    false, null, undefined, and void 0. SvelteKit wraps its data in a function whose arguments
    stand in for repeated values: (function(a,b){return {...}}("x",null)). This fills them in.
    Nothing is run: anything else, such as new Date(...), is an error.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Text
  )

  # Split the text into tokens in one pass. Matching from an offset instead costs time in
  # proportion to the whole text on every call, which made a 400 KB page take minutes.
  $pattern = '(?<s>"(?:[^"\\]|\\.)*"|''(?:[^''\\]|\\.)*'')|(?<n>-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|(?<w>[A-Za-z_$][\w$]*)|(?<p>[{}\[\]():,])|(?<x>\S)'
  $tokens = [regex]::Matches($Text, $pattern)
  $state = @{ At = 0; Params = $null }

  function Get-Token {
    if ($state.At -ge $tokens.Count) { throw 'unexpected end of the text' }
    $tokens[$state.At]
  }

  function Read-Punct {
    param([string]$Expected)
    $t = Get-Token
    if ($t.Value -ne $Expected) { throw "unexpected '$($t.Value)' at $($t.Index), expected '$Expected'" }
    $state.At++
  }

  function Test-Punct {
    param([string]$Char)
    $state.At -lt $tokens.Count -and $tokens[$state.At].Value -eq $Char
  }

  function ConvertFrom-JsString {
    # The token with its quotes. JavaScript escapes: \uXXXX, \u{X...}, \xXX, the usual letters,
    # and any other character as itself.
    param([string]$Token)
    $value = $Token.Substring(1, $Token.Length - 2)
    if (-not $value.Contains('\')) { return $value }
    [regex]::Replace($value, '\\(?:u\{(?<cp>[0-9A-Fa-f]+)\}|u(?<u>[0-9A-Fa-f]{4})|x(?<x>[0-9A-Fa-f]{2})|(?<c>[\s\S]))', {
        param($m)
        if ($m.Groups['cp'].Success) { return [char]::ConvertFromUtf32([Convert]::ToInt32($m.Groups['cp'].Value, 16)) }
        if ($m.Groups['u'].Success) { return [string][char][Convert]::ToInt32($m.Groups['u'].Value, 16) }
        if ($m.Groups['x'].Success) { return [string][char][Convert]::ToInt32($m.Groups['x'].Value, 16) }
        switch -CaseSensitive ($m.Groups['c'].Value) {
          'n' { "`n" } 'r' { "`r" } 't' { "`t" } 'b' { "`b" } 'f' { "`f" } 'v' { "`v" } '0' { "`0" }
          "`n" { '' } "`r" { '' }
          default { $m.Groups['c'].Value }
        }
      })
  }

  function Read-Value {
    $t = Get-Token
    $state.At++

    if ($t.Value -eq '{') {
      $fields = [ordered]@{}
      while (-not (Test-Punct '}')) {
        $key = Get-Token
        $state.At++
        if ($key.Groups['s'].Success) { $keyText = ConvertFrom-JsString $key.Value }
        elseif ($key.Groups['w'].Success -or $key.Groups['n'].Success) { $keyText = $key.Value }
        else { throw "unexpected '$($key.Value)' at $($key.Index), expected a key" }
        Read-Punct ':'
        $fields[$keyText] = Read-Value
        if (-not (Test-Punct '}')) { Read-Punct ',' }
      }
      $state.At++
      return [pscustomobject]$fields
    }

    if ($t.Value -eq '(') { return , (Read-Call) }

    if ($t.Value -eq '[') {
      $items = [Collections.Generic.List[object]]::new()
      while (-not (Test-Punct ']')) {
        $items.Add((Read-Value))
        if (-not (Test-Punct ']')) { Read-Punct ',' }
      }
      $state.At++
      return , $items.ToArray()
    }

    if ($t.Groups['s'].Success) { return ConvertFrom-JsString $t.Value }

    if ($t.Groups['n'].Success) {
      $invariant = [Globalization.CultureInfo]::InvariantCulture
      if ($t.Value -match '^-?\d+$') { return [int64]::Parse($t.Value, $invariant) }
      return [double]::Parse($t.Value, $invariant)
    }

    if ($t.Groups['w'].Success) {
      switch -CaseSensitive ($t.Value) {
        'true' { return $true }
        'false' { return $false }
        'null' { return $null }
        'undefined' { return $null }
        'void' {
          $zero = Get-Token
          if ($zero.Value -ne '0') { throw "unexpected 'void $($zero.Value)' at $($t.Index)" }
          $state.At++
          return $null
        }
      }
      if ($state.Params -and $state.Params.Contains($t.Value)) {
        return [pscustomobject]@{ PSTypeName = 'TvJsRef'; Name = $t.Value }
      }
      if ($t.Value -cin 'new', 'function', 'return') { throw "unexpected '$($t.Value)' at $($t.Index)" }
      throw "unknown name '$($t.Value)' at $($t.Index)"
    }
    throw "unexpected '$($t.Value)' at $($t.Index)"
  }

  function Resolve-Ref {
    param($Value, [hashtable]$Values)
    if ($Value -is [object[]]) {
      for ($i = 0; $i -lt $Value.Count; $i++) { $Value[$i] = Resolve-Ref $Value[$i] $Values }
      return , $Value
    }
    if ($Value -is [pscustomobject]) {
      if ($Value.PSObject.TypeNames[0] -eq 'TvJsRef') { return , $Values[$Value.Name] }
      foreach ($p in $Value.PSObject.Properties) { $p.Value = Resolve-Ref $p.Value $Values }
    }
    return , $Value
  }

  function Read-Call {
    # (function(a,b){return VALUE}(ARG,ARG)), after its first '('.
    $f = Get-Token
    if ($f.Value -cne 'function') { throw "unexpected '$($f.Value)' at $($f.Index), expected 'function'" }
    $state.At++
    Read-Punct '('
    $names = [Collections.Generic.List[string]]::new()
    while (-not (Test-Punct ')')) {
      $n = Get-Token
      if (-not $n.Groups['w'].Success) { throw "unexpected '$($n.Value)' at $($n.Index), expected a name" }
      $names.Add($n.Value)
      $state.At++
      if (-not (Test-Punct ')')) { Read-Punct ',' }
    }
    $state.At++
    Read-Punct '{'
    $return = Get-Token
    if ($return.Value -cne 'return') { throw "unexpected '$($return.Value)' at $($return.Index), expected 'return'" }
    $state.At++
    $outer = $state.Params
    $state.Params = [Collections.Generic.HashSet[string]]::new([string[]]$names.ToArray())
    $body = Read-Value
    $state.Params = $outer
    Read-Punct '}'
    Read-Punct '('
    $values = @{}
    foreach ($n in $names) {
      if (Test-Punct ')') { break }
      $values[$n] = Read-Value
      if (-not (Test-Punct ')')) { Read-Punct ',' }
    }
    Read-Punct ')'
    Read-Punct ')'
    return , (Resolve-Ref $body $values)
  }

  $value = Read-Value
  if ($state.At -lt $tokens.Count) { throw "unexpected '$($tokens[$state.At].Value)' at $($tokens[$state.At].Index) after the value" }
  return , $value
}
