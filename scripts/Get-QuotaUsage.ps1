<#
.SYNOPSIS
    Export per-subscription VM-family quota (used / limit / available) to CSV.

.DESCRIPTION
    Uses `az vm list-usage` to read the current usage and limit for the chosen compute
    quota families in a region, across one or many subscriptions. This answers
    "do they have capacity headroom?" - distinct from "is the SKU enabled?" (which is
    Scan-SkuEnablement.ps1). Remember: quota is NOT guaranteed capacity.

    Access required: Reader on the target subscriptions.

.PARAMETER Families
    Quota family names as returned by `az vm list-usage` (e.g. 'standardBsv2Family').

.EXAMPLE
    .\Get-QuotaUsage.ps1 -Location norwayeast -SubscriptionCsv .\mysubs.csv
#>
[CmdletBinding()]
param(
    [string]   $Location = 'norwayeast',
    [string[]] $Families = @('standardBsv2Family','standardDadv6Family','standardEadv6Family'),
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutPath) { $OutPath = Join-Path (Get-DefaultOutDir) ("quota-usage-{0}-{1}.csv" -f $Location, (Get-Date -Format 'yyyyMMdd')) }

$subs = Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv
Write-Host "Reading quota for $($subs.Count) subscription(s) in $Location..." -ForegroundColor Cyan

$rows = @(); $i = 0
$totals = @{}
foreach ($s in $subs) {
    $i++; Write-Progress -Activity "Quota usage" -Status "$($s.Name)" -PercentComplete (($i/$subs.Count)*100)
    az account set --subscription $s.SubId 2>$null
    $usage = az vm list-usage -l $Location -o json 2>$null | ConvertFrom-Json
    $rec = [ordered]@{ Name = $s.Name; SubId = $s.SubId }
    foreach ($f in $Families) {
        $u = $usage | Where-Object { $_.name.value -eq $f } | Select-Object -First 1
        $cur = if ($u) { [int]$u.currentValue } else { 0 }
        $lim = if ($u) { [int]$u.limit } else { 0 }
        $short = ($f -replace 'Family$','' -replace '^standard','')
        $rec["$short`_used"]  = $cur
        $rec["$short`_limit"] = $lim
        $rec["$short`_avail"] = $lim - $cur
        if (-not $totals.ContainsKey($short)) { $totals[$short] = @{ used=0; limit=0 } }
        $totals[$short].used  += $cur
        $totals[$short].limit += $lim
    }
    $rows += [pscustomobject]$rec
}
Write-Progress -Activity "Quota usage" -Completed

$rows | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($rows.Count) rows -> $OutPath" -ForegroundColor Green
foreach ($k in $totals.Keys) {
    $t = $totals[$k]
    Write-Host ("  TOTAL {0,-12} used {1} / limit {2} / available {3}" -f $k, $t.used, $t.limit, ($t.limit - $t.used))
}
