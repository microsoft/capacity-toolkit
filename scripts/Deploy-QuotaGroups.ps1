#Requires -Version 7.0
<#
.SYNOPSIS
    Generic, config-driven rollout engine for Azure Quota Groups (Microsoft.Quota/groupQuotas).

.DESCRIPTION
    Reads a JSON design file and idempotently provisions Azure Quota Groups:
      1. (optional) Registers Microsoft.Quota + Microsoft.Compute on each member subscription.
      2. Creates each quota group at its Management Group scope.
      3. Adds member subscriptions to the group.
      4. Submits group-level quota limit requests per (location, VM family).
      5. Allocates quota from the group down to individual subscriptions.

    The script is intentionally generic: it has no customer-specific logic. Point it at any
    design file to roll out any quota-group topology. Use -WhatIf for a dry run, and -Action
    to run a single phase. Every phase is idempotent (it checks for existing objects first).

    Generate a design file from your own analysis with New-QuotaGroupConfig.ps1, or start from
    ../examples/quota-groups.sample.json.

    Uses the Azure Quota Group REST API (default api-version 2025-09-01). Auth is taken from
    the current 'az login' context via 'az account get-access-token' (ARM audience).

    NOTE: group-level pooled limit requests (SetGroupLimits) may require platform approval and
    can return an 'Escalated' async state (a support ticket is opened automatically); the other
    phases (create group, add members, allocate) complete inline.

.PARAMETER ConfigPath
    Path to the JSON design file. See ../examples/quota-groups.sample.json for the schema.

.PARAMETER Action
    Which phase(s) to run: All (default), Validate, RegisterProviders, CreateGroups,
    AddSubscriptions, SetGroupLimits, Allocate.

.PARAMETER WhatIf
    Dry run. Prints every change it WOULD make without calling the write APIs.

.PARAMETER ApiVersion
    Override the Quota API version (default from config, else 2025-09-01).

.EXAMPLE
    ./Deploy-QuotaGroups.ps1 -ConfigPath ../examples/quota-groups.sample.json -Action Validate

.EXAMPLE
    ./Deploy-QuotaGroups.ps1 -ConfigPath ./my-design.json -WhatIf

.EXAMPLE
    ./Deploy-QuotaGroups.ps1 -ConfigPath ./my-design.json -Action CreateGroups
.NOTES
    Required permissions (per scope):
      - Register providers ...... Contributor on each member subscription
      - Create/delete groups .... GroupQuota Request Operator on the anchor Management Group
      - Allocate quota .......... Quota Request Operator on each member subscription
    Billing access is only needed to request NEW quota beyond the pooled total.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [ValidateSet('All', 'Validate', 'RegisterProviders', 'CreateGroups', 'AddSubscriptions', 'SetGroupLimits', 'Allocate')]
    [string]$Action = 'All',

    [string]$ApiVersion
)

