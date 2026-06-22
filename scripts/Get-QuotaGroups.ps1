<#
.SYNOPSIS
    Analyse Azure Quota Groups - discover whether a tenant already pools quota across subscriptions,
    how each group is DESIGNED (group type, member subscriptions, and any per-region/family pooled
    limits), via the Microsoft.Quota groupQuotas API.

.DESCRIPTION
    Quota Groups (a.k.a. allocation groups) let you pool subscriptions so a regional core
    allowance can flex between them without a per-subscription increase ticket for every move.
    This script answers:
      * Does this tenant already have quota groups?         (discovery)
      * How are they designed?                             (group type + member subscriptions)
      * Are pooled limits / allocations actually set?      (per-region/family limits, if any)

    It writes up to three CSVs:
      quota-groups-<date>.csv          one summary row per group (type, member count, regions w/ limits)
      quota-group-members-<date>.csv   one row per (group, member subscription)
      quota-group-limits-<date>.csv    one row per (group, region, family) pooled limit (only if any set)

    ACCESS: Quota Groups live at management-group scope. This script discovers management groups via the
    ARM REST API (Microsoft.Management/managementGroups) - note that `az account management-group list`
    can fail with AuthorizationFailed even when you DO have read access, because the CLI first attempts a
    `Microsoft.Management/register/action`; the REST list call used here does not. The script is defensive
    and reports clearly when nothing is visible, so it is safe to run in any tenant.

.PARAMETER ManagementGroupId
    Restrict to a single management group. Omit to scan every management group you can read.

.PARAMETER Regions
    Regions to query pooled limits for (the groupQuotaLimits API requires a location filter). Omit to
    capture groups + members only (limits are skipped with a note).

.PARAMETER ApiVersion
    groupQuotas API version (default 2023-06-01-preview).

.PARAMETER OutDir
    Output folder (default ..\output).

.EXAMPLE
    .\Get-QuotaGroups.ps1 -Regions norwayeast,swedencentral
#>
[CmdletBinding()]
param(
    [string]   $ManagementGroupId,
    [string[]] $Regions,
    [string]   $ApiVersion = '2023-06-01-preview',
    [string]   $OutDir
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutDir) { $OutDir = Get-DefaultOutDir }
$date = Get-Date -Format 'yyyyMMdd'

function Invoke-Rest([string]$url) {
    $r = az rest --method get --url $url -o json 2>$null | ConvertFrom-Json
    return $r
}

# ---- Resolve management groups (via ARM REST, not `az account management-group list`) ----
$mgs = @()
if ($ManagementGroupId) {
    $mgs = @([pscustomobject]@{ name = $ManagementGroupId })
} else {
    $list = Invoke-Rest "https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2021-04-01"
    if (-not $list -or -not $list.value) {
        Write-Warning "No management groups visible with the current identity. Quota Groups require management-group read access."
        Write-Host "Tip: pass -ManagementGroupId <id> explicitly if you know it and have access." -ForegroundColor DarkGray
        Write-Host "Tip: for a pooled-quota DESIGN snapshot that needs only subscription Reader, run Get-QuotaGroupPlan.ps1." -ForegroundColor DarkGray
        return
    }
    $mgs = $list.value
    Write-Host "Scanning $($mgs.Count) management group(s) for quota groups..." -ForegroundColor Cyan
}

# friendly subscription names for member rendering
$subMap = @{}
az account list --all --query "[].{id:id,name:name}" -o json 2>$null | ConvertFrom-Json | ForEach-Object { $subMap[$_.id] = $_.name }

