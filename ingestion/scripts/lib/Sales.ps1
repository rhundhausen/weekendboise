# Rules shared by the Auctions and Estate Sales readers (adapters/sales.ps1).

. "$PSScriptRoot/Schema.ps1"

function Get-TvSaleVerdict {
  <#
  .SYNOPSIS
    Whether one auction or sale is kept: keep, in-person (dropped as online or placeless),
    real-estate, or city.
  .DESCRIPTION
    In-person events only: anything whose title or text says "online" (any case) is dropped, and
    so is one with no street address or place, since a sale with nowhere to go is online bidding.
    Real estate auctions (a house or land) are dropped too: the site marks them (-RealEstate), or
    the title says "real estate". The text alone doesn't count, so an estate sale whose blurb
    mentions real estate services stays. Then only the cities this site already covers are kept (Resolve-TvCity, which includes Mountain
    Home and maps the mountain towns to Valley County).
  #>
  [CmdletBinding()]
  param(
    [string]$Title,
    [AllowEmptyString()][string]$Text,
    [bool]$HasPlace,
    [AllowNull()][AllowEmptyString()][string]$City,
    [bool]$RealEstate
  )

  if ("$Title`n$Text" -match '(?i)online' -or -not $HasPlace) { return 'in-person' }
  if ($RealEstate -or $Title -match '(?i)\breal estate\b') { return 'real-estate' }
  if (-not $City -or $City -eq 'Other') { return 'city' }
  'keep'
}

function Find-TvSaleTown {
  # The first "Town, ID" (or "Town, Idaho") in the text, as written, or $null.
  param([AllowEmptyString()][string]$Text)

  $match = [regex]::Match("$Text", '(?m)(?:^|,)\s*(?<town>[A-Z][A-Za-z.'' ]{1,30}?),\s*(?:ID|Idaho)\b')
  if ($match.Success) { $match.Groups['town'].Value.Trim() } else { $null }
}

function Get-TvNextDate {
  <#
  .SYNOPSIS
    A month and day with no year, as yyyy-MM-dd: this year, or next year when this year's date is
    more than six months gone. A date a few days or weeks past stays this year, so a stale listing
    becomes a past event rather than one a year ahead.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Month,
    [Parameter(Mandatory)][int]$Day,
    [Parameter(Mandatory)][datetime]$Today
  )

  $invariant = [Globalization.CultureInfo]::InvariantCulture
  $monthNumber = if ($Month -match '^\d+$') { [int]$Month } else {
    $names = $invariant.DateTimeFormat.AbbreviatedMonthNames
    [Array]::IndexOf($names, ($names | Where-Object { $_ -and $Month.Substring(0, 3) -ieq $_ } | Select-Object -First 1)) + 1
  }
  if ($monthNumber -lt 1 -or $monthNumber -gt 12) { throw "not a month: '$Month'" }

  $date = [datetime]::new($Today.Year, $monthNumber, $Day)
  if ($date -lt $Today.Date.AddMonths(-6)) { $date = $date.AddYears(1) }
  $date.ToString('yyyy-MM-dd', $invariant)
}

function ConvertTo-TvSaleTime {
  # A date (yyyy-MM-dd) and a clock time such as "2 pm" or "9:00 AM", as an event start in Boise time.
  param([string]$Date, [string]$Clock)

  $match = [regex]::Match($Clock, '(?i)^\s*(?<h>\d{1,2})(?::(?<m>\d{2}))?\s*(?<ap>[ap])\.?\s*m\.?\s*$')
  if (-not $match.Success) { return $null }
  $hour = [int]$match.Groups['h'].Value % 12
  if ($match.Groups['ap'].Value -ieq 'p') { $hour += 12 }
  $minute = if ($match.Groups['m'].Success) { [int]$match.Groups['m'].Value } else { 0 }
  ConvertTo-BoiseTime ('{0}T{1:00}:{2:00}:00' -f $Date, $hour, $minute)
}

function New-TvSaleEvent {
  <#
  .SYNOPSIS
    An Auctions and Estate Sales event, holding only the title, the company (as the venue), the
    city, start and end, and the link to the event on the company's site. No street address,
    photos, description, contact details, or price is passed on.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][pscustomobject]$Source,
    [Parameter(Mandatory)][string]$FetchedAt,
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Start,
    [string]$End,
    [switch]$AllDay,
    [Parameter(Mandatory)][string]$City,
    [Parameter(Mandatory)][string]$Url
  )

  New-TvEvent -Title $Title -Start $Start -End $End -AllDay:$AllDay `
    -Venue $Source.venue -VenueKey $Source.venueKey -City $City -Category $Source.category -Url $Url `
    -Sources @(@{ name = $Source.name; url = $Url; fetchedAt = $FetchedAt })
}
