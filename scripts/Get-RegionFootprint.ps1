<#
.SYNOPSIS
    Discover which Azure regions a tenant ACTUALLY uses (resource + AKS footprint), and optionally
    compare SKU enablement / quota across the current regions and any candidate regions being
    evaluated for a new or relocated deployment.

.DESCRIPTION
    Answers two questions that always come up in a capacity conversation:
      1. "Where does this tenant run today?"  -> resource & AKS counts per region (Resource Graph).
      2. "Is region X a viable place to deploy / move to?" -> per-region SKU regional+zonal enablement
         (and optionally quota headroom) so you can compare the home region against alternatives
         (e.g. Norway East vs Sweden Central vs West Europe).

    Access required: Reader. Uses the resource-graph az extension (auto-installed).

.PARAMETER EvaluateRegions
    Candidate regions to score for enablement (e.g. swedencentral,westeurope). The existing
    regions are always included automatically. Omit to only report the current footprint.

.PARAMETER Skus
    SKUs to score in the cross-region comparison (default: representative AKS set).

.PARAMETER SubscriptionIds / SubscriptionCsv
    Subscriptions to evaluate enablement for. Omit both = all visible subs. The footprint discovery
    itself always spans everything Resource Graph can see.

.PARAMETER OutDir
    Output folder (default ..\output).

.EXAMPLE
    .\Get-RegionFootprint.ps1
.EXAMPLE
    .\Get-RegionFootprint.ps1 -EvaluateRegions swedencentral,westeurope -SubscriptionCsv .\mysubs.csv
#>
[CmdletBinding()]
param(
    [string[]] $EvaluateRegions,
    [string[]] $Skus = @('Standard_B2s_v2','Standard_D2ads_v6','Standard_E2ads_v6'),
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [string]   $OutDir
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutDir) { $OutDir = Get-DefaultOutDir }
$date = Get-Date -Format 'yyyyMMdd'

az extension show --name resource-graph -o none 2>$null
if (-not $?) { az extension add --name resource-graph -o none 2>$null }

# ---- 1. Footprint discovery via Resource Graph ----------------------------------------------------
function Invoke-Graph([string]$Kql) {
    $rows = @(); $skip = 0
    do {
        $b = az graph query -q $Kql --first 1000 --skip $skip -o json 2>$null | ConvertFrom-Json
        if ($b.data) { $rows += $b.data }
        $total = $b.total_records; $skip += 1000
    } while ($b -and $b.data.Count -gt 0 -and $rows.Count -lt $total)
    return $rows
}

Write-Host "Discovering region footprint across the tenant..." -ForegroundColor Cyan
$resByLoc = Invoke-Graph "resources | where location != '' and location !~ 'global' | summarize Resources=count(), Subscriptions=dcount(subscriptionId) by location"
$aksByLoc = Invoke-Graph "resources | where type =~ 'microsoft.containerservice/managedclusters' | summarize AksClusters=count() by location"
$aksMap = @{}; $aksByLoc | ForEach-Object { $aksMap[$_.location] = [int]$_.AksClusters }

$currentRegions = @($resByLoc.location)

$footprint = foreach ($r in $resByLoc | Sort-Object { [int]$_.Resources } -Descending) {
    [pscustomobject]@{
        Region        = $r.location
        Resources     = [int]$r.Resources
        Subscriptions = [int]$r.Subscriptions
        AksClusters   = $(if ($aksMap.ContainsKey($r.location)) { $aksMap[$r.location] } else { 0 })
        Status        = if ($EvaluateRegions -contains $r.location) { 'Current+Candidate' } else { 'Current' }
    }
}
# candidate regions with no existing footprint
foreach ($cr in $EvaluateRegions) {
    if ($currentRegions -notcontains $cr) {
        $footprint += [pscustomobject]@{ Region=$cr; Resources=0; Subscriptions=0; AksClusters=0; Status='Candidate (no footprint)' }
    }
}
$fpCsv = Join-Path $OutDir "region-footprint-$date.csv"
$footprint | Export-Csv $fpCsv -NoTypeInformation -Encoding UTF8
Write-Host "`nRegion footprint -> $fpCsv" -ForegroundColor Green
$footprint | Format-Table Region, Resources, Subscriptions, AksClusters, Status -AutoSize

