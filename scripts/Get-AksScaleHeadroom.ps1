<#
.SYNOPSIS
    AKS scale-headroom check: can every node pool reach its autoscaler maxCount given the current
    VM-family vCPU quota in its subscription + region? Exports a per-pool detail CSV and a
    per-family rollup CSV.

.DESCRIPTION
    The toolkit already collects AKS inventory and per-family vCPU quota, but never joins them - so it
    cannot answer a common operational question: "if every node pool scaled to its maxCount, would we
    run out of family quota?" This is a silent risk that only surfaces during an incident or a scale
    event.

    This script performs that join as a pure READ-ONLY derivation from data the toolkit already reads:
      * AKS node pools (Azure Resource Graph) - vmSize, count, autoscaler min/max, mode, priority.
      * Microsoft.Compute/skus - VM size -> family + vCPUs.
      * az vm list-usage - per-family used / limit / available vCPUs (and the regional low-priority
        pool for Spot pools).

    Nothing is created, scaled or modified. Output is local CSV only.

    Per node pool it computes the incremental vCPUs needed to reach the scale target (maxCount when
    autoscaling is on, else current count), aggregates per VM family (Spot pools draw on a *separate*
    regional low-priority pool and are aggregated separately), and flags families that cannot fully
    scale within current quota.

    IMPORTANT: quota headroom is NOT guaranteed physical capacity (see docs/concepts.md). A pool that
    passes this check can still fail to allocate if the region is capacity-constrained; validate with
    Get-SpotPlacementScore.ps1 / a test deploy.

    Access required: Reader on the target subscriptions. Auto-installs the `resource-graph` az
    extension if missing.

.PARAMETER Location
    Region to evaluate (e.g. 'norwayeast'). Quota and SKU metadata are region-specific. Default
    'norwayeast'.

.PARAMETER SubscriptionIds
    Optional explicit subscription id(s). Omit to scan every visible subscription.

.PARAMETER SubscriptionCsv
    Optional CSV with a SubId column. Omit both to scan all visible subscriptions.

.PARAMETER OutDir
    Output folder (default ..\output). Two CSVs are written:
    aks-scale-headroom-detail-<region>-<date>.csv and aks-scale-headroom-rollup-<region>-<date>.csv.

.EXAMPLE
    .\Get-AksScaleHeadroom.ps1 -Location norwayeast

.EXAMPLE
    .\Get-AksScaleHeadroom.ps1 -Location swedencentral -SubscriptionCsv .\mysubs.csv
