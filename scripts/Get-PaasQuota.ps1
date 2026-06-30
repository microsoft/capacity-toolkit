<#
.SYNOPSIS
    PaaS quota visibility for the data tier: Azure SQL true quota/usage plus Cosmos DB throughput
    inventory. Exports a single CSV.

.DESCRIPTION
    The toolkit covers compute, networking, storage and App Service quota, but the data-PaaS tier is a
    blind spot. This script adds READ-ONLY coverage for:

      * Azure SQL Database - TRUE quota from the Microsoft.Sql usage APIs:
          - subscription/region usages (ServerQuota, VCoreQuota, free-database counters, etc.)
          - per-logical-server usages (server_dtu_quota / server_dtu_quota_current)
        Every row the API returns is emitted generically (IsInformational=False).

      * Azure Cosmos DB - there is NO verified subscription/region RU/s quota usage API, so this is
        reported honestly as inventory:
          - per-account configured total throughput limit (properties.capacity.totalThroughputLimit);
            a positive value is a real account-level limit, -1 / unset means no imposed limit.
          - optionally (-IncludeCosmosThroughputInventory) provisioned RU/s per SQL-API database and
            container, summed per account.
        Cosmos rows are IsInformational=True unless an account carries a positive configured limit.

    Nothing is created or modified. Output is local CSV only. This output does NOT feed the
    quota-groups feature, which is compute-vCPU-only.

    IMPORTANT: quota headroom is NOT guaranteed physical capacity (see docs/concepts.md).

    Access required: Reader on the target subscriptions. Uses Resource Graph for discovery
    (auto-installs the `resource-graph` az extension if missing).

.PARAMETER Service
    Which services to cover: AzureSQL, CosmosDB or All (default).

.PARAMETER Location
    Region(s) for the SQL subscription/region usage read (e.g. 'norwayeast'). Default 'norwayeast'.
    Ignored when -AllLocations is set. Per-server and Cosmos rows use each resource's own region.

.PARAMETER AllLocations
    Read SQL subscription/region usages for every physical Azure region, instead of -Location.

.PARAMETER SubscriptionIds
    Optional explicit subscription id(s). Omit to scan every visible subscription.

.PARAMETER SubscriptionCsv
    Optional CSV with a SubId column. Omit both to scan all visible subscriptions.

.PARAMETER NearLimitPct
    Percent-of-limit threshold for the NearLimit flag. Default 80.

.PARAMETER IncludeCosmosThroughputInventory
    Also enumerate provisioned RU/s per SQL-API Cosmos database and container (more calls; off by
    default).

.PARAMETER OutPath
    Output CSV path. Default ..\output\paas-quota-<region|all>-<date>.csv.

.EXAMPLE
    .\Get-PaasQuota.ps1 -Location norwayeast

.EXAMPLE
    .\Get-PaasQuota.ps1 -Service AzureSQL -AllLocations -SubscriptionCsv .\mysubs.csv
#>
[CmdletBinding()]
param(
    [ValidateSet('AzureSQL','CosmosDB','All')]
    [string]   $Service = 'All',
    [string[]] $Location = @('norwayeast'),
    [switch]   $AllLocations,
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [int]      $NearLimitPct = 80,
    [switch]   $IncludeCosmosThroughputInventory,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null

$SqlApi    = '2023-08-01'
$CosmosApi = '2024-11-15'

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
    $OutPath = Join-Path $outDir ("paas-quota-{0}-{1}.csv" -f $tag, $date)
}

$regions = @()
if ($AllLocations) {
    $regions = @(az account list-locations --query "[?metadata.regionType=='Physical'].name" -o json 2>$null | ConvertFrom-Json | Sort-Object)
} else {
    $regions = @($Location)
}
if (-not $regions -or $regions.Count -eq 0) { $regions = @('norwayeast') }

$doSql    = ($Service -eq 'All' -or $Service -eq 'AzureSQL')
$doCosmos = ($Service -eq 'All' -or $Service -eq 'CosmosDB')

