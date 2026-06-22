<#
.SYNOPSIS
    Generate a complete, self-consistent SYNTHETIC demo dataset (no Azure access required)
    so the capacity dashboard can be previewed offline with zero real tenant data.

.DESCRIPTION
    This is a clean-room generator: every value is invented from a deterministic seed for a
    fictional company ("Zava Inc"). It does NOT read or sanitize any real CSV, so its output
    is safe to commit and share. It emits the same CSV schemas the collector scripts produce,
    which the dashboard (New-CapacityDashboard.ps1) consumes directly.

    The generated universe deliberately showcases a range of dashboard states:
      * SKU enablement blocks and availability-zone gaps
      * near-capacity quota (general-purpose + burstable families)
      * GPU capacity crunch (NCads H100 v5)
      * a regional vCPU ceiling under pressure
      * one actively-pooled quota group and one that is not
      * AKS clusters in Failed / Upgrading / Canceled states
      * zone-redundant HA flexible servers alongside single-zone ones

    No Azure CLI, login, or network access is needed.

.PARAMETER OutDir
    Folder to write the CSVs into (default ..\output relative to this script).

.PARAMETER Company
    Display name of the fictional company (default 'Zava Inc').

.PARAMETER Prefix
    Short token used in resource/subscription names (default 'Zava').

.PARAMETER Location
    Primary region (default 'norwayeast').

.PARAMETER SecondaryRegion
    Comparison/secondary region (default 'swedencentral').

.PARAMETER Seed
    Integer seed for reproducible output (default 20260623). Same seed => identical files.

.EXAMPLE
    .\New-DemoDataset.ps1
    Writes a full demo dataset to ..\output, then render with:
    .\New-CapacityDashboard.ps1 -InputDir ..\output -Title "Zava Inc - Azure Capacity"

.EXAMPLE
    .\New-DemoDataset.ps1 -OutDir C:\temp\zava -Seed 7 -Company "Contoso Ltd" -Prefix Contoso
#>
[CmdletBinding()]
param(
    [string] $OutDir,
    [string] $Company         = 'Zava Inc',
    [string] $Prefix          = 'Zava',
    [string] $Location        = 'norwayeast',
    [string] $SecondaryRegion = 'swedencentral',
    [int]    $Seed            = 20260623
)

. "$PSScriptRoot\Common.ps1"

if (-not $OutDir) { $OutDir = Get-DefaultOutDir }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$rng   = New-Object System.Random($Seed)
$stamp = Get-Date -Format 'yyyyMMdd'
$P     = $Prefix

# ----------------------------------------------------------------------------- helpers
function RInt([int]$min, [int]$max) { return $rng.Next($min, $max + 1) }
function Pick($arr) { return $arr[$rng.Next(0, $arr.Count)] }
function Chance([double]$p) { return ($rng.NextDouble() -lt $p) }
function NewGuidD {
    $b = New-Object byte[] 16
    $rng.NextBytes($b)
    return ([guid][byte[]]$b).ToString()
}
function OutFile([string]$base) { return (Join-Path $OutDir ("{0}-{1}.csv" -f $base, $stamp)) }
function OutFileR([string]$base) { return (Join-Path $OutDir ("{0}-{1}-{2}.csv" -f $base, $Location, $stamp)) }
function Save($rows, [string]$path) {
    $rows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
}
# Turn a zone CSV like "2,3" into "AZ02,AZ03"; "none" => "none".
function ToAZ([string]$zones) {
    if (-not $zones -or $zones -eq '-' -or $zones -eq 'none') { return 'none' }
    return (($zones -split ',') | ForEach-Object { 'AZ0' + $_.Trim() }) -join ','
}

$workloads = 'Payments','Identity','Analytics','WebShop','DataLake','Platform','Billing',
             'Search','Logistics','Support','Risk','Media','IoT','ML','Reporting','Messaging'
$envs      = 'Prod','NonProd','Test','Dev'
$k8s       = '1.33.7','1.34.4','1.35.5'
$nodeSkus  = 'standard_b2s_v2','standard_d2ads_v6','standard_d4ads_v6','standard_d8ads_v6'

