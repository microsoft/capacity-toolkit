<#
.SYNOPSIS
    Generate Azure Spot Placement Scores (allocation-likelihood signal) for VM SKUs across
    regions / availability zones, exported to CSV.

.DESCRIPTION
    Calls the Spot Placement Score API
    (POST .../Microsoft.Compute/locations/{region}/placementScores/spot/generate, api-version
    2025-06-05) to estimate how likely a Spot deployment of a given size and count is to succeed in
    each region/zone. This is the closest programmatic answer Azure gives to the toolkit's core
    "quota is NOT capacity" caveat - but note the caveats below.

    READ-ONLY: the API only *generates* a score; it creates, modifies or deletes nothing. It does,
    however, require an extra read role beyond Reader (see Access required), exactly like quota-group
    reads need management-group read.

    IMPORTANT caveats (state these in any report):
      * The score is for SPOT capacity. There is no public placement-score API for on-demand
        (pay-as-you-go) VMs; treat a Spot score as a *proxy* for regional capacity pressure, never as
        a guarantee for on-demand allocation.
      * Scores are valid only at the moment they are requested (Spot shifts intra-day). Every row is
        timestamped (RetrievedUtc); never present a stale score as current.
      * 'High'/'Medium' does NOT guarantee allocation or no eviction.

    Access required: Reader (to read the subscription/SKU context) plus the built-in
    "Compute Recommendations Role" (single action Microsoft.Compute/locations/placementScores/
    generate/action - no mutations). Assign it on the target subscription(s).

.PARAMETER Location
    Home/primary region; default desired region and REST entry-point. Default 'norwayeast'.

.PARAMETER DesiredLocations
    Regions to score (max 8 per API call - chunked automatically). Defaults to -Location.

.PARAMETER Skus
    VM sizes to score, e.g. 'Standard_D4s_v5' (max 5 per API call - chunked automatically). If
    omitted, sourced from a capacity-config.json (-ConfigPath or output\capacity-config.json).

.PARAMETER ConfigPath
    Optional capacity-config.json (from Get-UsedSkus.ps1) to source -Skus when not given explicitly.

.PARAMETER DesiredCount
    The scenario instance count to score per region/zone. Set this to a realistic count for your
    deployment - it materially changes the score. Default 10.

.PARAMETER Regional
    Score at region scope (availabilityZones = false). Default is per-zone scoring.

.PARAMETER SubscriptionIds
    Optional explicit subscription id(s). The score is generated per subscription.

.PARAMETER SubscriptionCsv
    Optional CSV with a SubId column. Omit both to score all visible subscriptions.

.PARAMETER OutPath
    CSV output path (default ..\output\spot-placement-<region>-<date>.csv).

.EXAMPLE
    .\Get-SpotPlacementScore.ps1 -ConfigPath .\output\capacity-config.json -DesiredCount 50

.EXAMPLE
    .\Get-SpotPlacementScore.ps1 -Location norwayeast -DesiredLocations norwayeast,swedencentral `
        -Skus Standard_D4s_v5,Standard_E8s_v5 -DesiredCount 100
#>
[CmdletBinding()]
param(
    [string]   $Location = 'norwayeast',
    [string[]] $DesiredLocations,
    [string[]] $Skus,
    [string]   $ConfigPath,
    [int]      $DesiredCount = 10,
    [switch]   $Regional,
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [string]   $OutPath
)

. "$PSScriptRoot\Common.ps1"
Assert-AzLogin | Out-Null

$apiVersion = '2025-06-05'

if (-not $DesiredLocations -or $DesiredLocations.Count -eq 0) { $DesiredLocations = @($Location) }

# Resolve the SKUs to score: explicit -Skus wins, else read a capacity-config.json.
if (-not $Skus -or $Skus.Count -eq 0) {
    $cfg = $ConfigPath
    if (-not $cfg) { $cfg = Join-Path (Get-DefaultOutDir) 'capacity-config.json' }
    if (Test-Path $cfg) {
        $j = Get-Content $cfg -Raw | ConvertFrom-Json
        $Skus = @($j.skus)
        Write-Host "Sourced $($Skus.Count) SKU(s) from $cfg" -ForegroundColor DarkGray
    }
}
if (-not $Skus -or $Skus.Count -eq 0) {
    throw "No SKUs to score. Pass -Skus, or -ConfigPath to a capacity-config.json (run Get-UsedSkus.ps1 first)."
}

if (-not $OutPath) {
    $OutPath = Join-Path (Get-DefaultOutDir) ("spot-placement-{0}-{1}.csv" -f $Location, (Get-Date -Format 'yyyyMMdd'))
}

$subs = Resolve-Subscriptions -SubscriptionIds $SubscriptionIds -SubscriptionCsv $SubscriptionCsv

$zonal = 'true'
if ($Regional) { $zonal = 'false' }

Write-Host ("Scoring {0} SKU(s) x {1} region(s), count {2}, scope {3}, across {4} subscription(s)..." -f `
    $Skus.Count, $DesiredLocations.Count, $DesiredCount, $(if ($Regional) { 'regional' } else { 'per-zone' }), $subs.Count) -ForegroundColor Cyan

