<#
.SYNOPSIS
    Complete tenant resource inventory - EVERY Azure resource, grouped by type, subscription, region and
    zone-awareness, so nothing is left out of a capacity / resilience review.

.DESCRIPTION
    The other scripts focus on the resources that capacity and zonal enablement actually gate (VM SKUs,
    AKS, databases, zone-pinned resources). This one zooms all the way out: it lists the FULL footprint -
    every resource type is deployed, how many of each, in which subscriptions and regions,
    and how many carry an explicit availability-zone placement. Use it to make sure the targeted reviews
    haven't missed a resource type that matters.

    Output is one row per (type, subscription, region):
      Type, SubId, SubName, Location, Count, Zoned
    'Zoned' = how many of those resources expose a top-level `zones` property (zone-pinned).

    Access required: Reader. Uses the resource-graph az extension (auto-installed).

.PARAMETER SubscriptionIds
    Optional: restrict to specific subscriptions. Omit to scan everything visible.

.PARAMETER Location
    Optional: restrict to a single region.

.PARAMETER OutPath
    CSV output path (default ..\output\resource-inventory-<date>.csv).

.EXAMPLE
    .\Get-ResourceInventory.ps1
.EXAMPLE
    .\Get-ResourceInventory.ps1 -Location norwayeast
#>
[CmdletBinding()]
param(
    [string[]] $SubscriptionIds,
    [string]   $Location,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutPath) { $OutPath = Join-Path (Get-DefaultOutDir) ("resource-inventory-{0}.csv" -f (Get-Date -Format 'yyyyMMdd')) }

az extension show --name resource-graph -o none 2>$null
if (-not $?) { az extension add --name resource-graph -o none 2>$null }

# Single-line KQL (multi-line / regex queries silently return everything unprojected).
$where = "where type !startswith 'microsoft.resources/'"
if ($Location) { $where += " | where location =~ '$Location'" }
$query = "resources | $where | extend z=iif(isnotnull(zones) and array_length(zones) > 0,1,0) | summarize Count=count(), Zoned=sum(z) by type, subscriptionId, location | order by Count desc"

$cmd = @('graph','query','-q',$query,'--first','1000')
if ($SubscriptionIds) { $cmd += @('--subscriptions'); $cmd += $SubscriptionIds }

Write-Host "Inventorying every resource$(if($Location){" in $Location"})..." -ForegroundColor Cyan
$raw = @(); $skip = 0
do {
    $b = az @cmd --skip $skip -o json 2>$null | ConvertFrom-Json
    if ($b.data) { $raw += $b.data }
    $total = $b.total_records; $skip += 1000
} while ($b -and $b.data.Count -gt 0 -and $raw.Count -lt $total)

# Resolve subscription GUIDs to friendly names once.
$subMap = @{}
az account list --all --query "[].{id:id,name:name}" -o json 2>$null | ConvertFrom-Json | ForEach-Object { $subMap[$_.id] = $_.name }

$all = foreach ($r in $raw) {
    [pscustomobject]@{
        Type     = ($r.type -replace '^microsoft\.','')
        SubId    = $r.subscriptionId
        SubName  = if ($subMap.ContainsKey($r.subscriptionId)) { $subMap[$r.subscriptionId] } else { $r.subscriptionId }
        Location = $r.location
        Count    = [int]$r.Count
        Zoned    = [int]$r.Zoned
    }
}

$all | Sort-Object Count -Descending | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
$totalRes = ($all | Measure-Object Count -Sum).Sum
$zonedRes = ($all | Measure-Object Zoned -Sum).Sum
$types    = ($all.Type | Select-Object -Unique).Count
$subs     = ($all.SubId | Select-Object -Unique).Count
Write-Host "`nExported $($all.Count) (type x sub x region) rows -> $OutPath" -ForegroundColor Green
Write-Host "Total resources: $totalRes   distinct types: $types   subscriptions: $subs   zone-pinned: $zonedRes"

Write-Host "`nTop resource types:" -ForegroundColor Cyan
$all | Group-Object Type | ForEach-Object {
    [pscustomobject]@{ Type = $_.Name; Count = ($_.Group | Measure-Object Count -Sum).Sum }
} | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
    "  {0,-55} {1,6}" -f $_.Type, $_.Count
}
