<#
.SYNOPSIS
    Scan regional + zonal SKU enablement across one or many subscriptions and export to CSV.

.DESCRIPTION
    For each subscription, makes ONE Microsoft.Compute/skus REST call and reports, per SKU,
    whether it is regionally enabled and which (logical) availability zones are open.
    This is the core "what is actually switched on" check used to validate capacity readiness.

    Access required: Reader on the target subscriptions. No write access needed.

.PARAMETER Location
    Azure region short name (e.g. 'norwayeast', 'swedencentral', 'westeurope').

.PARAMETER Skus
    SKU names to evaluate (default: a representative AKS-relevant set).

.PARAMETER SubscriptionIds
    Explicit subscription ids. If omitted, uses -SubscriptionCsv, else all visible subs.

.PARAMETER SubscriptionCsv
    CSV containing a 'SubId' (or 'subscriptionId'/'id') and optional 'Name' column.

.PARAMETER OutPath
    CSV output path (default: ..\output\sku-enablement-<location>-<date>.csv).

.EXAMPLE
    .\Scan-SkuEnablement.ps1 -Location norwayeast
.EXAMPLE
    .\Scan-SkuEnablement.ps1 -Location swedencentral -SubscriptionCsv .\mysubs.csv -Skus Standard_D2ads_v6,Standard_B2s_v2
#>
[CmdletBinding()]
param(
    [string]   $Location = 'norwayeast',
    [string[]] $Skus = @('Standard_B2s_v2','Standard_D2ads_v6','Standard_E2ads_v6'),
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutPath) { $OutPath = Join-Path (Get-DefaultOutDir) ("sku-enablement-{0}-{1}.csv" -f $Location, (Get-Date -Format 'yyyyMMdd')) }

$subs = Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv
Write-Host "Scanning $($subs.Count) subscription(s) in $Location for $($Skus.Count) SKU(s)..." -ForegroundColor Cyan

$rows = @(); $i = 0
foreach ($s in $subs) {
    $i++; Write-Progress -Activity "SKU enablement scan" -Status "$($s.Name)" -PercentComplete (($i/$subs.Count)*100)
    $all = Get-ComputeSkus -SubId $s.SubId -Location $Location
    $rec = [ordered]@{ Name = $s.Name; SubId = $s.SubId }
    foreach ($skuName in $Skus) {
        $sku = $all | Where-Object { $_.name -eq $skuName } | Select-Object -First 1
        $st  = Resolve-SkuStatus -Sku $sku
        $short = ($skuName -replace '^Standard_','')
        $rec["$short`_reg"]   = $st.Regional
        $rec["$short`_zones"] = $st.Zones
    }
    $rows += [pscustomobject]$rec
}
Write-Progress -Activity "SKU enablement scan" -Completed

$rows | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($rows.Count) rows -> $OutPath" -ForegroundColor Green

# Console summary per SKU
foreach ($skuName in $Skus) {
    $short = ($skuName -replace '^Standard_','')
    $reg   = ($rows | Where-Object { $_."$short`_reg" -eq 'Enabled' }).Count
    $full  = ($rows | Where-Object { $_."$short`_zones" -eq '1,2,3' }).Count
    Write-Host ("  {0,-22} regional {1}/{2}   all-3-zones {3}/{2}" -f $skuName, $reg, $rows.Count, $full)
}
