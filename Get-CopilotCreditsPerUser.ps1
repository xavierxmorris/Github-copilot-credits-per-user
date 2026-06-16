<#
.SYNOPSIS
    Per-user net money + AI credit totals for GitHub Copilot in one month,
    aggregated across all models each user used.

.DESCRIPTION
    Calls GET /organizations/{org}/settings/billing/ai_credit/usage once per
    Copilot user, sums netAmount, and reports net USD and AI credits per user.
    1 AI credit = $0.01 USD, so credits = USD * 100.

.EXAMPLE
    ./Get-CopilotCreditsPerUser.ps1 -Org my-org
    ./Get-CopilotCreditsPerUser.ps1 -Org my-org -Year 2026 -Month 6 -CsvPath .\copilot-june.csv
    ./Get-CopilotCreditsPerUser.ps1 -Org my-org -Users alice,bob
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Org,
    [int]$Year  = (Get-Date).Year,
    [int]$Month = (Get-Date).Month,
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

# 1. Resolve the user list (explicit -Users, else enumerate Copilot seats).
if (-not $Users) {
    Write-Host "Listing current Copilot seats for '$Org' (for closed months, pass -Users to include anyone who has since lost their seat)..." -ForegroundColor Cyan
    $Users = @()
    $page = 1
    while ($true) {
        $resp = Invoke-GH "/orgs/$Org/copilot/billing/seats?per_page=100&page=$page"
        if (-not $resp -or -not $resp.seats -or $resp.seats.Count -eq 0) { break }
        $Users += $resp.seats.assignee.login
        if ($resp.seats.Count -lt 100) { break }
        $page++
    }
}
$Users = $Users | Where-Object { $_ } | Sort-Object -Unique
if (-not $Users) { throw "No Copilot users found for '$Org'. Pass -Users explicitly or check access." }
Write-Host ("Aggregating {0} users for {1}-{2:D2}..." -f $Users.Count, $Year, $Month) -ForegroundColor Cyan

# 2. One billing call per user, summed across all of that user's models.
#    A failed lookup is reported and excluded from totals - never folded in as $0.
$failed = 0
$rows = foreach ($u in $Users) {
    try {
        $usage = Invoke-GH "/organizations/$Org/settings/billing/ai_credit/usage?user=$u&year=$Year&month=$Month"
    }
    catch {
        Write-Warning "Usage lookup failed for '$u' - excluded from totals: $($_.Exception.Message)"
        $failed++
        [pscustomobject]@{ User = $u; Models = '(lookup failed)'; NetUSD = $null; AICredits = $null }
        continue
    }

    $items  = if ($usage.usageItems) { $usage.usageItems } else { @() }
    $netUsd = ($items | Measure-Object -Property netAmount -Sum).Sum
    if (-not $netUsd) { $netUsd = 0 }
    $models = ($items | Where-Object { $_.model } |
                  Select-Object -ExpandProperty model -Unique | Sort-Object) -join ', '

    [pscustomobject]@{
        User      = $u
        Models    = $models
        NetUSD    = [math]::Round($netUsd, 2)
        AICredits = [long][math]::Round($netUsd * 100, 0)
    }
}

# 3. Report, sorted by spend (failed rows last).
$rows = $rows | Sort-Object @{ Expression = { $null -ne $_.NetUSD }; Descending = $true }, NetUSD -Descending
$rows | Format-Table User, NetUSD, AICredits, Models -AutoSize

$ok     = $rows | Where-Object { $null -ne $_.NetUSD }
$totUsd = ($ok | Measure-Object NetUSD -Sum).Sum;    if (-not $totUsd) { $totUsd = 0 }
$totCr  = ($ok | Measure-Object AICredits -Sum).Sum; if (-not $totCr)  { $totCr  = 0 }
Write-Host ('TOTAL  net ${0:N2} USD  =  {1:N0} AI credits   ({2}-{3:D2})' -f $totUsd, $totCr, $Year, $Month) -ForegroundColor Green
if ($failed) { Write-Warning "$failed user(s) failed to fetch and are excluded from the total." }
Write-Host "Note: assumes netAmount is USD (1 credit = `$0.01). If a usage row shows pricePerUnit ~ 0.01, amounts are already credits - swap the columns." -ForegroundColor DarkGray

if ($CsvPath) {
    $rows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Saved CSV: $CsvPath" -ForegroundColor Green
}
