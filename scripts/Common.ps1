<#
.SYNOPSIS
    Shared helpers for the Azure Capacity / Enablement toolkit scripts.
.DESCRIPTION
    Dot-source this file from the other scripts:  . "$PSScriptRoot\Common.ps1"
    Requires only the Azure CLI (`az`) logged in with at least Reader on the
    target subscriptions. No special extensions are required except
    `resource-graph` for the AKS inventory script (auto-installed there).
#>

# Resolve the directory this script lives in, robust to being run via
# `powershell.exe -File <script>` (where $PSScriptRoot can be empty during
# param-default evaluation). Always returns a usable path.
function Get-ScriptDir {
    param([string]$Fallback = (Join-Path $env:USERPROFILE 'capacity-toolkit'))
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) { return (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    return $Fallback
}

# Default output folder (../output relative to the scripts folder).
function Get-DefaultOutDir {
    $dir = Join-Path (Split-Path -Parent (Get-ScriptDir)) 'output'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

# Verify the Azure CLI is present and logged in. Returns the tenant id.
function Assert-AzLogin {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI ('az') not found on PATH. Install it first: https://aka.ms/azcli"
    }
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) {
        throw "Not logged in. Run 'az login' (add --tenant <id> for a specific tenant)."
    }
    Write-Host "Signed in as $($acct.user.name) | tenant $($acct.tenantId)" -ForegroundColor DarkGray
    return $acct.tenantId
}

# Resolve the list of subscriptions to operate on.
#  -SubscriptionIds : explicit array of ids (wins if provided)
#  -SubscriptionCsv : path to a CSV with a 'SubId' (or 'subscriptionId'/'id') column
#  (neither)        : every enabled subscription the signed-in identity can see
function Resolve-Subscriptions {
    param(
        [string[]]$SubscriptionIds,
        [string]  $SubscriptionCsv
    )
    if ($SubscriptionIds -and $SubscriptionIds.Count) {
        return $SubscriptionIds | ForEach-Object { [pscustomobject]@{ Name = $_; SubId = $_ } }
    }
    if ($SubscriptionCsv) {
        if (-not (Test-Path $SubscriptionCsv)) { throw "CSV not found: $SubscriptionCsv" }
        $rows = Import-Csv $SubscriptionCsv
        return $rows | ForEach-Object {
            $id = $_.SubId; if (-not $id) { $id = $_.subscriptionId }; if (-not $id) { $id = $_.id }
            $nm = $_.Name; if (-not $nm) { $nm = $id }
            [pscustomobject]@{ Name = $nm; SubId = $id }
        } | Where-Object { $_.SubId }
    }
    Write-Host "No subscription list given - enumerating all visible enabled subscriptions..." -ForegroundColor DarkGray
    return az account list --query "[?state=='Enabled'].{Name:name,SubId:id}" -o json 2>$null | ConvertFrom-Json
}

# One REST call returns every compute SKU for a subscription+region.
function Get-ComputeSkus {
    param([Parameter(Mandatory)][string]$SubId, [Parameter(Mandatory)][string]$Location)
    $url = "https://management.azure.com/subscriptions/$SubId/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=location eq '$Location'"
    $j = az rest --method get --url $url -o json 2>$null | ConvertFrom-Json
    return $j.value
}

# Parse one SKU object into a regional/zonal status record.
#   Regional = 'BLOCKED' if a Location restriction exists, else 'Enabled'.
#   Zones    = the logical zones that are offered AND not zone-restricted.
function Resolve-SkuStatus {
    param($Sku)
    if (-not $Sku) { return [pscustomobject]@{ Regional = 'NotOffered'; Zones = '-' } }
    $locBlocked = $false; $blockedZones = @()
    foreach ($r in $Sku.restrictions) {
        if ($r.type -eq 'Location') { $locBlocked = $true }
        if ($r.type -eq 'Zone')     { $blockedZones += @($r.restrictionInfo.zones) }
    }
    $offered = @($Sku.locationInfo[0].zones)
    if ($locBlocked) { return [pscustomobject]@{ Regional = 'BLOCKED'; Zones = '-' } }
    $open = $offered | Where-Object { $blockedZones -notcontains $_ } | Sort-Object
    $zoneStr = if ($open) { ($open -join ',') } else { 'none' }
    return [pscustomobject]@{ Regional = 'Enabled'; Zones = $zoneStr }
}