# ----------------------------------------------------------------------------- subscriptions
# Focus subs (first 7 workloads, Prod) carry the per-subscription quota/enablement narrative.
$subs = @()
$seen = @{}
for ($i = 0; $i -lt 7; $i++) {
    $name = "$P-$($workloads[$i])-Prod-0$([int]($i+1))"
    $seen[$name] = $true
    $subs += [pscustomobject]@{ Name = $name; SubId = NewGuidD; Env = 'Prod'; Focus = $true }
}
while ($subs.Count -lt 32) {
    $wl  = Pick $workloads
    $env = Pick $envs
    $nn  = '{0:D2}' -f (RInt 1 18)
    $name = "$P-$wl-$env-$nn"
    if ($seen[$name]) { continue }
    $seen[$name] = $true
    $subs += [pscustomobject]@{ Name = $name; SubId = NewGuidD; Env = $env; Focus = $false }
}
$focus = $subs | Where-Object { $_.Focus }

# Subscription friendly-name lookup file (dashboard maps SubId -> Name from *subs*.csv).
Save ($subs | Select-Object Name, SubId) (Join-Path $OutDir ("{0}-subs.csv" -f $P.ToLower()))

# ----------------------------------------------------------------------------- quota groups
$mgProd    = "$P-Prod-MG"
$mgNon     = "$P-NonProd-MG"
$qgProd    = ($P.ToLower() + 'prodpool')
$qgNon     = ($P.ToLower() + 'nonprodpool')
$qgProdDsp = "$P Prod Pool"
$qgNonDsp  = "$P NonProd Pool"

$qgMembers = foreach ($s in $subs) {
    if ($s.Env -eq 'Prod') { $mg = $mgProd; $qg = $qgProd; $dsp = $qgProdDsp }
    else                   { $mg = $mgNon;  $qg = $qgNon;  $dsp = $qgNonDsp }
    [pscustomobject]@{ ManagementGroup = $mg; QuotaGroup = $qg; DisplayName = $dsp; SubId = $s.SubId; SubName = $s.Name }
}
Save $qgMembers (OutFile 'quota-group-members')

$prodCount = ($subs | Where-Object { $_.Env -eq 'Prod' }).Count
$nonCount  = $subs.Count - $prodCount
Save @(
    [pscustomobject]@{ ManagementGroup = $mgProd; QuotaGroup = $qgProd; DisplayName = $qgProdDsp; GroupType = 'AllocationGroup'; ProvisioningState = 'Succeeded'; Members = $prodCount; RegionsWithLimits = $Location; PooledLimitsSet = 'yes' }
    [pscustomobject]@{ ManagementGroup = $mgNon;  QuotaGroup = $qgNon;  DisplayName = $qgNonDsp;  GroupType = 'AllocationGroup'; ProvisioningState = 'Succeeded'; Members = $nonCount;  RegionsWithLimits = '';        PooledLimitsSet = 'no' }
) (OutFile 'quota-groups')

# ----------------------------------------------------------------------------- focus-sub model
# Build a rich record per focus sub, then derive every per-sub narrow table from it.
$focusSkus = 'D4ads_v6','D2ads_v6','B2s_v2','D8ads_v6'
$model = @()
$idx = 0
foreach ($s in $focus) {
    # default: healthy, all zones open
    $sku = @{}
    foreach ($k in $focusSkus) { $sku[$k] = @{ Reg = 'Enabled'; Zones = '1,2,3' } }

    $dadLimit = 1316; $bsvLimit = 2110; $regLimit = 2464; $spotLimit = 2103
    $dadUsed  = RInt 40 260
    $bsvUsed  = RInt 10 120
    $regUsed  = RInt 120 700
    $spotUsed = RInt 0 60
    $posture  = 'active'
    $hapatterns = '1->az1,2->az2,3->az3','1->az1,2->az3,3->az2','1->az2,2->az1,3->az3'
    $pattern = Pick $hapatterns

    switch ($idx) {
        0 { $dadUsed = 1224; $posture = 'tight' }                                   # Dadv6 ~93%
        1 { $sku['D8ads_v6'] = @{ Reg = 'BLOCKED'; Zones = '' }; $posture = 'active' } # SKU block
        2 { $sku['D4ads_v6'] = @{ Reg = 'Enabled'; Zones = '2,3' }; $posture = 'idle' } # zone gap
        3 { $bsvUsed = 2026; $posture = 'tight' }                                   # Bsv2 ~96%
        4 { $regUsed = 2316; $posture = 'tight' }                                   # regional ceiling ~94%
        5 { $sku['D2ads_v6'] = @{ Reg = 'Enabled'; Zones = '1,3' }; $posture = 'idle' } # zone gap
        default { $posture = 'active' }
    }
    $idx++

    $util = [int][math]::Round(100.0 * $regUsed / $regLimit)
    $model += [pscustomobject]@{
        Sub = $s; Sku = $sku; Pattern = $pattern; Posture = $posture
        DadUsed = $dadUsed; DadLimit = $dadLimit
        BsvUsed = $bsvUsed; BsvLimit = $bsvLimit
        RegUsed = $regUsed; RegLimit = $regLimit
        SpotUsed = $spotUsed; SpotLimit = $spotLimit
        Util = $util
    }
}