$ErrorActionPreference = 'Stop'
$script:Arm = 'https://management.azure.com'
$script:Summary = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$Msg) Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
function Write-Info { param([string]$Msg) Write-Host "    $Msg" }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK]   $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "    [SKIP] $Msg" -ForegroundColor DarkGray }
function Write-Plan { param([string]$Msg) Write-Host "    [PLAN] $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "    [FAIL] $Msg" -ForegroundColor Red }

function Add-Result {
    param([string]$Phase, [string]$Target, [string]$Status, [string]$Detail = '')
    $script:Summary.Add([pscustomobject]@{ Phase = $Phase; Target = $Target; Status = $Status; Detail = $Detail })
}

function Get-ArmToken {
    $t = az account get-access-token --resource $script:Arm -o json 2>$null | ConvertFrom-Json
    if (-not $t.accessToken) { throw "Could not obtain ARM access token. Run 'az login' first." }
    return $t.accessToken
}

# Core REST wrapper. Handles 200/201/202 and polls Azure-AsyncOperation to a terminal state.
function Invoke-Arm {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,        # path after https://management.azure.com
        [object]$Body,
        [switch]$AllowNotFound
    )
    $url = "$script:Arm$Path"
    if ($url -notmatch 'api-version=') {
        $sep = if ($url -match '\?') { '&' } else { '?' }
        $url = "${url}${sep}api-version=$script:ApiVersionEffective"
    }
    $headers = @{ Authorization = "Bearer $(Get-ArmToken)"; 'Content-Type' = 'application/json' }
    $jsonBody = $null
    if ($null -ne $Body) { $jsonBody = ($Body | ConvertTo-Json -Depth 12 -Compress) }

    $resp = Invoke-WebRequest -Method $Method -Uri $url -Headers $headers -Body $jsonBody `
        -SkipHttpErrorCheck -MaximumRedirection 0

    $code = [int]$resp.StatusCode
    if ($code -eq 404 -and $AllowNotFound) { return $null }
    if ($code -ge 400) {
        throw "HTTP $code on $Method $Path :: $($resp.Content)"
    }

    # Async polling
    if ($code -eq 202 -or $resp.Headers['Azure-AsyncOperation']) {
        $opUrl = $resp.Headers['Azure-AsyncOperation']
        if (-not $opUrl) { $opUrl = $resp.Headers['Location'] }
        if ($opUrl) { return (Wait-AsyncOperation -OperationUrl ([string]$opUrl)) }
    }
    if ($resp.Content) { try { return ($resp.Content | ConvertFrom-Json) } catch { return $resp.Content } }
    return $null
}

function Wait-AsyncOperation {
    param([Parameter(Mandatory)][string]$OperationUrl, [int]$TimeoutSec = 600)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $headers = @{ Authorization = "Bearer $(Get-ArmToken)" }
        $r = Invoke-WebRequest -Method GET -Uri $OperationUrl -Headers $headers -SkipHttpErrorCheck
        $obj = $null; try { $obj = $r.Content | ConvertFrom-Json } catch {}
        $state = $obj.status; if (-not $state) { $state = $obj.provisioningState }
        switch ($state) {
            'Succeeded' { return $obj }
            'Failed'    { throw "Async operation Failed: $($r.Content)" }
            'Canceled'  { throw "Async operation Canceled: $($r.Content)" }
            'Invalid'   { throw "Async operation Invalid: $($r.Content)" }
            'Escalated' { throw "Async operation Escalated (support ticket required): $($r.Content)" }
            default     { Write-Info "  ... async state: $state" }
        }
    }
    throw "Async operation timed out after ${TimeoutSec}s: $OperationUrl"
}

# ---------------------------------------------------------------------------
# Subscription name -> id resolution
# ---------------------------------------------------------------------------
function Get-SubscriptionMap {
    Write-Info "Loading subscription list (id + name)..."
    $subs = az account list --all -o json 2>$null | ConvertFrom-Json
    $byId = @{}; $byName = @{}
    foreach ($s in $subs) {
        $byId[$s.id.ToLower()] = $s
        if (-not $byName.ContainsKey($s.name)) { $byName[$s.name] = $s }
    }
    return @{ ById = $byId; ByName = $byName }
}

function Resolve-Subscription {
    param([string]$Ref, [hashtable]$Map)
    if ([string]::IsNullOrWhiteSpace($Ref)) { return $null }
    $low = $Ref.ToLower()
    if ($Map.ById.ContainsKey($low))  { return $Map.ById[$low].id }
    if ($Map.ByName.ContainsKey($Ref)) { return $Map.ByName[$Ref].id }
    # GUID that just isn't visible to this account - pass through but warn
    if ($Ref -match '^[0-9a-fA-F-]{36}$') { return $Ref }
    throw "Could not resolve subscription '$Ref' (not found by id or name in current context)."
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
function Test-Config {
    param([object]$Cfg, [hashtable]$Map)
    Write-Step "Validate configuration"
    $ok = $true
    if (-not $Cfg.groups -or $Cfg.groups.Count -eq 0) { Write-Err "No groups defined."; return $false }
    $names = @{}
    foreach ($g in $Cfg.groups) {
        $ctx = "group '$($g.name)'"
        if ($g.name -notmatch '^[a-z][a-z0-9]{2,62}$') {
            Write-Err "$ctx : name must match ^[a-z][a-z0-9]{2,62}$ (lowercase, no hyphens/underscores, 3-63 chars)."; $ok = $false
        }
        if ($names.ContainsKey($g.name)) { Write-Err "$ctx : duplicate group name."; $ok = $false }
        $names[$g.name] = $true
        if (-not $g.managementGroupId) { Write-Err "$ctx : managementGroupId is required."; $ok = $false }
        if (-not $g.members -or $g.members.Count -eq 0) { Write-Err "$ctx : at least one member required."; $ok = $false }
        foreach ($m in ($g.members | Select-Object -Unique)) {
            try { [void](Resolve-Subscription -Ref $m -Map $Map) }
            catch { Write-Err "$ctx : $($_.Exception.Message)"; $ok = $false }
        }
        foreach ($gl in @($g.groupLimits)) {
            if (-not $gl.location -or -not $gl.resourceName -or $null -eq $gl.limit) {
                Write-Err "$ctx : each groupLimit needs location, resourceName, limit."; $ok = $false
            }
        }
        foreach ($al in @($g.allocations)) {
            if (-not $al.location -or -not $al.resourceName -or $null -eq $al.limit -or -not $al.subscription) {
                Write-Err "$ctx : each allocation needs subscription, location, resourceName, limit."; $ok = $false
            }
        }
    }
    if ($ok) { Write-Ok "Configuration is valid ($($Cfg.groups.Count) groups)." }
    return $ok
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
function Invoke-RegisterProviders {
    param([object]$Cfg, [hashtable]$Map)
    Write-Step "Register resource providers (Microsoft.Quota, Microsoft.Compute)"
    $subIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($g in $Cfg.groups) {
        if ($g.PSObject.Properties.Name -contains 'registerProviders' -and -not $g.registerProviders) { continue }
        foreach ($m in $g.members) { [void]$subIds.Add((Resolve-Subscription -Ref $m -Map $Map)) }
    }
    foreach ($sid in $subIds) {
        foreach ($rp in @('Microsoft.Quota', 'Microsoft.Compute')) {
            $state = az provider show -n $rp --subscription $sid --query registrationState -o tsv 2>$null
            if ($state -eq 'Registered') { Write-Skip "$rp already registered on $sid"; continue }
            if ($PSCmdlet.ShouldProcess("$sid", "Register $rp")) {
                az provider register -n $rp --subscription $sid --only-show-errors 2>$null | Out-Null
                Write-Ok "Registering $rp on $sid (async; may take a few minutes)"
                Add-Result 'RegisterProviders' "$sid/$rp" 'Submitted'
            } else { Write-Plan "Register $rp on $sid"; Add-Result 'RegisterProviders' "$sid/$rp" 'WouldRegister' }
        }
    }
}

function Invoke-CreateGroups {
    param([object]$Cfg)
    Write-Step "Create quota groups"
    foreach ($g in $Cfg.groups) {
        $mg = $g.managementGroupId
        $path = "/providers/Microsoft.Management/managementGroups/$mg/providers/Microsoft.Quota/groupQuotas/$($g.name)"
        $existing = Invoke-Arm -Method GET -Path $path -AllowNotFound
        if ($existing) { Write-Skip "Group '$($g.name)' already exists under MG '$mg'"; Add-Result 'CreateGroups' $g.name 'Exists'; continue }
        $body = @{ properties = @{ displayName = $(if ($g.displayName) { $g.displayName } else { $g.name }) } }
        if ($PSCmdlet.ShouldProcess($g.name, "Create quota group under MG '$mg'")) {
            [void](Invoke-Arm -Method PUT -Path $path -Body $body)
            Write-Ok "Created group '$($g.name)' (display '$($g.displayName)') under MG '$mg'"
            Add-Result 'CreateGroups' $g.name 'Created'
        } else { Write-Plan "Create group '$($g.name)' under MG '$mg'"; Add-Result 'CreateGroups' $g.name 'WouldCreate' }
    }
}

function Invoke-AddSubscriptions {
    param([object]$Cfg, [hashtable]$Map)
    Write-Step "Add member subscriptions to groups"
    foreach ($g in $Cfg.groups) {
        $mg = $g.managementGroupId
        foreach ($m in ($g.members | Select-Object -Unique)) {
            $sid = Resolve-Subscription -Ref $m -Map $Map
            $path = "/providers/Microsoft.Management/managementGroups/$mg/providers/Microsoft.Quota/groupQuotas/$($g.name)/subscriptions/$sid"
            $existing = Invoke-Arm -Method GET -Path $path -AllowNotFound
            if ($existing) { Write-Skip "Sub $sid already in '$($g.name)'"; Add-Result 'AddSubscriptions' "$($g.name)/$sid" 'Exists'; continue }
            if ($PSCmdlet.ShouldProcess($sid, "Add to group '$($g.name)'")) {
                [void](Invoke-Arm -Method PUT -Path $path)
                Write-Ok "Added $sid to '$($g.name)'"
                Add-Result 'AddSubscriptions' "$($g.name)/$sid" 'Added'
            } else { Write-Plan "Add $sid to '$($g.name)'"; Add-Result 'AddSubscriptions' "$($g.name)/$sid" 'WouldAdd' }
        }
    }
}

function Invoke-SetGroupLimits {
    param([object]$Cfg)
    Write-Step "Submit group quota limit requests"
    $rp = $(if ($Cfg.resourceProvider) { $Cfg.resourceProvider } else { 'Microsoft.Compute' })
    foreach ($g in $Cfg.groups) {
        if (-not $g.groupLimits) { continue }
        $mg = $g.managementGroupId
        # group by location: one PATCH per location can carry multiple families
        $byLoc = $g.groupLimits | Group-Object location
        foreach ($loc in $byLoc) {
            $values = @()
            foreach ($gl in $loc.Group) {
                $values += @{ properties = @{ comment = $(if ($gl.comment) { $gl.comment } else { "Set by Deploy-QuotaGroups" }); limit = [int]$gl.limit; resourceName = $gl.resourceName } }
            }
            $path = "/providers/Microsoft.Management/managementGroups/$mg/providers/Microsoft.Quota/groupQuotas/$($g.name)/resourceProviders/$rp/groupQuotaLimits/$($loc.Name)"
            $body = @{ properties = @{ value = $values } }
            $desc = "$($g.name)/$($loc.Name): " + (($loc.Group | ForEach-Object { "$($_.resourceName)=$($_.limit)" }) -join ', ')
            if ($PSCmdlet.ShouldProcess($desc, "Request group limits")) {
                [void](Invoke-Arm -Method PATCH -Path $path -Body $body)
                Write-Ok "Requested group limits: $desc"
                Add-Result 'SetGroupLimits' $desc 'Requested'
            } else { Write-Plan "Request group limits: $desc"; Add-Result 'SetGroupLimits' $desc 'WouldRequest' }
        }
    }
}

function Invoke-Allocate {
    param([object]$Cfg, [hashtable]$Map)
    Write-Step "Allocate quota from groups to subscriptions"
    $rp = $(if ($Cfg.resourceProvider) { $Cfg.resourceProvider } else { 'Microsoft.Compute' })
    foreach ($g in $Cfg.groups) {
        if (-not $g.allocations) { continue }
        $mg = $g.managementGroupId
        # group by (subscription, location)
        $bySubLoc = $g.allocations | Group-Object { "$($_.subscription)|$($_.location)" }
        foreach ($grp in $bySubLoc) {
            $first = $grp.Group[0]
            $sid = Resolve-Subscription -Ref $first.subscription -Map $Map
            $loc = $first.location
            $values = @()
            foreach ($al in $grp.Group) {
                $values += @{ properties = @{ limit = [int]$al.limit; resourceName = $al.resourceName } }
            }
            $path = "/providers/Microsoft.Management/managementGroups/$mg/subscriptions/$sid/providers/Microsoft.Quota/groupQuotas/$($g.name)/resourceProviders/$rp/quotaAllocations/$loc"
            $body = @{ properties = @{ value = $values } }
            $desc = "$($g.name) -> $sid @ $loc : " + (($grp.Group | ForEach-Object { "$($_.resourceName)=$($_.limit)" }) -join ', ')
            if ($PSCmdlet.ShouldProcess($desc, "Allocate quota")) {
                [void](Invoke-Arm -Method PATCH -Path $path -Body $body)
                Write-Ok "Allocated: $desc"
                Add-Result 'Allocate' $desc 'Allocated'
            } else { Write-Plan "Allocate: $desc"; Add-Result 'Allocate' $desc 'WouldAllocate' }
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }
$Cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$script:ApiVersionEffective = $(if ($ApiVersion) { $ApiVersion } elseif ($Cfg.apiVersion) { $Cfg.apiVersion } else { '2025-09-01' })

Write-Step "Azure Quota Groups rollout"
Write-Info "Config        : $ConfigPath"
Write-Info "API version   : $script:ApiVersionEffective"
Write-Info "Action        : $Action"
Write-Info "Mode          : $(if ($WhatIfPreference) { 'WHATIF (dry run)' } else { 'EXECUTE' })"

# Context check
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { throw "Not logged in. Run 'az login' first." }
Write-Info "Signed-in as  : $($acct.user.name)"
if ($Cfg.tenantId -and $acct.tenantId -ne $Cfg.tenantId) {
    Write-Host "    [WARN] Logged-in tenant ($($acct.tenantId)) != config tenant ($($Cfg.tenantId))." -ForegroundColor Yellow
}

$Map = Get-SubscriptionMap

if (-not (Test-Config -Cfg $Cfg -Map $Map)) { throw "Configuration validation failed. Fix the errors above." }
if ($Action -eq 'Validate') { Write-Ok "Validate-only run complete."; return }

$run = @{
    RegisterProviders = { Invoke-RegisterProviders -Cfg $Cfg -Map $Map }
    CreateGroups      = { Invoke-CreateGroups -Cfg $Cfg }
    AddSubscriptions  = { Invoke-AddSubscriptions -Cfg $Cfg -Map $Map }
    SetGroupLimits    = { Invoke-SetGroupLimits -Cfg $Cfg }
    Allocate          = { Invoke-Allocate -Cfg $Cfg -Map $Map }
}
$order = @('RegisterProviders', 'CreateGroups', 'AddSubscriptions', 'SetGroupLimits', 'Allocate')

foreach ($phase in $order) {
    if ($Action -eq 'All' -or $Action -eq $phase) {
        try { & $run[$phase] }
        catch { Write-Err "$phase : $($_.Exception.Message)"; Add-Result $phase '(phase)' 'Error' $_.Exception.Message }
    }
}

Write-Step "Summary"
if ($script:Summary.Count -eq 0) { Write-Info "Nothing to do." }
else { $script:Summary | Format-Table Phase, Status, Target, Detail -AutoSize | Out-String -Width 160 | Write-Host }
$errors = ($script:Summary | Where-Object Status -eq 'Error').Count
if ($errors) { Write-Host "Completed with $errors error(s)." -ForegroundColor Red; exit 1 }
Write-Host "Done." -ForegroundColor Green
