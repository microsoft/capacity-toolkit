<#
.SYNOPSIS
    Storage quota visibility: regional storage-account count usage vs limit per subscription, with an
    optional informational managed-disk capacity inventory. Exports a single CSV.

.DESCRIPTION
    The number of storage accounts per subscription per region is a real, adjustable Azure quota
    (default 250) and a common, silent blocker for storage-heavy or multi-tenant platforms. This
    script surfaces that headroom as a pure READ-ONLY read of the regional Storage usage API (the data
    behind `az storage account show-usage`).

    Nothing is created or modified. Output is local CSV only.

    Per subscription + region it reports the StorageAccounts counter with Used / Limit / Available /
    PctUsed and an OK / NearLimit / AtLimit flag (threshold via -NearLimitPct, default 80%).

    Optionally (-IncludeDiskCapacityInventory) it adds an INFORMATIONAL managed-disk capacity
    inventory: total provisioned GiB by region (and disk SKU), summed from Resource Graph. This is
    explicitly NOT a quota - Azure exposes no general per-subscription managed-disk capacity quota
    usage API - so those rows carry IsQuota=False, blank Limit/Available/PctUsed and a Flag of
    'Informational'. They are inventory, not a compliance signal.

    IMPORTANT: quota headroom is NOT guaranteed physical capacity (see docs/concepts.md).

    Access required: Reader on the target subscriptions. The disk inventory uses Resource Graph
    (auto-installs the `resource-graph` az extension if missing).

.PARAMETER Location
    Region(s) to evaluate (e.g. 'norwayeast'). Quota is region-specific. Default 'norwayeast'. Ignored
    when -AllLocations is set.

.PARAMETER AllLocations
    Evaluate every physical Azure region the signed-in identity can list, instead of -Location.

.PARAMETER SubscriptionIds
    Optional explicit subscription id(s). Omit to scan every visible subscription.

.PARAMETER SubscriptionCsv
    Optional CSV with a SubId column. Omit both to scan all visible subscriptions.

.PARAMETER NearLimitPct
    Percent-of-limit threshold for the NearLimit flag. Default 80.

.PARAMETER IncludeDiskCapacityInventory
    Also emit informational managed-disk provisioned-GiB rows (Resource Graph). Off by default to keep
    the quota signal clean.

.PARAMETER OutPath
    Output CSV path. Default ..\output\storage-quota-<region|all>-<date>.csv.

.EXAMPLE
    .\Get-StorageQuota.ps1 -Location norwayeast

.EXAMPLE
    .\Get-StorageQuota.ps1 -AllLocations -IncludeDiskCapacityInventory -SubscriptionCsv .\mysubs.csv
