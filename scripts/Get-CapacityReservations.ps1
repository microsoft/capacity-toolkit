<#
.SYNOPSIS
    Inventory Azure on-demand Capacity Reservations (the "guaranteed capacity" construct) across
    subscriptions, with reserved-vs-consumed utilisation, exported to CSV.

.DESCRIPTION
    On-demand capacity reservation is the construct that actually *guarantees* compute capacity for a
    VM size in a region/zone - as distinct from quota, which only grants permission to deploy
    (see docs/concepts.md, "quota is NOT capacity"). This script enumerates every
    `Microsoft.Compute/capacityReservationGroups` and its child `capacityReservations` the signed-in
    identity can see, and reports - per reservation - the SKU, region, zone, reserved instance count,
    the capacity actually reserved/billed at runtime, how many instances are consuming it, and
    over/under-allocation flags.

    READ-ONLY: it issues only ARM GET calls (`az rest --method get`). It creates, modifies or deletes
    nothing.

    Access required: Reader on the target subscription(s). Shared groups owned by another scope may
    surface but fail the detail read - those are recorded as ErrorCode/ErrorMessage rows rather than
    escalating privileges.

    NOTE: Capacity Reservation is NOT the same as a Reserved Instance. Reserved Instances are a billing
    discount and carry no capacity guarantee; only capacity reservations hold capacity.

.PARAMETER Location
    Optional region filter (e.g. 'norwayeast'). Omit to inventory all regions.

.PARAMETER SubscriptionIds
    Optional explicit subscription id(s). Omit to scan every visible subscription.

.PARAMETER SubscriptionCsv
    Optional CSV with a SubId column. Omit both to scan all visible subscriptions.

.PARAMETER OutPath
    CSV output path (default ..\output\capacity-reservations-<date>.csv).

.EXAMPLE
    .\Get-CapacityReservations.ps1

.EXAMPLE
    .\Get-CapacityReservations.ps1 -Location norwayeast -SubscriptionCsv .\mysubs.csv
