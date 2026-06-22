<#
.SYNOPSIS
    Complete-sight catalogue of EVERY VM SKU family in a region: regional + zonal enablement, quota
    head-room (used / limit / available) and whether you actually use it today - across one or many
    subscriptions. Unlike Scan-SkuEnablement (which checks a chosen SKU list) this enumerates the whole
    Microsoft.Compute SKU catalogue, so nothing enabled-but-unused or blocked-but-needed slips through.

.DESCRIPTION
    For each subscription in scope and the target region it:
      1. Reads the full Microsoft.Compute/skus catalogue and resolves each SKU's regional + zonal status.
      2. Reads every `az vm list-usage` row (all families + the Total Regional vCPUs and Spot totals).
      3. Aggregates to FAMILY level and joins enablement to quota (family code == SKU family field).
      4. Cross-references the discovered in-use SKUs (Get-UsedSkus.ps1 / used-skus CSV) so each family is
         tagged InUse / not, with the deployed instance count.

    Outputs:
      * sku-catalogue-<region>-<date>.csv  - one row per family: enablement coverage + summed quota + in-use
      * regional-totals-<region>-<date>.csv - per-subscription Total Regional vCPUs and Spot vCPUs

    Console highlights three things that matter for "complete sight":
      * Enabled + quota but UNUSED  -> latent head-room you already have
      * IN USE but BLOCKED / low head-room -> risk
      * Blocked families              -> what a support request would need to cover

    Access required: Reader on the target subscriptions.

.PARAMETER Location
    Region to catalogue (default norwayeast).

.PARAMETER SubscriptionIds
    Explicit subscription IDs. Omit to scan every visible subscription.

.PARAMETER SubscriptionCsv
    CSV (Name,SubId) to scope the scan. Overridden by -SubscriptionIds.

.PARAMETER UsedSkusCsv
    Optional used-skus-*.csv from Get-UsedSkus.ps1 to flag in-use families. If omitted the newest one in
    -OutDir is used automatically (when present).

.PARAMETER OnlyRelevant
    Hide families that are not offered in the region AND have zero quota AND are not in use (cuts ~150
    legacy/empty rows). Off by default - full catalogue is the point.

.PARAMETER OutDir
    Output folder (default ..\output).

.EXAMPLE
    .\Get-SkuCatalogue.ps1 -Location norwayeast -SubscriptionCsv .\output\my-subs.csv
#>
[CmdletBinding()]
param(
    [string]   $Location = 'norwayeast',
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [string]   $UsedSkusCsv,
    [switch]   $OnlyRelevant,
    [string]   $OutDir
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutDir) { $OutDir = Get-DefaultOutDir }
$date = Get-Date -Format 'yyyyMMdd'

$subs = Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv
if (-not $subs) { throw "No subscriptions resolved." }

# In-use map (family -> instance count) from discovery, if available
if (-not $UsedSkusCsv) {
    $latest = Get-ChildItem -Path $OutDir -Filter "used-skus-$Location-*.csv" -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $UsedSkusCsv = $latest.FullName }
}
$inUseFam = @{}
if ($UsedSkusCsv -and (Test-Path $UsedSkusCsv)) {
    Import-Csv $UsedSkusCsv | ForEach-Object {
        if ($_.Family -and $_.Family -notlike '(not offered*') {
            $inUseFam[$_.Family] = [int]($inUseFam[$_.Family]) + [int]$_.Total
        }
    }
    Write-Host "In-use reference: $UsedSkusCsv ($($inUseFam.Count) family(ies) deployed)" -ForegroundColor DarkGray
}

function Series([string]$family) {
    if ($family -match '(?i)^standard([A-Z]+)') { return $matches[1].Substring(0,1).ToUpper() }
    if ($family -match '(?i)^basic([A-Z])')     { return $matches[1].ToUpper() }
    return '?'
}

Write-Host "Cataloguing all SKU families in $Location across $($subs.Count) subscription(s)..." -ForegroundColor Cyan

# Accumulators keyed by family
$fam = @{}              # family -> @{ Series; Offered; Enabled; Blocked; Zones=@{pattern->count}; SkuNames=set }
$famQuota = @{}         # family -> @{ Used; Limit; Avail }
$totals = @()           # per-sub regional + spot totals

function Ensure-Fam([string]$f) {
    if (-not $fam.ContainsKey($f)) {
        $fam[$f] = [ordered]@{ Series=(Series $f); Offered=0; Enabled=0; Blocked=0; Zones=@{}; Skus=@{} }
    }
    if (-not $famQuota.ContainsKey($f)) { $famQuota[$f] = [ordered]@{ Used=0; Limit=0; Avail=0 } }
}

