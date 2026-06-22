<#
.SYNOPSIS
    Model a pooled Quota Group DESIGN from per-subscription quota you can already read - no
    management-group access required.

.DESCRIPTION
    A tenant often has many subscriptions, each with its own per-region core limit. Some sit near
    their cap while others are idle. A Quota Group pools those limits so capacity can flex between
    subscriptions without a separate increase ticket per move.

    This script reads the per-subscription quota CSVs produced by Get-QuotaUsage.ps1
    (regional-totals-*.csv and quota-usage-*.csv) and models, for the analysis region:
      * the pooled limit (sum of member limits) and pooled used / pooled headroom,
      * per-family pooled totals,
      * an "imbalance" signal - how much headroom is stranded in idle subs while others are tight,
      * a suggested pooled allowance.

    It is purely an analysis/design aid - it does NOT create or modify anything. Use it to justify and
    size a Quota Group request even when you only have subscription Reader.

.PARAMETER InputDir
    Folder containing the Get-QuotaUsage CSVs (default ..\output).

.PARAMETER Region
    Analysis region label used in the output filename (default: parsed from the CSV name).

.PARAMETER HeadroomFactor
    Suggested pooled allowance = pooled used * HeadroomFactor, floored at the current pooled limit.
    Default 1.3 (30% headroom over current pooled utilisation).

.EXAMPLE
    .\Get-QuotaGroupPlan.ps1
#>
[CmdletBinding()]
param(
    [string] $InputDir,
    [string] $Region,
    [double] $HeadroomFactor = 1.3
)

. "$PSScriptRoot\Common.ps1"
if (-not $InputDir) { $InputDir = Get-DefaultOutDir }
$date = Get-Date -Format 'yyyyMMdd'

function Get-Latest([string]$pattern) {
    Get-ChildItem -Path $InputDir -Filter $pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

$totalsFile = Get-Latest 'regional-totals-*.csv'
$usageFile  = Get-Latest 'quota-usage-*.csv'
if (-not $totalsFile) {
    Write-Warning "No regional-totals-*.csv found in $InputDir. Run Get-QuotaUsage.ps1 first."
    return
}
if (-not $Region) {
    if ($totalsFile.BaseName -match 'regional-totals-(.+)-\d{8}$') { $Region = $Matches[1] } else { $Region = 'region' }
}

# friendly subscription names
$subMap = @{}
az account list --all --query "[].{id:id,name:name}" -o json 2>$null | ConvertFrom-Json | ForEach-Object { $subMap[$_.id] = $_.name }
function SubName([string]$id) { if ($subMap.ContainsKey($id)) { $subMap[$id] } else { $id } }

$totals = Import-Csv $totalsFile.FullName
$memberCount = $totals.Count

# ---- Total Regional vCPU pool ----
$poolUsed  = ($totals | Measure-Object RegionalvCPU_Used  -Sum).Sum
$poolLimit = ($totals | Measure-Object RegionalvCPU_Limit -Sum).Sum
$poolAvail = $poolLimit - $poolUsed

# stranded headroom: sum of per-sub avail in subs using < 50% of their limit
$stranded = 0
foreach ($t in $totals) {
    $lim = [double]$t.RegionalvCPU_Limit; $usd = [double]$t.RegionalvCPU_Used
    if ($lim -gt 0 -and ($usd / $lim) -lt 0.5) { $stranded += ($lim - $usd) }
}
$suggested = [math]::Max([math]::Ceiling($poolUsed * $HeadroomFactor), $poolLimit)

$planRows = @()
$planRows += [pscustomobject]@{
    Region    = $Region
    Scope     = 'Total Regional vCPUs'
    Members   = $memberCount
    PoolUsed  = $poolUsed
    PoolLimit = $poolLimit
    PoolAvail = $poolAvail
    StrandedHeadroom = $stranded
    SuggestedPool    = $suggested
}

# ---- Per-family pools (from quota-usage-*.csv) ----
if ($usageFile) {
    $usage = Import-Csv $usageFile.FullName
    $cols  = ($usage | Get-Member -MemberType NoteProperty).Name
    $families = $cols | Where-Object { $_ -match '_used$' } | ForEach-Object { $_ -replace '_used$','' } | Sort-Object -Unique
    foreach ($fam in $families) {
        $u = "${fam}_used"; $l = "${fam}_limit"
        $fUsed  = ($usage | Measure-Object $u -Sum).Sum
        $fLimit = ($usage | Measure-Object $l -Sum).Sum
        $fStr = 0
        foreach ($r in $usage) {
            $rl = [double]$r.$l; $ru = [double]$r.$u
            if ($rl -gt 0 -and ($ru / $rl) -lt 0.5) { $fStr += ($rl - $ru) }
        }
        $fSug = [math]::Max([math]::Ceiling($fUsed * $HeadroomFactor), $fLimit)
        $planRows += [pscustomobject]@{
            Region    = $Region
            Scope     = "$fam family"
            Members   = $memberCount
            PoolUsed  = $fUsed
            PoolLimit = $fLimit
            PoolAvail = ($fLimit - $fUsed)
            StrandedHeadroom = $fStr
            SuggestedPool    = $fSug
        }
    }
}

# ---- per-subscription contribution (the imbalance picture) ----
$contrib = foreach ($t in $totals) {
    $lim = [double]$t.RegionalvCPU_Limit; $usd = [double]$t.RegionalvCPU_Used
    $pct = if ($lim -gt 0) { [math]::Round(($usd / $lim) * 100, 1) } else { 0 }
    [pscustomobject]@{
        Region   = $Region
        SubName  = SubName $t.SubId
        SubId    = $t.SubId
        Used     = $usd
        Limit    = $lim
        Avail    = ($lim - $usd)
        UtilPct  = $pct
        Posture  = if ($pct -ge 80) { 'tight' } elseif ($pct -lt 50) { 'idle' } else { 'balanced' }
    }
}

$planCsv    = Join-Path $InputDir "quota-group-plan-$Region-$date.csv"
$contribCsv = Join-Path $InputDir "quota-group-plan-members-$Region-$date.csv"
$planRows | Export-Csv $planCsv -NoTypeInformation -Encoding UTF8
$contrib  | Export-Csv $contribCsv -NoTypeInformation -Encoding UTF8

Write-Host "Pooled quota DESIGN snapshot for '$Region' ($memberCount subscriptions):" -ForegroundColor Cyan
$planRows | Format-Table Scope, PoolUsed, PoolLimit, PoolAvail, StrandedHeadroom, SuggestedPool -AutoSize
Write-Host "Per-subscription posture:" -ForegroundColor Cyan
$contrib | Sort-Object UtilPct -Descending | Format-Table SubName, Used, Limit, UtilPct, Posture -AutoSize
Write-Host "`nExported -> $planCsv" -ForegroundColor Green
Write-Host "Exported -> $contribCsv" -ForegroundColor Green
Write-Host "`nInterpretation: $stranded vCPUs of headroom sit in under-50%-utilised subscriptions while the pool's busiest subs may be near cap. Pooling lets that capacity flex without per-sub tickets." -ForegroundColor DarkGray
