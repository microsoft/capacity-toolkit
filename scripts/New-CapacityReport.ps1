<#
.SYNOPSIS
    One-shot capacity & enablement report: runs the SKU-enablement, zone-mapping and quota scans,
    joins them into a single CSV + a Markdown summary you can paste into a status update.

.DESCRIPTION
    Orchestrates the individual scripts and produces:
      * combined-capacity-report-<region>-<date>.csv  (one row per subscription, all signals)
      * combined-capacity-report-<region>-<date>.md   (executive-style summary + table)
    Optionally appends a tenant-wide AKS inventory.

    Access required: Reader on the target subscriptions.

.EXAMPLE
    .\New-CapacityReport.ps1 -Location norwayeast -SubscriptionCsv .\mysubs.csv -IncludeAks
#>
[CmdletBinding()]
param(
    [string]   $Location = 'norwayeast',
    [string[]] $Skus = @('Standard_B2s_v2','Standard_D2ads_v6','Standard_E2ads_v6'),
    [string[]] $Families = @('standardBsv2Family','standardDadv6Family','standardEadv6Family'),
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [switch]   $IncludeAks,
    [switch]   $IncludeZonal,
    [switch]   $IncludeCatalogue,
    [switch]   $IncludeInventory,
    [switch]   $IncludeQuotaGroups,
    [switch]   $Dashboard,
    [switch]   $EnablementRequest,
    [string[]] $EvaluateRegions,
    [string]   $SecondaryRegion,
    [string]   $ConfigPath,
    [string]   $OutDir
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutDir) { $OutDir = Get-DefaultOutDir }
$date = Get-Date -Format 'yyyyMMdd'

# Optional config from Get-UsedSkus.ps1: supplies location, skus, families and (optionally) subscriptions.
# Explicit parameters always win over the config file.
if ($ConfigPath) {
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('Location')  -and $cfg.location)  { $Location = $cfg.location }
    if (-not $PSBoundParameters.ContainsKey('Skus')      -and $cfg.skus)      { $Skus     = @($cfg.skus) }
    if (-not $PSBoundParameters.ContainsKey('Families')  -and $cfg.families)  { $Families = @($cfg.families) }
    if (-not $PSBoundParameters.ContainsKey('SubscriptionIds') -and -not $SubscriptionCsv -and $cfg.subscriptions) {
        $SubscriptionIds = @($cfg.subscriptions | ForEach-Object { $_.id } | Where-Object { $_ })
    }
    Write-Host "Loaded config $ConfigPath -> region $Location, $($Skus.Count) SKU(s), $($Families.Count) family(ies)" -ForegroundColor Cyan
}

# Run the three core scans into temp CSVs
$skuCsv   = Join-Path $OutDir "sku-enablement-$Location-$date.csv"
$zoneCsv  = Join-Path $OutDir "zone-mappings-$Location-$date.csv"
$quotaCsv = Join-Path $OutDir "quota-usage-$Location-$date.csv"

& "$PSScriptRoot\Scan-SkuEnablement.ps1" -Location $Location -Skus $Skus -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv -OutPath $skuCsv
& "$PSScriptRoot\Get-ZoneMappings.ps1"   -Location $Location -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv -OutPath $zoneCsv
& "$PSScriptRoot\Get-QuotaUsage.ps1"     -Location $Location -Families $Families -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv -OutPath $quotaCsv

# Join on SubId
$sku   = Import-Csv $skuCsv
$zone  = @{}; Import-Csv $zoneCsv  | ForEach-Object { $zone[$_.SubId]  = $_ }
$quota = @{}; Import-Csv $quotaCsv | ForEach-Object { $quota[$_.SubId] = $_ }

$combined = foreach ($r in $sku) {
    $z = $zone[$r.SubId]; $q = $quota[$r.SubId]
    $out = [ordered]@{ Name = $r.Name; SubId = $r.SubId }
    $r.PSObject.Properties | Where-Object { $_.Name -notin 'Name','SubId' } | ForEach-Object { $out[$_.Name] = $_.Value }
    if ($z) { $out['ZonePattern'] = $z.Pattern }
    if ($q) { $q.PSObject.Properties | Where-Object { $_.Name -notin 'Name','SubId' } | ForEach-Object { $out[$_.Name] = $_.Value } }
    [pscustomobject]$out
}
$combinedCsv = Join-Path $OutDir "combined-capacity-report-$Location-$date.csv"
$combined | Export-Csv $combinedCsv -NoTypeInformation -Encoding UTF8

