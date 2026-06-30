<#
.SYNOPSIS
    Subscription / resource-group structural limit visibility: live counts of ARM control-plane
    objects (resource groups, tags, resources per type, deployments, role assignments) compared
    against the documented Azure Resource Manager limits. Exports a single CSV.

.DESCRIPTION
    Many silent deployment blockers are NOT capacity quotas at all - they are fixed ARM structural
    limits (e.g. 980 resource groups per subscription, 800 resources per resource group per type,
    4000 role assignments per subscription). Azure exposes no per-subscription usage API for these,
    so this script counts the live objects via Azure Resource Graph and the ARM control plane and
    compares each count against the corresponding limit documented on Microsoft Learn.

    Nothing is created or modified. Output is local CSV only. Reader is sufficient.

    Honesty rules:
      - These limits are documented constants (LimitSource = MicrosoftLearnDocumented), not values
        returned by a quota usage API. Each row carries a DocReference to the exact Learn article.
      - IsTrueQuota is False for every row: these are structural ARM limits, most of which are fixed
        and non-adjustable (they are not the adjustable capacity quotas surfaced by the other
        scripts in this toolkit, and they do NOT feed the compute-only quota-groups feature).
      - High-cardinality checks (resources per RG/type, tag density) emit ONLY rows at or near the
        limit, to keep the signal clean. Region inventory is purely Informational.

    Default checks (Reader, Resource Graph):
      - Resource groups per subscription            vs 980
      - Tags applied directly to the subscription   vs 50
      - Resources per resource group, per type      vs 800   (near/at-limit rows only)

    Opt-in checks (each behind a switch):
      - -IncludeTagDensity        Tags per resource / resource group        vs 50    (near/at only)
      - -IncludeDeploymentHistory Subscription deployments per location      vs 800, and distinct
                                  deployment locations                       vs 10
      - -IncludeRoleAssignments   Role assignments per subscription          vs 4000  (lists all
                                  assignments at/below the subscription scope; can be slow)
      - -IncludeRegionInventory   Resources per region (Informational inventory, no limit)

    IMPORTANT: a structural limit is a hard ceiling on object count, NOT guaranteed physical
    capacity (see docs/concepts.md).

    Access required: Reader on the target subscriptions. Uses Resource Graph (auto-installs the
    `resource-graph` az extension if missing).

.PARAMETER SubscriptionIds
    Optional explicit subscription id(s). Omit to scan every visible subscription.

.PARAMETER SubscriptionCsv
    Optional CSV with a SubId column. Omit both to scan all visible subscriptions.

.PARAMETER NearLimitPct
    Percent-of-limit threshold for the NearLimit flag. Default 80.

.PARAMETER IncludeTagDensity
    Also emit near/at-limit rows for tags per resource or resource group (vs 50).

.PARAMETER IncludeDeploymentHistory
    Also count subscription-level deployments per location (vs 800) and distinct deployment
    locations (vs 10) from the deployment history.

.PARAMETER IncludeRoleAssignments
    Also count role assignments at/below the subscription scope (vs 4000). Can be slow on large
    subscriptions.

.PARAMETER IncludeRegionInventory
    Also emit Informational resources-per-region counts (no documented limit).

.PARAMETER OutPath
    Output CSV path. Default ..\output\subscription-limits-<date>.csv.

.EXAMPLE
    .\Get-SubscriptionLimits.ps1

.EXAMPLE
    .\Get-SubscriptionLimits.ps1 -IncludeDeploymentHistory -IncludeRoleAssignments -SubscriptionCsv .\mysubs.csv
