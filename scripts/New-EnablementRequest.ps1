<#
.SYNOPSIS
    Generate correctly-worded Azure support ticket text to request Regional Enablement and/or Zonal
    Enablement (AZ01 / AZ02 / AZ03) for specific VM SKUs across one or more subscriptions.

.DESCRIPTION
    Inspects the CURRENT enablement state per subscription (regional block + blocked availability
    zones) and produces a ready-to-paste support request that asks ONLY for what is actually missing,
    expressed in the PHYSICAL availability-zone labels Azure support uses (AZ01/AZ02/AZ03) rather than
    logical zone numbers (which differ per subscription).

    Produces:
      * enablement-request-<region>-<date>.md   (paste into the support ticket / e-mail)
      * enablement-findings-<region>-<date>.csv  (the per-sub/per-SKU gap analysis behind it)

    Access required: Reader. (Filing the ticket is a manual step; this only drafts it.)

.PARAMETER Location
    Region the enablement is requested in (e.g. norwayeast, swedencentral).

.PARAMETER Skus
    SKUs to request enablement for.

.PARAMETER TargetZones
    Physical zones to open, as AZ labels (default AZ01,AZ02,AZ03).

.PARAMETER IncludeAlreadyEnabled
    Also list subscriptions/SKUs that are already fully enabled (default: only request what's missing).

.PARAMETER SubscriptionIds / SubscriptionCsv / OutDir
    See the other scripts.

.EXAMPLE
    .\New-EnablementRequest.ps1 -Location norwayeast -Skus Standard_B2s_v2,Standard_D2ads_v6 -SubscriptionCsv .\mysubs.csv
#>
[CmdletBinding()]
param(
    [string]   $Location = 'norwayeast',
    [string[]] $Skus = @('Standard_B2s_v2','Standard_D2ads_v6'),
    [string[]] $TargetZones = @('AZ01','AZ02','AZ03'),
    [switch]   $IncludeAlreadyEnabled,
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [string]   $OutDir
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null
if (-not $OutDir) { $OutDir = Get-DefaultOutDir }
$date = Get-Date -Format 'yyyyMMdd'

function ConvertTo-AzLabel([string]$physicalZone) {
    # 'norwayeast-az3' -> 'AZ03'
    if ($physicalZone -match '-az(\d+)$') { return ('AZ{0:D2}' -f [int]$matches[1]) }
    return $physicalZone
}

$subs = Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv
Write-Host "Analysing enablement gaps for $($subs.Count) subscription(s) in $Location..." -ForegroundColor Cyan

$findings = @()
foreach ($s in $subs) {
    # Per-sub logical->physical map
    $url = "https://management.azure.com/subscriptions/$($s.SubId)/locations?api-version=2022-12-01"
    $loc = az rest --method get --url $url -o json 2>$null | ConvertFrom-Json
    $map = ($loc.value | Where-Object { $_.name -eq $Location }).availabilityZoneMappings
    $log2phys = @{}; foreach ($m in $map) { $log2phys[$m.logicalZone] = (ConvertTo-AzLabel $m.physicalZone) }

    $all = Get-ComputeSkus -SubId $s.SubId -Location $Location
    foreach ($skuName in $Skus) {
        $sku = $all | Where-Object { $_.name -eq $skuName } | Select-Object -First 1
        if (-not $sku) {
            $findings += [pscustomobject]@{ Name=$s.Name; SubId=$s.SubId; Sku=$skuName; RegionalNeeded='SKU not offered'; ZonesOpen='-'; ZonesNeeded='-' }
            continue
        }
        $st = Resolve-SkuStatus -Sku $sku
        $regionalNeeded = ($st.Regional -ne 'Enabled')

        # Translate currently-open logical zones to physical AZ labels
        $openPhys = @()
        if ($st.Zones -and $st.Zones -notin @('-','none')) {
            $openPhys = $st.Zones.Split(',') | ForEach-Object { if ($log2phys.ContainsKey($_)) { $log2phys[$_] } } | Where-Object { $_ } | Sort-Object
        }
        $zonesNeeded = @($TargetZones | Where-Object { $openPhys -notcontains $_ }) | Sort-Object

        $findings += [pscustomobject]@{
            Name           = $s.Name
            SubId          = $s.SubId
            Sku            = $skuName
            RegionalNeeded = if ($regionalNeeded) { 'YES' } else { 'no' }
            ZonesOpen      = if ($openPhys) { ($openPhys -join ',') } else { 'none' }
            ZonesNeeded    = if ($regionalNeeded) { ($TargetZones -join ',') } elseif ($zonesNeeded) { ($zonesNeeded -join ',') } else { 'none' }
        }
    }
}

$findCsv = Join-Path $OutDir "enablement-findings-$Location-$date.csv"
$findings | Export-Csv $findCsv -NoTypeInformation -Encoding UTF8

# Subs/SKUs that actually need something
$gaps = $findings | Where-Object { $_.RegionalNeeded -eq 'YES' -or ($_.ZonesNeeded -ne 'none' -and $_.ZonesNeeded -ne '-') }

# ---- Build the support-ticket draft ---------------------------------------------------------------
$md = @()
$md += "# Azure Support Request - Regional & Zonal Enablement"
$md += ""
$md += "| Field | Value |"
$md += "|---|---|"
$md += "| Region | **$Location** |"
$md += "| SKUs requested | $($Skus -join ', ') |"
$md += "| Availability zones requested | $($TargetZones -join ', ') |"
$md += "| Subscriptions in scope | $($subs.Count) |"
$md += "| Generated | $(Get-Date -Format 'yyyy-MM-dd HH:mm') |"
$md += ""

if (-not $gaps) {
    $md += "> All requested SKUs are already regionally and zonally enabled in **$Location** for every subscription in scope. No support request required."
} else {
    $md += "## Request summary"
    $md += ""
    $md += "We request **Regional Enablement** and **Zonal Enablement** for the VM SKUs below in **$Location**, for the listed subscriptions and physical availability zones ($($TargetZones -join ', ')). Quota alone is not sufficient — please ensure the SKUs are unblocked at both the regional and the zonal level so capacity can be deployed."
    $md += ""
    $md += "### Per-subscription requirements"
    $md += ""
    $md += "| Subscription | Subscription ID | SKU | Regional enablement needed | Zonal enablement needed |"
    $md += "|---|---|---|---|---|"
    foreach ($g in $gaps) {
        $md += "| $($g.Name) | $($g.SubId) | $($g.Sku) | $($g.RegionalNeeded) | $($g.ZonesNeeded) |"
    }
    $md += ""
    $md += "### Suggested ticket text (copy/paste)"
    $md += ""
    $md += '```text'
    $md += "Subject: Regional and Zonal Enablement request - $Location"
    $md += ""
    $md += "Hello,"
    $md += ""
    $md += "We are requesting capacity enablement in the $Location region. For the subscriptions and"
    $md += "VM SKUs listed below, please enable the SKUs regionally and in availability zones $($TargetZones -join ', ')."
    $md += "We understand assigned quota does not guarantee capacity; the goal of this request is to"
    $md += "remove the regional/zonal restrictions so the capacity can be deployed."
    $md += ""
    $bySub = $gaps | Group-Object SubId
    foreach ($grp in $bySub) {
        $nm = ($grp.Group | Select-Object -First 1).Name
        $md += "Subscription: $nm ($($grp.Name))"
        foreach ($g in $grp.Group) {
            $parts = @()
            if ($g.RegionalNeeded -eq 'YES') { $parts += 'Regional enablement' }
            if ($g.ZonesNeeded -ne 'none' -and $g.ZonesNeeded -ne '-') { $parts += "Zonal enablement ($($g.ZonesNeeded))" }
            $md += "  - $($g.Sku): $($parts -join ' + ')"
        }
        $md += ""
    }
    $md += "Region: $Location"
    $md += "Thank you."
    $md += '```'
}

if ($IncludeAlreadyEnabled) {
    $ok = $findings | Where-Object { $_.RegionalNeeded -eq 'no' -and ($_.ZonesNeeded -eq 'none') }
    if ($ok) {
        $md += ""
        $md += "## Already enabled (no action needed)"
        $md += ""
        $md += "| Subscription | SKU | Zones open |"
        $md += "|---|---|---|"
        foreach ($o in $ok) { $md += "| $($o.Name) | $($o.Sku) | $($o.ZonesOpen) |" }
    }
}

$reqMd = Join-Path $OutDir "enablement-request-$Location-$date.md"
$md -join "`n" | Set-Content $reqMd -Encoding UTF8

Write-Host "`nFindings  -> $findCsv" -ForegroundColor Green
Write-Host "Request   -> $reqMd"  -ForegroundColor Green
Write-Host ("`nSubscriptions needing enablement: {0} of {1} (SKU rows with a gap: {2})" -f (($gaps.SubId | Select-Object -Unique).Count), $subs.Count, $gaps.Count)