# sku-enablement (Name == SubId, mirrors collector output)
Save ($model | ForEach-Object {
    [pscustomobject][ordered]@{
        Name = $_.Sub.SubId; SubId = $_.Sub.SubId
        D4ads_v6_reg = $_.Sku['D4ads_v6'].Reg; D4ads_v6_zones = $_.Sku['D4ads_v6'].Zones
        D2ads_v6_reg = $_.Sku['D2ads_v6'].Reg; D2ads_v6_zones = $_.Sku['D2ads_v6'].Zones
        B2s_v2_reg   = $_.Sku['B2s_v2'].Reg;   B2s_v2_zones   = $_.Sku['B2s_v2'].Zones
        D8ads_v6_reg = $_.Sku['D8ads_v6'].Reg; D8ads_v6_zones = $_.Sku['D8ads_v6'].Zones
    }
}) (OutFileR 'sku-enablement')

# zone-mappings
Save ($model | ForEach-Object {
    $parts = $_.Pattern -split ','
    $map = @{}
    foreach ($pp in $parts) { $lr = $pp -split '->'; $map[$lr[0]] = "$Location-$($lr[1])" }
    [pscustomobject][ordered]@{
        Name = $_.Sub.SubId; SubId = $_.Sub.SubId
        logical1 = $map['1']; logical2 = $map['2']; logical3 = $map['3']; Pattern = $_.Pattern
    }
}) (OutFileR 'zone-mappings')

# quota-usage
Save ($model | ForEach-Object {
    [pscustomobject][ordered]@{
        Name = $_.Sub.SubId; SubId = $_.Sub.SubId
        Dadv6_used = $_.DadUsed; Dadv6_limit = $_.DadLimit; Dadv6_avail = ($_.DadLimit - $_.DadUsed)
        Bsv2_used  = $_.BsvUsed; Bsv2_limit  = $_.BsvLimit; Bsv2_avail  = ($_.BsvLimit - $_.BsvUsed)
    }
}) (OutFileR 'quota-usage')

# regional-totals
Save ($model | ForEach-Object {
    [pscustomobject][ordered]@{
        Name = $_.Sub.SubId; SubId = $_.Sub.SubId
        RegionalvCPU_Used = $_.RegUsed; RegionalvCPU_Limit = $_.RegLimit; RegionalvCPU_Avail = ($_.RegLimit - $_.RegUsed)
        SpotvCPU_Used = $_.SpotUsed; SpotvCPU_Limit = $_.SpotLimit
    }
}) (OutFileR 'regional-totals')

# combined-capacity-report
Save ($model | ForEach-Object {
    [pscustomobject][ordered]@{
        Name = $_.Sub.SubId; SubId = $_.Sub.SubId
        D4ads_v6_reg = $_.Sku['D4ads_v6'].Reg; D4ads_v6_zones = $_.Sku['D4ads_v6'].Zones
        D2ads_v6_reg = $_.Sku['D2ads_v6'].Reg; D2ads_v6_zones = $_.Sku['D2ads_v6'].Zones
        B2s_v2_reg   = $_.Sku['B2s_v2'].Reg;   B2s_v2_zones   = $_.Sku['B2s_v2'].Zones
        D8ads_v6_reg = $_.Sku['D8ads_v6'].Reg; D8ads_v6_zones = $_.Sku['D8ads_v6'].Zones
        ZonePattern  = $_.Pattern
        Dadv6_used = $_.DadUsed; Dadv6_limit = $_.DadLimit; Dadv6_avail = ($_.DadLimit - $_.DadUsed)
        Bsv2_used  = $_.BsvUsed; Bsv2_limit  = $_.BsvLimit; Bsv2_avail  = ($_.BsvLimit - $_.BsvUsed)
    }
}) (OutFileR 'combined-capacity-report')