# ---- 2. Cross-region enablement + quota comparison (only if candidate regions given) --------------
if ($EvaluateRegions) {
    $compareRegions = @($currentRegions + $EvaluateRegions | Where-Object { $_ } | Select-Object -Unique)
    $subs = Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv
    Write-Host "`nScoring SKU enablement for $($subs.Count) sub(s) across $($compareRegions.Count) region(s)..." -ForegroundColor Cyan

    # Map the in-scope SKUs to their quota families once (family is region-agnostic).
    $wantFams = [ordered]@{}
    foreach ($s in $subs) {
        $cat = Get-ComputeSkus -SubId $s.SubId -Location $compareRegions[0]
        if ($cat) {
            foreach ($sk in $Skus) {
                $m = $cat | Where-Object { $_.name -eq $sk } | Select-Object -First 1
                if ($m -and $m.family) { $wantFams[$m.family] = $true }
            }
            break
        }
    }
    $famList = @($wantFams.Keys)

    $comparison = @(); $quotaCompare = @()
    foreach ($region in $compareRegions) {
        # --- enablement per SKU ---
        $perSku = @{}; foreach ($sk in $Skus) { $perSku[$sk] = [pscustomobject]@{ Reg=0; Full=0; Offered=0 } }
        foreach ($s in $subs) {
            $all = Get-ComputeSkus -SubId $s.SubId -Location $region
            if (-not $all) { continue }
            foreach ($sk in $Skus) {
                $sku = $all | Where-Object { $_.name -eq $sk } | Select-Object -First 1
                if (-not $sku) { continue }
                $perSku[$sk].Offered++
                $st = Resolve-SkuStatus -Sku $sku
                if ($st.Regional -eq 'Enabled') { $perSku[$sk].Reg++ }
                if ($st.Zones -eq '1,2,3')      { $perSku[$sk].Full++ }
            }
        }
        foreach ($sk in $Skus) {
            $comparison += [pscustomobject]@{
                Region        = $region
                Sku           = $sk
                Offered       = $perSku[$sk].Offered
                RegionalOf    = "$($perSku[$sk].Reg)/$($subs.Count)"
                All3ZonesOf   = "$($perSku[$sk].Full)/$($subs.Count)"
            }
        }
        # --- quota headroom per region (Total Regional + Spot + in-scope families) ---
        $qAgg = [ordered]@{}
        foreach ($s in $subs) {
            $usage = az vm list-usage --location $region --subscription $s.SubId -o json 2>$null | ConvertFrom-Json
            foreach ($u in $usage) {
                $key = $u.name.value
                if ($key -ne 'cores' -and $key -ne 'lowPriorityCores' -and $famList -notcontains $key) { continue }
                if (-not $qAgg.Contains($key)) { $qAgg[$key] = [pscustomobject]@{ Used=0; Limit=0 } }
                $qAgg[$key].Used  += [int]$u.currentValue
                $qAgg[$key].Limit += [int]$u.limit
            }
        }
        foreach ($k in $qAgg.Keys) {
            $label = switch ($k) { 'cores' { 'Total Regional vCPUs' } 'lowPriorityCores' { 'Spot vCPUs' } default { $k } }
            $quotaCompare += [pscustomobject]@{
                Region = $region
                Metric = $label
                Key    = $k
                Used   = $qAgg[$k].Used
                Limit  = $qAgg[$k].Limit
                Avail  = ($qAgg[$k].Limit - $qAgg[$k].Used)
            }
        }
    }
    $cmpCsv = Join-Path $OutDir "region-sku-comparison-$date.csv"
    $comparison | Export-Csv $cmpCsv -NoTypeInformation -Encoding UTF8
    Write-Host "`nCross-region SKU comparison -> $cmpCsv" -ForegroundColor Green
    $comparison | Format-Table Region, Sku, Offered, RegionalOf, All3ZonesOf -AutoSize

    $qCsv = Join-Path $OutDir "region-quota-comparison-$date.csv"
    $quotaCompare | Export-Csv $qCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Cross-region quota comparison -> $qCsv" -ForegroundColor Green
    $quotaCompare | Where-Object { $_.Key -eq 'cores' } | Format-Table Region, Metric, Used, Limit, Avail -AutoSize
}