# Generic ARG discovery (paged) for one resource type in one subscription.
function Get-ArgResources {
    param([string]$SubId, [string]$TypeFilter)
    $query = "resources | where $TypeFilter | project id, subscriptionId, resourceGroup, name, location | order by name asc"
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

# Build a usage row from a Microsoft.Sql usage object (true quota).
function New-SqlRow {
    param($U, $Sub, $Region, $Resource)
    $used  = [double]$U.properties.currentValue
    $limit = [double]$U.properties.limit

    # Free-tier / promotional countdown counters (e.g. *Free*, *DaysLeft, *TokensLeft) are not capacity
    # quotas - a "full" countdown is healthy, not exhausted - so report them as informational.
    $isPromo = ($U.name -match '(?i)free' -or $U.name -match '(?i)left$')

    $available = ''
    $pctUsed   = ''
    $flag      = 'OK'
    if ($isPromo) {
        $flag = 'Informational'
    } elseif ($limit -gt 0) {
        $available = $limit - $used
        $pctUsed   = [Math]::Round(($used / $limit) * 100, 1)
        if ($used -ge $limit) { $flag = 'AtLimit' }
        elseif ($pctUsed -ge $NearLimitPct) { $flag = 'NearLimit' }
        else { $flag = 'OK' }
    } else {
        $flag = 'Unknown'
    }
    return [pscustomobject][ordered]@{
        Subscription    = $Sub.Name
        SubscriptionId  = $Sub.SubId
        Region          = $Region
        Service         = 'AzureSQL'
        Resource        = $Resource
        Metric          = $U.name
        Used            = $used
        Limit           = $(if ($limit -gt 0) { $limit } else { '' })
        Available       = $available
        PctUsed         = $pctUsed
        Unit            = $U.properties.unit
        IsInformational = $isPromo
        Flag            = $flag
        Notes           = $(if ($isPromo) { 'Free-tier / promotional countdown counter, not a capacity quota.' } else { 'Quota is not guaranteed capacity.' })
    }
}

Write-Host ("Evaluating PaaS quota ({0}) across {1} subscription(s)..." -f $Service, $subs.Count) -ForegroundColor Cyan

$rows = @()

foreach ($s in $subs) {
    az account set --subscription $s.SubId 2>$null

    # ---- Azure SQL ----
    if ($doSql) {
        # Subscription/region true quota.
        foreach ($region in $regions) {
            $url = "https://management.azure.com/subscriptions/$($s.SubId)/providers/Microsoft.Sql/locations/$region/usages?api-version=$SqlApi"
            $resp = $null
            try { $resp = az rest --method get --url $url -o json 2>$null | ConvertFrom-Json } catch { $resp = $null }
            if ($resp -and $resp.value) {
                foreach ($u in $resp.value) {
                    $rows += New-SqlRow -U $u -Sub $s -Region $region -Resource 'Subscription/Region'
                }
            }
        }

        # Per-logical-server DTU quota.
        $servers = Get-ArgResources -SubId $s.SubId -TypeFilter "type =~ 'microsoft.sql/servers'"
        foreach ($srv in $servers) {
            $surl = "https://management.azure.com/subscriptions/$($s.SubId)/resourceGroups/$($srv.resourceGroup)/providers/Microsoft.Sql/servers/$($srv.name)/usages?api-version=$SqlApi"
            $sresp = $null
            try { $sresp = az rest --method get --url $surl -o json 2>$null | ConvertFrom-Json } catch { $sresp = $null }
            if ($sresp -and $sresp.value) {
                foreach ($u in $sresp.value) {
                    $rows += New-SqlRow -U $u -Sub $s -Region $srv.location -Resource ("server:" + $srv.name)
                }
            }
        }
    }

    # ---- Cosmos DB ----
    if ($doCosmos) {
        $accounts = Get-ArgResources -SubId $s.SubId -TypeFilter "type =~ 'microsoft.documentdb/databaseaccounts'"
        foreach ($acc in $accounts) {
            $aurl = "https://management.azure.com/subscriptions/$($s.SubId)/resourceGroups/$($acc.resourceGroup)/providers/Microsoft.DocumentDB/databaseAccounts/$($acc.name)?api-version=$CosmosApi"
            $a = $null
            try { $a = az rest --method get --url $aurl -o json 2>$null | ConvertFrom-Json } catch { $a = $null }

            $ttl = $null
            if ($a -and $a.properties -and $a.properties.capacity) { $ttl = $a.properties.capacity.totalThroughputLimit }
            $isServerless = $false
            if ($a -and $a.properties -and $a.properties.capabilities) {
                $isServerless = (@($a.properties.capabilities | Where-Object { $_.name -eq 'EnableServerless' }).Count -gt 0)
            }

            # Account-level configured throughput limit row.
            $hasLimit = ($null -ne $ttl -and [double]$ttl -gt 0)
            $accNote = 'No verified subscription/region RU/s quota API; account-level limit only.'
            if ($isServerless) { $accNote = 'Serverless account; no provisioned RU/s.' }
            elseif (-not $hasLimit) { $accNote = 'totalThroughputLimit unset/-1: no imposed account throughput limit.' }

            $rows += [pscustomobject][ordered]@{
                Subscription    = $s.Name
                SubscriptionId  = $s.SubId
                Region          = $acc.location
                Service         = 'CosmosDB'
                Resource        = ("account:" + $acc.name)
                Metric          = 'AccountTotalThroughputLimit'
                Used            = ''
                Limit           = $(if ($hasLimit) { [double]$ttl } else { '' })
                Available       = ''
                PctUsed         = ''
                Unit            = 'RU/s'
                IsInformational = (-not $hasLimit)
                Flag            = $(if ($hasLimit) { 'ConfiguredLimit' } else { 'Informational' })
                Notes           = $accNote
            }

            # Optional provisioned RU/s inventory (SQL API databases + containers).
            if ($IncludeCosmosThroughputInventory -and -not $isServerless) {
                $dbs = $null
                try { $dbs = az cosmosdb sql database list --account-name $acc.name --resource-group $acc.resourceGroup -o json 2>$null | ConvertFrom-Json } catch { $dbs = $null }
                foreach ($db in @($dbs)) {
                    # Database-level shared throughput (if any).
                    $dbThr = $null
                    try { $dbThr = az cosmosdb sql database throughput show --account-name $acc.name --resource-group $acc.resourceGroup --name $db.name -o json 2>$null | ConvertFrom-Json } catch { $dbThr = $null }
                    if ($dbThr -and $dbThr.resource) {
                        $ru = $dbThr.resource.throughput
                        if ($dbThr.resource.autoscaleSettings -and $dbThr.resource.autoscaleSettings.maxThroughput) { $ru = $dbThr.resource.autoscaleSettings.maxThroughput }
                        $rows += [pscustomobject][ordered]@{
                            Subscription    = $s.Name
                            SubscriptionId  = $s.SubId
                            Region          = $acc.location
                            Service         = 'CosmosDB'
                            Resource        = ("db:" + $acc.name + "/" + $db.name)
                            Metric          = 'ProvisionedRU/s'
                            Used            = [double]$ru
                            Limit           = ''
                            Available       = ''
                            PctUsed         = ''
                            Unit            = 'RU/s'
                            IsInformational = $true
                            Flag            = 'Informational'
                            Notes           = 'Database-level shared throughput (autoscale max if autoscale).'
                        }
                    }
                    # Container-level dedicated throughput.
                    $ctrs = $null
                    try { $ctrs = az cosmosdb sql container list --account-name $acc.name --resource-group $acc.resourceGroup --database-name $db.name -o json 2>$null | ConvertFrom-Json } catch { $ctrs = $null }
                    foreach ($ct in @($ctrs)) {
                        $ctThr = $null
                        try { $ctThr = az cosmosdb sql container throughput show --account-name $acc.name --resource-group $acc.resourceGroup --database-name $db.name --name $ct.name -o json 2>$null | ConvertFrom-Json } catch { $ctThr = $null }
                        if ($ctThr -and $ctThr.resource) {
                            $cru = $ctThr.resource.throughput
                            if ($ctThr.resource.autoscaleSettings -and $ctThr.resource.autoscaleSettings.maxThroughput) { $cru = $ctThr.resource.autoscaleSettings.maxThroughput }
                            $rows += [pscustomobject][ordered]@{
                                Subscription    = $s.Name
                                SubscriptionId  = $s.SubId
                                Region          = $acc.location
                                Service         = 'CosmosDB'
                                Resource        = ("container:" + $acc.name + "/" + $db.name + "/" + $ct.name)
                                Metric          = 'ProvisionedRU/s'
                                Used            = [double]$cru
                                Limit           = ''
                                Available       = ''
                                PctUsed         = ''
                                Unit            = 'RU/s'
                                IsInformational = $true
                                Flag            = 'Informational'
                                Notes           = 'Container-level dedicated throughput (autoscale max if autoscale).'
                            }
                        }
                    }
                }
            }
        }
    }
}

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "`nNo PaaS quota data returned for the scanned subscription(s)/region(s)." -ForegroundColor Yellow
    return
}

