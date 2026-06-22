<#
.SYNOPSIS
    Inventory every zone-pinned resource in the tenant (or selected subscriptions) and flag
    single-zone deployments - a fast availability-zone resilience sweep across ALL resource types,
    not just VMs/VMSS/AKS.

.DESCRIPTION
    Many Azure resources record their availability-zone placement in a top-level `zones` property
    (VMs, VM Scale Sets, managed disks, public IPs, NAT gateways, application gateways, Data Explorer
    clusters, and more). This script lists them all via Resource Graph, shows which zone(s) each sits
    in, and flags resources pinned to a single zone so you can spot resilience gaps quickly.

    Note: a single-zone resource is not automatically "wrong" (a zonal VM is meant to be in one zone;
    resilience comes from having peers spread across zones). Treat SingleZone as a prompt to verify
    intent, not a failure.

    Access required: Reader. Uses the resource-graph az extension (auto-installed).

.PARAMETER SubscriptionIds
    Optional: restrict to specific subscriptions. Omit to scan everything visible.

.PARAMETER Location
    Optional: filter to a region.

.PARAMETER OutPath
    CSV output path (default ..\output\zonal-resources-<date>.csv).

.EXAMPLE
    .\Get-ZonalResourceInventory.ps1
.EXAMPLE
    .\Get-ZonalResourceInventory.ps1 -Location norwayeast
#>
[CmdletBinding()]
param(
    [string[]] $SubscriptionIds,
    [string]   $Location,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutPath) { $OutPath = Join-Path (Get-DefaultOutDir) ("zonal-resources-{0}.csv" -f (Get-Date -Format 'yyyyMMdd')) }

az extension show --name resource-graph -o none 2>$null
if (-not $?) { az extension add --name resource-graph -o none 2>$null }

$clauses = @(
    "resources",
    "where isnotnull(zones) and array_length(zones) > 0"
)
if ($Location) { $clauses += "where location =~ '$Location'" }
$clauses += "project name, type, subscriptionId, resourceGroup, location, zones=tostring(zones), zoneCount=array_length(zones)"
$clauses += "order by type asc, name asc"
$query = $clauses -join ' | '

$cmd = @('graph','query','-q',$query,'--first','1000')
if ($SubscriptionIds) { $cmd += @('--subscriptions'); $cmd += $SubscriptionIds }

Write-Host "Scanning for zone-pinned resources..." -ForegroundColor Cyan
$raw = @(); $skip = 0
do {
    $b = az @cmd --skip $skip -o json 2>$null | ConvertFrom-Json
    if ($b.data) { $raw += $b.data }
    $total = $b.total_records; $skip += 1000
} while ($b -and $b.data.Count -gt 0 -and $raw.Count -lt $total)

$all = foreach ($r in $raw) {
    [pscustomobject]@{
        name           = $r.name
        type           = ($r.type -replace '^microsoft\.','')
        subscriptionId = $r.subscriptionId
        resourceGroup  = $r.resourceGroup
        location       = $r.location
        zones          = ($r.zones -replace '[\[\]"]','')
        zoneCount      = [int]$r.zoneCount
        SingleZone     = ([int]$r.zoneCount -eq 1)
    }
}

$all | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($all.Count) zone-pinned resource(s) -> $OutPath" -ForegroundColor Green

Write-Host "`nBy resource type:"
$all | Group-Object type | Sort-Object Count -Descending | ForEach-Object {
    $single = ($_.Group | Where-Object SingleZone).Count
    "  {0,-45} {1,5}   (single-zone: {2})" -f $_.Name, $_.Count, $single
}
Write-Host "`nSingle-zone resources: $(($all | Where-Object SingleZone).Count) of $($all.Count)"
Write-Host "Multi-zone (zone-redundant/spanning): $(($all | Where-Object {-not $_.SingleZone}).Count)"
