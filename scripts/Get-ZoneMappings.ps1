<#
.SYNOPSIS
    Resolve the per-subscription logical -> physical Availability Zone mapping and export to CSV.

.DESCRIPTION
    Azure assigns each SUBSCRIPTION its own logical->physical zone mapping, so "zone 1" in one
    subscription can be a different datacenter than "zone 1" in another. SKU zone restrictions are
    reported in LOGICAL zone numbers, so to reason about physical resilience (and to set AKS
    --zones correctly) you must translate them per subscription.

    Access required: Reader on the target subscriptions.

.PARAMETER Location
    Azure region short name (e.g. 'norwayeast').

.PARAMETER SubscriptionIds / SubscriptionCsv / OutPath
    See Scan-SkuEnablement.ps1.

.EXAMPLE
    .\Get-ZoneMappings.ps1 -Location norwayeast -SubscriptionCsv .\mysubs.csv
#>
[CmdletBinding()]
param(
    [string]   $Location = 'norwayeast',
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutPath) { $OutPath = Join-Path (Get-DefaultOutDir) ("zone-mappings-{0}-{1}.csv" -f $Location, (Get-Date -Format 'yyyyMMdd')) }

$subs = Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv
Write-Host "Resolving zone mappings for $($subs.Count) subscription(s) in $Location..." -ForegroundColor Cyan

$rows = @(); $i = 0
foreach ($s in $subs) {
    $i++; Write-Progress -Activity "Zone mapping" -Status "$($s.Name)" -PercentComplete (($i/$subs.Count)*100)
    $url = "https://management.azure.com/subscriptions/$($s.SubId)/locations?api-version=2022-12-01"
    $loc = az rest --method get --url $url -o json 2>$null | ConvertFrom-Json
    $map = ($loc.value | Where-Object { $_.name -eq $Location }).availabilityZoneMappings
    $rec = [ordered]@{ Name = $s.Name; SubId = $s.SubId }
    foreach ($lz in '1','2','3') {
        $phys = ($map | Where-Object { $_.logicalZone -eq $lz }).physicalZone
        $rec["logical$lz"] = if ($phys) { $phys } else { 'n/a' }
    }
    # Compact pattern e.g. "1->az2,2->az3,3->az1"
    $rec['Pattern'] = (($map | Sort-Object { [int]$_.logicalZone } | ForEach-Object { "$($_.logicalZone)->$($_.physicalZone -replace '.*-','')" }) -join ',')
    $rows += [pscustomobject]$rec
}
Write-Progress -Activity "Zone mapping" -Completed

$rows | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($rows.Count) rows -> $OutPath" -ForegroundColor Green
$rows | Format-Table Name, logical1, logical2, logical3 -AutoSize