# enablement-findings (only where a block or zone gap exists)
$allAz = @('1','2','3')
$findings = foreach ($m in $model) {
    foreach ($k in $focusSkus) {
        $st = $m.Sku[$k]
        if ($st.Reg -eq 'BLOCKED') {
            [pscustomobject]@{ Name = $m.Sub.SubId; SubId = $m.Sub.SubId; Sku = "Standard_$k"; RegionalNeeded = 'yes'; ZonesOpen = 'none'; ZonesNeeded = 'AZ01,AZ02,AZ03' }
        }
        else {
            $open = @(); if ($st.Zones) { $open = $st.Zones -split ',' }
            $missing = $allAz | Where-Object { $open -notcontains $_ }
            if ($missing) {
                [pscustomobject]@{ Name = $m.Sub.SubId; SubId = $m.Sub.SubId; Sku = "Standard_$k"; RegionalNeeded = 'no'; ZonesOpen = (ToAZ $st.Zones); ZonesNeeded = (($missing | ForEach-Object { 'AZ0' + $_ }) -join ',') }
            }
        }
    }
}
Save $findings (OutFileR 'enablement-findings')

# quota-group-plan (pooled prod group, primary region)
$poolDadUsed = ($model | Measure-Object DadUsed -Sum).Sum
$poolBsvUsed = ($model | Measure-Object BsvUsed -Sum).Sum
$poolRegUsed = ($model | Measure-Object RegUsed -Sum).Sum
Save @(
    [pscustomobject]@{ Region = $Location; Scope = 'Total Regional vCPUs'; Members = $focus.Count; PoolUsed = $poolRegUsed; PoolLimit = 2464; PoolAvail = (2464 - $poolRegUsed); StrandedHeadroom = (2464 - $poolRegUsed); SuggestedPool = 2464 }
    [pscustomobject]@{ Region = $Location; Scope = 'Bsv2 family';          Members = $focus.Count; PoolUsed = $poolBsvUsed; PoolLimit = 2110; PoolAvail = (2110 - $poolBsvUsed); StrandedHeadroom = (2110 - $poolBsvUsed); SuggestedPool = 2110 }
    [pscustomobject]@{ Region = $Location; Scope = 'Dadv6 family';         Members = $focus.Count; PoolUsed = $poolDadUsed; PoolLimit = 1316; PoolAvail = (1316 - $poolDadUsed); StrandedHeadroom = [math]::Max(0, 1316 - $poolDadUsed); SuggestedPool = 1316 }
) (OutFileR 'quota-group-plan')

# quota-group-plan-members
Save ($model | ForEach-Object {
    [pscustomobject]@{ Region = $Location; SubName = $_.Sub.Name; SubId = $_.Sub.SubId; Used = $_.RegUsed; Limit = $_.RegLimit; Avail = ($_.RegLimit - $_.RegUsed); UtilPct = $_.Util; Posture = $_.Posture }
}) (OutFileR 'quota-group-plan-members')

# ----------------------------------------------------------------------------- AKS inventory
$aks = @()
$target = 42
for ($i = 0; $i -lt $target; $i++) {
    $s   = Pick $subs
    $wl  = Pick $workloads
    $loc = $Location; if (Chance 0.18) { $loc = $SecondaryRegion }
    $aks += [pscustomobject]@{
        name = ("aks-{0}-{1}-{2:D2}" -f $P.ToLower(), $wl.ToLower(), (RInt 1 30))
        subscriptionId = $s.SubId
        resourceGroup  = ("rg-{0}-{1:D3}" -f $P.ToLower(), (RInt 1 300))
        location  = $loc
        provState = 'Succeeded'
        k8s       = (Pick $k8s)
        nodePools = (RInt 1 4)
        nodeCount = (RInt 2 28)
        skus      = (Pick $nodeSkus)
    }
}
# inject lifecycle variety
$pool = 0..($aks.Count - 1) | Sort-Object { $rng.Next() }
foreach ($j in $pool[0..5])   { $aks[$j].provState = 'Failed' }
foreach ($j in $pool[6..8])   { $aks[$j].provState = 'Upgrading' }
foreach ($j in $pool[9..10])  { $aks[$j].provState = 'Canceled' }
Save $aks (OutFile 'aks-inventory')

