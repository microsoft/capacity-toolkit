<#
.SYNOPSIS
    Tenant-wide (or subscription-scoped) AKS inventory via Azure Resource Graph, exported to CSV.

.DESCRIPTION
    Lists every AKS managed cluster the signed-in identity can see, with subscription, resource
    group, region, provisioning state, Kubernetes version and the node VM sizes in use. Resource
    Graph is the fastest way to inventory at scale and works with Reader access. Handles paging.

    Access required: Reader (at the scope you want to inventory). Auto-installs the
    `resource-graph` az extension if missing.

.PARAMETER SubscriptionIds
    Optional: restrict to specific subscriptions. Omit to scan everything visible.

.PARAMETER Location
    Optional: filter to a region (e.g. 'norwayeast'). Omit for all regions.

.PARAMETER OutPath
    CSV output path (default: ..\output\aks-inventory-<date>.csv).

.EXAMPLE
    .\Get-AksInventory.ps1
.EXAMPLE
    .\Get-AksInventory.ps1 -Location norwayeast -OutPath .\ne-aks.csv
#>
[CmdletBinding()]
param(
    [string[]] $SubscriptionIds,
    [string]   $Location,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutPath) { $OutPath = Join-Path (Get-DefaultOutDir) ("aks-inventory-{0}.csv" -f (Get-Date -Format 'yyyyMMdd')) }

az extension show --name resource-graph -o none 2>$null
if (-not $?) {
    Write-Host "Installing az 'resource-graph' extension..." -ForegroundColor DarkGray
    az extension add --name resource-graph -o none 2>$null
}

# Reliable pattern: project raw rows (incl. the agentPoolProfiles array as JSON),
# then collapse node SKUs in PowerShell. Avoids mv-expand/summarize column-loss and
# pagination quirks seen with Resource Graph aggregations. Build as a single line so
# an empty optional filter never injects a blank line that truncates the KQL.
$clauses = @(
    "resources",
    "where type =~ 'microsoft.containerservice/managedclusters'"
)
if ($Location) { $clauses += "where location =~ '$Location'" }
$clauses += "project name, subscriptionId, resourceGroup, location, provState = tostring(properties.provisioningState), k8s = tostring(properties.kubernetesVersion), pools = tostring(properties.agentPoolProfiles)"
$clauses += "order by subscriptionId asc, name asc"
$query = $clauses -join ' | '

$cmd = @('graph','query','-q',$query,'--first','1000')
if ($SubscriptionIds) { $cmd += @('--subscriptions'); $cmd += $SubscriptionIds }

$raw = @(); $skip = 0
do {
    $b = az @cmd --skip $skip -o json 2>$null | ConvertFrom-Json
    if ($b.data) { $raw += $b.data }
    $total = $b.total_records
    $skip += 1000
} while ($b -and $b.data.Count -gt 0 -and $raw.Count -lt $total)

# Parse node pools per cluster from the JSON blob.
$all = foreach ($c in $raw) {
    $skus = @(); $nodePools = 0; $nodeCount = 0
    try {
        $pp = if ($c.pools) { $c.pools | ConvertFrom-Json } else { $null }
        if ($pp) {
            $nodePools = @($pp).Count
            $skus = @($pp | ForEach-Object { $_.vmSize } | Where-Object { $_ } | Select-Object -Unique)
            $nodeCount = ($pp | ForEach-Object { [int]($_.count) } | Measure-Object -Sum).Sum
        }
    } catch {}
    [pscustomobject]@{
        name           = $c.name
        subscriptionId = $c.subscriptionId
        resourceGroup  = $c.resourceGroup
        location       = $c.location
        provState      = $c.provState
        k8s            = $c.k8s
        nodePools      = $nodePools
        nodeCount      = $nodeCount
        skus           = ($skus -join ';')
    }
}

$all | Select-Object name, subscriptionId, resourceGroup, location, provState, k8s, nodePools, nodeCount, skus |
    Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($all.Count) cluster(s) -> $OutPath" -ForegroundColor Green

# Summaries
Write-Host "`nClusters: $($all.Count)   Subscriptions hosting AKS: $(($all.subscriptionId | Select-Object -Unique).Count)"
Write-Host "`nBy region:"
$all | Group-Object location | Sort-Object Count -Descending | ForEach-Object { "  {0,-18} {1}" -f $_.Name, $_.Count }
Write-Host "`nBy provisioning state:"
$all | Group-Object provState | Sort-Object Count -Descending | ForEach-Object { "  {0,-14} {1}" -f $_.Name, $_.Count }

# Node SKU family rollup (clusters containing each family)
$fam = @{}
foreach ($c in $all) {
    $fams = ([regex]::Matches($c.skus,'(?i)Standard_[A-Za-z0-9]+') | ForEach-Object { $_.Value } |
             ForEach-Object { if ($_ -match '(?i)^Standard_([A-Za-z]+)') { $matches[1].ToUpper() } } | Select-Object -Unique)
    foreach ($x in $fams) { $fam[$x] = ($fam[$x] + 1) }
}
if ($fam.Count) {
    Write-Host "`nNode SKU family usage (clusters containing each family):"
    $fam.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "  {0,-8} {1}" -f $_.Key, $_.Value }
}
