#Requires -Version 7.0
<#
.SYNOPSIS
    Turns a quota report into a populated Deploy-QuotaGroups.ps1 design file.

.DESCRIPTION
    Takes a "skeleton" quota-groups config (groups + members + managementGroupId, with
    empty groupLimits/allocations) and a quota report CSV, and produces a fully populated
    config ready for Deploy-QuotaGroups.ps1.

    Two report formats are auto-detected:

      1. Toolkit-native (this repo) - the WIDE quota-usage-*.csv emitted by Get-QuotaUsage.ps1.
         One row per subscription; per-family columns '<short>_used' / '<short>_limit'
         (e.g. Bsv2_used, Bsv2_limit). The short name is unpivoted back to the Quota API
         family token: "standard<short>family" (lowercase). Because this format has no
         per-row location, the region is taken from -Locations (single region; default
         norwayeast).

      2. External - the LONG CSV from martinopedal/azure-quota-reports (Get-AzureQuotas.ps1),
         with Provider / QuotaId / Limit / CurrentUsage / SubscriptionId / Location columns.

    For each group this script computes:
      allocations  : per member/location/family, limit = that member's CURRENT Limit
                     (preserves existing capacity - no subscription loses quota)
      groupLimits  : per location/family, limit = sum(member current Limits) + headroom buffer
                     (the headroom is the shared pool the group can move between members)

    Only VM families (matching -FamilyFilter, default '...Family$') with usage above
    -MinUsage on at least one member are included, keeping configs focused.

.PARAMETER SkeletonConfig
    Path to a quota-groups config containing groups with name/displayName/managementGroupId/members.
    groupLimits and allocations are (re)generated. See ../examples/quota-groups.sample.json.

.PARAMETER QuotaReportCsv
    Path to either a toolkit quota-usage-*.csv or an external azure-quota-reports CSV.
    The format is detected from the column headers.

.PARAMETER OutputConfig
    Where to write the populated config JSON.

.PARAMETER Locations
    External format: restrict to these locations (default norwayeast; '*' for all).
    Toolkit format: the single region the wide CSV represents (first value is used).

.PARAMETER FamilyFilter
    Regex (case-insensitive) selecting which compute quota families to include. Default 'Family$'
    (VM SKU families; excludes aggregate counters like 'cores' / 'virtualMachines').

.PARAMETER MinUsage
    A family is included for a group only if at least one member's CurrentUsage exceeds this.
    Default 0 (any usage). Set to -1 to include every family the members have quota for.

.PARAMETER HeadroomPercent
    Shared buffer added on top of the summed member limits to form the group limit. Default 20.

.PARAMETER PreserveExistingLimits
    allocations use each member's current Limit (default). With -PreserveExistingLimits:$false,
    allocations use CurrentUsage instead (tighter; subscriptions keep only what they use).

