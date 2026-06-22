<#
.SYNOPSIS
    Watch one or more subscriptions until a SKU becomes regional + zonal enabled (enablement landing
    watch), logging each poll and surfacing any allocation/quota errors from the activity log.

.DESCRIPTION
    Built for "we opened a support request for regional / zonal enablement - tell me the moment it
    lands." Polls Microsoft.Compute/skus per subscription on an interval and writes a CSV log row each cycle.
    Optionally also watches a specific resource (e.g. an AKS cluster) for Error/Failed activity-log
    events so you catch allocation errors during a reconcile. Safe to run from Task Scheduler.

    Access required: Reader on the target subscriptions.

.PARAMETER SubscriptionIds
    Subscriptions to watch (required).

.PARAMETER Sku / Location
    The SKU and region to watch (default Standard_B2s_v2 / norwayeast).

.PARAMETER TargetZones
    Logical zones that must be open to count as "done" (default 1,2,3).

.PARAMETER IntervalSeconds / MaxMinutes
    Poll cadence and overall time budget.

.PARAMETER WatchResourceIds
    Optional resource ids (e.g. an AKS cluster) to scan the activity log for errors.

.PARAMETER LogPath
    CSV log path. Defaults to ..\output\enablement-watch-<date>.csv (resolved robustly).

.EXAMPLE
    .\Watch-SkuEnablement.ps1 -SubscriptionIds 00000000-0000-0000-0000-000000000001 -Sku Standard_B2s_v2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]] $SubscriptionIds,
    [string]   $Sku = 'Standard_B2s_v2',
    [string]   $Location = 'norwayeast',
    [string[]] $TargetZones = @('1','2','3'),
    [int]      $IntervalSeconds = 1800,   # 30 min
    [int]      $MaxMinutes = 1440,        # 24 h
    [string[]] $WatchResourceIds,
    [string]   $LogPath
)

# --- Robust path resolution (works under `powershell.exe -File`, where $PSScriptRoot can be empty) ---
. "$PSScriptRoot\Common.ps1"
if (-not $LogPath) {
    $LogPath = Join-Path (Get-DefaultOutDir) ("enablement-watch-{0}.csv" -f (Get-Date -Format 'yyyyMMdd'))
}
Assert-AzLogin | Out-Null

$deadline = (Get-Date).AddMinutes($MaxMinutes)
$seenErrors = @{}
Write-Host "Watching $Sku in $Location across $($SubscriptionIds.Count) sub(s). Target zones: $($TargetZones -join ',')." -ForegroundColor Cyan
Write-Host "Log -> $LogPath`n" -ForegroundColor DarkGray

while ((Get-Date) -lt $deadline) {
    $stamp = Get-Date -Format 's'
    $allDone = $true
    foreach ($sub in $SubscriptionIds) {
        $skus = Get-ComputeSkus -SubId $sub -Location $Location
        $st = Resolve-SkuStatus -Sku ($skus | Where-Object { $_.name -eq $Sku } | Select-Object -First 1)
        $openZones = if ($st.Zones -in @('-','none')) { @() } else { $st.Zones -split ',' }
        $zonesMet = -not ($TargetZones | Where-Object { $openZones -notcontains $_ })
        $done = ($st.Regional -eq 'Enabled' -and $zonesMet)
        if (-not $done) { $allDone = $false }
        [pscustomobject]@{
            Timestamp = $stamp; Sub = $sub; Sku = $Sku
            Regional = $st.Regional; Zones = $st.Zones; Done = $done
        } | Export-Csv $LogPath -NoTypeInformation -Encoding UTF8 -Append
        Write-Host ("{0}  {1}  reg={2,-8} zones={3,-7} done={4}" -f (Get-Date -Format HH:mm:ss), $sub, $st.Regional, $st.Zones, $done)
    }

    # Optional: surface allocation/quota errors on watched resources (e.g. AKS during reconcile)
    foreach ($rid in $WatchResourceIds) {
        $start = (Get-Date).AddMinutes(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $errs = az monitor activity-log list --resource-id $rid --start-time $start `
                  --query "[?level=='Error' || level=='Critical' || status.value=='Failed'].{t:eventTimestamp,op:operationName.localizedValue,sub:subStatus.localizedValue}" `
                  -o json 2>$null | ConvertFrom-Json
        foreach ($e in $errs) {
            $key = "$($e.t)|$($e.op)"
            if (-not $seenErrors.ContainsKey($key)) {
                $seenErrors[$key] = $true
                Write-Host ("  !! ERROR {0}  {1}  {2}" -f $e.t, $e.op, $e.sub) -ForegroundColor Red
            }
        }
    }

    if ($allDone) {
        Write-Host "`nAll target subscriptions ENABLED (regional + zones $($TargetZones -join ',')). Stopping." -ForegroundColor Green
        break
    }
    if ((Get-Date).AddSeconds($IntervalSeconds) -ge $deadline) { break }
    Start-Sleep -Seconds $IntervalSeconds
}
Write-Host "Watch finished at $(Get-Date -Format s)." -ForegroundColor Cyan
