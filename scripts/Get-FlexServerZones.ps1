<#
.SYNOPSIS
    Inventory Azure Database for PostgreSQL / MySQL Flexible Servers with their compute SKU,
    availability zone and high-availability (standby zone) configuration, and flag servers that are
    single-zone (no zone-redundant HA).

.DESCRIPTION
    Flexible Servers are the one major managed-PaaS service where you choose BOTH the compute SKU
    (Burstable B-series / General Purpose D-series / Memory Optimized E-series) AND the availability
    zone, plus an optional zone-redundant HA standby in a second zone. This script reports all of that
    via Resource Graph so you can review database resilience the same way you review VM/AKS zonal
    spread.

    Access required: Reader. Uses the resource-graph az extension (auto-installed).

.PARAMETER SubscriptionIds
    Optional: restrict to specific subscriptions. Omit to scan everything visible.

.PARAMETER Location
    Optional: filter to a region.

.PARAMETER OutPath
    CSV output path (default ..\output\flexserver-zones-<date>.csv).

.EXAMPLE
    .\Get-FlexServerZones.ps1
.EXAMPLE
    .\Get-FlexServerZones.ps1 -Location norwayeast
#>
[CmdletBinding()]
param(
    [string[]] $SubscriptionIds,
    [string]   $Location,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutPath) { $OutPath = Join-Path (Get-DefaultOutDir) ("flexserver-zones-{0}.csv" -f (Get-Date -Format 'yyyyMMdd')) }

az extension show --name resource-graph -o none 2>$null
if (-not $?) { az extension add --name resource-graph -o none 2>$null }

$clauses = @(
    "resources",
    "where type in~ ('microsoft.dbforpostgresql/flexibleservers','microsoft.dbformysql/flexibleservers')"
)
if ($Location) { $clauses += "where location =~ '$Location'" }
$clauses += "project name, engine=tostring(split(type,'/')[0]), subscriptionId, resourceGroup, location, sku=tostring(sku.name), tier=tostring(sku.tier), zone=tostring(properties.availabilityZone), haMode=tostring(properties.highAvailability.mode), standbyZone=tostring(properties.highAvailability.standbyAvailabilityZone), version=tostring(properties.version)"
$clauses += "order by subscriptionId asc, name asc"
$query = $clauses -join ' | '

$cmd = @('graph','query','-q',$query,'--first','1000')
if ($SubscriptionIds) { $cmd += @('--subscriptions'); $cmd += $SubscriptionIds }

Write-Host "Scanning for PostgreSQL / MySQL Flexible Servers..." -ForegroundColor Cyan
$raw = @(); $skip = 0
do {
    $b = az @cmd --skip $skip -o json 2>$null | ConvertFrom-Json
    if ($b.data) { $raw += $b.data }
    $total = $b.total_records; $skip += 1000
} while ($b -and $b.data.Count -gt 0 -and $raw.Count -lt $total)

$all = foreach ($r in $raw) {
    $ha = ($r.haMode -and $r.haMode -ne 'Disabled')
    [pscustomobject]@{
        name          = $r.name
        engine        = ($r.engine -replace '^microsoft\.dbfor','' -replace '/flexibleservers','')
        subscriptionId= $r.subscriptionId
        resourceGroup = $r.resourceGroup
        location      = $r.location
        sku           = $r.sku
        tier          = $r.tier
        zone          = $r.zone
        haMode        = if ($r.haMode) { $r.haMode } else { 'Disabled' }
        standbyZone   = $r.standbyZone
        zoneRedundant = ($ha -and $r.haMode -eq 'ZoneRedundant')
        version       = $r.version
    }
}

$all | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($all.Count) Flexible Server(s) -> $OutPath" -ForegroundColor Green

Write-Host "`nBy tier:"
$all | Group-Object tier | Sort-Object Count -Descending | ForEach-Object { "  {0,-18} {1}" -f $_.Name, $_.Count }
Write-Host "`nHigh availability:"
$all | Group-Object haMode | Sort-Object Count -Descending | ForEach-Object { "  {0,-18} {1}" -f $_.Name, $_.Count }
Write-Host "`nZone-redundant (HA across two zones): $(($all | Where-Object zoneRedundant).Count) of $($all.Count)"
Write-Host "Single-zone (no zone-redundant HA):    $(($all | Where-Object {-not $_.zoneRedundant}).Count) of $($all.Count)"