#>
[CmdletBinding()]
param(
    [string]   $Location,
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null

$apiVersion = '2024-07-01'

if (-not $OutPath) {
    $OutPath = Join-Path (Get-DefaultOutDir) ("capacity-reservations-{0}.csv" -f (Get-Date -Format 'yyyyMMdd'))
}

$subs = Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv
Write-Host ("Inventorying capacity reservations across {0} subscription(s){1}..." -f `
    $subs.Count, $(if ($Location) { " in $Location" } else { '' })) -ForegroundColor Cyan

# Parse the resource group out of an ARM resource id.
function Get-RgFromId {
    param([string]$Id)
    if ($Id -match '/resourceGroups/([^/]+)/') { return $matches[1] }
    return ''
}

# GET an ARM url, returning the parsed object or $null. Sets script-scope $LastRestError on failure.
function Invoke-ArmGet {
    param([string]$Url)
    $script:LastRestError = $null
    $out = az rest --method get --url $Url -o json 2>&1
    if ($LASTEXITCODE -eq 0) {
        try { return ($out | Out-String | ConvertFrom-Json) } catch { return $null }
    }
    $script:LastRestError = ($out | Out-String).Trim()
    return $null
}

$rows = @()
$authWarned = $false

foreach ($s in $subs) {
    az account set --subscription $s.SubId 2>$null

    $grpUrl = "https://management.azure.com/subscriptions/$($s.SubId)/providers/Microsoft.Compute/capacityReservationGroups?api-version=$apiVersion"
    $grpResp = Invoke-ArmGet -Url $grpUrl
    if (-not $grpResp) {
        if ($LastRestError -match 'Authorization|does not have|Forbidden|403') {
            if (-not $authWarned) {
                Write-Warning "Access denied reading capacity reservation groups in sub $($s.SubId). Reader is required on the owning scope."
                $authWarned = $true
            }
        } elseif ($LastRestError) {
            Write-Warning "Failed to list capacity reservation groups in sub $($s.SubId): $LastRestError"
        }
        continue
    }

    $groups = @($grpResp.value)
    if ($Location) {
        $groups = @($groups | Where-Object { $_.location -and ($_.location -ieq $Location) })
    }

    foreach ($g in $groups) {
        $grpRg     = Get-RgFromId $g.id
        $grpZones  = if ($g.zones) { (@($g.zones) -join ',') } else { '' }

        $resUrl = "https://management.azure.com$($g.id)/capacityReservations?api-version=$apiVersion&`$expand=instanceView"
        $resResp = Invoke-ArmGet -Url $resUrl
        if (-not $resResp) {
            $rows += [pscustomobject][ordered]@{
                Subscription            = $s.Name
                SubscriptionId          = $s.SubId
                ResourceGroup           = $grpRg
                GroupName               = $g.name
                GroupId                 = $g.id
                ReservationName         = ''
                ReservationId           = ''
                Region                  = $g.location
                GroupZones              = $grpZones
                Zone                    = ''
                Sku                     = ''
                ReservedInstances       = ''
                CurrentReservedCapacity = ''
                ConsumedInstances       = ''
                AssociatedVMs           = ''
                UnusedInstances         = ''
                UtilizationPct          = ''
                ProvisioningState       = ''
                TimeCreated             = ''
                IsEmptyGroup            = ''
                IsIdle                  = ''
                OverAllocated           = ''
                AtCapacity              = ''
                ErrorCode               = 'DetailReadFailed'
                ErrorMessage            = $LastRestError
            }
            continue
        }

        $reservations = @($resResp.value)
        if ($reservations.Count -eq 0) {
            $rows += [pscustomobject][ordered]@{
                Subscription            = $s.Name
                SubscriptionId          = $s.SubId
                ResourceGroup           = $grpRg
                GroupName               = $g.name
                GroupId                 = $g.id
                ReservationName         = ''
                ReservationId           = ''
                Region                  = $g.location
                GroupZones              = $grpZones
                Zone                    = ''
                Sku                     = ''
                ReservedInstances       = 0
                CurrentReservedCapacity = 0
                ConsumedInstances       = 0
                AssociatedVMs           = 0
                UnusedInstances         = 0
                UtilizationPct          = ''
                ProvisioningState       = ''
                TimeCreated             = ''
                IsEmptyGroup            = $true
                IsIdle                  = $false
                OverAllocated           = $false
                AtCapacity              = $false
                ErrorCode               = ''
                ErrorMessage            = ''
            }
            continue
        }

        foreach ($r in $reservations) {
            $p = $r.properties
            $iv = $null
            if ($p) { $iv = $p.instanceView }

            $reserved = 0
            if ($r.sku -and $r.sku.capacity) { $reserved = [int]$r.sku.capacity }

            $currentReserved = 0
            $haveCurrent = $false
            if ($iv -and $iv.utilizationInfo -and ($null -ne $iv.utilizationInfo.currentCapacity)) {
                $currentReserved = [int]$iv.utilizationInfo.currentCapacity
                $haveCurrent = $true
            }

            $consumed = 0
            if ($iv -and $iv.utilizationInfo -and $iv.utilizationInfo.virtualMachinesAllocated) {
                $consumed = @($iv.utilizationInfo.virtualMachinesAllocated).Count
            }

            $associated = 0
            if ($p -and $p.virtualMachinesAssociated) {
                $associated = @($p.virtualMachinesAssociated).Count
            }

            # Effective reserved capacity = runtime value when present, else the requested ask.
            $effReserved = if ($haveCurrent) { $currentReserved } else { $reserved }
            $unused = $effReserved - $consumed
            if ($unused -lt 0) { $unused = 0 }

            $utilPct = ''
            if ($effReserved -gt 0) {
                $utilPct = [math]::Round(($consumed / $effReserved) * 100, 1)
            }

            $isIdle      = ($effReserved -gt 0 -and $consumed -eq 0)
            $overAlloc   = ($effReserved -gt 0 -and $consumed -lt $effReserved)
            $atCapacity  = ($effReserved -gt 0 -and $consumed -ge $effReserved)

            $zone = if ($r.zones) { (@($r.zones) -join ',') } else { '' }
            $sku  = if ($r.sku) { $r.sku.name } else { '' }

            $provState = ''
            $timeCreated = ''
            if ($p) {
                if ($p.provisioningState) { $provState = $p.provisioningState }
                if ($p.timeCreated) { $timeCreated = $p.timeCreated }
            }

            $rows += [pscustomobject][ordered]@{
                Subscription            = $s.Name
                SubscriptionId          = $s.SubId
                ResourceGroup           = $grpRg
                GroupName               = $g.name
                GroupId                 = $g.id
                ReservationName         = $r.name
                ReservationId           = $r.id
                Region                  = $r.location
                GroupZones              = $grpZones
                Zone                    = $zone
                Sku                     = $sku
                ReservedInstances       = $reserved
                CurrentReservedCapacity = $effReserved
                ConsumedInstances       = $consumed
                AssociatedVMs           = $associated
                UnusedInstances         = $unused
                UtilizationPct          = $utilPct
                ProvisioningState       = $provState
                TimeCreated             = $timeCreated
                IsEmptyGroup            = $false
                IsIdle                  = $isIdle
                OverAllocated           = $overAlloc
                AtCapacity              = $atCapacity
                ErrorCode               = ''
                ErrorMessage            = ''
            }
        }
    }
}

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "`nNo capacity reservation groups found in the scanned subscription(s)." -ForegroundColor Yellow
    Write-Host "Remember: capacity reservations are the only construct that guarantees capacity - quota does not." -ForegroundColor DarkYellow
    return
}