# used-skus (aggregate node SKU usage across AKS)
Save (@('B2s_v2','D2ads_v6','D4ads_v6','D8ads_v6') | ForEach-Object {
    $sk = "standard_$($_.ToLower())"
    $cnt = ($aks | Where-Object { $_.skus -eq $sk }).Count
    [pscustomobject]@{ Sku = "Standard_$_"; Family = ("standard{0}Family" -f ($_ -replace '_','')); VmCount = (RInt 0 20); VmssCount = (RInt 4 40); AksCount = $cnt; Total = ($cnt + (RInt 4 40)); Zones = (Pick @('1,2,3','2,3','1,2')) }
}) (OutFileR 'used-skus')

# ----------------------------------------------------------------------------- flex servers
$flexTiers = @(
    @{ Tier = 'Burstable';      Sku = 'Standard_B2s' },
    @{ Tier = 'GeneralPurpose'; Sku = 'Standard_D4ads_v6' },
    @{ Tier = 'MemoryOptimized';Sku = 'Standard_E4ads_v6' }
)
$flex = @()
$flexN = 26
for ($i = 0; $i -lt $flexN; $i++) {
    $s = Pick $subs
    $t = Pick $flexTiers
    $eng = Pick @('postgres','mysql')
    $z = "$([int](RInt 1 3))"
    $hr = ($i -lt 12)   # first 12 are zone-redundant HA
    if ($hr) {
        $standby = "$([int](RInt 1 3))"; if ($standby -eq $z) { $standby = "$((([int]$z) % 3) + 1)" }
        $ha = 'ZoneRedundant'; $zr = 'True'
    } else {
        $standby = ''; $ha = (Pick @('Disabled','SameZone')); $zr = 'False'
    }
    $ver = if ($eng -eq 'postgres') { Pick @('15','16','17') } else { Pick @('8.0.37','8.4.0') }
    $flex += [pscustomobject]@{
        name = ("{0}-{1}-db-{2:D2}" -f $P.ToLower(), (Pick $workloads).ToLower(), (RInt 1 40))
        engine = $eng; subscriptionId = $s.SubId
        resourceGroup = ("rg-{0}-db-{1:D3}" -f $P.ToLower(), (RInt 1 200))
        location = $Location; sku = $t.Sku; tier = $t.Tier
        zone = $z; haMode = $ha; standbyZone = $standby; zoneRedundant = $zr; version = $ver
    }
}
Save $flex (OutFile 'flexserver-zones')

# ----------------------------------------------------------------------------- zonal resources
$ztypes = 'compute/disks','compute/virtualmachinescalesets','compute/virtualmachines'
$zonal = @()
for ($i = 0; $i -lt 34; $i++) {
    $s = Pick $subs
    $single = Chance 0.45
    if ($single) { $zones = "$([int](RInt 1 3))"; $zc = 1; $sz = 'True' }
    else { $perm = '1','2','3' | Sort-Object { $rng.Next() }; $zones = ($perm -join ','); $zc = 3; $sz = 'False' }
    $zonal += [pscustomobject]@{
        name = ("zonal-{0}-{1}-{2:D2}" -f $P.ToLower(), (Pick $workloads).ToLower(), (RInt 1 40))
        type = (Pick $ztypes); subscriptionId = $s.SubId
        resourceGroup = ("rg-{0}-{1:D3}" -f $P.ToLower(), (RInt 1 300))
        location = $Location; zones = $zones; zoneCount = $zc; SingleZone = $sz
    }
}
Save $zonal (OutFile 'zonal-resources')

# ----------------------------------------------------------------------------- resource inventory
$rtypes = 'storage/storageaccounts','compute/virtualmachines','compute/disks','network/networkinterfaces',
          'network/publicipaddresses','keyvault/vaults','managedidentity/userassignedidentities',
          'insights/components','insights/scheduledqueryrules','containerservice/managedclusters',
          'dbforpostgresql/flexibleservers','web/sites','network/loadbalancers','network/virtualnetworks'