#>
[CmdletBinding()]
param(
    [string]   $Location = 'norwayeast',
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [string]   $OutDir
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null

if (-not $OutDir) { $OutDir = Get-DefaultOutDir }
$date         = Get-Date -Format 'yyyyMMdd'
$detailOut    = Join-Path $OutDir ("aks-scale-headroom-detail-{0}-{1}.csv" -f $Location, $date)
$rollupOut    = Join-Path $OutDir ("aks-scale-headroom-rollup-{0}-{1}.csv" -f $Location, $date)

az extension show --name resource-graph -o none 2>$null
if (-not $?) {
    Write-Host "Installing az 'resource-graph' extension..." -ForegroundColor DarkGray
    az extension add --name resource-graph -o none 2>$null
}

$subs = Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv
Write-Host ("Evaluating AKS scale-headroom across {0} subscription(s) in {1}..." -f $subs.Count, $Location) -ForegroundColor Cyan

# Read every AKS cluster in $Location for one subscription via Resource Graph (paged).
function Get-AksClusters {
    param([string]$SubId, [string]$Loc)
    $clauses = @(
        "resources",
        "where type =~ 'microsoft.containerservice/managedclusters'",
        "where location =~ '$Loc'",
        "project id, name, subscriptionId, resourceGroup, location, provState = tostring(properties.provisioningState), k8s = tostring(properties.kubernetesVersion), clusterPower = tostring(properties.powerState.code), pools = tostring(properties.agentPoolProfiles)",
        "order by name asc"
    )
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

$detail = @()

foreach ($s in $subs) {
    az account set --subscription $s.SubId 2>$null

    $clusters = Get-AksClusters -SubId $s.SubId -Loc $Location
    if (-not $clusters -or $clusters.Count -eq 0) { continue }

    # VM size -> { family, vCPUs } lookup for this sub+region.
    $skuMap = @{}
    foreach ($sku in (Get-ComputeSkus -SubId $s.SubId -Location $Location)) {
        if ($sku.resourceType -ne 'virtualMachines') { continue }
        $v = ($sku.capabilities | Where-Object { $_.name -eq 'vCPUs' } | Select-Object -First 1).value
        if ($null -ne $v) {
            $skuMap[$sku.name] = [pscustomobject]@{ Family = $sku.family; VCPUs = [int]$v }
        }
    }

    # Per-family quota lookup (used/limit/avail) + the regional low-priority (Spot) pool.
    $quotaMap = @{}
    $spotQuota = $null
    foreach ($u in (az vm list-usage -l $Location -o json 2>$null | ConvertFrom-Json)) {
        $key = $u.name.value
        $rec = [pscustomobject]@{ Used = [int]$u.currentValue; Limit = [int]$u.limit; Avail = ([int]$u.limit - [int]$u.currentValue) }
        if ($key -eq 'lowPriorityCores') { $spotQuota = $rec }
        $quotaMap[$key.ToLower()] = $rec
    }

    foreach ($c in $clusters) {
        $pp = $null
        try { if ($c.pools) { $pp = $c.pools | ConvertFrom-Json } } catch { $pp = $null }
        if (-not $pp) { continue }

        foreach ($pool in @($pp)) {
            $vmSize = $pool.vmSize
            $isSpot = ($pool.scaleSetPriority -eq 'Spot')

            $fam = ''; $vcpu = 0; $haveSku = $false
            if ($vmSize -and $skuMap.ContainsKey($vmSize)) {
                $fam = $skuMap[$vmSize].Family
                $vcpu = $skuMap[$vmSize].VCPUs
                $haveSku = $true
            }

            $current = 0
            if ($null -ne $pool.count) { $current = [int]$pool.count }

            $autoscale = ($pool.enableAutoScaling -eq $true)
            $minCount = ''
            $maxCount = ''
            if ($null -ne $pool.minCount) { $minCount = [int]$pool.minCount }
            if ($null -ne $pool.maxCount) { $maxCount = [int]$pool.maxCount }

            # Target = autoscaler maxCount when autoscaling is on, else the current (manual) count.
            # Never invent a maxCount for a manually-scaled pool.
            $target = $current
            if ($autoscale -and ($null -ne $pool.maxCount)) { $target = [int]$pool.maxCount }

            $currentVCPUs = $vcpu * $current
            $targetVCPUs  = $vcpu * $target
            $incremental  = $targetVCPUs - $currentVCPUs
            if ($incremental -lt 0) { $incremental = 0 }

            $poolPower = ''
            if ($pool.powerState -and $pool.powerState.code) { $poolPower = $pool.powerState.code }
            elseif ($c.clusterPower) { $poolPower = $c.clusterPower }

            $detail += [pscustomobject][ordered]@{
                SubscriptionName       = $s.Name
                SubscriptionId         = $s.SubId
                Location               = $Location
                ResourceGroup          = $c.resourceGroup
                ClusterName            = $c.name
                ClusterId              = $c.id
                ProvisioningState      = $c.provState
                PowerState             = $poolPower
                KubernetesVersion      = $c.k8s
                PoolName               = $pool.name
                PoolMode               = $pool.mode
                VmSize                 = $vmSize
                VmFamily               = $fam
                VCPUsPerNode           = $(if ($haveSku) { $vcpu } else { '' })
                EnableAutoScaling      = $autoscale
                MinCount               = $minCount
                MaxCount               = $maxCount
                CurrentCount           = $current
                TargetCount            = $target
                CurrentCommittedVCPUs  = $(if ($haveSku) { $currentVCPUs } else { '' })
                RequiredAtTargetVCPUs  = $(if ($haveSku) { $targetVCPUs } else { '' })
                IncrementalVCPUsNeeded = $(if ($haveSku) { $incremental } else { '' })
                ScaleSetPriority       = $(if ($isSpot) { 'Spot' } else { 'Regular' })
                # Filled in after group aggregation:
                QuotaUsed                 = ''
                QuotaLimit                = ''
                QuotaAvail                = ''
                CanFullyScaleFamilyGroup  = ''
                ShortfallVCPUs            = ''
                Finding                   = ''
                _HaveSku                  = $haveSku
                _IsSpot                   = $isSpot
                _SpotAvail                = $(if ($spotQuota) { $spotQuota.Avail } else { $null })
                _SpotUsed                 = $(if ($spotQuota) { $spotQuota.Used } else { $null })
                _SpotLimit                = $(if ($spotQuota) { $spotQuota.Limit } else { $null })
                _FamUsed                  = $(if ($fam -and $quotaMap.ContainsKey($fam.ToLower())) { $quotaMap[$fam.ToLower()].Used } else { $null })
                _FamLimit                 = $(if ($fam -and $quotaMap.ContainsKey($fam.ToLower())) { $quotaMap[$fam.ToLower()].Limit } else { $null })
                _FamAvail                 = $(if ($fam -and $quotaMap.ContainsKey($fam.ToLower())) { $quotaMap[$fam.ToLower()].Avail } else { $null })
            }
        }
    }
}

if (-not $detail -or $detail.Count -eq 0) {
    Write-Host "`nNo AKS node pools found in $Location for the scanned subscription(s)." -ForegroundColor Yellow
    return
}

# Aggregate per quota group: regular pools by (sub, family); Spot pools by (sub) against the single
# regional low-priority pool, since all Spot families share it.
$rollup = @()
$verdict = @{}   # key -> @{ CanFullyScale; Shortfall }

# Regular groups.
$regular = @($detail | Where-Object { $_._IsSpot -eq $false -and $_._HaveSku -eq $true -and $_._FamAvail -ne $null })
foreach ($grp in ($regular | Group-Object SubscriptionId, VmFamily)) {
    $first = $grp.Group[0]
    $needed = ($grp.Group | Measure-Object IncrementalVCPUsNeeded -Sum).Sum
    $avail  = [int]$first._FamAvail
    $can    = ($needed -le $avail)
    $short  = [Math]::Max(0, $needed - $avail)
    $key = "R|$($first.SubscriptionId)|$($first.VmFamily.ToLower())"
    $verdict[$key] = [pscustomobject]@{ CanFullyScale = $can; Shortfall = $short }

    $rollup += [pscustomobject][ordered]@{
        SubscriptionName       = $first.SubscriptionName
        SubscriptionId         = $first.SubscriptionId
        Location               = $Location
        VmFamily               = $first.VmFamily
        QuotaClass             = 'Regular'
        PoolCount              = $grp.Group.Count
        ClusterCount           = (@($grp.Group | Select-Object -ExpandProperty ClusterId -Unique)).Count
        CurrentCommittedVCPUs  = ($grp.Group | Measure-Object CurrentCommittedVCPUs -Sum).Sum
        RequiredAtTargetVCPUs  = ($grp.Group | Measure-Object RequiredAtTargetVCPUs -Sum).Sum
        IncrementalVCPUsNeeded = $needed
        QuotaUsed              = [int]$first._FamUsed
        QuotaLimit             = [int]$first._FamLimit
        QuotaAvail             = $avail
        CanFullyScale          = $can
        ShortfallVCPUs         = $short
        Notes                  = ''
    }
}

# Spot groups (one per subscription; shared regional low-priority pool).
$spot = @($detail | Where-Object { $_._IsSpot -eq $true -and $_._HaveSku -eq $true })
foreach ($grp in ($spot | Group-Object SubscriptionId)) {
    $first = $grp.Group[0]
    $needed = ($grp.Group | Measure-Object IncrementalVCPUsNeeded -Sum).Sum
    $haveSpotQuota = ($null -ne $first._SpotAvail)
    $avail = if ($haveSpotQuota) { [int]$first._SpotAvail } else { 0 }
    $can   = if ($haveSpotQuota) { ($needed -le $avail) } else { $null }
    $short = if ($haveSpotQuota) { [Math]::Max(0, $needed - $avail) } else { '' }
    $fams  = (@($grp.Group | Select-Object -ExpandProperty VmFamily -Unique | Where-Object { $_ }) -join ';')
    $key = "S|$($first.SubscriptionId)"
    $verdict[$key] = [pscustomobject]@{ CanFullyScale = $can; Shortfall = $short }

    $rollup += [pscustomobject][ordered]@{
        SubscriptionName       = $first.SubscriptionName
        SubscriptionId         = $first.SubscriptionId
        Location               = $Location
        VmFamily               = $fams
        QuotaClass             = 'Spot'
        PoolCount              = $grp.Group.Count
        ClusterCount           = (@($grp.Group | Select-Object -ExpandProperty ClusterId -Unique)).Count
        CurrentCommittedVCPUs  = ($grp.Group | Measure-Object CurrentCommittedVCPUs -Sum).Sum
        RequiredAtTargetVCPUs  = ($grp.Group | Measure-Object RequiredAtTargetVCPUs -Sum).Sum
        IncrementalVCPUsNeeded = $needed
        QuotaUsed              = $(if ($haveSpotQuota) { [int]$first._SpotUsed } else { '' })
        QuotaLimit             = $(if ($haveSpotQuota) { [int]$first._SpotLimit } else { '' })
        QuotaAvail             = $(if ($haveSpotQuota) { $avail } else { '' })
        CanFullyScale          = $can
        ShortfallVCPUs         = $short
        Notes                  = 'Spot draws on the single regional low-priority vCPU pool, shared across all Spot families'
    }
}

# Join the family/group verdict + quota numbers back onto each detail row and decide its Finding.
foreach ($row in $detail) {
    if (-not $row._HaveSku) {
        $row.Finding = 'MissingSkuMetadata'
    }
    elseif ($row._IsSpot) {
        $row.QuotaUsed  = $(if ($null -ne $row._SpotUsed)  { $row._SpotUsed }  else { '' })
        $row.QuotaLimit = $(if ($null -ne $row._SpotLimit) { $row._SpotLimit } else { '' })
        $row.QuotaAvail = $(if ($null -ne $row._SpotAvail) { $row._SpotAvail } else { '' })
        $key = "S|$($row.SubscriptionId)"
        $v = $verdict[$key]
        if ($null -eq $row._SpotAvail) {
            $row.Finding = 'SpotQuotaCheckNeeded'
        } elseif ($v -and $v.CanFullyScale -eq $false) {
            $row.CanFullyScaleFamilyGroup = $false
            $row.ShortfallVCPUs = $v.Shortfall
            $row.Finding = 'QuotaShortfall'
        } else {
            $row.CanFullyScaleFamilyGroup = $true
            $row.ShortfallVCPUs = 0
            $row.Finding = 'OK'
        }
    }
    elseif ($null -eq $row._FamAvail) {
        $row.Finding = 'MissingQuotaFamily'
    }
    else {
        $row.QuotaUsed  = $row._FamUsed
        $row.QuotaLimit = $row._FamLimit
        $row.QuotaAvail = $row._FamAvail
        $key = "R|$($row.SubscriptionId)|$($row.VmFamily.ToLower())"
        $v = $verdict[$key]
        if ($v -and $v.CanFullyScale -eq $false) {
            $row.CanFullyScaleFamilyGroup = $false
            $row.ShortfallVCPUs = $v.Shortfall
            $row.Finding = 'QuotaShortfall'
        } else {
            $row.CanFullyScaleFamilyGroup = $true
            $row.ShortfallVCPUs = 0
            $row.Finding = 'OK'
        }
    }
}

# Drop the internal working columns before export.
$detailCols = $detail[0].psobject.Properties.Name | Where-Object { $_ -notlike '_*' }
$detailOutObj = $detail | Select-Object $detailCols

$detailOutObj | Export-Csv $detailOut -NoTypeInformation -Encoding UTF8
$rollup       | Export-Csv $rollupOut -NoTypeInformation -Encoding UTF8

Write-Host "`nExported $($detailOutObj.Count) node-pool row(s) -> $detailOut" -ForegroundColor Green
Write-Host "Exported $($rollup.Count) family-group row(s) -> $rollupOut" -ForegroundColor Green

# Summary.
$walls = @($rollup | Where-Object { $_.CanFullyScale -eq $false })
$findings = $detail | Group-Object Finding | Sort-Object Count -Descending
Write-Host "`nFindings:"
$findings | ForEach-Object { "  {0,-22} {1}" -f $_.Name, $_.Count }

if ($walls.Count) {
    Write-Host "`nQuota walls (a family group that cannot fully scale to target within current quota):" -ForegroundColor Red
    $walls | Sort-Object ShortfallVCPUs -Descending | ForEach-Object {
        "  {0,-28} {1,-22} {2,-8} short {3} vCPUs (need {4}, avail {5})" -f `
            $_.SubscriptionName, $_.VmFamily, $_.QuotaClass, $_.ShortfallVCPUs, $_.IncrementalVCPUsNeeded, $_.QuotaAvail
    }
} else {
    Write-Host "`nNo quota walls: every node-pool family group can scale to target within current quota." -ForegroundColor Green
}

Write-Host "`nReminder: quota headroom is not guaranteed physical capacity. Validate a target region with" -ForegroundColor DarkYellow
Write-Host "Get-SpotPlacementScore.ps1 or a small test deploy before relying on scale-out." -ForegroundColor DarkYellow