#>
[CmdletBinding()]
param(
    [string[]] $Location = @('norwayeast'),
    [switch]   $AllLocations,
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [int]      $NearLimitPct = 80,
    [switch]   $IncludeDiskCapacityInventory,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null

if ($IncludeDiskCapacityInventory) {
    az extension show --name resource-graph -o none 2>$null
    if (-not $?) {
        Write-Host "Installing az 'resource-graph' extension..." -ForegroundColor DarkGray
        az extension add --name resource-graph -o none 2>$null
    }
}

$subs = @(Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv)

$date = Get-Date -Format 'yyyyMMdd'
if (-not $OutPath) {
    $outDir = Get-DefaultOutDir
    $tag = if ($AllLocations) { 'all' } else { ($Location -join '-') }
    $OutPath = Join-Path $outDir ("storage-quota-{0}-{1}.csv" -f $tag, $date)
}

$regions = @()
if ($AllLocations) {
    $regions = @(az account list-locations --query "[?metadata.regionType=='Physical'].name" -o json 2>$null | ConvertFrom-Json | Sort-Object)
} else {
    $regions = @($Location)
}
if (-not $regions -or $regions.Count -eq 0) { $regions = @('norwayeast') }

# Sum provisioned managed-disk GiB by region + disk SKU for one subscription (Resource Graph, paged).
function Get-DiskInventory {
    param([string]$SubId, [string[]]$Regions, [bool]$AllRegions)
    $clauses = @(
        "resources",
        "where type =~ 'microsoft.compute/disks'"
    )
    if (-not $AllRegions) {
        $list = ($Regions | ForEach-Object { "'" + $_.ToLower() + "'" }) -join ','
        $clauses += "where tolower(location) in ($list)"
    }
    $clauses += "extend diskSizeGB = tolong(properties.diskSizeGB), diskSku = tostring(sku.name)"
    $clauses += "summarize Used = sum(diskSizeGB), DiskCount = count() by location, diskSku"
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

Write-Host ("Evaluating storage quota across {0} subscription(s) x {1} region(s)..." -f $subs.Count, $regions.Count) -ForegroundColor Cyan

$rows = @()

foreach ($s in $subs) {
    az account set --subscription $s.SubId 2>$null

    # 1. Storage-account count quota per region.
    foreach ($region in $regions) {
        $usage = $null
        try { $usage = az storage account show-usage --location $region -o json 2>$null | ConvertFrom-Json } catch { $usage = $null }
        if (-not $usage) { continue }

        foreach ($u in @($usage)) {
            if ($u.name.value -ne 'StorageAccounts') { continue }
            $used  = [long]$u.currentValue
            $limit = [long]$u.limit

            $available = ''
            $pctUsed   = ''
            $flag      = 'Unknown'
            if ($limit -gt 0) {
                $available = $limit - $used
                $pctUsed   = [Math]::Round(($used / $limit) * 100, 1)
                if ($used -ge $limit) { $flag = 'AtLimit' }
                elseif ($pctUsed -ge $NearLimitPct) { $flag = 'NearLimit' }
                else { $flag = 'OK' }
            }

            $rows += [pscustomobject][ordered]@{
                Subscription   = $s.Name
                SubscriptionId = $s.SubId
                Region         = $region
                Metric         = 'StorageAccounts'
                DiskSku        = ''
                Used           = $used
                Limit          = $limit
                Available      = $available
                PctUsed        = $pctUsed
                Unit           = 'Count'
                IsQuota        = $true
                Flag           = $flag
                Notes          = 'Quota is not guaranteed capacity.'
            }
        }
    }

    # 2. Optional informational managed-disk capacity inventory.
    if ($IncludeDiskCapacityInventory) {
        $disks = Get-DiskInventory -SubId $s.SubId -Regions $regions -AllRegions ([bool]$AllLocations)
        foreach ($d in $disks) {
            $rows += [pscustomobject][ordered]@{
                Subscription   = $s.Name
                SubscriptionId = $s.SubId
                Region         = $d.location
                Metric         = 'ManagedDiskProvisionedGiB'
                DiskSku        = $d.diskSku
                Used           = [long]$d.Used
                Limit          = ''
                Available      = ''
                PctUsed        = ''
                Unit           = 'GiB'
                IsQuota        = $false
                Flag           = 'Informational'
                Notes          = ("Inventory only ({0} disk(s)); no managed-disk capacity quota endpoint." -f $d.DiskCount)
            }
        }
    }
}

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "`nNo storage usage data returned for the scanned subscription(s)/region(s)." -ForegroundColor Yellow
    return
}

$rows | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($rows.Count) storage row(s) -> $OutPath" -ForegroundColor Green

$walls = @($rows | Where-Object { $_.Flag -eq 'AtLimit' })
$near  = @($rows | Where-Object { $_.Flag -eq 'NearLimit' })

Write-Host ("`nStorage-account quota - At limit: {0}   Near limit (>= {1}%): {2}" -f $walls.Count, $NearLimitPct, $near.Count)

if ($walls.Count) {
    Write-Host "`nAt storage-account limit:" -ForegroundColor Red
    $walls | Sort-Object SubscriptionId, Region | ForEach-Object { "  {0,-24} {1,-16} {2}/{3}" -f $_.Subscription, $_.Region, $_.Used, $_.Limit }
}
if ($near.Count) {
    Write-Host "`nNear storage-account limit:" -ForegroundColor Yellow
    $near | Sort-Object { [double]$_.PctUsed } -Descending | ForEach-Object { "  {0,-24} {1,-16} {2}% ({3}/{4})" -f $_.Subscription, $_.Region, $_.PctUsed, $_.Used, $_.Limit }
}
if (-not $walls.Count -and -not $near.Count) {
    Write-Host "`nNo storage-account counters at or near limit for the scanned scope." -ForegroundColor Green
}

Write-Host "`nReminder: quota headroom is not guaranteed physical capacity." -ForegroundColor DarkYellow
