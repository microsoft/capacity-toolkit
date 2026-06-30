<#
.SYNOPSIS
    App Service quota visibility: App Service Plan inventory plus Microsoft.Web regional and per-plan
    usage vs limit per subscription. Exports a single CSV.

.DESCRIPTION
    App Service capacity pressure is invisible to the compute-vCPU view the toolkit already has: an
    App Service Plan can hit its per-region / per-resource-group plan limit, or a dedicated plan can
    reach its tier scale-out instance ceiling, and a deploy or scale-out will fail. This script
    surfaces that as a pure READ-ONLY read of three sources the platform already exposes:

      * App Service Plans (Azure Resource Graph) - SKU, tier, location, current instance count.
      * Microsoft.Web/locations/{loc}/usages (api-version 2025-05-01) - subscription/region quota.
      * Microsoft.Web/serverfarms/{name}/usages (api-version 2025-05-01) - per-plan usage counters.

    Nothing is created or modified. Output is local CSV only.

    Row scopes:
      * SubscriptionRegion - one row per Microsoft.Web regional usage counter.
      * AppServicePlan     - one row per per-plan usage counter.
      * InventoryDerived   - one row per plan comparing the current instance count to the documented
                             tier scale-out ceiling (a Microsoft Learn constant, not an API value).

    True quota/usage rows (IsTrueQuota=True) come from the Microsoft.Web usage APIs; documented and
    inventory-derived rows are labelled LimitBasis accordingly so they are never confused with
    API-reported quota. Counters whose limit is missing / 0 / unbounded are flagged HasUnknownLimit
    rather than given fabricated math.

    IMPORTANT: quota headroom is NOT guaranteed physical capacity (see docs/concepts.md). Passing a
    quota check does not prove a plan can scale out in a capacity-constrained region.

    Access required: Reader on the target subscriptions. Auto-installs the `resource-graph` az
    extension if missing.

.PARAMETER Location
    Region(s) for the subscription/region Microsoft.Web usage read and the ASP inventory filter
    (e.g. 'norwayeast'). Default 'norwayeast'. Ignored when -AllLocations is set.

.PARAMETER AllLocations
    Evaluate every physical Azure region the signed-in identity can list, instead of -Location, and
    inventory App Service Plans in all regions.

.PARAMETER SubscriptionIds
    Optional explicit subscription id(s). Omit to scan every visible subscription.

.PARAMETER SubscriptionCsv
    Optional CSV with a SubId column. Omit both to scan all visible subscriptions.

.PARAMETER NearLimitPct
    Percent-of-limit threshold for the NearLimit flag. Default 80.

.PARAMETER OutPath
    Output CSV path. Default ..\output\appservice-quota-<region|all>-<date>.csv.

.EXAMPLE
    .\Get-AppServiceQuota.ps1 -Location norwayeast

.EXAMPLE
    .\Get-AppServiceQuota.ps1 -AllLocations -SubscriptionCsv .\mysubs.csv