$summary = @(); $members = @(); $limits = @()
foreach ($mg in $mgs) {
    $mgId = $mg.name
    $base = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$mgId/providers/Microsoft.Quota/groupQuotas"
    $groups = Invoke-Rest "$base`?api-version=$ApiVersion"
    if (-not $groups -or -not $groups.value) { continue }

    foreach ($g in $groups.value) {
        $gName    = $g.name
        $gDisplay = if ($g.properties.displayName) { $g.properties.displayName } else { $gName }
        $gType    = if ($g.properties.groupType) { $g.properties.groupType } else { '' }
        $gState   = if ($g.properties.provisioningState) { $g.properties.provisioningState } else { '' }
        Write-Host "  Found quota group '$gDisplay' under '$mgId' (type: $gType)" -ForegroundColor Green

        # member subscriptions enrolled in the group
        $subs = Invoke-Rest "$base/$gName/subscriptions?api-version=$ApiVersion"
        $memberIds = @()
        if ($subs -and $subs.value) {
            foreach ($m in $subs.value) {
                $sid = if ($m.properties.subscriptionId) { $m.properties.subscriptionId } else { $m.name }
                if (-not $sid) { continue }
                $memberIds += $sid
                $members += [pscustomobject]@{
                    ManagementGroup = $mgId
                    QuotaGroup      = $gName
                    DisplayName     = $gDisplay
                    SubId           = $sid
                    SubName         = if ($subMap.ContainsKey($sid)) { $subMap[$sid] } else { $sid }
                }
            }
        }
        $memberCount = ($memberIds | Select-Object -Unique).Count

        # per-region / per-family pooled compute limits (requires a location filter)
        $regionsWithLimits = @()
        if ($Regions) {
            foreach ($loc in $Regions) {
                $u = "$base/$gName/resourceProviders/Microsoft.Compute/groupQuotaLimits?api-version=$ApiVersion&`$filter=location eq '$loc'"
                $lim = Invoke-Rest $u
                if ($lim -and $lim.value) {
                    foreach ($l in $lim.value) {
                        $p = $l.properties
                        $regionsWithLimits += $loc
                        $limits += [pscustomobject]@{
                            ManagementGroup = $mgId
                            QuotaGroup      = $gName
                            DisplayName     = $gDisplay
                            Region          = $loc
                            Resource        = $(if ($p.resourceName) { $p.resourceName } else { $l.name })
                            Limit           = $p.limit
                            Allocated       = $(if ($p.allocatedToSubscriptions) { ($p.allocatedToSubscriptions.value -join ';') } else { '' })
                        }
                    }
                }
            }
        }

        $summary += [pscustomobject]@{
            ManagementGroup   = $mgId
            QuotaGroup        = $gName
            DisplayName       = $gDisplay
            GroupType         = $gType
            ProvisioningState = $gState
            Members           = $memberCount
            RegionsWithLimits = (($regionsWithLimits | Select-Object -Unique) -join ';')
            PooledLimitsSet   = if ($limits | Where-Object QuotaGroup -eq $gName) { 'yes' } else { 'no' }
        }
    }
}

if (-not $summary) {
    Write-Warning "No quota groups found in the management groups you can read. This tenant may not use Quota Groups yet."
    Write-Host "Run Get-QuotaGroupPlan.ps1 to model a pooled quota DESIGN from the per-subscription quota you can already read." -ForegroundColor DarkGray
    return
}

$csv = Join-Path $OutDir "quota-groups-$date.csv"
$summary | Export-Csv $csv -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($summary.Count) group summary row(s) -> $csv" -ForegroundColor Green

if ($members) {
    $mcsv = Join-Path $OutDir "quota-group-members-$date.csv"
    $members | Export-Csv $mcsv -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($members.Count) membership row(s) -> $mcsv" -ForegroundColor Green
}
if ($limits) {
    $lcsv = Join-Path $OutDir "quota-group-limits-$date.csv"
    $limits | Export-Csv $lcsv -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($limits.Count) pooled-limit row(s) -> $lcsv" -ForegroundColor Green
} elseif ($Regions) {
    Write-Host "No pooled compute limits are set on these groups in $($Regions -join ', ') - they pool the members but rely on each subscription's own quota." -ForegroundColor DarkYellow
}

Write-Host "`nQuota groups discovered:" -ForegroundColor Cyan
$summary | Format-Table DisplayName, GroupType, Members, PooledLimitsSet, RegionsWithLimits -AutoSize
