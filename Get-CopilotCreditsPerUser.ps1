<#
.SYNOPSIS
    Per-user net money + AI credit totals for GitHub Copilot in one month,
    aggregated across all models, at organization, enterprise, or personal scope.

.DESCRIPTION
    Reads GitHub usage-based billing (AI credits; 1 credit = $0.01 USD) and reports,
    for a month: net USD spend + AI credit count per user, summed across all models.

    Scope is selected by the target parameter you pass:
      -Org <name>          Every user with a Copilot seat in the organization.
      -Enterprise <slug>   Users billed to an enterprise (pass -Users or -Organizations).
      -Self                Only the authenticated user's own personal Copilot usage.

    Billing endpoints (https://docs.github.com/en/rest/billing/usage):
      Org   GET /organizations/{org}/settings/billing/ai_credit/usage?user=...
      Ent   GET /enterprises/{ent}/settings/billing/ai_credit/usage?user=...
      User  GET /users/{username}/settings/billing/ai_credit/usage   (path-scoped)

    For Org/Enterprise auto-discovery, the per-user total is reconciled against the
    scope aggregate (same call without ?user=) to surface any unattributed usage,
    e.g. from users who lost their seat mid-month.

.NOTES
    Access required:
      -Org         organization owner or billing manager
      -Enterprise  enterprise admin or billing manager
      -Self        the "user" OAuth scope (gh auth refresh -h github.com -s user)

    Enterprise-managed users: a user whose Copilot is billed by an org or enterprise
    will NOT see usage on their personal (-Self) account - it is billed to the owning
    org/enterprise. Query that scope instead (requires billing access there).

    GitHub exposes no enterprise-wide Copilot seats endpoint, so -Organizations is a
    user-DISCOVERY source: it lists each named org's seats, then the enterprise usage
    endpoint reports each resolved user's full enterprise usage (not org-scoped).

    The usage endpoints document no page/per_page params and return an aggregate
    report, so usageItems are treated as a single non-paginated set.

.EXAMPLE
    ./Get-CopilotCreditsPerUser.ps1 -Org my-org
    ./Get-CopilotCreditsPerUser.ps1 -Org my-org -Users alice,bob -CsvPath .\june.csv
    ./Get-CopilotCreditsPerUser.ps1 -Enterprise my-ent -Users alice,bob
    ./Get-CopilotCreditsPerUser.ps1 -Enterprise my-ent -Organizations team-a,team-b -Month 6
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

    [Parameter(ParameterSetName = 'Enterprise')]
    [string[]]$Organizations,

    [string]$Product,

    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'
$apiVersion        = '2022-11-28'
$script:failed     = 0
$script:perUserRaw = 0.0
$productQ          = if ($Product) { "&product=$Product" } else { "" }

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

# Emit the Copilot seat logins for an org (paginated). Wrap calls in @() to keep an array.
function Get-OrgSeatLogins([string]$OrgName) {
    $page = 1
    while ($true) {
        $resp = Invoke-GH "/orgs/$OrgName/copilot/billing/seats?per_page=100&page=$page"
        if (-not $resp -or -not $resp.seats -or $resp.seats.Count -eq 0) { break }
        $resp.seats.assignee.login
        if ($resp.seats.Count -lt 100) { break }
        $page++
    }
}

# Net USD + distinct models from a usageItems array.
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

# Loop a set of users against a billing base path; failures are reported and excluded.
function Get-PerUserRows([string]$BillingBase, [string[]]$UserList) {
    foreach ($u in $UserList) {
        try {
            $usage = Invoke-GH ("{0}?user={1}&year={2}&month={3}{4}" -f $BillingBase, $u, $Year, $Month, $productQ)
        }
        catch {
            Write-Warning "Usage lookup failed for '$u' - excluded from totals: $(($_.Exception.Message -split "`n")[0])"
            $script:failed++
            [pscustomobject]@{ User = $u; Models = '(lookup failed)'; NetUSD = $null; AICredits = $null }
            continue
        }
        $summary = Get-UsageSummary $usage.usageItems
        $script:perUserRaw += [double]$summary.NetUsd
        New-Row $u $summary
    }
}

$billingBase    = $null
$autoDiscovered = $false

switch ($PSCmdlet.ParameterSetName) {

    'Self' {
        $me = (Invoke-GH "/user").login
        Write-Host ("Fetching personal usage for '{0}' ({1}-{2:D2})..." -f $me, $Year, $Month) -ForegroundColor Cyan
        $usage = Invoke-GH ("/users/{0}/settings/billing/ai_credit/usage?year={1}&month={2}{3}" -f $me, $Year, $Month, $productQ)
        $rows  = ,(New-Row $me (Get-UsageSummary $usage.usageItems))
        if (-not $usage.usageItems -or $usage.usageItems.Count -eq 0) {
            Write-Warning ("No personal Copilot usage for '{0}'. If your Copilot is managed/billed by an organization or enterprise, usage is billed there - not on your personal account. Ask a billing manager to run:  -Org <org> -Users {0}   or   -Enterprise <slug> -Users {0}" -f $me)
        }
    }

    'Org' {
        $billingBase = "/organizations/$Org/settings/billing/ai_credit/usage"
        if (-not $Users) {
            $autoDiscovered = $true
            Write-Host "Listing current Copilot seats for org '$Org' (for closed months, pass -Users to include anyone who has since lost their seat)..." -ForegroundColor Cyan
            try { $Users = @(Get-OrgSeatLogins $Org) }
            catch {
                throw "Could not list Copilot seats for org '$Org' ($(($_.Exception.Message -split "`n")[0])). Re-run with -Users to specify accounts explicitly."
            }
        }
        $Users = $Users | Where-Object { $_ } | Sort-Object -Unique
        if (-not $Users) { throw "No Copilot users found for org '$Org'. Pass -Users explicitly or check access." }
        Write-Host ("Aggregating {0} users for {1}-{2:D2}..." -f $Users.Count, $Year, $Month) -ForegroundColor Cyan
        $rows = Get-PerUserRows $billingBase $Users
    }

    'Enterprise' {
        $billingBase = "/enterprises/$Enterprise/settings/billing/ai_credit/usage"
        if (-not $Users) {
            if ($Organizations) {
                $autoDiscovered = $true
                Write-Host ("Enumerating Copilot seats across {0} org(s) for enterprise '{1}'..." -f $Organizations.Count, $Enterprise) -ForegroundColor Cyan
                $Users = @(foreach ($o in $Organizations) {
                    try { Get-OrgSeatLogins $o }
                    catch { Write-Warning "Could not list seats for org '$o': $(($_.Exception.Message -split "`n")[0])" }
                })
            }
            else {
                throw "Enterprise mode needs -Users <logins> or -Organizations <orgs>. GitHub exposes no enterprise-wide Copilot seats endpoint, so accounts must be supplied or gathered per organization."
            }
        }
        $Users = $Users | Where-Object { $_ } | Sort-Object -Unique
        if (-not $Users) { throw "No Copilot users resolved for enterprise '$Enterprise'. Pass -Users or check -Organizations access." }
        Write-Host ("Aggregating {0} users for {1}-{2:D2}..." -f $Users.Count, $Year, $Month) -ForegroundColor Cyan
        $rows = Get-PerUserRows $billingBase $Users
    }
}

# Report, sorted by spend (failed rows last).
$rows = $rows | Sort-Object @{ Expression = { $null -ne $_.NetUSD }; Descending = $true }, NetUSD -Descending
$rows | Format-Table User, NetUSD, AICredits, Models -AutoSize

$ok     = $rows | Where-Object { $null -ne $_.NetUSD }
$totUsd = ($ok | Measure-Object NetUSD -Sum).Sum;    if (-not $totUsd) { $totUsd = 0 }
$totCr  = ($ok | Measure-Object AICredits -Sum).Sum; if (-not $totCr)  { $totCr  = 0 }
Write-Host ('TOTAL  net ${0:N2} USD  =  {1:N0} AI credits   ({2}-{3:D2})' -f $totUsd, $totCr, $Year, $Month) -ForegroundColor Green
if ($script:failed) { Write-Warning "$($script:failed) user(s) failed to fetch and are excluded from the total." }

# Reconcile per-user sum against the scope aggregate (Org/Enterprise only) to catch
# usage not attributed to the queried users (e.g. seats removed mid-month).
if ($billingBase) {
    try {
        $scope    = Invoke-GH ("{0}?year={1}&month={2}{3}" -f $billingBase, $Year, $Month, $productQ)
        $scopeNet = ($scope.usageItems | Measure-Object -Property netAmount -Sum).Sum
        if (-not $scopeNet) { $scopeNet = 0 }
        $gap = [math]::Round($scopeNet - $script:perUserRaw, 2)
        Write-Host ('Reconcile: scope total ${0:N2} USD; attributed to queried users ${1:N2} USD; unattributed ${2:N2} USD' -f $scopeNet, $script:perUserRaw, $gap) -ForegroundColor DarkGray
        if ($autoDiscovered -and $gap -gt 0.005) {
            Write-Warning ("`${0:N2} USD of scope usage is not attributed to the discovered users (e.g. accounts without a current seat, or orgs not in -Organizations). Pass -Users for a complete monthly list." -f $gap)
        }
    }
    catch {
        Write-Warning "Reconciliation skipped: $(($_.Exception.Message -split "`n")[0])"
    }
}

Write-Host "Note: amounts are USD (1 credit = `$0.01); verified against the billing schema grossAmount = grossQuantity x pricePerUnit." -ForegroundColor DarkGray

if ($CsvPath) {
    $rows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Saved CSV: $CsvPath" -ForegroundColor Green
}