#>
[CmdletBinding()]
param(
    [string[]] $Location = @('norwayeast'),
    [switch]   $AllLocations,
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [int]      $NearLimitPct = 80,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null

$ApiVersion = '2025-05-01'

az extension show --name resource-graph -o none 2>$null
if (-not $?) {
    Write-Host "Installing az 'resource-graph' extension..." -ForegroundColor DarkGray
    az extension add --name resource-graph -o none 2>$null
}

$subs = @(Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv)

$date = Get-Date -Format 'yyyyMMdd'
if (-not $OutPath) {
    $outDir = Get-DefaultOutDir
    $tag = if ($AllLocations) { 'all' } else { ($Location -join '-') }
    $OutPath = Join-Path $outDir ("appservice-quota-{0}-{1}.csv" -f $tag, $date)
}

$regions = @()
if ($AllLocations) {
    $regions = @(az account list-locations --query "[?metadata.regionType=='Physical'].name" -o json 2>$null | ConvertFrom-Json | Sort-Object)
} else {
    $regions = @($Location)
}
if (-not $regions -or $regions.Count -eq 0) { $regions = @('norwayeast') }

# Documented per-tier scale-out instance ceiling (Microsoft Learn App Service limits). Conservative;
# returns 0 when the SKU cannot be mapped confidently.
function Get-InstanceCeiling {
    param([string]$Sku)
    if (-not $Sku) { return 0 }
    $u = $Sku.ToUpper()
    if ($u -match '^I\d') { return 100 }                  # Isolated (I1/I2/I3, I1v2...)
    if ($u -match 'V2$' -or $u -match 'V3$' -or $u -match 'V4$') { return 30 }  # Premium v2/v3/v4
    if ($u -match '^P0V') { return 30 }
    if ($u -match '^P[123]$') { return 20 }               # legacy Premium v1
    if ($u -match '^S\d') { return 10 }                   # Standard
    if ($u -match '^B\d') { return 3 }                    # Basic
    if ($u -eq 'F1' -or $u -eq 'D1') { return 1 }         # Free / Shared
    return 0
}

# Read every App Service Plan for one subscription via Resource Graph (paged), optionally filtered by region.
function Get-AppServicePlans {
    param([string]$SubId, [string[]]$Regions, [bool]$AllRegions)
    $clauses = @(
        "resources",
        "where type =~ 'microsoft.web/serverfarms'"
    )
    if (-not $AllRegions) {
        $list = ($Regions | ForEach-Object { "'" + $_.ToLower() + "'" }) -join ','
        $clauses += "where tolower(location) in ($list)"
    }
    $clauses += "project id, subscriptionId, resourceGroup, name, location, kind, skuName = tostring(sku.name), skuTier = tostring(sku.tier), capacity = toint(sku.capacity)"
    $clauses += "order by name asc"
    $query = $clauses -join ' | '
    $cmd = @('graph','query','-q',$query,'--first','1000','--subscriptions',$SubId)
    $rows = @(); $skip = 0
    do {
        $b = az @cmd --skip $skip -o json 2>$null | ConvertFrom-Json
        if ($b.data) { $rows += $b.data }
        $total = $b.total_records
        $skip += 1000
    } while ($b -and $b.data.Count -gt 0 -and $rows.Count -lt $total)
    return ,$rows
}

# Turn one CsmUsageQuota object into the shared row, computing flags.
function New-UsageRow {
    param($Quota, $Sub, $Region, $Rg, $Plan, $Sku, $Tier, $Capacity, $Scope, $Source)
    $metricId  = $Quota.name.value
    $metricTxt = $Quota.name.localizedValue
    if (-not $metricTxt) { $metricTxt = $metricId }
    $used  = [long]$Quota.currentValue
    $limit = [long]$Quota.limit

    $unknownLimit = ($limit -le 0)
    $available = ''
    $pctUsed   = ''
    $nearLimit = $false
    $atLimit   = $false
    if (-not $unknownLimit) {
        $available = $limit - $used
        $pctUsed   = [Math]::Round(($used / $limit) * 100, 1)
        $atLimit   = ($used -ge $limit)
        $nearLimit = (($pctUsed -ge $NearLimitPct) -and (-not $atLimit))
    }

    return [pscustomobject][ordered]@{
        Subscription           = $Sub.Name
        SubscriptionId         = $Sub.SubId
        Region                 = $Region
        ResourceGroup          = $Rg
        AppServicePlan         = $Plan
        Sku                    = $Sku
        Tier                   = $Tier
        Capacity               = $Capacity
        Scope                  = $Scope
        Metric                 = $metricTxt
        MetricId               = $metricId
        MetricSource           = $Source
        Used                   = $used
        Limit                  = $(if ($unknownLimit) { '' } else { $limit })
        Available              = $available
        PctUsed                = $pctUsed
        Unit                   = $Quota.unit
        IsTrueQuota            = $true
        LimitBasis             = $(if ($unknownLimit) { 'Unknown' } else { 'ApiReported' })
        NearLimit              = $nearLimit
        AtLimit                = $atLimit
        PlanNearInstanceCeiling = ''
        PlanAtInstanceCeiling   = ''
        HasUnknownLimit        = $unknownLimit
        Status                 = 'Success'
        Error                  = ''
    }
}

Write-Host ("Evaluating App Service quota across {0} subscription(s) x {1} region(s)..." -f $subs.Count, $regions.Count) -ForegroundColor Cyan

$rows = @()

foreach ($s in $subs) {
    az account set --subscription $s.SubId 2>$null

    # 1. Subscription/region Microsoft.Web usages.
    foreach ($region in $regions) {
        $url = "https://management.azure.com/subscriptions/$($s.SubId)/providers/Microsoft.Web/locations/$region/usages?api-version=$ApiVersion"
        $resp = $null
        try { $resp = az rest --method get --url $url -o json 2>$null | ConvertFrom-Json } catch { $resp = $null }
        if ($resp -and $resp.value) {
            foreach ($q in $resp.value) {
                $rows += New-UsageRow -Quota $q -Sub $s -Region $region -Rg '' -Plan '' -Sku '' -Tier '' -Capacity '' -Scope 'SubscriptionRegion' -Source 'Microsoft.Web/locations/usages'
            }
        }
    }

    # 2. App Service Plan inventory + per-plan usages + documented instance ceiling.
    $plans = Get-AppServicePlans -SubId $s.SubId -Regions $regions -AllRegions ([bool]$AllLocations)
    foreach ($p in $plans) {
        # Per-plan usage counters.
        $purl = "https://management.azure.com/subscriptions/$($s.SubId)/resourceGroups/$($p.resourceGroup)/providers/Microsoft.Web/serverfarms/$($p.name)/usages?api-version=$ApiVersion"
        $presp = $null
        try { $presp = az rest --method get --url $purl -o json 2>$null | ConvertFrom-Json } catch { $presp = $null }
        if ($presp -and $presp.value) {
            foreach ($q in $presp.value) {
                $rows += New-UsageRow -Quota $q -Sub $s -Region $p.location -Rg $p.resourceGroup -Plan $p.name -Sku $p.skuName -Tier $p.skuTier -Capacity $p.capacity -Scope 'AppServicePlan' -Source 'Microsoft.Web/serverfarms/usages'
            }
        }

        # Documented instance-ceiling inventory row.
        $ceiling = Get-InstanceCeiling -Sku $p.skuName
        $cap = 0
        if ($null -ne $p.capacity) { $cap = [int]$p.capacity }
        $nearCeil = ''
        $atCeil   = ''
        $ceilLimit = ''
        $ceilAvail = ''
        $ceilPct   = ''
        $unknownCeil = ($ceiling -le 0)
        if (-not $unknownCeil) {
            $ceilLimit = $ceiling
            $ceilAvail = $ceiling - $cap
            $ceilPct   = [Math]::Round(($cap / $ceiling) * 100, 1)
            $atCeil    = ($cap -ge $ceiling)
            $nearCeil  = (($ceilPct -ge $NearLimitPct) -and (-not $atCeil))
        }

        $rows += [pscustomobject][ordered]@{
            Subscription            = $s.Name
            SubscriptionId          = $s.SubId
            Region                  = $p.location
            ResourceGroup           = $p.resourceGroup
            AppServicePlan          = $p.name
            Sku                     = $p.skuName
            Tier                    = $p.skuTier
            Capacity                = $cap
            Scope                   = 'InventoryDerived'
            Metric                  = 'Scale-out instance ceiling'
            MetricId                = 'InstanceCount'
            MetricSource            = 'DocumentedLimit'
            Used                    = $cap
            Limit                   = $ceilLimit
            Available               = $ceilAvail
            PctUsed                 = $ceilPct
            Unit                    = 'Instances'
            IsTrueQuota             = $false
            LimitBasis              = $(if ($unknownCeil) { 'Unknown' } else { 'MicrosoftLearnDocumented' })
            NearLimit               = ''
            AtLimit                 = ''
            PlanNearInstanceCeiling = $nearCeil
            PlanAtInstanceCeiling   = $atCeil
            HasUnknownLimit         = $unknownCeil
            Status                  = 'Success'
            Error                   = ''
        }
    }
}

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "`nNo App Service data returned for the scanned subscription(s)/region(s)." -ForegroundColor Yellow
    return
}

