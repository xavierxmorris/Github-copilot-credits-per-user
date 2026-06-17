<#
.SYNOPSIS
    Per-user net money + AI credit totals for GitHub Copilot in one month,
    aggregated across all models, at organization, enterprise, or personal scope.

.DESCRIPTION
    Reads GitHub usage-based billing (AI credits; 1 credit = $0.01 USD) and reports,
    for a month: net USD spend + AI credit count per user, summed across all models.

    Scope is selected by the target parameter you pass:
      -Org <name>          Every user with a Copilot seat in the organization.
      -Enterprise <slug>   Every user with a Copilot seat in the enterprise.
      -Self                Only the authenticated user's personal Copilot usage.

.EXAMPLE
    ./Get-CopilotCreditsPerUser.ps1 -Org my-org
    ./Get-CopilotCreditsPerUser.ps1 -Enterprise my-ent -Year 2026 -Month 6 -CsvPath .\ent-june.csv
    ./Get-CopilotCreditsPerUser.ps1 -Org my-org -Users alice,bob
    ./Get-CopilotCreditsPerUser.ps1 -Self
#>
[CmdletBinding(DefaultParameterSetName = 'Org')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Org')]
    [string]$Org,

    [Parameter(Mandatory, ParameterSetName = 'Enterprise')]
    [string]$Enterprise,

    [Parameter(Mandatory, ParameterSetName = 'Self')]
    [switch]$Self,

    [int]$Year  = (Get-Date).Year,
    [int]$Month = (Get-Date).Month,

    [Parameter(ParameterSetName = 'Org')]
    [Parameter(ParameterSetName = 'Enterprise')]
    [string[]]$Users,

    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2022-11-28'

function Invoke-GH([string]$Path) {
    # Localize so a non-zero gh exit doesn't get auto-thrown before we inspect it.
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $raw  = gh api -H "X-GitHub-Api-Version: $apiVersion" $Path 2>$errFile
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            $detail = (Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue)
            throw "gh api failed ($code) for $Path`n$detail"
        }
        $text = ($raw -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { throw "gh api returned an empty response for $Path" }
        return $text | ConvertFrom-Json
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $prevNative
        Remove-Item -Path $errFile -ErrorAction SilentlyContinue
    }
}

# Summarize a usageItems array into net USD + the distinct models seen.
function Get-UsageSummary($items) {
    if (-not $items) { $items = @() }
    $netUsd = ($items | Measure-Object -Property netAmount -Sum).Sum
    if (-not $netUsd) { $netUsd = 0 }
    $models = ($items | Where-Object { $_.model } |
                  Select-Object -ExpandProperty model -Unique | Sort-Object) -join ', '
    [pscustomobject]@{ NetUsd = $netUsd; Models = $models }
}

function New-Row($user, $summary) {
    [pscustomobject]@{
        User      = $user
        Models    = $summary.Models
        NetUSD    = [math]::Round($summary.NetUsd, 2)
        AICredits = [long][math]::Round($summary.NetUsd * 100, 0)
    }
}

# Resolve scope -> billing base path, seats path, and a label.
switch ($PSCmdlet.ParameterSetName) {
    'Org' {
        $billingBase = "/organizations/$Org/settings/billing/ai_credit/usage"
        $seatsPath   = "/orgs/$Org/copilot/billing/seats"
        $scopeLabel  = "org '$Org'"
    }
    'Enterprise' {
        $billingBase = "/enterprises/$Enterprise/settings/billing/ai_credit/usage"
        $seatsPath   = "/enterprises/$Enterprise/copilot/billing/seats"
        $scopeLabel  = "enterprise '$Enterprise'"
    }
    'Self' {
        $me          = (Invoke-GH "/user").login
        $billingBase = "/users/$me/settings/billing/ai_credit/usage"
        $scopeLabel  = "personal account '$me'"
    }
}

$failed = 0

if ($PSCmdlet.ParameterSetName -eq 'Self') {
    # One call, one row - the personal endpoint is already user-scoped by path.
    Write-Host ("Fetching {0} usage for {1}-{2:D2}..." -f $scopeLabel, $Year, $Month) -ForegroundColor Cyan
    $usage = Invoke-GH ("{0}?year={1}&month={2}" -f $billingBase, $Year, $Month)
    $rows  = ,(New-Row $me (Get-UsageSummary $usage.usageItems))
}
else {
    # Org / Enterprise: resolve the user list (explicit -Users, else current seats), then loop.
    if (-not $Users) {
        Write-Host "Listing current Copilot seats for $scopeLabel (for closed months, pass -Users to include anyone who has since lost their seat)..." -ForegroundColor Cyan
        try {
            $Users = @()
            $page = 1
            while ($true) {
                $resp = Invoke-GH "${seatsPath}?per_page=100&page=$page"
                if (-not $resp -or -not $resp.seats -or $resp.seats.Count -eq 0) { break }
                $Users += $resp.seats.assignee.login
                if ($resp.seats.Count -lt 100) { break }
                $page++
            }
        }
        catch {
            $first = ($_.Exception.Message -split "`n")[0]
            throw "Could not list Copilot seats for $scopeLabel ($first). Re-run with -Users to specify accounts explicitly."
        }
    }
    $Users = $Users | Where-Object { $_ } | Sort-Object -Unique
    if (-not $Users) { throw "No Copilot users found for $scopeLabel. Pass -Users explicitly or check access." }
    Write-Host ("Aggregating {0} users for {1}-{2:D2}..." -f $Users.Count, $Year, $Month) -ForegroundColor Cyan

    $rows = foreach ($u in $Users) {
        try {
            $usage = Invoke-GH ("{0}?user={1}&year={2}&month={3}" -f $billingBase, $u, $Year, $Month)
        }
        catch {
            Write-Warning "Usage lookup failed for '$u' - excluded from totals: $(($_.Exception.Message -split "`n")[0])"
            $failed++
            [pscustomobject]@{ User = $u; Models = '(lookup failed)'; NetUSD = $null; AICredits = $null }
            continue
        }
        New-Row $u (Get-UsageSummary $usage.usageItems)
    }
}

# Report, sorted by spend (failed rows last).
$rows = $rows | Sort-Object @{ Expression = { $null -ne $_.NetUSD }; Descending = $true }, NetUSD -Descending
$rows | Format-Table User, NetUSD, AICredits, Models -AutoSize

$ok     = $rows | Where-Object { $null -ne $_.NetUSD }
$totUsd = ($ok | Measure-Object NetUSD -Sum).Sum;    if (-not $totUsd) { $totUsd = 0 }
$totCr  = ($ok | Measure-Object AICredits -Sum).Sum; if (-not $totCr)  { $totCr  = 0 }
Write-Host ('TOTAL  net ${0:N2} USD  =  {1:N0} AI credits   ({2}-{3:D2})' -f $totUsd, $totCr, $Year, $Month) -ForegroundColor Green
if ($failed) { Write-Warning "$failed user(s) failed to fetch and are excluded from the total." }
Write-Host "Note: amounts are USD (1 credit = `$0.01); verified against the billing schema grossAmount = grossQuantity x pricePerUnit." -ForegroundColor DarkGray

if ($CsvPath) {
    $rows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Saved CSV: $CsvPath" -ForegroundColor Green
}