.EXAMPLE
    # Toolkit-native: feed the wide quota-usage CSV straight from Get-QuotaUsage.ps1
    ./New-QuotaGroupConfig.ps1 -SkeletonConfig ../examples/quota-groups.sample.json `
        -QuotaReportCsv ../output/quota-usage-20260101.csv -OutputConfig ./my-design.json

.EXAMPLE
    # External azure-quota-reports CSV, tighter allocations + 30% buffer, two regions
    ./New-QuotaGroupConfig.ps1 -SkeletonConfig ./skeleton.json `
        -QuotaReportCsv ./AzureQuotas.csv -OutputConfig ./out.json `
        -Locations norwayeast,westeurope -HeadroomPercent 30 -PreserveExistingLimits:$false
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SkeletonConfig,
    [Parameter(Mandatory)][string]$QuotaReportCsv,
    [Parameter(Mandatory)][string]$OutputConfig,
    [string[]]$Locations = @('norwayeast'),
    [string]$FamilyFilter = 'Family$',
    [int]$MinUsage = 0,
    [ValidateRange(0, 1000)][int]$HeadroomPercent = 20,
    [bool]$PreserveExistingLimits = $true
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SkeletonConfig)) { throw "Skeleton config not found: $SkeletonConfig" }
if (-not (Test-Path $QuotaReportCsv)) { throw "Quota report CSV not found: $QuotaReportCsv" }

$cfg = Get-Content $SkeletonConfig -Raw | ConvertFrom-Json
if (-not $cfg.groups) { throw "Skeleton has no 'groups'." }

$rows = @(Import-Csv $QuotaReportCsv)
if ($rows.Count -eq 0) { throw "Quota report CSV is empty: $QuotaReportCsv" }

$cols = @($rows[0].PSObject.Properties.Name)
$subCol = @('SubscriptionId', 'SubId', 'Subscription', 'subscriptionId') | Where-Object { $cols -contains $_ } | Select-Object -First 1

# --- Normalize either format into a flat list of {SubscriptionId, Location, ResourceName, Limit, CurrentUsage} ---
$norm = [System.Collections.Generic.List[object]]::new()

if ($cols -contains 'QuotaId') {
    # External azure-quota-reports format (long).
    $format = 'external (azure-quota-reports)'
    $wantAll = ($Locations -contains '*')
    if (-not $subCol) { throw "External report is missing a subscription id column (SubscriptionId)." }
    foreach ($r in $rows) {
        if ($r.Provider -and $r.Provider -ne 'Microsoft.Compute') { continue }
        if (-not ($r.QuotaId -imatch $FamilyFilter)) { continue }
        if (-not ($wantAll -or ($Locations -contains $r.Location))) { continue }
        $norm.Add([pscustomobject]@{
            SubscriptionId = "$($r.$subCol)"
            Location       = "$($r.Location)"
            ResourceName   = "$($r.QuotaId)".ToLower()
            Limit          = [long]$r.Limit
            CurrentUsage   = [long]$r.CurrentUsage
        })
    }
}
elseif (($cols -contains 'SubId') -and ($cols | Where-Object { $_ -match '_limit$' })) {
    # Toolkit-native wide quota-usage format. Unpivot '<short>_limit' / '<short>_used' pairs.
    $format = 'toolkit (quota-usage wide)'
    $loc = if ($Locations -contains '*') { 'norwayeast' } else { $Locations[0] }
    if ($Locations.Count -gt 1) {
        Write-Warning "Toolkit wide CSV has no per-row location; using first -Locations value '$loc'."
    }
    $limitCols = @($cols | Where-Object { $_ -match '_limit$' })
    foreach ($r in $rows) {
        $sid = "$($r.SubId)"
        foreach ($lc in $limitCols) {
            $short = $lc -replace '_limit$', ''
            $resourceName = ("standard$($short)family").ToLower()
            if (-not ($resourceName -imatch $FamilyFilter)) { continue }
            $limVal = 0; $useVal = 0
            [long]::TryParse("$($r.$lc)", [ref]$limVal) | Out-Null
            $usedCol = "${short}_used"
            if ($cols -contains $usedCol) { [long]::TryParse("$($r.$usedCol)", [ref]$useVal) | Out-Null }
            if ($limVal -le 0 -and $useVal -le 0) { continue }
            $norm.Add([pscustomobject]@{
                SubscriptionId = $sid
                Location       = $loc
                ResourceName   = $resourceName
                Limit          = $limVal
                CurrentUsage   = $useVal
            })
        }
    }
}
else {
    throw "Unrecognized quota report format. Expected an external report with a 'QuotaId' column, or a toolkit quota-usage CSV with 'SubId' + '<family>_limit' columns. Found columns: $($cols -join ', ')"
}

# Index by subscriptionId for fast per-group lookup.
$bySub = @{}
foreach ($r in $norm) {
    $sid = $r.SubscriptionId.ToLower()
    if (-not $bySub.ContainsKey($sid)) { $bySub[$sid] = [System.Collections.Generic.List[object]]::new() }
    $bySub[$sid].Add($r)
}

Write-Host "Report format : $format" -ForegroundColor Cyan
Write-Host "Loaded $($norm.Count) compute family rows (filter '$FamilyFilter')." -ForegroundColor Cyan
$allocSource = if ($PreserveExistingLimits) { 'current Limit' } else { 'current Usage' }
Write-Host "Headroom: $HeadroomPercent%  |  Allocations from: $allocSource" -ForegroundColor Cyan

$grandFamilies = 0
foreach ($g in $cfg.groups) {
    $memberIds = @($g.members | ForEach-Object { "$_".ToLower() })

    $memberRows = foreach ($sid in $memberIds) { if ($bySub.ContainsKey($sid)) { $bySub[$sid] } }
    $memberRows = @($memberRows)

    $allocations = [System.Collections.Generic.List[object]]::new()
    $groupLimits = [System.Collections.Generic.List[object]]::new()

    $byLocFam = $memberRows | Group-Object { "$($_.Location)|$($_.ResourceName)" }
    foreach ($lf in $byLocFam) {
        $parts = $lf.Name -split '\|', 2
        $loc = $parts[0]; $resourceName = $parts[1]
        $famRows = $lf.Group

        $maxUsage = ($famRows | ForEach-Object { [long]$_.CurrentUsage } | Measure-Object -Maximum).Maximum
        if ($MinUsage -ge 0 -and $maxUsage -le $MinUsage) { continue }

        $sumLimits = 0
        foreach ($r in $famRows) {
            $allocVal = if ($PreserveExistingLimits) { [long]$r.Limit } else { [long]$r.CurrentUsage }
            $sumLimits += [long]$r.Limit
            $allocations.Add([ordered]@{
                subscription = $r.SubscriptionId
                location     = $loc
                resourceName = $resourceName
                limit        = $allocVal
            })
        }
        $groupTotal = [math]::Ceiling($sumLimits * (1 + $HeadroomPercent / 100.0))
        $groupLimits.Add([ordered]@{
            location     = $loc
            resourceName = $resourceName
            limit        = [int]$groupTotal
            comment      = "Sum of $($famRows.Count) member limits ($sumLimits) + $HeadroomPercent% headroom"
        })
        $grandFamilies++
    }

    $g.groupLimits = $groupLimits
    $g.allocations = $allocations
    Write-Host ("  {0,-26} families={1,-3} allocations={2}" -f $g.name, $groupLimits.Count, $allocations.Count)
}

$cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputConfig -Encoding UTF8
Write-Host "`nWrote populated config: $OutputConfig" -ForegroundColor Green
Write-Host "Total (group x location x family) limits: $grandFamilies" -ForegroundColor Green
Write-Host "Next: ./Deploy-QuotaGroups.ps1 -ConfigPath '$OutputConfig' -Action Validate" -ForegroundColor Yellow