$rows | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($rows.Count) App Service row(s) -> $OutPath" -ForegroundColor Green

$plans = @($rows | Where-Object { $_.Scope -eq 'InventoryDerived' })
$quotaWalls = @($rows | Where-Object { $_.AtLimit -eq $true })
$quotaNear  = @($rows | Where-Object { $_.NearLimit -eq $true })
$ceilWalls  = @($rows | Where-Object { $_.PlanAtInstanceCeiling -eq $true })
$ceilNear   = @($rows | Where-Object { $_.PlanNearInstanceCeiling -eq $true })

Write-Host ("`nApp Service Plans: {0}   Quota at-limit: {1}   near: {2}   At ceiling: {3}   near: {4}" -f `
    $plans.Count, $quotaWalls.Count, $quotaNear.Count, $ceilWalls.Count, $ceilNear.Count)

if ($ceilWalls.Count) {
    Write-Host "`nPlans at their documented scale-out instance ceiling:" -ForegroundColor Red
    $ceilWalls | ForEach-Object { "  {0,-24} {1,-14} {2,-8} {3}/{4} instances" -f $_.Subscription, $_.Sku, $_.Region, $_.Used, $_.Limit }
}
if ($quotaWalls.Count) {
    Write-Host "`nMicrosoft.Web quota counters at limit:" -ForegroundColor Red
    $quotaWalls | ForEach-Object { "  {0,-24} {1,-16} {2,-28} {3}/{4}" -f $_.Subscription, $_.Region, $_.MetricId, $_.Used, $_.Limit }
}
if (-not $quotaWalls.Count -and -not $quotaNear.Count -and -not $ceilWalls.Count -and -not $ceilNear.Count) {
    Write-Host "`nNo App Service quota counters or plans at/near limit for the scanned scope." -ForegroundColor Green
}

Write-Host "`nReminder: quota headroom is not guaranteed physical capacity." -ForegroundColor DarkYellow