foreach ($s in $subs) {
    $catalogue = Get-ComputeSkus -SubId $s.SubId -Location $Location
    # group SKUs by family, compute per-family enablement for THIS sub
    $bySkuFamily = @{}
    foreach ($sku in $catalogue) {
        if ($sku.resourceType -ne 'virtualMachines') { continue }
        if (-not $sku.family) { continue }
        $st = Resolve-SkuStatus -Sku $sku
        $f = $sku.family
        if (-not $bySkuFamily.ContainsKey($f)) { $bySkuFamily[$f] = [ordered]@{ AnyEnabled=$false; AllBlocked=$true; Zones=@{}; Skus=@{} } }
        $bySkuFamily[$f].Skus[$sku.name] = $true
        if ($st.Regional -eq 'Enabled') {
            $bySkuFamily[$f].AnyEnabled = $true; $bySkuFamily[$f].AllBlocked = $false
            $z = $st.Zones
            $bySkuFamily[$f].Zones[$z] = [int]$bySkuFamily[$f].Zones[$z] + 1
        }
    }
    foreach ($f in $bySkuFamily.Keys) {
        Ensure-Fam $f
        $fam[$f].Offered++
        foreach ($k in $bySkuFamily[$f].Skus.Keys) { $fam[$f].Skus[$k] = $true }
        if ($bySkuFamily[$f].AnyEnabled) {
            $fam[$f].Enabled++
            # dominant zone pattern for this sub/family
            $zp = ($bySkuFamily[$f].Zones.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
            if ($zp) { $fam[$f].Zones[$zp] = [int]$fam[$f].Zones[$zp] + 1 }
        } else {
            $fam[$f].Blocked++
        }
    }
    # quota for this sub: all families + totals
    $usage = az vm list-usage --location $Location --subscription $s.SubId -o json 2>$null | ConvertFrom-Json
    $tReg = $usage | Where-Object { $_.name.value -eq 'cores' } | Select-Object -First 1
    $tSpot= $usage | Where-Object { $_.name.value -eq 'lowPriorityCores' } | Select-Object -First 1
    $totals += [pscustomobject]@{
        Name = $s.Name; SubId = $s.SubId
        RegionalvCPU_Used  = [int]$tReg.currentValue;  RegionalvCPU_Limit  = [int]$tReg.limit
        RegionalvCPU_Avail = ([int]$tReg.limit - [int]$tReg.currentValue)
        SpotvCPU_Used = [int]$tSpot.currentValue; SpotvCPU_Limit = [int]$tSpot.limit
    }
    foreach ($row in $usage) {
        $code = $row.name.value
        if ($code -notmatch 'Family$') { continue }
        Ensure-Fam $code
        $famQuota[$code].Used  += [int]$row.currentValue
        $famQuota[$code].Limit += [int]$row.limit
        $famQuota[$code].Avail += ([int]$row.limit - [int]$row.currentValue)
    }
}

$subCount = $subs.Count
$rows = foreach ($f in ($fam.Keys | Sort-Object)) {
    $q = $famQuota[$f]
    $zp = ($fam[$f].Zones.GetEnumerator() | Sort-Object Value -Descending |
           ForEach-Object { "$($_.Key) [$($_.Value)]" }) -join '; '
    $inUse = $inUseFam.ContainsKey($f)
    [pscustomobject]@{
        Family        = $f
        Series        = $fam[$f].Series
        OfferedSubs   = $fam[$f].Offered
        EnabledSubs   = $fam[$f].Enabled
        BlockedSubs   = $fam[$f].Blocked
        ZonePatterns  = $zp
        SkuCount      = $fam[$f].Skus.Count
        QuotaUsed     = [int]$q.Used
        QuotaLimit    = [int]$q.Limit
        QuotaAvail    = [int]$q.Avail
        InUse         = $inUse
        InstancesInUse= if ($inUse) { $inUseFam[$f] } else { 0 }
    }
}

if ($OnlyRelevant) {
    $rows = $rows | Where-Object { $_.OfferedSubs -gt 0 -or $_.QuotaLimit -gt 0 -or $_.InUse }
}
$rows = $rows | Sort-Object @{e='InUse';Descending=$true}, @{e='QuotaAvail';Descending=$true}, Family

$catCsv = Join-Path $OutDir "sku-catalogue-$Location-$date.csv"
$rows | Export-Csv $catCsv -NoTypeInformation -Encoding UTF8
$totCsv = Join-Path $OutDir "regional-totals-$Location-$date.csv"
$totals | Export-Csv $totCsv -NoTypeInformation -Encoding UTF8

Write-Host "`nCatalogue -> $catCsv  ($($rows.Count) families)" -ForegroundColor Green
Write-Host "Totals    -> $totCsv" -ForegroundColor Green

# Regional totals summary
$rt = $totals | Measure-Object RegionalvCPU_Avail -Sum
Write-Host "`nTotal Regional vCPUs available across scope: $([int]$rt.Sum)" -ForegroundColor Cyan

# Highlights
$enabledUnused = $rows | Where-Object { $_.EnabledSubs -gt 0 -and -not $_.InUse -and $_.QuotaAvail -gt 0 } | Sort-Object QuotaAvail -Descending
$usedBlocked   = $rows | Where-Object { $_.InUse -and $_.BlockedSubs -gt 0 }
$usedLowHead   = $rows | Where-Object { $_.InUse -and $_.QuotaLimit -gt 0 -and ($_.QuotaAvail / [math]::Max(1,$_.QuotaLimit)) -lt 0.15 }
$blocked       = $rows | Where-Object { $_.OfferedSubs -gt 0 -and $_.EnabledSubs -eq 0 }

Write-Host "`n-- Enabled with quota but NOT in use (latent head-room) --" -ForegroundColor Yellow
$enabledUnused | Select-Object Family, Series, EnabledSubs, ZonePatterns, QuotaAvail -First 12 | Format-Table -Auto | Out-String | Write-Host

if ($usedBlocked) {
    Write-Host "-- IN USE but BLOCKED on one or more subscriptions (risk) --" -ForegroundColor Red
    $usedBlocked | Select-Object Family, EnabledSubs, BlockedSubs, InstancesInUse, QuotaAvail | Format-Table -Auto | Out-String | Write-Host
}
if ($usedLowHead) {
    Write-Host "-- IN USE with < 15% quota head-room (risk) --" -ForegroundColor Red
    $usedLowHead | Select-Object Family, QuotaUsed, QuotaLimit, QuotaAvail, InstancesInUse | Format-Table -Auto | Out-String | Write-Host
}
Write-Host "Families offered but fully blocked in $Location (scope): $($blocked.Count)" -ForegroundColor DarkGray
