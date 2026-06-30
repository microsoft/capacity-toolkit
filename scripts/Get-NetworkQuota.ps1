<#
.SYNOPSIS
    Network quota visibility: regional Microsoft.Network usage vs limit per subscription. Reports
    where networking resources (VNets, public IPs, NICs, load balancers, NAT gateways, etc.) are
    approaching their per-subscription regional quota. Exports a single CSV.

.DESCRIPTION
    The toolkit already tracks compute vCPU quota, but networking quota is a common and silent
    deployment blocker - you cannot create a VM if the subscription is out of Public IP Addresses or
    Network Interfaces in the region. This script surfaces that headroom as a pure READ-ONLY read of
    the Microsoft.Network regional usages API (the same data behind `az network list-usages`).

    Nothing is created or modified. Output is local CSV only.

    Per subscription + region it lists every network usage counter with Used / Limit / Available /
    PctUsed and flags counters that are at (>=100%) or near (>= -NearLimitPct, default 80%) their
    limit. Some counters are reported by the API with a placeholder "unlimited" limit
    (2147483647); these are emitted with IsUnbounded = True and blank Available/PctUsed rather than
    fabricated math. Per-VNet sub-counters (names ending in PerVirtualNetwork) are returned by the
    API with a static, subscription-level snapshot and are flagged as PerResourceScope = True so they
    are not mistaken for a saturation scan of every VNet.

    IMPORTANT: quota headroom is NOT guaranteed physical capacity (see docs/concepts.md). Passing a
    quota check does not prove the resource can be allocated in a capacity-constrained region.

    Access required: Reader on the target subscriptions.

.PARAMETER Location
    Region(s) to evaluate (e.g. 'norwayeast'). Quota is region-specific. Default 'norwayeast'. Ignored
    when -AllLocations is set.

.PARAMETER AllLocations
    Evaluate every physical Azure region the signed-in identity can list (az account list-locations),
    instead of -Location.

.PARAMETER SubscriptionIds
    Optional explicit subscription id(s). Omit to scan every visible subscription.

.PARAMETER SubscriptionCsv
    Optional CSV with a SubId column. Omit both to scan all visible subscriptions.

.PARAMETER NearLimitPct
    Percent-of-limit threshold for the NearLimit flag. Default 80.

.PARAMETER OutPath
    Output CSV path. Default ..\output\network-quota-<region|all>-<date>.csv.

.EXAMPLE
    .\Get-NetworkQuota.ps1 -Location norwayeast

.EXAMPLE
    .\Get-NetworkQuota.ps1 -AllLocations -SubscriptionCsv .\mysubs.csv
#>
[CmdletBinding()]
param(
    [string[]] $Location = @('norwayeast'),
    [switch]   $AllLocations,
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [int]      $NearLimitPct = 80,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null

$UNBOUNDED = 2147483647

$subs = @(Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv)

$date = Get-Date -Format 'yyyyMMdd'
if (-not $OutPath) {
    $outDir = Get-DefaultOutDir
    $tag = if ($AllLocations) { 'all' } else { ($Location -join '-') }
    $OutPath = Join-Path $outDir ("network-quota-{0}-{1}.csv" -f $tag, $date)
}

# Resolve the region list once (shared across subscriptions when -AllLocations).
$regions = @()
if ($AllLocations) {
    $regions = @(az account list-locations --query "[?metadata.regionType=='Physical'].name" -o json 2>$null | ConvertFrom-Json | Sort-Object)
} else {
    $regions = @($Location)
}
if (-not $regions -or $regions.Count -eq 0) { $regions = @('norwayeast') }

Write-Host ("Evaluating network quota across {0} subscription(s) x {1} region(s)..." -f $subs.Count, $regions.Count) -ForegroundColor Cyan

$rows = @()

foreach ($s in $subs) {
    az account set --subscription $s.SubId 2>$null
    foreach ($region in $regions) {
        $usages = $null
        try {
            $usages = az network list-usages --location $region -o json 2>$null | ConvertFrom-Json
        } catch { $usages = $null }
        if (-not $usages) { continue }

        foreach ($u in $usages) {
            $metricId  = $u.name.value
            $metricTxt = $u.name.localizedValue
            if (-not $metricTxt) { $metricTxt = $metricId }
            $used  = [long]$u.currentValue
            $limit = [long]$u.limit

            $isUnbounded   = ($limit -ge $UNBOUNDED)
            $perResource   = ($metricId -match 'PerVirtualNetwork$')

            $available = ''
            $pctUsed   = ''
            $nearLimit = $false
            $atLimit   = $false
            if (-not $isUnbounded -and $limit -gt 0) {
                $available = $limit - $used
                $pctUsed   = [Math]::Round(($used / $limit) * 100, 1)
                $atLimit   = ($used -ge $limit)
                $nearLimit = (($pctUsed -ge $NearLimitPct) -and (-not $atLimit))
            }

            $notes = ''
            if ($isUnbounded) {
                $notes = 'API reports no effective limit (placeholder 2147483647); treated as unbounded.'
            } elseif ($perResource) {
                $notes = 'Per-VNet counter; subscription-level snapshot, not a per-resource saturation scan.'
            }

            $rows += [pscustomobject][ordered]@{
                Subscription     = $s.Name
                SubscriptionId   = $s.SubId
                Region           = $region
                Metric           = $metricTxt
                MetricId         = $metricId
                Used             = $used
                Limit            = $(if ($isUnbounded) { '' } else { $limit })
                Available        = $available
                PctUsed          = $pctUsed
                Unit             = $u.unit
                IsUnbounded      = $isUnbounded
                PerResourceScope = $perResource
                NearLimit        = $nearLimit
                AtLimit          = $atLimit
                Notes            = $notes
            }
        }
    }
}

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "`nNo network usage data returned for the scanned subscription(s)/region(s)." -ForegroundColor Yellow
    return
}

$rows | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($rows.Count) network usage row(s) -> $OutPath" -ForegroundColor Green

$walls = @($rows | Where-Object { $_.AtLimit -eq $true })
$near  = @($rows | Where-Object { $_.NearLimit -eq $true })

Write-Host ("`nAt limit: {0}   Near limit (>= {1}%): {2}" -f $walls.Count, $NearLimitPct, $near.Count)

if ($walls.Count) {
    Write-Host "`nAt-limit network counters:" -ForegroundColor Red
    $walls | Sort-Object SubscriptionId, Region, MetricId | ForEach-Object {
        "  {0,-24} {1,-16} {2,-28} {3}/{4}" -f $_.Subscription, $_.Region, $_.MetricId, $_.Used, $_.Limit
    }
}
if ($near.Count) {
    Write-Host "`nNear-limit network counters:" -ForegroundColor Yellow
    $near | Sort-Object { [double]$_.PctUsed } -Descending | ForEach-Object {
        "  {0,-24} {1,-16} {2,-28} {3}% ({4}/{5})" -f $_.Subscription, $_.Region, $_.MetricId, $_.PctUsed, $_.Used, $_.Limit
    }
}
if (-not $walls.Count -and -not $near.Count) {
    Write-Host "`nNo network counters at or near limit for the scanned scope." -ForegroundColor Green
}

Write-Host "`nReminder: quota headroom is not guaranteed physical capacity." -ForegroundColor DarkYellow