$rows | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($rows.Count) PaaS row(s) -> $OutPath" -ForegroundColor Green

$trueQuota = @($rows | Where-Object { $_.IsInformational -eq $false })
$walls = @($rows | Where-Object { $_.Flag -eq 'AtLimit' })
$near  = @($rows | Where-Object { $_.Flag -eq 'NearLimit' })

Write-Host ("`nTrue-quota rows: {0}   At limit: {1}   Near limit (>= {2}%): {3}" -f $trueQuota.Count, $walls.Count, $NearLimitPct, $near.Count)

if ($walls.Count) {
    Write-Host "`nPaaS quota counters at limit:" -ForegroundColor Red
    $walls | ForEach-Object { "  {0,-24} {1,-10} {2,-28} {3}/{4}" -f $_.Subscription, $_.Service, $_.Metric, $_.Used, $_.Limit }
}
if ($near.Count) {
    Write-Host "`nPaaS quota counters near limit:" -ForegroundColor Yellow
    $near | Sort-Object { [double]$_.PctUsed } -Descending | ForEach-Object { "  {0,-24} {1,-10} {2,-28} {3}% ({4}/{5})" -f $_.Subscription, $_.Service, $_.Metric, $_.PctUsed, $_.Used, $_.Limit }
}
if (-not $walls.Count -and -not $near.Count) {
    Write-Host "`nNo PaaS quota counters at or near limit for the scanned scope." -ForegroundColor Green
}

Write-Host "`nReminder: quota headroom is not guaranteed physical capacity. Cosmos RU/s rows are inventory," -ForegroundColor DarkYellow
Write-Host "not a subscription/region quota - Azure exposes no verified Cosmos RU/s usage API." -ForegroundColor DarkYellow