$inv = @()
foreach ($s in ($subs | Sort-Object { $rng.Next() } | Select-Object -First 22)) {
    $n = RInt 3 6
    foreach ($t in ($rtypes | Sort-Object { $rng.Next() } | Select-Object -First $n)) {
        $cnt = RInt 1 90
        $zoned = 0; if ($t -match 'virtualmachines|disks|managedclusters') { $zoned = RInt 0 $cnt }
        $inv += [pscustomobject]@{ Type = $t; SubId = $s.SubId; SubName = $s.Name; Location = $Location; Count = $cnt; Zoned = $zoned }
    }
}
Save $inv (OutFile 'resource-inventory')

# ----------------------------------------------------------------------------- sku catalogue
$families = @(
    @{ F = 'standardBsv2Family';        S = 'B'; InUse = $true  },
    @{ F = 'standardBSFamily';          S = 'B'; InUse = $false },
    @{ F = 'standardDadsv6Family';      S = 'D'; InUse = $true  },
    @{ F = 'standardDadv6Family';       S = 'D'; InUse = $true  },
    @{ F = 'standardDasv6Family';       S = 'D'; InUse = $false },
    @{ F = 'standardDdsv6Family';       S = 'D'; InUse = $false },
    @{ F = 'standardDldsv6Family';      S = 'D'; InUse = $false },
    @{ F = 'standardDsv6Family';        S = 'D'; InUse = $false },
    @{ F = 'standardEadsv6Family';      S = 'E'; InUse = $true  },
    @{ F = 'standardEasv6Family';       S = 'E'; InUse = $false },
    @{ F = 'standardEdsv6Family';       S = 'E'; InUse = $false },
    @{ F = 'standardEsv6Family';        S = 'E'; InUse = $false },
    @{ F = 'standardFsv2Family';        S = 'F'; InUse = $true  },
    @{ F = 'standardFXFamily';          S = 'F'; InUse = $false },
    @{ F = 'standardLsv3Family';        S = 'L'; InUse = $false },
    @{ F = 'standardMsv3Family';        S = 'M'; InUse = $false },
    @{ F = 'standardMdsMediumMemoryv3Family'; S = 'M'; InUse = $false },
    @{ F = 'standardNCadsH100v5Family'; S = 'N'; InUse = $true  },
    @{ F = 'standardNDSH100v5Family';   S = 'N'; InUse = $false },
    @{ F = 'standardNVadsA10v5Family';  S = 'N'; InUse = $false }
)
$zoneStrs = '1,2,3','2,3','1,3','1,2'
$totalSubs = $subs.Count
$cat = foreach ($fam in $families) {
    $offered = RInt ($totalSubs - 6) $totalSubs
    $blocked = RInt 0 3
    $enabled = [math]::Max(0, $offered - $blocked)
    $skuCount = RInt 3 14
    # build a couple of zone-pattern buckets
    $zp = "$([string](Pick $zoneStrs)) [$([int](RInt 1 5))]; $([string](Pick $zoneStrs)) [$([int](RInt 1 3))]"
    switch ($fam.F) {
        'standardNCadsH100v5Family' { $limit = 100; $used = 92; $skuCount = 4 }   # GPU crunch
        'standardDadv6Family'       { $limit = 1316; $used = 1180 }               # ~90%
        'standardBsv2Family'        { $limit = 2110; $used = (RInt 1500 1880) }
        default {
            if ($fam.InUse) { $limit = RInt 600 2400; $used = RInt 80 ([int]($limit * 0.6)) }
            else            { $limit = RInt 600 2400; $used = 0 }
        }
    }
    $inUseStr = 'False'; $inst = 0
    if ($fam.InUse) { $inUseStr = 'True'; $inst = RInt 4 60 }
    [pscustomobject]@{
        Family = $fam.F; Series = $fam.S; OfferedSubs = $offered; EnabledSubs = $enabled; BlockedSubs = $blocked
        ZonePatterns = $zp; SkuCount = $skuCount; QuotaUsed = $used; QuotaLimit = $limit; QuotaAvail = ($limit - $used)
        InUse = $inUseStr; InstancesInUse = $inst
    }
}
Save $cat (OutFileR 'sku-catalogue')