# Markdown summary
$md = @()
$md += "# Capacity & Enablement Report - $Location"
$md += ""
$md += "| Field | Value |"
$md += "|---|---|"
$md += "| Date | $(Get-Date -Format 'yyyy-MM-dd HH:mm') |"
$md += "| Region | $Location |"
$md += "| Subscriptions scanned | $($combined.Count) |"
$md += "| SKUs | $($Skus -join ', ') |"
$md += ""
$md += "## Enablement summary"
$md += ""
$md += "| SKU | Regional enabled | All-3-zones |"
$md += "|---|---|---|"
foreach ($skuName in $Skus) {
    $short = ($skuName -replace '^Standard_','')
    $reg  = ($combined | Where-Object { $_."$short`_reg" -eq 'Enabled' }).Count
    $full = ($combined | Where-Object { $_."$short`_zones" -eq '1,2,3' }).Count
    $md += "| $skuName | $reg / $($combined.Count) | $full / $($combined.Count) |"
}
$md += ""
$md += "## Per-subscription detail"
$md += ""
$hdr = @('Subscription','SubId')
foreach ($skuName in $Skus) { $short = ($skuName -replace '^Standard_',''); $hdr += "$short reg"; $hdr += "$short zones" }
$hdr += 'Zone pattern'
$md += "| " + ($hdr -join ' | ') + " |"
$md += "|" + (($hdr | ForEach-Object { '---' }) -join '|') + "|"
foreach ($c in $combined) {
    $cells = @($c.Name, $c.SubId)
    foreach ($skuName in $Skus) { $short = ($skuName -replace '^Standard_',''); $cells += $c."$short`_reg"; $cells += $c."$short`_zones" }
    $cells += $c.ZonePattern
    $md += "| " + ($cells -join ' | ') + " |"
}
$combinedMd = Join-Path $OutDir "combined-capacity-report-$Location-$date.md"
$md -join "`n" | Set-Content $combinedMd -Encoding UTF8

if ($IncludeAks) {
    $aksCsv = Join-Path $OutDir "aks-inventory-$date.csv"
    & "$PSScriptRoot\Get-AksInventory.ps1" -Location $Location -OutPath $aksCsv
}

if ($IncludeZonal) {
    & "$PSScriptRoot\Get-ZonalResourceInventory.ps1" -Location $Location -SubscriptionIds $SubscriptionIds -OutPath (Join-Path $OutDir "zonal-resources-$date.csv")
    & "$PSScriptRoot\Get-FlexServerZones.ps1"        -Location $Location -SubscriptionIds $SubscriptionIds -OutPath (Join-Path $OutDir "flexserver-zones-$date.csv")
}

if ($IncludeCatalogue) {
    & "$PSScriptRoot\Get-SkuCatalogue.ps1" -Location $Location -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv -OutDir $OutDir
}

if ($IncludeInventory) {
    & "$PSScriptRoot\Get-ResourceInventory.ps1" -Location $Location -SubscriptionIds $SubscriptionIds -OutPath (Join-Path $OutDir "resource-inventory-$date.csv")
}

if ($EvaluateRegions) {
    & "$PSScriptRoot\Get-RegionFootprint.ps1" -EvaluateRegions $EvaluateRegions -Skus $Skus -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv -OutDir $OutDir
}

if ($IncludeQuotaGroups) {
    # Existing pools (management-group scope; defensive if none visible)...
    $qgRegions = @($Location); if ($EvaluateRegions) { $qgRegions += $EvaluateRegions }
    & "$PSScriptRoot\Get-QuotaGroups.ps1" -Regions ($qgRegions | Select-Object -Unique) -OutDir $OutDir
    # ...and a pooled-quota DESIGN snapshot from the per-sub quota already scanned (subscription Reader only).
    & "$PSScriptRoot\Get-QuotaGroupPlan.ps1" -InputDir $OutDir -Region $Location
}

if ($EnablementRequest) {
    & "$PSScriptRoot\New-EnablementRequest.ps1" -Location $Location -Skus $Skus -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv -OutDir $OutDir
}

if ($Dashboard) {
    $dashArgs = @{ InputDir = $OutDir; Location = $Location }
    if ($SecondaryRegion) { $dashArgs['SecondaryRegion'] = $SecondaryRegion }
    & "$PSScriptRoot\New-CapacityDashboard.ps1" @dashArgs
}

Write-Host "`n=== Report complete ===" -ForegroundColor Green
Write-Host "  CSV : $combinedCsv"
Write-Host "  MD  : $combinedMd"
if ($Dashboard) { Write-Host "  HTML: $(Join-Path $OutDir "capacity-dashboard-$date.html")" }