#>
[CmdletBinding()]
param(
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [int]      $NearLimitPct = 80,
    [switch]   $IncludeTagDensity,
    [switch]   $IncludeDeploymentHistory,
    [switch]   $IncludeRoleAssignments,
    [switch]   $IncludeRegionInventory,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null

az extension show --name resource-graph -o none 2>$null
if (-not $?) {
    Write-Host "Installing az 'resource-graph' extension..." -ForegroundColor DarkGray
    az extension add --name resource-graph -o none 2>$null
}

$subs = @(Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv)

$date = Get-Date -Format 'yyyyMMdd'
if (-not $OutPath) {
    $outDir = Get-DefaultOutDir
    $OutPath = Join-Path $outDir ("subscription-limits-{0}.csv" -f $date)
}

# Documented ARM structural limits (Microsoft Learn). Values verified against the cited articles.
$LimitsDoc        = 'https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits'
$RbacLimitsDoc    = 'https://learn.microsoft.com/azure/role-based-access-control/troubleshoot-limits'
$LIMIT_RG_PER_SUB         = 980
$LIMIT_TAGS_PER_SCOPE     = 50
$LIMIT_RES_PER_RG_TYPE    = 800
$LIMIT_SUB_DEPLOY_PER_LOC = 800
$LIMIT_SUB_DEPLOY_LOCS    = 10
$LIMIT_ROLE_PER_SUB       = 4000

# Run a Resource Graph query for a single subscription, paged.
function Get-Arg {
    param([string]$Query, [string]$SubId)
    $cmd = @('graph','query','-q',$Query,'--first','1000','--subscriptions',$SubId)
    $rows = @(); $skip = 0
    do {
        $b = az @cmd --skip $skip -o json 2>$null | ConvertFrom-Json
        if ($b.data) { $rows += $b.data }
        $total = $b.total_records
        $skip += 1000
    } while ($b -and $b.data.Count -gt 0 -and $rows.Count -lt $total)
    return ,$rows
}

# Build one limit row with computed Available / PctUsed / Flag.
function New-LimitRow {
    param(
        [string]$Sub, [string]$SubId, [string]$Scope, [string]$LimitName,
        [long]$Used, $Limit, [string]$Unit, [string]$Source, [bool]$IsTrueQuota,
        [string]$DocRef, [string]$Notes, [int]$NearPct
    )
    $available = ''
    $pctUsed   = ''
    $flag      = 'Informational'
    if ($Limit -is [int] -or $Limit -is [long] -or $Limit -is [double]) {
        if ([double]$Limit -gt 0) {
            $available = [long]$Limit - $Used
            $pctUsed   = [Math]::Round(($Used / [double]$Limit) * 100, 1)
            if ($Used -ge [double]$Limit) { $flag = 'AtLimit' }
            elseif ($pctUsed -ge $NearPct) { $flag = 'NearLimit' }
            else { $flag = 'OK' }
        }
    }
    [pscustomobject][ordered]@{
        Subscription   = $Sub
        SubscriptionId = $SubId
        Scope          = $Scope
        LimitName      = $LimitName
        Used           = $Used
        Limit          = $Limit
        Available      = $available
        PctUsed        = $pctUsed
        Unit           = $Unit
        LimitSource    = $Source
        IsTrueQuota    = $IsTrueQuota
        Flag           = $flag
        DocReference   = $DocRef
        Notes          = $Notes
    }
}

Write-Host ("Evaluating subscription structural limits across {0} subscription(s)..." -f $subs.Count) -ForegroundColor Cyan

$rows = @()
$nearFloorRgType = [Math]::Floor($LIMIT_RES_PER_RG_TYPE * $NearLimitPct / 100)
$nearFloorTags   = [Math]::Floor($LIMIT_TAGS_PER_SCOPE * $NearLimitPct / 100)

foreach ($s in $subs) {
    az account set --subscription $s.SubId 2>$null

    # 1. Resource groups per subscription vs 980.
    $rgData = Get-Arg -SubId $s.SubId -Query "resourcecontainers | where type =~ 'microsoft.resources/subscriptions/resourcegroups' | summarize Used = count()"
    $rgCount = 0
    if ($rgData -and $rgData.Count -gt 0) { $rgCount = [long]$rgData[0].Used }
    $rows += New-LimitRow -Sub $s.Name -SubId $s.SubId -Scope 'Subscription' -LimitName 'ResourceGroupsPerSubscription' `
        -Used $rgCount -Limit $LIMIT_RG_PER_SUB -Unit 'Count' -Source 'MicrosoftLearnDocumented' -IsTrueQuota $false `
        -DocRef $LimitsDoc -Notes 'Fixed ARM limit; not adjustable.' -NearPct $NearLimitPct

    # 2. Tags applied directly to the subscription vs 50.
    $subTags = $null
    try { $subTags = az tag list --resource-id ("/subscriptions/{0}" -f $s.SubId) -o json 2>$null | ConvertFrom-Json } catch { $subTags = $null }
    $subTagCount = 0
    if ($subTags -and $subTags.properties -and $subTags.properties.tags) {
        $subTagCount = @($subTags.properties.tags.PSObject.Properties).Count
    }
    $rows += New-LimitRow -Sub $s.Name -SubId $s.SubId -Scope 'Subscription' -LimitName 'TagsPerSubscription' `
        -Used $subTagCount -Limit $LIMIT_TAGS_PER_SCOPE -Unit 'Count' -Source 'MicrosoftLearnDocumented' -IsTrueQuota $false `
        -DocRef $LimitsDoc -Notes 'Tags applied directly to the subscription object.' -NearPct $NearLimitPct

    # 3. Resources per resource group, per type vs 800 (near/at-limit rows only).
    $perType = Get-Arg -SubId $s.SubId -Query ("resources | summarize Used = count() by resourceGroup, type | where Used >= {0}" -f $nearFloorRgType)
    foreach ($p in $perType) {
        $rows += New-LimitRow -Sub $s.Name -SubId $s.SubId -Scope ("ResourceGroup/{0}" -f $p.type) -LimitName 'ResourcesPerResourceGroupPerType' `
            -Used ([long]$p.Used) -Limit $LIMIT_RES_PER_RG_TYPE -Unit 'Count' -Source 'MicrosoftLearnDocumented' -IsTrueQuota $false `
            -DocRef $LimitsDoc -Notes ("Resource group '{0}'. Some types are exempt from the 800 limit." -f $p.resourceGroup) -NearPct $NearLimitPct
    }

    # 4. Optional: tags per resource or resource group vs 50 (near/at-limit only).
    if ($IncludeTagDensity) {
        $tagDense = Get-Arg -SubId $s.SubId -Query ("resources | union resourcecontainers | extend TagCount = array_length(bag_keys(tags)) | where isnotnull(TagCount) and TagCount >= {0} | project name, type, TagCount" -f $nearFloorTags)
        foreach ($t in $tagDense) {
            $rows += New-LimitRow -Sub $s.Name -SubId $s.SubId -Scope ("Resource/{0}" -f $t.type) -LimitName 'TagsPerResourceOrResourceGroup' `
                -Used ([long]$t.TagCount) -Limit $LIMIT_TAGS_PER_SCOPE -Unit 'Count' -Source 'MicrosoftLearnDocumented' -IsTrueQuota $false `
                -DocRef $LimitsDoc -Notes 'Per-resource / per-RG tag ceiling.' -NearPct $NearLimitPct
        }
    }

    # 5. Optional: subscription deployment history vs 800 per location, and distinct locations vs 10.
    if ($IncludeDeploymentHistory) {
        $deps = $null
        try { $deps = az deployment sub list --query "[].location" -o json 2>$null | ConvertFrom-Json } catch { $deps = $null }
        $deps = @($deps | Where-Object { $_ })
        $byLoc = $deps | Group-Object | Sort-Object Count -Descending
        foreach ($g in $byLoc) {
            $rows += New-LimitRow -Sub $s.Name -SubId $s.SubId -Scope ("Subscription/{0}" -f $g.Name) -LimitName 'SubscriptionDeploymentsPerLocation' `
                -Used ([long]$g.Count) -Limit $LIMIT_SUB_DEPLOY_PER_LOC -Unit 'Count' -Source 'MicrosoftLearnDocumented' -IsTrueQuota $false `
                -DocRef $LimitsDoc -Notes 'Deployment history is auto-pruned near the limit.' -NearPct $NearLimitPct
        }
        $locCount = @($byLoc).Count
        $rows += New-LimitRow -Sub $s.Name -SubId $s.SubId -Scope 'Subscription' -LimitName 'SubscriptionDeploymentLocations' `
            -Used ([long]$locCount) -Limit $LIMIT_SUB_DEPLOY_LOCS -Unit 'Count' -Source 'MicrosoftLearnDocumented' -IsTrueQuota $false `
            -DocRef $LimitsDoc -Notes 'Distinct locations used for subscription-level deployments.' -NearPct $NearLimitPct
    }

    # 6. Optional: role assignments at/below the subscription scope vs 4000.
    if ($IncludeRoleAssignments) {
        $scope = "/subscriptions/{0}" -f $s.SubId
        $ras = $null
        try { $ras = az role assignment list --all --scope $scope --query "[].scope" -o json 2>$null | ConvertFrom-Json } catch { $ras = $null }
        $ras = @($ras | Where-Object { $_ -and $_.ToLower().StartsWith($scope.ToLower()) })
        $rows += New-LimitRow -Sub $s.Name -SubId $s.SubId -Scope 'Subscription' -LimitName 'RoleAssignmentsPerSubscription' `
            -Used ([long]$ras.Count) -Limit $LIMIT_ROLE_PER_SUB -Unit 'Count' -Source 'MicrosoftLearnDocumented' -IsTrueQuota $false `
            -DocRef $RbacLimitsDoc -Notes 'Fixed limit (cannot be increased); excludes management-group scope and eligible assignments.' -NearPct $NearLimitPct
    }

    # 7. Optional: Informational resources-per-region inventory (no documented limit).
    if ($IncludeRegionInventory) {
        $byRegion = Get-Arg -SubId $s.SubId -Query "resources | summarize Used = count() by location"
        foreach ($r in $byRegion) {
            $rows += New-LimitRow -Sub $s.Name -SubId $s.SubId -Scope ("Region/{0}" -f $r.location) -LimitName 'ResourcesPerRegion' `
                -Used ([long]$r.Used) -Limit '' -Unit 'Count' -Source 'Inventory' -IsTrueQuota $false `
                -DocRef '' -Notes 'Inventory only; no per-region resource-count limit.' -NearPct $NearLimitPct
        }
    }
}

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "`nNo subscription limit data returned for the scanned subscription(s)." -ForegroundColor Yellow
    return
}

$rows | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($rows.Count) limit row(s) -> $OutPath" -ForegroundColor Green

$walls = @($rows | Where-Object { $_.Flag -eq 'AtLimit' })
$near  = @($rows | Where-Object { $_.Flag -eq 'NearLimit' })

Write-Host ("`nStructural limits - At limit: {0}   Near limit (>= {1}%): {2}" -f $walls.Count, $NearLimitPct, $near.Count)

if ($walls.Count) {
    Write-Host "`nAt limit:" -ForegroundColor Red
    $walls | Sort-Object SubscriptionId, LimitName | ForEach-Object { "  {0,-34} {1,-22} {2}/{3}" -f $_.LimitName, $_.Scope, $_.Used, $_.Limit }
}
if ($near.Count) {
    Write-Host "`nNear limit:" -ForegroundColor Yellow
    $near | Sort-Object { [double]$_.PctUsed } -Descending | ForEach-Object { "  {0,-34} {1,-22} {2}% ({3}/{4})" -f $_.LimitName, $_.Scope, $_.PctUsed, $_.Used, $_.Limit }
}

Write-Host "`nReminder: these are documented ARM structural limits (object-count ceilings), not adjustable capacity quotas and not guaranteed physical capacity." -ForegroundColor DarkGray