# ----------------------------------------------------------------------------- region footprint + comparisons
$regions = @(
    @{ R = $Location;        Status = 'Current' },
    @{ R = $SecondaryRegion; Status = 'Current+Candidate' },
    @{ R = 'westeurope';     Status = 'Current+Candidate' },
    @{ R = 'northeurope';    Status = 'Current' },
    @{ R = 'uksouth';        Status = 'Candidate' },
    @{ R = 'germanywestcentral'; Status = 'Candidate' }
)
Save ($regions | ForEach-Object {
    $isPrimary = ($_.R -eq $Location)
    if ($isPrimary) { $res = RInt 6000 11000; $sc = $subs.Count; $ak = $aks.Count }
    else { $res = RInt 30 1800; $sc = RInt 4 40; $ak = RInt 0 6 }
    [pscustomobject]@{ Region = $_.R; Resources = $res; Subscriptions = $sc; AksClusters = $ak; Status = $_.Status }
}) (OutFile 'region-footprint')

$cmpRegions = $regions | ForEach-Object { $_.R }
$cmpSkus = 'Standard_B2s_v2','Standard_D2ads_v6','Standard_D4ads_v6','Standard_D8ads_v6','Standard_E4ads_v6','Standard_NC40ads_H100_v5'
Save $(foreach ($r in $cmpRegions) { foreach ($sk in $cmpSkus) {
    $off = $totalSubs
    $reg = RInt ($totalSubs - 5) $totalSubs
    $z3  = RInt 1 $totalSubs
    [pscustomobject]@{ Region = $r; Sku = $sk; Offered = $off; RegionalOf = ("{0}/{1}" -f $reg, $totalSubs); All3ZonesOf = ("{0}/{1}" -f $z3, $totalSubs) }
}}) (OutFile 'region-sku-comparison')

$cmpMetrics = @(
    @{ M = 'Spot vCPUs';            K = 'lowPriorityCores' },
    @{ M = 'Total Regional vCPUs'; K = 'cores' },
    @{ M = 'standardBsv2Family';   K = 'standardBsv2Family' },
    @{ M = 'standardDadv6Family';  K = 'standardDadv6Family' },
    @{ M = 'standardEadsv6Family'; K = 'standardEadsv6Family' },
    @{ M = 'standardNCadsH100v5Family'; K = 'standardNCadsH100v5Family' }
)
Save $(foreach ($r in $cmpRegions) { foreach ($mt in $cmpMetrics) {
    $isPrimary = ($r -eq $Location)
    $limit = RInt 1000 2500
    if ($isPrimary) { $used = RInt 80 ([int]($limit * 0.7)) } else { $used = 0 }
    [pscustomobject]@{ Region = $r; Metric = $mt.M; Key = $mt.K; Used = $used; Limit = $limit; Avail = ($limit - $used) }
}}) (OutFile 'region-quota-comparison')

# ----------------------------------------------------------------------------- summary
Write-Host ""
Write-Host "Synthetic demo dataset for '$Company' written to:" -ForegroundColor Cyan
Write-Host "  $OutDir" -ForegroundColor Cyan
$files = Get-ChildItem $OutDir -Filter *.csv | Sort-Object Name
Write-Host ("  {0} CSV files, {1} subscriptions ({2} focus)" -f $files.Count, $subs.Count, $focus.Count) -ForegroundColor DarkGray
Write-Host ""
Write-Host "Showcased states:" -ForegroundColor DarkGray
Write-Host "  - SKU block + zone gaps (sku-enablement / enablement-findings)"
Write-Host "  - near-cap quota: Dadv6 ~93%, Bsv2 ~96%, regional vCPU ~94%"
Write-Host "  - GPU crunch: NCadsH100v5 92/100"
Write-Host "  - AKS: 6 Failed, 3 Upgrading, 2 Canceled (of $($aks.Count))"
Write-Host "  - 12 zone-redundant HA flexible servers"
Write-Host "  - 1 pooled quota group, 1 not"
Write-Host ""
Write-Host "Render the dashboard offline (no Azure login needed):" -ForegroundColor Yellow
Write-Host ("  .\New-CapacityDashboard.ps1 -InputDir `"{0}`" -Location {1} -SecondaryRegion {2} -Title `"{3} - Azure Capacity & Enablement`"" -f $OutDir, $Location, $SecondaryRegion, $Company)
