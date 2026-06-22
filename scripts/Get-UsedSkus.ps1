<#
.SYNOPSIS
    Discover every VM SKU actually in use across the tenant (or a subscription scope) - from Virtual
    Machines, VM Scale Sets and AKS node pools - and auto-map each one to its quota family. Emits a CSV
    plus a ready-to-use capacity-config.json so the rest of the toolkit runs against the tenant's REAL
    SKUs instead of a hard-coded B/D/E default list.

.DESCRIPTION
    Many capacity reviews start by guessing which SKUs matter. This script removes the guesswork:

      1. Uses Azure Resource Graph to enumerate the VM sizes deployed today:
           * microsoft.compute/virtualmachines            -> properties.hardwareProfile.vmSize
           * microsoft.compute/virtualmachinescalesets    -> sku.name  (covers AKS system/user pools too)
           * microsoft.containerservice/managedclusters   -> agentPoolProfiles[].vmSize
      2. Maps every SKU name to its quota family (e.g. Standard_D2ads_v6 -> standardDadv6Family) using
         the Microsoft.Compute/skus API - no hard-coded lookup table.
      3. Writes:
           * used-skus-<region>-<date>.csv   - one row per SKU with VM / VMSS / AKS counts + family + zones
           * capacity-config.json            - { location, skus[], families[], subscriptions[] }

    Feed the config straight into the orchestrator:
        .\New-CapacityReport.ps1 -ConfigPath .\output\capacity-config.json -IncludeAks -Dashboard

    Access required: Reader on the target subscriptions (Resource Graph + Compute SKUs read).

.PARAMETER Location
    Region used for the family/zone lookup and config (default norwayeast). SKU discovery itself is
    region-agnostic; this only affects which region's SKU catalogue is read for family mapping.

.PARAMETER SubscriptionIds
    Optional list of subscription IDs to scope discovery to. Omit to scan every visible subscription.

.PARAMETER SubscriptionCsv
    Optional CSV (Name,SubId) to scope discovery. Overridden by -SubscriptionIds.

.PARAMETER Top
    Keep only the N most-used SKUs in the emitted config (0 = keep all, default 0).

.PARAMETER OutDir
    Output folder (default ..\output).

.EXAMPLE
    .\Get-UsedSkus.ps1
    Discover everything in the tenant and emit config + CSV.

.EXAMPLE
    .\Get-UsedSkus.ps1 -SubscriptionCsv .\mysubs.csv -Location swedencentral -Top 10
#>
[CmdletBinding()]
param(
    [string]   $Location = 'norwayeast',
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [int]      $Top = 0,
    [string]   $OutDir
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutDir) { $OutDir = Get-DefaultOutDir }
$date = Get-Date -Format 'yyyyMMdd'

# Ensure resource-graph extension
az extension show --name resource-graph -o none 2>$null; if (-not $?) { az extension add --name resource-graph -o none 2>$null }

# Resolve optional subscription scope
$subs = $null
if ($SubscriptionIds -and $SubscriptionIds.Count) { $subs = $SubscriptionIds }
elseif ($SubscriptionCsv) { $subs = (Resolve-Subscriptions -SubscriptionCsv $SubscriptionCsv).SubId }
$scopeArgs = @()
if ($subs) { $scopeArgs = @('--subscriptions') + $subs }

function Invoke-Graph([string]$query) {
    $all = @(); $skip = 0
    do {
        $b = az graph query -q $query --first 1000 --skip $skip @scopeArgs -o json 2>$null | ConvertFrom-Json
        if (-not $b) { break }
        if ($b.data) { $all += $b.data }
        $total = [int]$b.total_records
        $skip += 1000
    } while ($b.data.Count -gt 0 -and $all.Count -lt $total)
    return $all
}

Write-Host "Discovering VM SKUs in use$([string]::Format('{0}', $(if ($subs) { " across $($subs.Count) subscription(s)" } else { ' across the tenant' })))..." -ForegroundColor Cyan

$qVm   = "resources | where type =~ 'microsoft.compute/virtualmachines' | extend s=tolower(tostring(properties.hardwareProfile.vmSize)) | where isnotempty(s) | summarize Count=count() by SkuName=s"
$qVmss = "resources | where type =~ 'microsoft.compute/virtualmachinescalesets' | extend s=tolower(tostring(sku.name)) | where isnotempty(s) | summarize Count=count() by SkuName=s"
$qAks  = "resources | where type =~ 'microsoft.containerservice/managedclusters' | mv-expand pool=properties.agentPoolProfiles | extend s=tolower(tostring(pool.vmSize)) | where isnotempty(s) | summarize Count=count() by SkuName=s"