$rows | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($rows.Count) row(s) -> $OutPath" -ForegroundColor Green

# Summaries (exclude empty-group / error placeholder rows from utilisation maths).
$real = @($rows | Where-Object { $_.IsEmptyGroup -eq $false -and -not $_.ErrorCode })
$emptyGroups = @($rows | Where-Object { $_.IsEmptyGroup -eq $true }).Count
$errorRows   = @($rows | Where-Object { $_.ErrorCode }).Count

Write-Host ("`nReservations: {0}   Empty groups: {1}   Unreadable groups: {2}" -f $real.Count, $emptyGroups, $errorRows)

if ($real.Count) {
    $totReserved = ($real | Measure-Object CurrentReservedCapacity -Sum).Sum
    $totConsumed = ($real | Measure-Object ConsumedInstances -Sum).Sum
    $totUnused   = ($real | Measure-Object UnusedInstances -Sum).Sum
    $idle        = @($real | Where-Object { $_.IsIdle -eq $true }).Count
    Write-Host ("  Reserved (current): {0}   Consumed: {1}   Unused: {2}   Idle reservations: {3}" -f `
        $totReserved, $totConsumed, $totUnused, $idle)

    Write-Host "`nBy region:"
    $real | Group-Object Region | Sort-Object Count -Descending | ForEach-Object { "  {0,-18} {1}" -f $_.Name, $_.Count }

    Write-Host "`nBy SKU:"
    $real | Group-Object Sku | Sort-Object Count -Descending | ForEach-Object { "  {0,-22} {1}" -f $_.Name, $_.Count }

    if ($idle -gt 0) {
        Write-Host "`nIdle (paid-for, no VMs consuming) - reserved capacity sitting unused:" -ForegroundColor DarkYellow
        $real | Where-Object { $_.IsIdle -eq $true } | ForEach-Object {
            "  {0,-24} {1,-16} {2} reserved in {3} {4}" -f $_.GroupName, $_.Sku, $_.CurrentReservedCapacity, $_.Region, $_.Zone
        }
    }
}