# Split into API-allowed chunks: <= 8 regions and <= 5 sizes per request.
function Split-Chunk {
    param([object[]]$Items, [int]$Size)
    $out = @()
    for ($i = 0; $i -lt $Items.Count; $i += $Size) {
        $end = [Math]::Min($i + $Size - 1, $Items.Count - 1)
        $out += ,@($Items[$i..$end])
    }
    # Leading comma stops PowerShell from unwrapping a single-element result on return,
    # which would otherwise flatten one chunk back into its items (and index region/SKU
    # strings character-by-character).
    return ,$out
}

$regionChunks = Split-Chunk -Items $DesiredLocations -Size 8
$skuChunks    = Split-Chunk -Items $Skus -Size 5

$rows = @()
$roleWarned = $false
$bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("sps-body-{0}.json" -f ([guid]::NewGuid().ToString('N')))

foreach ($s in $subs) {
    az account set --subscription $s.SubId 2>$null
    foreach ($rc in $regionChunks) {
        $entryRegion = $rc[0]
        $url = "https://management.azure.com/subscriptions/$($s.SubId)/providers/Microsoft.Compute/locations/$entryRegion/placementScores/spot/generate?api-version=$apiVersion"
        foreach ($sc in $skuChunks) {
            # Build the request body by hand: PS 5.1 ConvertTo-Json unwraps single-element arrays,
            # which the API rejects, so we emit the (tiny, fixed) JSON explicitly.
            $locJson  = (($rc | ForEach-Object { '"' + $_ + '"' }) -join ',')
            $sizeJson = (($sc | ForEach-Object { '{"sku":"' + $_ + '"}' }) -join ',')
            $json = '{"availabilityZones":' + $zonal + ',"desiredCount":' + $DesiredCount + ',"desiredLocations":[' + $locJson + '],"desiredSizes":[' + $sizeJson + ']}'
            Set-Content -Path $bodyFile -Value $json -Encoding UTF8 -NoNewline

            $attempt = 0; $resp = $null
            while ($attempt -lt 2) {
                $attempt++
                $out = az rest --method post --url $url --headers 'Content-Type=application/json' --body "@$bodyFile" -o json 2>&1
                if ($LASTEXITCODE -eq 0) {
                    try { $resp = $out | ConvertFrom-Json } catch { $resp = $null }
                    break
                }
                $text = ($out | Out-String)
                if ($text -match '429|TooManyRequests|rate') {
                    Start-Sleep -Seconds 5; continue
                }
                if ($text -match 'Authorization|does not have|Forbidden|403') {
                    if (-not $roleWarned) {
                        Write-Warning "Access denied calling the Spot Placement Score API. Assign the built-in 'Compute Recommendations Role' on subscription $($s.SubId) (it grants only Microsoft.Compute/locations/placementScores/generate/action - no mutations)."
                        $roleWarned = $true
                    }
                    break
                }
                Write-Warning "Spot Placement Score call failed for sub $($s.SubId) [$entryRegion]: $($text.Trim())"
                break
            }

            if ($resp -and $resp.placementScores) {
                foreach ($p in $resp.placementScores) {
                    $zoneVal = $p.availabilityZone
                    if (-not $zoneVal) { $zoneVal = 'regional' }
                    $rows += [pscustomobject][ordered]@{
                        SubscriptionName = $s.Name
                        SubscriptionId   = $s.SubId
                        Sku              = $p.sku
                        Region           = $p.region
                        Zone             = $zoneVal
                        DesiredCount     = $DesiredCount
                        Score            = $p.score
                        IsQuotaAvailable = $p.isQuotaAvailable
                        RetrievedUtc     = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
                    }
                }
            }
        }
    }
}

Remove-Item $bodyFile -ErrorAction SilentlyContinue

if (-not $rows -or $rows.Count -eq 0) {
    Write-Warning "No placement scores returned. Check the 'Compute Recommendations Role' assignment and that the SKUs/regions are valid."
    return
}

$rows | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($rows.Count) score(s) -> $OutPath" -ForegroundColor Green

Write-Host "`nScore distribution:" -ForegroundColor Cyan
$rows | Group-Object Score | Sort-Object Count -Descending | ForEach-Object { "  {0,-22} {1}" -f $_.Name, $_.Count }

Write-Host "`nReminder: Spot placement scores are a time-sensitive proxy for capacity pressure, not a" -ForegroundColor DarkYellow
Write-Host "guarantee - and they reflect SPOT, not on-demand, allocation. Validate with a test deploy." -ForegroundColor DarkYellow