$vm   = Invoke-Graph $qVm
$vmss = Invoke-Graph $qVmss
$aks  = Invoke-Graph $qAks

# Merge counts per SKU
$tally = @{}
function Add-Tally($rows,[string]$key) {
    foreach ($r in $rows) {
        $sku = $r.SkuName
        if (-not $tally.ContainsKey($sku)) { $tally[$sku] = [ordered]@{ VmCount=0; VmssCount=0; AksCount=0 } }
        $tally[$sku][$key] = [int]$r.Count
    }
}
Add-Tally $vm   'VmCount'
Add-Tally $vmss 'VmssCount'
Add-Tally $aks  'AksCount'

if ($tally.Count -eq 0) { Write-Warning "No VM / VMSS / AKS workloads found in scope."; return }

# Build SKU -> family/zone/proper-name map from the Compute SKUs catalogue (one sub is enough)
$mapSub = if ($subs) { $subs[0] } else { (az account show --query id -o tsv 2>$null) }
Write-Host "Mapping $($tally.Count) SKU(s) to quota families via $Location catalogue..." -ForegroundColor Cyan
$catalogue = Get-ComputeSkus -SubId $mapSub -Location $Location
$famMap = @{}
foreach ($c in $catalogue) {
    if ($c.resourceType -eq 'virtualMachines') {
        $famMap[$c.name.ToLower()] = [pscustomobject]@{
            Name   = $c.name
            Family = $c.family
            Zones  = (($c.locationInfo.zones | Sort-Object) -join ',')
        }
    }
}

# Compose result rows
$rows = foreach ($kv in $tally.GetEnumerator()) {
    $info = $famMap[$kv.Key]
    $total = [int]$kv.Value.VmCount + [int]$kv.Value.VmssCount + [int]$kv.Value.AksCount
    [pscustomobject]@{
        Sku       = if ($info) { $info.Name } else { $kv.Key }
        Family    = if ($info) { $info.Family } else { '(not offered in '+$Location+')' }
        VmCount   = $kv.Value.VmCount
        VmssCount = $kv.Value.VmssCount
        AksCount  = $kv.Value.AksCount
        Total     = $total
        Zones     = if ($info) { $info.Zones } else { '' }
    }
}
$rows = $rows | Sort-Object Total -Descending
if ($Top -gt 0) { $rows = $rows | Select-Object -First $Top }

$csv = Join-Path $OutDir "used-skus-$Location-$date.csv"
$rows | Export-Csv $csv -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($rows.Count) SKU(s) -> $csv" -ForegroundColor Green

# Console summary
$rows | Select-Object Sku, Family, VmCount, VmssCount, AksCount, Total, Zones | Format-Table -Auto | Out-String | Write-Host

# Emit reusable config
$skuList = @($rows | Where-Object { $_.Family -notlike '(not offered*' } | Select-Object -ExpandProperty Sku)
$famList = @($rows | Where-Object { $_.Family -notlike '(not offered*' } | Select-Object -ExpandProperty Family -Unique)
$skipped = @($rows | Where-Object { $_.Family -like '(not offered*' } | Select-Object -ExpandProperty Sku)
$subObjs = @()
if ($SubscriptionCsv) { $subObjs = Resolve-Subscriptions -SubscriptionCsv $SubscriptionCsv | ForEach-Object { @{ name=$_.Name; id=$_.SubId } } }
elseif ($subs) { $subObjs = $subs | ForEach-Object { @{ name=$_; id=$_ } } }

$config = [ordered]@{
    location      = $Location
    generated     = (Get-Date -Format 's')
    discoveredFrom= @{ virtualMachines=$vm.Count; scaleSets=$vmss.Count; aksNodePools=$aks.Count }
    subscriptions = $subObjs
    skus          = $skuList
    families      = $famList
}
$cfgPath = Join-Path $OutDir 'capacity-config.json'
$config | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8
Write-Host "Config     -> $cfgPath" -ForegroundColor Green
Write-Host "  skus     : $($skuList.Count)  families: $($famList.Count)" -ForegroundColor DarkGray
if ($skipped.Count) { Write-Host "  note     : $($skipped.Count) SKU(s) in use are not offered in $Location and were left out of the config: $($skipped -join ', ')" -ForegroundColor Yellow }
Write-Host "`nRun the full report against the discovered SKUs:" -ForegroundColor Cyan
Write-Host "  .\New-CapacityReport.ps1 -ConfigPath `"$cfgPath`" -IncludeAks -IncludeZonal -Dashboard" -ForegroundColor Gray
