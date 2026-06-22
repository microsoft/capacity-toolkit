<#
.SYNOPSIS
    Render a single self-contained, interactive HTML dashboard from the toolkit's CSV outputs -
    tabbed navigation, a subscription filter, an at-a-glance Overview, plus enablement matrix, quota
    bars, zone mappings, AKS rollups, region footprint and resilience views. No internet or external
    libraries required (inline CSS + vanilla JS).

.DESCRIPTION
    Looks in -InputDir for the latest CSVs produced by the other scripts and builds an executive-style
    HTML report you can open in a browser or share:
      * Overview      - headline KPIs and any risk flags
      * SKU enablement matrix (colour-coded Enabled / blocked / partial-zones)
      * Quota usage bars per VM family
      * Logical -> physical availability-zone mapping
      * AKS footprint (rollups + per-cluster table)
      * Region footprint (where you run today + candidate regions)
      * Zone-pinned resource resilience
      * Database Flexible Servers

    A header freshness badge shows when the underlying data was collected (green < 12h, amber < 48h,
    red older / missing) and when the HTML itself was rendered. The subscription drop-down filters every
    per-subscription table at once.

    Access required: none (operates on already-exported CSVs).

.PARAMETER InputDir
    Folder containing the CSV exports (default ..\output).

.PARAMETER Location
    Region tag used to pick the right enablement/zone/quota CSVs (default norwayeast). This is the
    Primary / Home region - all candidate regions are compared against it.

.PARAMETER SecondaryRegion
    The chosen secondary / target region for relocation or expansion (e.g. swedencentral). It is shown
    first among the candidates and compared against the Primary. If omitted, the candidate with the
    strongest readiness (most zones + headroom) is picked automatically.

.PARAMETER Title
    Dashboard heading. If omitted, it is auto-derived from the signed-in tenant's display name
    (via Microsoft Graph), e.g. "Contoso - Azure Capacity & Enablement". The region is intentionally
    not pinned in the title because the dashboard spans multiple regions.

.PARAMETER OutPath
    HTML output path (default ..\output\capacity-dashboard-<date>.html).

.EXAMPLE
    .\New-CapacityDashboard.ps1 -Location norwayeast -Title "Contoso - Norway East"
#>
[CmdletBinding()]
param(
    [string] $InputDir,
    [string] $Location = 'norwayeast',
    [string] $SecondaryRegion,
    [string] $Title,
    [string] $OutPath
)

. "$PSScriptRoot\Common.ps1"
if (-not $InputDir) { $InputDir = Get-DefaultOutDir }
$date = Get-Date -Format 'yyyyMMdd'
if (-not $OutPath) { $OutPath = Join-Path $InputDir "capacity-dashboard-$date.html" }

$script:dataTimes = New-Object System.Collections.Generic.List[datetime]
function Get-LatestCsv([string]$pattern) {
    $f = Get-ChildItem -Path $InputDir -Filter $pattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { $script:dataTimes.Add($f.LastWriteTime) }
    return $f
}
function DataAge([datetime]$t) {
    $span = (Get-Date) - $t
    if ($span.TotalMinutes -lt 60) { '{0:N0} min ago' -f $span.TotalMinutes }
    elseif ($span.TotalHours -lt 24) { '{0:N1} h ago' -f $span.TotalHours }
    else { '{0:N1} days ago' -f $span.TotalDays }
}
function HtmlEnc([string]$s) { if ($null -eq $s) { return '' } [System.Web.HttpUtility]::HtmlEncode($s) }
function Pill([string]$text,[string]$cls) { "<span class='pill $cls'>$(HtmlEnc $text)</span>" }
# Render a physical-zone label (e.g. "norwayeast-az2") as a chip coloured by its AZ number, so the
# logical->physical scramble is visible across rows. Falls back to a plain chip if no az suffix.
function PhysZone([string]$val) {
    if (-not $val) { return "<span class='muted'>-</span>" }
    $n = ''
    if ($val -match 'az\s*([123])') { $n = $matches[1] }
    $short = if ($val -match '(az\s*[123])') { ($matches[1] -replace '\s','').ToUpper() } else { $val }
    $cls = if ($n) { "pz$n" } else { 'pz0' }
    "<span class='pzchip $cls' title='$(HtmlEnc $val)'>$(HtmlEnc $short)</span>"
}
function ZoneCls([string]$z) {
    if ($z -in @('1,2,3')) { 'ok' } elseif ($z -in @('-','none','',$null)) { 'bad' } else { 'warn' }
}
# Turn a raw "2,3 [3]; 1,2,3 [3]" zone-pattern string into AZ1/AZ2/AZ3 coverage chips.
function ZoneChips([string]$patterns,[int]$enabledSubs) {
    $z = @{ '1' = 0; '2' = 0; '3' = 0 }
    if ($patterns -and $patterns -ne '-') {
        foreach ($seg in $patterns -split ';') {
            if ($seg -match '([\d,]+)\s*\[(\d+)\]') {
                $zlist = ($matches[1] -split ','); $cnt = [int]$matches[2]
                foreach ($d in '1','2','3') { if ($zlist -contains $d) { $z[$d] += $cnt } }
            }
        }
    }
    $green = 0; $out = ''
    foreach ($d in '1','2','3') {
        $c = $z[$d]
        $cls = if ($enabledSubs -gt 0 -and $c -ge $enabledSubs) { $green++; 'zok' } elseif ($c -gt 0) { 'zpart' } else { 'znone' }
        $title = "AZ$d open on $c of $enabledSubs enabled subscription(s)"
        $out += "<span class='zchip $cls' title='$title'>AZ$d</span>"
    }
    "<span class='zones-cell' data-sort='$green' title='$(HtmlEnc $patterns)'>$out</span>"
}
function AggBadge { "<span class='aggbadge' title='This view rolls up across all subscriptions; the subscription filter does not narrow it.'>&#931; all subscriptions</span>" }
function Bar([double]$pct,[string]$cls,[string]$label) {
    $p = [math]::Min(100,[math]::Max(0,$pct))
    "<div class='bar'><div class='fill $cls' style='width:$([math]::Round($p,1))%'></div><span class='barlbl'>$(HtmlEnc $label)</span></div>"
}

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# Subscriptions that drive the drop-down (only the region-scoped subs, with friendly names).
$script:subNames = [ordered]@{}

# Friendly subscription-name lookup (GUID -> display name), so tables never show bare GUIDs.
# Sourced from _demo-subs.csv / any *-subs.csv (Name,SubId) and supplemented by `az account list`.
$script:friendly = @{}
foreach ($csv in (Get-ChildItem -Path $InputDir -Filter '*subs*.csv' -ErrorAction SilentlyContinue)) {
    try {
        Import-Csv $csv.FullName | ForEach-Object {
            if ($_.SubId -and $_.Name -and ($_.Name -ne $_.SubId)) { $script:friendly[$_.SubId] = $_.Name }
        }
    } catch { }
}
try {
    az account list --all --query "[].{id:id,name:name}" -o json 2>$null | ConvertFrom-Json | ForEach-Object {
        if ($_.id -and -not $script:friendly.ContainsKey($_.id)) { $script:friendly[$_.id] = $_.name }
    }
} catch { }
function FriendlyName([string]$id,[string]$fallback) {
    if ($id -and $script:friendly.ContainsKey($id)) { return $script:friendly[$id] }
    if ($fallback -and $fallback -ne $id) { return $fallback }
    return $id
}

function RegSub([string]$id,[string]$name) {
    if (-not $id) { return }
    $disp = FriendlyName $id $name
    if ($disp -and $disp -ne $id) { $script:subNames[$id] = $disp }
    elseif (-not $script:subNames.Contains($id)) { $script:subNames[$id] = $id }
}

# Overview KPI tiles + risk flags accumulated as sections are built.
$script:ovTiles = New-Object System.Collections.Generic.List[string]
$script:ovFlags = New-Object System.Collections.Generic.List[string]
function AddTile([string]$num,[string]$label,[string]$small,[string]$cls) {
    $script:ovTiles.Add("<div class='tile'><div class='tnum $cls'>$(HtmlEnc $num)</div><div class='tlbl'>$(HtmlEnc $label)</div><div class='tsmall'>$(HtmlEnc $small)</div></div>")
}
function AddFlag([string]$text,[string]$cls) {
    $script:ovFlags.Add("<div class='flag $cls'>$(HtmlEnc $text)</div>")
}

$panes = New-Object System.Collections.Generic.List[object]
function AddPane([string]$id,[string]$title,[string]$body) {
    $panes.Add([pscustomobject]@{ Id = $id; Title = $title; Body = $body })
}

# ---- SKU enablement matrix ------------------------------------------------------------------------
$skuFile = Get-LatestCsv "sku-enablement-$Location-*.csv"; if (-not $skuFile) { $skuFile = Get-LatestCsv 'sku-enablement-*.csv' }
if ($skuFile) {
    $rows = Import-Csv $skuFile.FullName
    $skuCols = ($rows | Get-Member -MemberType NoteProperty).Name | Where-Object { $_ -match '_reg$' } | ForEach-Object { $_ -replace '_reg$','' }
    $h = "<h2>SKU enablement - $Location</h2><div class='sub'>Source: $(HtmlEnc $skuFile.Name)</div>"
    $h += "<div class='tablewrap'><table class='sortable'><thead><tr><th>Subscription</th>"
    foreach ($c in $skuCols) { $h += "<th>$(HtmlEnc $c)<br><span class='muted'>regional</span></th><th><span class='muted'>zones</span></th>" }
    $h += "</tr></thead><tbody>"
    foreach ($r in $rows) {
        RegSub $r.SubId $r.Name
        $h += "<tr data-sub='$(HtmlEnc $r.SubId)'><td class='name'>$(HtmlEnc $r.Name)</td>"
        foreach ($c in $skuCols) {
            $reg = $r."$c`_reg"; $zon = $r."$c`_zones"
            $regCls = if ($reg -eq 'Enabled') { 'ok' } elseif ($reg -eq 'BLOCKED') { 'bad' } else { 'warn' }
            $h += "<td>$(Pill $reg $regCls)</td><td>$(Pill $zon (ZoneCls $zon))</td>"
        }
        $h += "</tr>"
    }
    $h += "</tbody></table></div>"
    $tiles = ""
    foreach ($c in $skuCols) {
        $tot = $rows.Count
        $en  = ($rows | Where-Object { $_."$c`_reg" -eq 'Enabled' }).Count
        $full= ($rows | Where-Object { $_."$c`_zones" -eq '1,2,3' }).Count
        $tiles += "<div class='tile'><div class='tnum'>$en/$tot</div><div class='tlbl'>$(HtmlEnc $c) regional</div><div class='tsmall'>$full/$tot all 3 zones</div></div>"
        $cls = if ($en -lt $tot) { 'bad' } elseif ($full -lt $tot) { 'warn' } else { 'ok' }
        AddTile "$en/$tot" "$c regional" "$full/$tot all-3-zones" $cls
        if ($en -lt $tot) { AddFlag "$c is not regionally enabled on $($tot-$en) of $tot subscription(s)" 'bad' }
        elseif ($full -lt $tot) { AddFlag "$c is missing one or more zones on $($tot-$full) of $tot subscription(s)" 'warn' }
    }
    $h += "<div class='tiles'>$tiles</div>"
    AddPane 'sku' 'SKU Enablement' $h
}

# ---- Quota usage (per subscription) ---------------------------------------------------------------
$qFile = Get-LatestCsv "quota-usage-$Location-*.csv"; if (-not $qFile) { $qFile = Get-LatestCsv 'quota-usage-*.csv' }
if ($qFile) {
    $rows = Import-Csv $qFile.FullName
    $fams = ($rows | Get-Member -MemberType NoteProperty).Name | Where-Object { $_ -match '_limit$' } | ForEach-Object { $_ -replace '_limit$','' }
    $h = "<h2>Quota usage - $Location</h2><div class='sub'>Source: $(HtmlEnc $qFile.Name) &middot; per subscription &middot; <span class='muted'>use the subscription filter or click a column header to sort</span></div>"
    $tiles = ""
    foreach ($f in $fams) {
        $used = ($rows | Measure-Object "$f`_used" -Sum).Sum
        $lim  = ($rows | Measure-Object "$f`_limit" -Sum).Sum
        $avail= ($rows | Measure-Object "$f`_avail" -Sum).Sum
        $pct  = if ($lim) { ($used/$lim)*100 } else { 0 }
        $cls  = if ($pct -ge 90) { 'bad' } elseif ($pct -ge 70) { 'warn' } else { 'ok' }
        $tiles += "<div class='tile'><div class='tnum $cls'>$avail</div><div class='tlbl'>$(HtmlEnc $f) cores free</div><div class='tsmall'>$used used / $lim limit (all subs)</div></div>"
        AddTile ([string]$avail) "$f cores available" "$used used / $lim limit" $cls
    }
    $h += "<div class='tiles'>$tiles</div>"
    $h += "<h3 style='margin-top:18px'>Per-subscription family quota</h3><div class='tablewrap scroll'><table class='sortable'><thead><tr><th>Subscription</th><th>Family</th><th>Used</th><th>Limit</th><th>Available</th><th>Utilisation</th></tr></thead><tbody>"
    foreach ($r in $rows) {
        RegSub $r.SubId $r.Name
        foreach ($f in $fams) {
            $used = [int]$r."$f`_used"; $lim = [int]$r."$f`_limit"; $avail = [int]$r."$f`_avail"
            $pct = if ($lim) { ($used/$lim)*100 } else { 0 }
            $cls = if ($pct -ge 90) { 'bad' } elseif ($pct -ge 70) { 'warn' } else { 'ok' }
            $h += "<tr data-sub='$(HtmlEnc $r.SubId)'><td class='name'>$(HtmlEnc $r.Name)</td><td>$(HtmlEnc $f)</td><td data-sort='$used'>$used</td><td data-sort='$lim'>$lim</td><td data-sort='$avail'>$avail</td><td data-sort='$([math]::Round($pct,1))'>$(Bar $pct $cls ([string]([math]::Round($pct,0))+'%'))</td></tr>"
        }
    }
    $h += "</tbody></table></div>"
    $totFile = Get-LatestCsv "regional-totals-$Location-*.csv"; if (-not $totFile) { $totFile = Get-LatestCsv 'regional-totals-*.csv' }
    if ($totFile) {
        $trows = Import-Csv $totFile.FullName
        $h += "<h3 style='margin-top:22px'>Total Regional &amp; Spot vCPUs per subscription</h3>"
        $h += "<div class='sub'>The Total Regional vCPU limit caps <b>every VM family combined</b>, independently of per-family quota.</div>"
        $h += "<div class='tablewrap scroll'><table class='sortable'><thead><tr><th>Subscription</th><th>Regional used</th><th>Regional limit</th><th>Regional free</th><th>Spot used</th><th>Spot limit</th></tr></thead><tbody>"
        foreach ($r in $trows) {
            RegSub $r.SubId $r.Name
            $ru = [int]$r.RegionalvCPU_Used; $rl = [int]$r.RegionalvCPU_Limit; $ra = [int]$r.RegionalvCPU_Avail
            $pct = if ($rl) { ($ru/$rl)*100 } else { 0 }
            $rcls = if ($pct -ge 90) { 'bad' } elseif ($pct -ge 70) { 'warn' } else { 'ok' }
            $h += "<tr data-sub='$(HtmlEnc $r.SubId)'><td class='name'>$(HtmlEnc $r.Name)</td><td data-sort='$ru'>$ru</td><td data-sort='$rl'>$rl</td><td data-sort='$ra'>$(Pill ([string]$ra) $rcls)</td><td data-sort='$([int]$r.SpotvCPU_Used)'>$([int]$r.SpotvCPU_Used)</td><td data-sort='$([int]$r.SpotvCPU_Limit)'>$([int]$r.SpotvCPU_Limit)</td></tr>"
        }
        $h += "</tbody></table></div>"
    }
    AddPane 'quota' 'Quota' $h
}

# ---- Full SKU catalogue (complete sight) ----------------------------------------------------------
$catFile = Get-LatestCsv "sku-catalogue-$Location-*.csv"; if (-not $catFile) { $catFile = Get-LatestCsv 'sku-catalogue-*.csv' }
if ($catFile) {
    $rows = Import-Csv $catFile.FullName
    $totFile = Get-LatestCsv "regional-totals-$Location-*.csv"; if (-not $totFile) { $totFile = Get-LatestCsv 'regional-totals-*.csv' }
    $regAvail = 0; $regLimit = 0
    if ($totFile) { $t = Import-Csv $totFile.FullName; $regAvail = ($t | Measure-Object RegionalvCPU_Avail -Sum).Sum; $regLimit = ($t | Measure-Object RegionalvCPU_Limit -Sum).Sum }
    $inUse   = @($rows | Where-Object { $_.InUse -eq 'True' })
    $latent  = @($rows | Where-Object { [int]$_.EnabledSubs -gt 0 -and $_.InUse -ne 'True' -and [int]$_.QuotaAvail -gt 0 })
    $blocked = @($rows | Where-Object { [int]$_.OfferedSubs -gt 0 -and [int]$_.EnabledSubs -eq 0 })
    $h = "<h2>SKU catalogue - complete sight</h2><div class='sub'>Source: $(HtmlEnc $catFile.Name) &middot; $($rows.Count) families catalogued &middot; $(AggBadge)</div>"
    $h += "<div class='tiles'>"
    $h += "<div class='tile'><div class='tnum'>$regAvail</div><div class='tlbl'>Total Regional vCPUs free</div><div class='tsmall'>of $regLimit limit</div></div>"
    $h += "<div class='tile'><div class='tnum ok'>$($inUse.Count)</div><div class='tlbl'>families in use</div><div class='tsmall'>actively deployed</div></div>"
    $h += "<div class='tile'><div class='tnum warn'>$($latent.Count)</div><div class='tlbl'>enabled but unused</div><div class='tsmall'>latent head-room</div></div>"
    $h += "<div class='tile'><div class='tnum bad'>$($blocked.Count)</div><div class='tlbl'>fully blocked</div><div class='tsmall'>offered but 0 subs enabled</div></div>"
    $h += "</div>"
    $h += "<h3 style='margin-top:18px'>All families</h3><div class='toolbar' style='margin:0 0 10px'><input id='catSearch' placeholder='filter families (e.g. Dadv6, E, Bsv2)...' onkeyup=`"filterCat(this.value)`"><span class='hint'>click any column header to sort</span></div>"
    $h += "<div class='tablewrap scroll'><table id='catTable' class='sortable'><thead><tr><th>Family</th><th>Series</th><th>Enabled subs</th><th>Blocked subs</th><th>Zone coverage</th><th>Quota used</th><th>Limit</th><th>Available</th><th>In use</th></tr></thead><tbody>"
    foreach ($r in $rows) {
        $enCls = if ([int]$r.EnabledSubs -eq 0 -and [int]$r.OfferedSubs -gt 0) { 'bad' } elseif ([int]$r.BlockedSubs -gt 0) { 'warn' } else { 'ok' }
        $useTxt = if ($r.InUse -eq 'True') { "yes ($($r.InstancesInUse))" } else { 'no' }
        $usePill = if ($r.InUse -eq 'True') { Pill $useTxt 'ok' } else { Pill 'no' 'off' }
        $useSort = if ($r.InUse -eq 'True') { [int]$r.InstancesInUse } else { 0 }
        $h += "<tr><td class='name'>$(HtmlEnc $r.Family)</td><td>$(HtmlEnc $r.Series)</td><td data-sort='$([int]$r.EnabledSubs)'>$(Pill $r.EnabledSubs $enCls)</td><td data-sort='$([int]$r.BlockedSubs)'>$(HtmlEnc $r.BlockedSubs)</td><td>$(ZoneChips $r.ZonePatterns ([int]$r.EnabledSubs))</td><td data-sort='$([int]$r.QuotaUsed)'>$(HtmlEnc $r.QuotaUsed)</td><td data-sort='$([int]$r.QuotaLimit)'>$(HtmlEnc $r.QuotaLimit)</td><td data-sort='$([int]$r.QuotaAvail)'>$(HtmlEnc $r.QuotaAvail)</td><td data-sort='$useSort'>$usePill</td></tr>"
    }
    $h += "</tbody></table></div>"
    AddTile ([string]$regAvail) 'Total Regional vCPUs free' "of $regLimit across scope" 'ok'
    $blkCls = if ($blocked.Count) { 'warn' } else { 'ok' }
    AddTile ([string]$blocked.Count) 'fully-blocked families' 'offered but not enabled' $blkCls
    AddPane 'catalogue' 'SKU Catalogue' $h
}

# ---- Zone mappings --------------------------------------------------------------------------------
$zFile = Get-LatestCsv "zone-mappings-$Location-*.csv"; if (-not $zFile) { $zFile = Get-LatestCsv 'zone-mappings-*.csv' }
if ($zFile) {
    $rows = Import-Csv $zFile.FullName
    $h = "<h2>Logical &rarr; physical zone mapping</h2><div class='sub'>Each subscription's logical zones 1/2/3 map to <b>different</b> physical datacentres (AZ) &mdash; the same logical number is rarely the same physical zone across subs. Colours track the <b>physical</b> AZ so you can see the scramble at a glance. Source: $(HtmlEnc $zFile.Name).</div>"
    $h += "<div class='tablewrap'><table class='sortable'><thead><tr><th>Subscription</th><th>Logical 1</th><th>Logical 2</th><th>Logical 3</th></tr></thead><tbody>"
    foreach ($r in $rows) {
        RegSub $r.SubId $r.Name
        $disp = FriendlyName $r.SubId $r.Name
        $h += "<tr data-sub='$(HtmlEnc $r.SubId)'><td class='name'>$(HtmlEnc $disp)</td><td>$(PhysZone $r.logical1)</td><td>$(PhysZone $r.logical2)</td><td>$(PhysZone $r.logical3)</td></tr>"
    }
    $h += "</tbody></table></div>"
    AddPane 'zones' 'Zone Mapping' $h
}

# ---- AKS footprint --------------------------------------------------------------------------------
$aFile = Get-LatestCsv 'aks-inventory-*.csv'
if ($aFile) {
    $rows = Import-Csv $aFile.FullName
    $subCount = (($rows.subscriptionId | Select-Object -Unique)).Count
    $h = "<h2>AKS footprint</h2><div class='sub'>Source: $(HtmlEnc $aFile.Name) &middot; $($rows.Count) clusters / $subCount subscriptions (tenant-wide)</div>"
    function RollupBars($groups,$titleTxt) {
        $max = ($groups | Measure-Object Count -Maximum).Maximum
        $out = "<div class='rollup'><h3>$(HtmlEnc $titleTxt)</h3>"
        foreach ($g in $groups | Sort-Object Count -Descending) {
            $pct = if ($max) { ($g.Count/$max)*100 } else { 0 }
            $out += "<div class='rrow'><span class='rk'>$(HtmlEnc $g.Name)</span>$(Bar $pct 'ok' ([string]$g.Count))</div>"
        }
        return $out + "</div>"
    }
    $byRegion = $rows | Group-Object location | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Count=$_.Count } }
    $byState  = $rows | Group-Object provState | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Count=$_.Count } }
    $famTally = @{}
    foreach ($c in $rows) {
        $f = ([regex]::Matches($c.skus,'(?i)Standard_[A-Za-z0-9]+') | ForEach-Object { $_.Value } |
              ForEach-Object { if ($_ -match '(?i)^Standard_([A-Za-z]+)') { $matches[1].ToUpper() } } | Select-Object -Unique)
        foreach ($x in $f) { $famTally[$x] = ($famTally[$x] + 1) }
    }
    $byFam = $famTally.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name=$_.Key; Count=$_.Value } }
    $h += "<div class='rollups'>" + (RollupBars $byRegion 'Clusters by region') + (RollupBars $byFam 'Clusters by node-SKU family') + (RollupBars $byState 'Clusters by provisioning state') + "</div>"
    # per-cluster table (filterable)
    $h += "<h3 style='margin-top:18px'>Clusters</h3><div class='tablewrap scroll'><table class='sortable'><thead><tr><th>Cluster</th><th>Region</th><th>State</th><th>Nodes</th><th>Pools</th><th>Node SKUs</th></tr></thead><tbody>"
    foreach ($c in $rows | Sort-Object location, name) {
        $stCls = if ($c.provState -eq 'Succeeded') { 'ok' } elseif ($c.provState -match 'Fail|Cancel') { 'bad' } else { 'warn' }
        $skuChips = (($c.skus -split ';') | Where-Object { $_ } | ForEach-Object { "<span class='skuchip'>$(HtmlEnc ($_.Trim()))</span>" }) -join ''
        if (-not $skuChips) { $skuChips = "<span class='muted'>-</span>" }
        $h += "<tr data-sub='$(HtmlEnc $c.subscriptionId)'><td class='name'>$(HtmlEnc $c.name)</td><td>$(HtmlEnc $c.location)</td><td>$(Pill $c.provState $stCls)</td><td data-sort='$([int]$c.nodeCount)'>$(HtmlEnc $c.nodeCount)</td><td data-sort='$([int]$c.nodePools)'>$(HtmlEnc $c.nodePools)</td><td class='skucell' data-sort='$(HtmlEnc $c.skus)'>$skuChips</td></tr>"
    }
    $h += "</tbody></table></div>"
    AddTile ([string]$rows.Count) 'AKS clusters' "$subCount subscriptions" 'ok'
    AddPane 'aks' 'AKS' $h
}

# ---- Region footprint -----------------------------------------------------------------------------
$rFile = Get-LatestCsv 'region-footprint-*.csv'
if ($rFile) {
    $rows = Import-Csv $rFile.FullName
    $maxRes = ($rows | Measure-Object Resources -Maximum).Maximum
    $candidates = @($rows | Where-Object { $_.Status -like '*Candidate*' }).Count
    $h = "<h2>Regions</h2><div class='sub'>Where you run today, and whether other regions are ready if you want to <b>relocate or expand</b> &mdash; checking SKU enablement, zone coverage and real quota headroom side by side.</div>"
    $h += "<h3 style='margin-top:18px'>Region footprint</h3><div class='sub'>Resources, subscriptions and AKS clusters per region &middot; Source: $(HtmlEnc $rFile.Name) &middot; $(AggBadge)</div>"
    $h += "<div class='tablewrap'><table class='sortable'><thead><tr><th>Region</th><th>Resources</th><th>Subscriptions</th><th>AKS clusters</th><th>Status</th></tr></thead><tbody>"
    foreach ($r in $rows | Sort-Object { [int]$_.Resources } -Descending) {
        $pct = if ($maxRes) { ([double]$r.Resources/$maxRes)*100 } else { 0 }
        $statCls = if ($r.Status -like 'Candidate*') { 'warn' } else { 'ok' }
        $h += "<tr><td class='name'>$(HtmlEnc $r.Region)</td><td data-sort='$([int]$r.Resources)'>$(Bar $pct 'ok' ([string]$r.Resources))</td><td data-sort='$([int]$r.Subscriptions)'>$(HtmlEnc $r.Subscriptions)</td><td data-sort='$([int]$r.AksClusters)'>$(HtmlEnc $r.AksClusters)</td><td>$(Pill $r.Status $statCls)</td></tr>"
    }
    $h += "</tbody></table></div>"
    # ===== Migration-readiness: the executive answer (home + candidate regions) =====
    $cmpFile  = Get-LatestCsv 'region-sku-comparison-*.csv'
    $qcmpFile = Get-LatestCsv 'region-quota-comparison-*.csv'
    $crows = if ($cmpFile)  { Import-Csv $cmpFile.FullName }  else { @() }
    $qrows = if ($qcmpFile) { Import-Csv $qcmpFile.FullName } else { @() }

    $homeReg    = $Location.ToLower()
    $candRegions = @($rows | Where-Object { $_.Status -like '*Candidate*' } | Select-Object -ExpandProperty Region | ForEach-Object { $_.ToLower() })
    $skuList = @($crows.Sku | Select-Object -Unique)
    $skuTotal = $skuList.Count

    function RegStats([string]$rg) {
        $rf = 0; $zf = 0
        foreach ($sk in $skuList) {
            $c = $crows | Where-Object { $_.Region -eq $rg -and $_.Sku -eq $sk } | Select-Object -First 1
            if ($c) {
                $rd = [int]($c.RegionalOf -split '/')[1]; $rn = [int]($c.RegionalOf -split '/')[0]; $zn = [int]($c.All3ZonesOf -split '/')[0]
                if ($rd -gt 0 -and $rn -ge $rd) { $rf++ }
                if ($rd -gt 0 -and $zn -ge $rd) { $zf++ }
            }
        }
        $tr = $qrows | Where-Object { $_.Region -eq $rg -and $_.Metric -eq 'Total Regional vCPUs' } | Select-Object -First 1
        $trAvail = if ($tr) { [int]$tr.Avail } else { 0 }
        $trLimit = if ($tr) { [int]$tr.Limit } else { 0 }
        $minFam = $null
        foreach ($q in $qrows | Where-Object { $_.Region -eq $rg -and $_.Metric -like 'standard*Family' }) {
            $a = [int]$q.Avail; if ($null -eq $minFam -or $a -lt $minFam) { $minFam = $a }
        }
        if ($null -eq $minFam) { $minFam = $trAvail }
        [pscustomobject]@{ RegFull=$rf; ZonesFull=$zf; TrAvail=$trAvail; TrLimit=$trLimit; MinFam=$minFam }
    }

    if ($crows.Count -or $qrows.Count) {
        $allCmpRegs = @($crows.Region + $qrows.Region | ForEach-Object { $_.ToLower() } | Select-Object -Unique)
        $homeStats = RegStats $homeReg

        # Resolve the chosen secondary: explicit param, else the strongest candidate.
        $secReg = ''
        if ($SecondaryRegion) {
            $s = $SecondaryRegion.ToLower()
            if ($allCmpRegs -contains $s) { $secReg = $s }
        }
        if (-not $secReg) {
            $best = $null; $bestKey = -1
            foreach ($c in ($candRegions | Where-Object { $_ -ne $homeReg } | Select-Object -Unique)) {
                $cs = RegStats $c
                $key = ($cs.ZonesFull * 100000) + ($cs.RegFull * 10000) + $cs.TrAvail
                if ($key -gt $bestKey) { $bestKey = $key; $best = $c }
            }
            $secReg = $best
        }
        $script:secReg = $secReg
        $otherCands = @($candRegions | Where-Object { $_ -ne $homeReg -and $_ -ne $secReg } | Select-Object -Unique)
        $cardRegs = @($homeReg)
        if ($secReg) { $cardRegs += $secReg }
        $cardRegs += $otherCands

        function DeltaMark([int]$val,[int]$base,[string]$unit) {
            if ($val -gt $base) { "<span class='dlt up'>&#9650; +$($val-$base) vs home</span>" }
            elseif ($val -lt $base) { "<span class='dlt dn'>&#9660; -$($base-$val) vs home</span>" }
            else { "<span class='dlt eq'>= home</span>" }
        }

        $h += "<h3 style='margin-top:22px'>Migration readiness</h3>"
        $h += "<div class='sub'>Anchored on the <b>Primary (home)</b> region, then your <b>chosen secondary</b>, then any other candidates. A target needs the SKUs <b>regionally enabled</b>, ideally <b>all three zones</b> open, and real <b>quota headroom</b> &mdash; but remember <b>quota is not capacity</b>: green here means it is <i>allowed</i>, not that the cores are physically available. Validate with a small test deployment before committing.</div>"
        $h += "<div class='rcards'>"
        foreach ($rg in $cardRegs) {
            $isHome = ($rg -eq $homeReg)
            $isSec  = ($rg -eq $secReg)
            $st = if ($isHome) { $homeStats } else { RegStats $rg }
            $role = if ($isHome) { 'home' } elseif ($isSec) { 'sec' } else { 'cand' }
            $icon = if ($isHome) { '&#8962;' } elseif ($isSec) { '&#9733;' } else { '&#9671;' }
            $tag  = if ($isHome) { 'primary / home' } elseif ($isSec) { 'chosen secondary' } else { 'other candidate' }
            $enabled = ($skuTotal -gt 0 -and $st.RegFull -eq $skuTotal)
            $zonesOk = ($skuTotal -gt 0 -and $st.ZonesFull -eq $skuTotal)
            $quotaOk = ($st.TrAvail -gt 0)
            if ($isHome) { $verdict = 'Primary (current)'; $vcls = 'ok' }
            elseif (-not $enabled) { $verdict = 'Weak &middot; not fully enabled'; $vcls = 'bad' }
            elseif (-not $quotaOk) { $verdict = 'Enabled &middot; no quota'; $vcls = 'bad' }
            elseif ($zonesOk) { $verdict = 'Viable target'; $vcls = 'ok' }
            else { $verdict = 'Viable &middot; zone gaps'; $vcls = 'warn' }
            $rcls = if ($skuTotal -gt 0 -and $st.RegFull -eq $skuTotal) { 'ok' } elseif ($st.RegFull -gt 0) { 'warn' } else { 'bad' }
            $zcls = if ($skuTotal -gt 0 -and $st.ZonesFull -eq $skuTotal) { 'ok' } elseif ($st.ZonesFull -gt 0) { 'warn' } else { 'bad' }
            $qcls = if ($st.TrAvail -le 0) { 'bad' } elseif ($st.TrLimit -gt 0 -and ($st.TrAvail / $st.TrLimit) -lt 0.2) { 'warn' } else { 'ok' }
            $fcls = if ($st.MinFam -le 0) { 'bad' } elseif ($st.MinFam -lt 100) { 'warn' } else { 'ok' }
            # deltas vs home (not shown on the home card itself)
            $zDlt = if ($isHome) { '' } else { DeltaMark $st.ZonesFull $homeStats.ZonesFull }
            $qDlt = if ($isHome) { '' } else { DeltaMark $st.TrAvail $homeStats.TrAvail }
            $h += "<div class='rcard $role'>"
            $h += "<div class='rcard-h'><span class='ricon'>$icon</span>$(HtmlEnc $rg)<span class='rtag'>$tag</span></div>"
            $h += "<div class='rverdict $vcls'>$verdict</div>"
            $h += "<div class='rmetrics'>"
            $h += "<div><span class='rk'>SKUs regionally enabled</span>$(Pill "$($st.RegFull)/$skuTotal" $rcls)</div>"
            $h += "<div><span class='rk'>SKUs all-3-zones</span>$(Pill "$($st.ZonesFull)/$skuTotal" $zcls) $zDlt</div>"
            $h += "<div><span class='rk'>Regional headroom</span>$(Pill ([string]$st.TrAvail) $qcls) <span class='muted'>/ $($st.TrLimit) cores</span> $qDlt</div>"
            $h += "<div><span class='rk'>Tightest family</span>$(Pill ([string]$st.MinFam) $fcls) <span class='muted'>cores free</span></div>"
            $h += "</div></div>"
        }
        $h += "</div>"
        # compact mention of regions with incidental footprint
        $footprintElsewhere = @($rows | Where-Object {
            $rg = $_.Region.ToLower()
            $rg -ne $homeReg -and $rg -ne $secReg -and $otherCands -notcontains $rg -and [int]$_.Resources -gt 0
        } | Sort-Object { [int]$_.Resources } -Descending)
        if ($footprintElsewhere.Count) {
            $fpTxt = ($footprintElsewhere | ForEach-Object { "<b>$(HtmlEnc $_.Region)</b> ($($_.Resources))" }) -join ' &middot; '
            $h += "<div class='note' style='margin-top:6px'><b>Also has footprint in:</b> $fpTxt. Not evaluated as relocation targets, but worth noting &mdash; add any to <code>-EvaluateRegions</code> to compare them with the same depth.</div>"
        }
        $h += "<div class='sub' style='margin-top:8px'><b>Reminder:</b> an approved quota only raises the ceiling. Even where headroom looks ample, a region can be capacity-constrained &mdash; confirm with a small deployment in the target region before relocating workloads.</div>"
    }

    # Ordered region list for the detail matrices: home, chosen secondary, other candidates, the rest.
    function OrderRegions([string[]]$all) {
        $a = @($all | ForEach-Object { $_.ToLower() })
        $ordered = @()
        if ($a -contains $homeReg) { $ordered += $homeReg }
        if ($script:secReg -and $a -contains $script:secReg -and $ordered -notcontains $script:secReg) { $ordered += $script:secReg }
        foreach ($c in $candRegions) { if ($a -contains $c -and $ordered -notcontains $c) { $ordered += $c } }
        foreach ($r in $a) { if ($ordered -notcontains $r) { $ordered += $r } }
        return $ordered
    }
    function ColCls([string]$rg) { if ($rg -eq $homeReg) { ' class="colhome"' } elseif ($rg -eq $script:secReg) { ' class="colsec"' } elseif ($candRegions -contains $rg) { ' class="colcand"' } else { '' } }
    function ColHdr([string]$rg) {
        $mark = if ($rg -eq $homeReg) { '&#8962; ' } elseif ($rg -eq $script:secReg) { '&#9733; ' } elseif ($candRegions -contains $rg) { '&#9671; ' } else { '' }
        "<th$(ColCls $rg)>$mark$(HtmlEnc $rg)</th>"
    }

    # ---- Detail: SKU enablement matrix (reordered + cleaner cells) ----
    if ($crows.Count) {
        $regList = OrderRegions @($crows.Region | Select-Object -Unique)
        $scopeCnt = if ($script:subNames.Count -gt 0) { [string]$script:subNames.Count } else { '?' }
        $h += "<h3 style='margin-top:24px'>SKU enablement by region <span class='muted' style='font-weight:400'>(detail)</span></h3><div class='sub'>&#8962; home &middot; &#9733; chosen secondary &middot; &#9671; other candidate &middot; <b>reg</b> = subs with the SKU regionally enabled, <b>AZ</b> = subs with all three zones open (of $scopeCnt in scope).</div>"
        $h += "<div class='tablewrap scroll'><table class='sortable'><thead><tr><th>SKU</th>"
        foreach ($rg in $regList) { $h += ColHdr $rg }
        $h += "</tr></thead><tbody>"
        foreach ($sk in $skuList) {
            $h += "<tr><td class='name'>$(HtmlEnc $sk)</td>"
            foreach ($rg in $regList) {
                $c = $crows | Where-Object { $_.Region -eq $rg -and $_.Sku -eq $sk } | Select-Object -First 1
                if (-not $c) { $h += "<td$(ColCls $rg)><span class='muted'>n/a</span></td>"; continue }
                $regDen = [int]($c.RegionalOf -split '/')[1]; $regNum = [int]($c.RegionalOf -split '/')[0]; $zNum = [int]($c.All3ZonesOf -split '/')[0]
                $rcls = if ($regNum -eq 0) { 'bad' } elseif ($regNum -lt $regDen) { 'warn' } else { 'ok' }
                $zc = if ($zNum -ge $regDen -and $regDen -gt 0) { 'ok' } elseif ($zNum -gt 0) { 'warn' } else { 'off' }
                $h += "<td$(ColCls $rg) data-sort='$regNum'>$(Pill "reg $($c.RegionalOf)" $rcls) $(Pill "AZ $($c.All3ZonesOf)" $zc)</td>"
            }
            $h += "</tr>"
        }
        $h += "</tbody></table></div>"
    }
    # ---- Detail: quota headroom matrix (reordered) ----
    if ($qrows.Count) {
        $regList2 = OrderRegions @($qrows.Region | Select-Object -Unique)
        $metrics  = @($qrows | Sort-Object { $_.Key -ne 'cores' }, Metric | Select-Object -ExpandProperty Metric -Unique)
        $h += "<h3 style='margin-top:24px'>Quota headroom by region <span class='muted' style='font-weight:400'>(detail)</span></h3><div class='sub'>Available <span class='muted'>/ limit</span> cores summed across the in-scope subscriptions. &#8962; home &middot; &#9733; chosen secondary &middot; &#9671; other candidate.</div>"
        $h += "<div class='tablewrap scroll'><table class='sortable'><thead><tr><th>Quota</th>"
        foreach ($rg in $regList2) { $h += ColHdr $rg }
        $h += "</tr></thead><tbody>"
        foreach ($mt in $metrics) {
            $h += "<tr><td class='name'>$(HtmlEnc $mt)</td>"
            foreach ($rg in $regList2) {
                $q = $qrows | Where-Object { $_.Region -eq $rg -and $_.Metric -eq $mt } | Select-Object -First 1
                if (-not $q) { $h += "<td$(ColCls $rg)><span class='muted'>n/a</span></td>"; continue }
                $avail = [int]$q.Avail; $lim = [int]$q.Limit
                $pct = if ($lim) { (([int]$q.Used)/$lim)*100 } else { 0 }
                $cls = if ($lim -eq 0) { 'bad' } elseif ($pct -ge 90) { 'bad' } elseif ($pct -ge 70) { 'warn' } else { 'ok' }
                $h += "<td$(ColCls $rg) data-sort='$avail'>$(Pill ([string]$avail) $cls) <span class='muted'>/ $lim</span></td>"
            }
            $h += "</tr>"
        }
        $h += "</tbody></table></div><div class='sub' style='margin-top:8px'>A SKU can be enabled in a candidate region yet still have little or no quota there - new regions often start with low limits. Request a quota increase before relocating.</div>"
    }
    if ($candidates) { AddTile ([string]$candidates) 'candidate region(s)' 'evaluated for relocation' 'warn' }
    AddPane 'regions' 'Regions' $h
}

# ---- Zonal resource resilience --------------------------------------------------------------------
$znFile = Get-LatestCsv 'zonal-resources-*.csv'
if ($znFile) {
    $rows = Import-Csv $znFile.FullName
    $single = @($rows | Where-Object { $_.SingleZone -eq 'True' }).Count
    $h = "<h2>Zone-pinned resource resilience</h2><div class='sub'>Source: $(HtmlEnc $znFile.Name) &middot; $($rows.Count) zone-pinned resources &middot; $single single-zone</div>"
    $h += "<h3>By resource type</h3><div class='tablewrap'><table class='sortable'><thead><tr><th>Resource type</th><th>Total</th><th>Single-zone</th><th>Multi-zone</th></tr></thead><tbody>"
    foreach ($g in $rows | Group-Object type | Sort-Object Count -Descending) {
        $sz = @($g.Group | Where-Object { $_.SingleZone -eq 'True' }).Count
        $mz = $g.Count - $sz
        $szCls = if ($sz -eq $g.Count -and $g.Name -notmatch 'disk|virtualmachines$') { 'warn' } else { 'ok' }
        $h += "<tr><td class='name'>$(HtmlEnc $g.Name)</td><td data-sort='$($g.Count)'>$($g.Count)</td><td data-sort='$sz'>$(Pill ([string]$sz) $szCls)</td><td data-sort='$mz'>$mz</td></tr>"
    }
    $h += "</tbody></table></div>"
    $h += "<h3 style='margin-top:20px'>Every zone-pinned resource</h3><div class='sub'>Filterable by subscription &middot; click a column header to sort.</div>"
    $h += "<div class='tablewrap scroll'><table class='sortable'><thead><tr><th>Resource</th><th>Type</th><th>Resource group</th><th>Location</th><th>Zones</th><th>Resilience</th></tr></thead><tbody>"
    foreach ($r in $rows | Sort-Object type, name) {
        $zCls = if ($r.SingleZone -eq 'True') { 'warn' } else { 'ok' }
        $zTxt = if ($r.SingleZone -eq 'True') { 'single-zone' } else { 'multi-zone' }
        $h += "<tr data-sub='$(HtmlEnc $r.subscriptionId)'><td class='name'>$(HtmlEnc $r.name)</td><td>$(HtmlEnc $r.type)</td><td>$(HtmlEnc $r.resourceGroup)</td><td>$(HtmlEnc $r.location)</td><td class='mono' data-sort='$([int]$r.zoneCount)'>$(HtmlEnc $r.zones)</td><td>$(Pill $zTxt $zCls)</td></tr>"
    }
    $h += "</tbody></table></div><div class='sub' style='margin-top:8px'>Single-zone is expected for individual VMs and disks; review it for stateful or front-door resources that should be zone-redundant.</div>"
    AddTile ([string]$single) 'single-zone resources' "of $($rows.Count) zone-pinned" 'warn'
    AddPane 'zonal' 'Resilience' $h
}

# ---- Database Flexible Server resilience ----------------------------------------------------------
$fsFile = Get-LatestCsv 'flexserver-zones-*.csv'
if ($fsFile) {
    $rows = Import-Csv $fsFile.FullName
    $zr = @($rows | Where-Object { $_.zoneRedundant -eq 'True' }).Count
    $noHa = $rows.Count - $zr
    $h = "<h2>Database Flexible Servers</h2><div class='sub'>Source: $(HtmlEnc $fsFile.Name) &middot; $($rows.Count) servers &middot; $zr zone-redundant HA</div>"
    $tiles = ""
    foreach ($grp in $rows | Group-Object haMode | Sort-Object Count -Descending) {
        $cls = if ($grp.Name -eq 'ZoneRedundant') { 'ok' } else { 'warn' }
        $tiles += "<div class='tile'><div class='tnum'>$($grp.Count)</div><div class='tlbl'>$(Pill $grp.Name $cls)</div></div>"
    }
    $h += "<div class='tiles'>$tiles</div>"
    $h += "<div class='tablewrap scroll' style='margin-top:14px'><table class='sortable'><thead><tr><th>Server</th><th>Engine</th><th>Tier</th><th>SKU</th><th>Zone</th><th>HA mode</th><th>Standby</th></tr></thead><tbody>"
    foreach ($r in $rows | Sort-Object haMode, name) {
        $haCls = if ($r.zoneRedundant -eq 'True') { 'ok' } else { 'warn' }
        $h += "<tr data-sub='$(HtmlEnc $r.subscriptionId)'><td class='name'>$(HtmlEnc $r.name)</td><td>$(HtmlEnc $r.engine)</td><td>$(HtmlEnc $r.tier)</td><td>$(HtmlEnc $r.sku)</td><td>$(HtmlEnc $r.zone)</td><td>$(Pill $r.haMode $haCls)</td><td>$(HtmlEnc $r.standbyZone)</td></tr>"
    }
    $h += "</tbody></table></div>"
    AddTile ([string]$noHa) 'DBs without zone-redundant HA' "of $($rows.Count) Flexible Servers" 'warn'
    AddPane 'flex' 'Databases' $h
}

# ---- Full resource inventory (complete overview) --------------------------------------------------
$invFile = Get-LatestCsv 'resource-inventory-*.csv'
if ($invFile) {
    $rows = Import-Csv $invFile.FullName
    $totalRes = ($rows | Measure-Object Count -Sum).Sum
    $zonedRes = ($rows | Measure-Object Zoned -Sum).Sum
    $types    = ($rows.Type | Select-Object -Unique).Count
    $subCnt   = ($rows.SubId | Select-Object -Unique).Count
    $h = "<h2>Full resource inventory - complete overview</h2><div class='sub'>Source: $(HtmlEnc $invFile.Name) &middot; every resource type across $subCnt subscription(s) &middot; <span class='muted'>nothing left out</span></div>"
    $h += "<div class='tiles'>"
    $h += "<div class='tile'><div class='tnum'>$totalRes</div><div class='tlbl'>total resources</div><div class='tsmall'>across $subCnt subscriptions</div></div>"
    $h += "<div class='tile'><div class='tnum'>$types</div><div class='tlbl'>distinct resource types</div><div class='tsmall'>full footprint</div></div>"
    $h += "<div class='tile'><div class='tnum ok'>$zonedRes</div><div class='tlbl'>zone-pinned resources</div><div class='tsmall'>carry an AZ placement</div></div>"
    $h += "</div>"
    # by type (aggregate, searchable + sortable)
    $byType = $rows | Group-Object Type | ForEach-Object {
        [pscustomobject]@{
            Type  = $_.Name
            Total = ($_.Group | Measure-Object Count -Sum).Sum
            Zoned = ($_.Group | Measure-Object Zoned -Sum).Sum
            Subs  = ($_.Group.SubId | Select-Object -Unique).Count
            Regs  = ($_.Group.Location | Select-Object -Unique).Count
        }
    } | Sort-Object Total -Descending
    $h += "<h3 style='margin-top:18px'>By resource type $(AggBadge)</h3>"
    $h += "<div class='toolbar' style='margin:0 0 10px'><input id='invSearch' placeholder='filter types (e.g. storage, network, sql)...' onkeyup=`"filterInv(this.value)`"><span class='hint'>click any column header to sort</span></div>"
    $h += "<div class='tablewrap scroll'><table id='invTypeTable' class='sortable'><thead><tr><th>Resource type</th><th>Count</th><th>Zone-pinned</th><th>Subscriptions</th><th>Regions</th></tr></thead><tbody>"
    foreach ($t in $byType) {
        $h += "<tr><td class='name'>$(HtmlEnc $t.Type)</td><td data-sort='$($t.Total)'>$($t.Total)</td><td data-sort='$($t.Zoned)'>$(if($t.Zoned){Pill ([string]$t.Zoned) 'ok'}else{Pill '0' 'off'})</td><td data-sort='$($t.Subs)'>$($t.Subs)</td><td data-sort='$($t.Regs)'>$($t.Regs)</td></tr>"
    }
    $h += "</tbody></table></div>"
    # per subscription x type (filterable + sortable)
    $h += "<h3 style='margin-top:20px'>By subscription &amp; type</h3><div class='sub'>Filterable by subscription &middot; click a column header to sort.</div>"
    $h += "<div class='tablewrap scroll'><table class='sortable'><thead><tr><th>Subscription</th><th>Resource type</th><th>Location</th><th>Count</th><th>Zone-pinned</th></tr></thead><tbody>"
    foreach ($r in $rows | Sort-Object SubName, @{e={[int]$_.Count};desc=$true}) {
        $h += "<tr data-sub='$(HtmlEnc $r.SubId)'><td class='name'>$(HtmlEnc $r.SubName)</td><td>$(HtmlEnc $r.Type)</td><td>$(HtmlEnc $r.Location)</td><td data-sort='$([int]$r.Count)'>$(HtmlEnc $r.Count)</td><td data-sort='$([int]$r.Zoned)'>$(HtmlEnc $r.Zoned)</td></tr>"
    }
    $h += "</tbody></table></div>"
    AddTile ([string]$totalRes) 'total resources' "$types types / $subCnt subs" 'ok'
    AddPane 'inventory' 'Inventory' $h
}

# ---- Quota Groups: existing pools (if any) + pooled-design snapshot -------------------------------
$qgFile   = Get-LatestCsv 'quota-groups-*.csv'
$qgmFile  = Get-LatestCsv 'quota-group-members-*.csv'
$planFile = Get-LatestCsv 'quota-group-plan-*.csv'
$planMemFile = Get-LatestCsv 'quota-group-plan-members-*.csv'
# quota-group-plan-members-*.csv also matches quota-group-plan-*.csv; disambiguate.
if ($planFile -and $planFile.Name -like 'quota-group-plan-members-*') {
    $planFile = Get-ChildItem -Path $InputDir -Filter 'quota-group-plan-*.csv' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'quota-group-plan-members-*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if ($qgFile -or $planFile) {
    $h = "<h2>Quota Groups</h2><div class='sub'>Pool a regional core allowance and flex it across subscriptions without a per-subscription increase ticket for every move.</div>"

    # --- existing quota groups (read at management-group scope) ---
    if ($qgFile) {
        $qg = Import-Csv $qgFile.FullName
        $qglFile = Get-LatestCsv 'quota-group-limits-*.csv'
        $grpCount = ($qg.QuotaGroup | Select-Object -Unique).Count
        $memTotal = ($qg | Measure-Object Members -Sum).Sum
        $withLimits = ($qg | Where-Object { $_.PooledLimitsSet -eq 'yes' }).Count
        $h += "<div class='tiles'>"
        $h += "<div class='tile'><div class='tnum ok'>$grpCount</div><div class='tlbl'>quota groups in use</div><div class='tsmall'>discovered live</div></div>"
        $h += "<div class='tile'><div class='tnum'>$memTotal</div><div class='tlbl'>pooled subscriptions</div><div class='tsmall'>across all groups</div></div>"
        $h += "<div class='tile'><div class='tnum$(if($withLimits){' ok'}else{' warn'})'>$withLimits / $grpCount</div><div class='tlbl'>groups with pooled limits</div><div class='tsmall'>vs members-only pools</div></div>"
        $h += "</div>"
        $h += "<h3 style='margin-top:18px'>Existing groups $(AggBadge)</h3>"
        $h += "<div class='tablewrap scroll'><table class='sortable'><thead><tr><th>Group</th><th>Type</th><th>Members</th><th>Pooled limits</th><th>Regions w/ limits</th><th>State</th></tr></thead><tbody>"
        foreach ($r in $qg | Sort-Object @{e={[int]$_.Members};desc=$true}) {
            $disp = if ($r.DisplayName) { $r.DisplayName } else { $r.QuotaGroup }
            $plcls = if ($r.PooledLimitsSet -eq 'yes') { 'ok' } else { 'off' }
            $regTxt = if ($r.RegionsWithLimits) { HtmlEnc $r.RegionsWithLimits } else { '<span class="muted">none</span>' }
            $h += "<tr><td class='name'>$(HtmlEnc $disp)</td><td>$(HtmlEnc $r.GroupType)</td><td data-sort='$([int]$r.Members)'>$(HtmlEnc $r.Members)</td><td>$(Pill $r.PooledLimitsSet $plcls)</td><td>$regTxt</td><td>$(HtmlEnc $r.ProvisioningState)</td></tr>"
        }
        $h += "</tbody></table></div>"
        # pooled limits detail (only when any group actually sets limits)
        if ($qglFile) {
            $qgl = Import-Csv $qglFile.FullName
            if ($qgl) {
                $h += "<h3 style='margin-top:20px'>Pooled limits by region &amp; family $(AggBadge)</h3>"
                $h += "<div class='tablewrap scroll'><table class='sortable'><thead><tr><th>Group</th><th>Region</th><th>Family</th><th>Pooled limit</th></tr></thead><tbody>"
                foreach ($l in $qgl | Sort-Object DisplayName, Region, Resource) {
                    $disp = if ($l.DisplayName) { $l.DisplayName } else { $l.QuotaGroup }
                    $h += "<tr><td class='name'>$(HtmlEnc $disp)</td><td>$(HtmlEnc $l.Region)</td><td>$(HtmlEnc $l.Resource)</td><td data-sort='$([int]$l.Limit)'>$(Pill ([string]$l.Limit) 'ok')</td></tr>"
                }
                $h += "</tbody></table></div>"
            }
        } else {
            $h += "<div class='note' style='margin-top:12px'>These groups are <b>allocation groups</b> that pool their member subscriptions, but no pooled compute limit is set on them yet - each member still draws on its own per-subscription quota. Setting a group limit is what lets capacity flex between members without a per-sub ticket.</div>"
        }
        if ($qgmFile) {
            $qgm = Import-Csv $qgmFile.FullName
            $h += "<h3 style='margin-top:20px'>Group membership</h3><div class='sub'>$($qgm.Count) member subscription(s) across $grpCount group(s). Click a header to sort.</div>"
            $h += "<div class='tablewrap scroll'><table class='sortable'><thead><tr><th>Group</th><th>Member subscription</th></tr></thead><tbody>"
            foreach ($m in $qgm | Sort-Object DisplayName, SubName) {
                $disp = if ($m.DisplayName) { $m.DisplayName } else { $m.QuotaGroup }
                $h += "<tr><td class='name'>$(HtmlEnc $disp)</td><td>$(HtmlEnc $m.SubName)</td></tr>"
            }
            $h += "</tbody></table></div>"
        }
        AddTile ([string]$grpCount) 'quota groups' "$memTotal subs pooled" 'ok'
        if ($withLimits -lt $grpCount) {
            AddFlag "$($grpCount - $withLimits) of $grpCount quota group(s) pool subscriptions but have no pooled compute limit set - members still rely on their own per-sub quota. Setting a group limit unlocks cross-sub flexing." 'warn'
        }
    } else {
        $h += "<div class='flags'><div class='flag'>No quota groups found in this tenant (or management-group access is unavailable to read them). The pooled-quota design below is modelled from the per-subscription quota you can already see.</div></div>"
    }

    # --- pooled-design snapshot (subscription-Reader only) ---
    if ($planFile) {
        $plan = Import-Csv $planFile.FullName
        $totalRow = $plan | Where-Object { $_.Scope -like 'Total Regional*' } | Select-Object -First 1
        $h += "<h3 style='margin-top:22px'>Pooled-quota design snapshot $(AggBadge)</h3>"
        $h += "<div class='sub'>What a Quota Group could look like across the in-scope subscriptions, if they were pooled today.</div>"
        if ($totalRow) {
            $h += "<div class='tiles'>"
            $h += "<div class='tile'><div class='tnum'>$($totalRow.Members)</div><div class='tlbl'>candidate member subs</div><div class='tsmall'>in scope</div></div>"
            $h += "<div class='tile'><div class='tnum'>$($totalRow.PoolLimit)</div><div class='tlbl'>pooled regional limit</div><div class='tsmall'>sum of member limits</div></div>"
            $h += "<div class='tile'><div class='tnum ok'>$($totalRow.PoolAvail)</div><div class='tlbl'>pooled headroom</div><div class='tsmall'>$($totalRow.PoolUsed) vCPU used</div></div>"
            $h += "<div class='tile'><div class='tnum warn'>$($totalRow.StrandedHeadroom)</div><div class='tlbl'>stranded headroom</div><div class='tsmall'>idle in &lt;50% subs</div></div>"
            $h += "</div>"
        }
        $h += "<table class='sortable' style='margin-top:14px'><thead><tr><th>Scope</th><th>Members</th><th>Pooled used</th><th>Pooled limit</th><th>Pooled free</th><th>Stranded headroom</th><th>Suggested pool</th></tr></thead><tbody>"
        foreach ($p in $plan) {
            $h += "<tr><td class='name'>$(HtmlEnc $p.Scope)</td><td data-sort='$([int]$p.Members)'>$(HtmlEnc $p.Members)</td><td data-sort='$([int]$p.PoolUsed)'>$(HtmlEnc $p.PoolUsed)</td><td data-sort='$([int]$p.PoolLimit)'>$(HtmlEnc $p.PoolLimit)</td><td data-sort='$([int]$p.PoolAvail)'>$(HtmlEnc $p.PoolAvail)</td><td data-sort='$([int]$p.StrandedHeadroom)'>$(HtmlEnc $p.StrandedHeadroom)</td><td data-sort='$([int]$p.SuggestedPool)'>$(Pill ([string]$p.SuggestedPool) 'ok')</td></tr>"
        }
        $h += "</tbody></table>"

        if ($planMemFile) {
            $pm = Import-Csv $planMemFile.FullName
            $h += "<h3 style='margin-top:22px'>Per-subscription posture</h3>"
            $h += "<div class='sub'>Imbalance is the case for pooling: idle subscriptions hold headroom the busy ones could borrow. Filterable by subscription; click a header to sort.</div>"
            $h += "<div class='tablewrap scroll'><table class='sortable'><thead><tr><th>Subscription</th><th>Used</th><th>Limit</th><th>Utilisation</th><th>Posture</th></tr></thead><tbody>"
            foreach ($m in $pm | Sort-Object @{e={[double]$_.UtilPct};desc=$true}) {
                RegSub $m.SubId $m.SubName
                $pct = [double]$m.UtilPct
                $bcls = if ($pct -ge 80) { 'bad' } elseif ($pct -lt 50) { 'warn' } else { 'ok' }
                $pcls = if ($m.Posture -eq 'tight') { 'bad' } elseif ($m.Posture -eq 'idle') { 'warn' } else { 'ok' }
                $h += "<tr data-sub='$(HtmlEnc $m.SubId)'><td class='name'>$(HtmlEnc $m.SubName)</td><td data-sort='$([int]$m.Used)'>$(HtmlEnc $m.Used)</td><td data-sort='$([int]$m.Limit)'>$(HtmlEnc $m.Limit)</td><td data-sort='$pct'>$(Bar $pct $bcls ("{0}%" -f $pct))</td><td>$(Pill $m.Posture $pcls)</td></tr>"
            }
            $h += "</tbody></table></div>"
        }
        if ($totalRow) {
            AddTile ([string]$totalRow.PoolLimit) 'pooled regional limit' "$($totalRow.Members) candidate subs" ''
            if ([int]$totalRow.StrandedHeadroom -gt 0) {
                AddFlag "Quota Groups opportunity: $($totalRow.StrandedHeadroom) vCPUs of headroom sit idle in under-utilised subscriptions and could flex to busier ones via a pooled quota group." 'warn'
            }
        }
    }

    $h += "<h3 style='margin-top:22px'>What to do next</h3>"
    $h += "<div class='note'><ul style='margin:6px 0 0 18px'>"
    $h += "<li><b>Already pooled?</b> If groups appear above, confirm each member sub and that pooled limits match the workload spread.</li>"
    $h += "<li><b>Not pooled yet?</b> Use the design snapshot to justify a Quota Group: pool the per-sub limits, then redistribute the stranded headroom without per-sub tickets.</li>"
    $h += "<li><b>Access note:</b> reading or creating quota groups needs Reader/Contributor on the management group (the Microsoft.Quota groupQuotas API is management-group scoped). Subscription-only access can model the design but not enumerate live groups.</li>"
    $h += "</ul></div>"
    AddPane 'quotagroups' 'Quota Groups' $h
}

if ($panes.Count -eq 0) { Write-Warning "No recognised CSV exports found in $InputDir. Run the scan scripts first."; return }

# ---- Group related tabs together (Overview is inserted first separately) ---------------------------
# Enablement (SKU/zones) -> Quota (+ Quota Groups) -> Regions -> Resource inventories.
$tabOrder = @('sku','catalogue','zones','quota','quotagroups','regions','aks','flex','zonal','inventory')
$sorted = $panes | Sort-Object @{ e = { $idx = $tabOrder.IndexOf($_.Id); if ($idx -lt 0) { 99 } else { $idx } } }, Title
$panes = New-Object System.Collections.Generic.List[object]
foreach ($p in $sorted) { $panes.Add($p) }

# ---- Overview pane (built last, shown first) ------------------------------------------------------
$ovBody = "<h2>Overview</h2><div class='sub'>Headline metrics across all sections. Use the tabs for detail.</div>"
if ($script:ovTiles.Count) { $ovBody += "<div class='tiles'>" + ($script:ovTiles -join '') + "</div>" }
if ($script:ovFlags.Count) {
    $ovBody += "<h3 style='margin-top:20px'>Attention</h3><div class='flags'>" + ($script:ovFlags -join '') + "</div>"
} else {
    $ovBody += "<h3 style='margin-top:20px'>Attention</h3><div class='flags'><div class='flag ok'>No enablement gaps detected in the scanned subscriptions.</div></div>"
}
$panes.Insert(0, [pscustomobject]@{ Id = 'overview'; Title = 'Overview'; Body = $ovBody })

# ---- Assemble tabs / panes / toolbar --------------------------------------------------------------
$tabBtns = ''; $panesHtml = ''; $i = 0
foreach ($p in $panes) {
    $act = if ($i -eq 0) { ' active' } else { '' }
    $disp = if ($i -eq 0) { 'block' } else { 'none' }
    $tabBtns   += "<button class='tab$act' data-target='tab-$($p.Id)' onclick=`"switchTab(this)`">$(HtmlEnc $p.Title)</button>"
    $panesHtml += "<section id='tab-$($p.Id)' class='tabpane' style='display:$disp'>$($p.Body)</section>"
    $i++
}

$subOpts = "<option value='__all'>All subscriptions ($($script:subNames.Count))</option>"
foreach ($kv in $script:subNames.GetEnumerator()) {
    $subOpts += "<option value='$(HtmlEnc $kv.Key)'>$(HtmlEnc $kv.Value)</option>"
}

$css = @"
:root{--bg:#0f1620;--card:#17202b;--ink:#e8eef5;--muted:#8aa0b5;--line:#243140;--ok:#2ea66b;--warn:#d98a1f;--bad:#cf4747;--accent:#3b82f6}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 'Segoe UI',system-ui,sans-serif}
header{padding:22px 32px 0;border-bottom:1px solid var(--line);background:linear-gradient(180deg,#1b2735,#0f1620);position:sticky;top:0;z-index:20}
header h1{margin:0 0 4px;font-size:22px}header .meta{color:var(--muted);font-size:13px}
header .refresh{margin-top:8px;display:inline-block;font-size:12px;padding:4px 10px;border-radius:6px;border:1px solid var(--line)}
.fresh-ok{background:rgba(45,160,90,.15);border-color:#2da05a !important;color:#7fe0a3}
.fresh-warn{background:rgba(200,160,40,.15);border-color:#c8a028 !important;color:#e8c766}
.fresh-bad{background:rgba(200,70,70,.15);border-color:#c84646 !important;color:#e89090}
.toolbar{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin:14px 0 0}
.toolbar label{font-size:12px;color:var(--muted)}
.toolbar select,.toolbar input{background:#0c131b;color:var(--ink);border:1px solid var(--line);border-radius:7px;padding:7px 10px;font:13px 'Segoe UI',sans-serif;min-width:230px}
.toolbar .hint{font-size:11px;color:var(--muted)}
nav.tabs{display:flex;gap:4px;flex-wrap:wrap;margin-top:14px}
.tab{background:transparent;color:var(--muted);border:none;border-bottom:2px solid transparent;padding:10px 14px;font:600 13px 'Segoe UI',sans-serif;cursor:pointer}
.tab:hover{color:var(--ink)}
.tab.active{color:var(--ink);border-bottom-color:var(--accent)}
main{padding:24px 32px;max-width:1240px;margin:0 auto}
section.tabpane{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px 20px;margin:0 0 22px}
h2{margin:0 0 2px;font-size:17px}h3{font-size:13px;color:var(--muted);margin:0 0 8px;text-transform:uppercase;letter-spacing:.04em}
.sub{color:var(--muted);font-size:12px;margin-bottom:14px}.muted{color:var(--muted);font-weight:400;font-size:11px}
.tablewrap{overflow-x:auto}.tablewrap.scroll{max-height:460px;overflow-y:auto}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);white-space:nowrap}
thead th{position:sticky;top:0;background:var(--card);z-index:1}
th{color:var(--muted);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.03em}
td.name{font-weight:600}td.mono,.mono{font-family:Consolas,monospace;font-size:11px;color:var(--muted);white-space:normal}
.pill{display:inline-block;padding:2px 9px;border-radius:999px;font-size:12px;font-weight:600}
.pill.ok{background:rgba(46,166,107,.16);color:#5fd39b}.pill.warn{background:rgba(217,138,31,.16);color:#f0b65f}.pill.bad{background:rgba(207,71,71,.16);color:#f08585}
.pill.off{background:rgba(120,130,140,.12);color:#8093a3;border:1px solid var(--line)}
.zchip{display:inline-block;padding:2px 7px;margin-right:4px;border-radius:5px;font-size:11px;font-weight:700;font-family:Consolas,monospace}
.zchip.zok{background:rgba(46,166,107,.20);color:#6fe0aa;border:1px solid rgba(45,160,90,.5)}
.zchip.zpart{background:rgba(217,138,31,.20);color:#f0b65f;border:1px solid rgba(200,160,40,.5)}
.zchip.znone{background:rgba(120,130,140,.10);color:#5f6f7d;border:1px solid var(--line)}
.aggbadge{display:inline-block;font-size:11px;font-weight:600;padding:2px 8px;border-radius:999px;background:rgba(59,130,246,.14);color:#8ab4f8;border:1px solid rgba(59,130,246,.35)}
table.sortable th{cursor:pointer;user-select:none}table.sortable th:hover{color:var(--ink)}
table.sortable th.asc::after{content:' \25B2';font-size:9px;color:var(--accent)}
table.sortable th.desc::after{content:' \25BC';font-size:9px;color:var(--accent)}
.bar{position:relative;background:#0c131b;border-radius:6px;height:20px;min-width:120px;overflow:hidden}
.fill{position:absolute;left:0;top:0;bottom:0;border-radius:6px}.fill.ok{background:var(--ok)}.fill.warn{background:var(--warn)}.fill.bad{background:var(--bad)}
.barlbl{position:relative;z-index:1;padding:0 8px;line-height:20px;font-size:11px;font-weight:600}
.tiles{display:flex;gap:14px;flex-wrap:wrap;margin-top:16px}
.tile{background:#0c131b;border:1px solid var(--line);border-radius:10px;padding:12px 16px;min-width:150px}
.tnum{font-size:22px;font-weight:700;color:var(--accent)}.tnum.ok{color:#5fd39b}.tnum.warn{color:#f0b65f}.tnum.bad{color:#f08585}
.tlbl{font-size:12px;margin-top:2px}.tsmall{font-size:11px;color:var(--muted)}
.rollups{display:flex;gap:24px;flex-wrap:wrap}.rollup{flex:1;min-width:260px}
.rrow{display:flex;align-items:center;gap:10px;margin:5px 0}.rk{min-width:120px;font-size:12px}
.flags{display:flex;flex-direction:column;gap:8px}
.note{background:#0c131b;border:1px solid var(--line);border-radius:10px;padding:10px 16px;font-size:13px;margin-top:8px}.note li{margin:4px 0}
.rcards{display:flex;gap:14px;flex-wrap:wrap;margin:14px 0 6px}
.rcard{background:#0c131b;border:1px solid var(--line);border-radius:12px;padding:14px 16px;min-width:240px;flex:1}
.rcard.home{border-color:#3a6ea5;box-shadow:inset 0 0 0 1px rgba(58,110,165,.25)}
.rcard.sec{border-color:#2da05a;box-shadow:inset 0 0 0 1px rgba(46,166,107,.3)}
.rcard.cand{border-color:#c8a028;box-shadow:inset 0 0 0 1px rgba(200,160,40,.2)}
.dlt{font-size:11px;margin-left:6px;font-weight:600}.dlt.up{color:#7fe0a3}.dlt.dn{color:#f0b65f}.dlt.eq{color:var(--muted)}
.rcard-h{font-weight:700;font-size:14px;margin-bottom:2px}.ricon{margin-right:6px}
.rtag{font-size:10px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);border:1px solid var(--line);border-radius:8px;padding:1px 6px;margin-left:8px;vertical-align:middle}
.rverdict{display:inline-block;font-size:12px;font-weight:700;padding:3px 10px;border-radius:8px;margin:6px 0 12px}
.rverdict.ok{background:rgba(46,166,107,.15);color:#7fe0a3}.rverdict.warn{background:rgba(217,138,31,.15);color:#f0b65f}.rverdict.bad{background:rgba(217,70,70,.15);color:#f08585}
.rmetrics{display:flex;flex-direction:column;gap:7px}.rmetrics .rk{display:inline-block;min-width:150px;font-size:12px;color:var(--muted)}
th.colhome,td.colhome{background:rgba(58,110,165,.10)}th.colsec,td.colsec{background:rgba(46,166,107,.10)}th.colcand,td.colcand{background:rgba(200,160,40,.08)}
.skucell{max-width:520px}.skuchip{display:inline-block;background:#13202e;border:1px solid var(--line);border-radius:6px;padding:1px 7px;margin:2px 4px 2px 0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;color:#cfe3f5;white-space:nowrap}
.pzchip{display:inline-block;min-width:34px;text-align:center;border-radius:6px;padding:2px 9px;font-weight:600;font-size:12px;letter-spacing:.3px;border:1px solid transparent}
.pz1{background:rgba(56,139,253,.18);border-color:rgba(56,139,253,.5);color:#79c0ff}
.pz2{background:rgba(63,185,80,.18);border-color:rgba(63,185,80,.5);color:#56d364}
.pz3{background:rgba(219,109,40,.18);border-color:rgba(219,109,40,.5);color:#e3935a}
.pz0{background:#13202e;border-color:var(--line);color:#8b949e}
.flag{padding:9px 12px;border-radius:8px;font-size:13px;border:1px solid var(--line)}
.flag.ok{background:rgba(46,166,107,.12);border-color:#2da05a;color:#7fe0a3}
.flag.warn{background:rgba(217,138,31,.12);border-color:#c8a028;color:#f0b65f}
.flag.bad{background:rgba(207,71,71,.12);border-color:#c84646;color:#f08585}
.empty{color:var(--muted);font-style:italic;padding:10px 0}
footer{padding:18px 32px;color:var(--muted);font-size:12px;border-top:1px solid var(--line)}
"@

$acct = az account show -o json 2>$null | ConvertFrom-Json
# Pull the tenant's friendly name + primary domain from Microsoft Graph (read-only). Falls back
# gracefully if Graph isn't reachable (e.g. restricted directory) - then we use the tenant GUID.
$tenantName = $null; $tenantDomain = $null
try {
    $org = az rest --method get --url "https://graph.microsoft.com/v1.0/organization?`$select=displayName,verifiedDomains" -o json 2>$null | ConvertFrom-Json
    if ($org -and $org.value) {
        $tenantName = $org.value[0].displayName
        $tenantDomain = ($org.value[0].verifiedDomains | Where-Object { $_.isDefault } | Select-Object -First 1).name
    }
} catch { }
if (-not $tenantName -and $acct) { $tenantName = $acct.tenantId }

# Auto-derive the heading from the tenant when no explicit -Title was given (region is NOT pinned in
# the title because the dashboard spans multiple regions; the analysis region is shown in the meta line).
if (-not $Title) {
    $Title = if ($tenantName) { "$tenantName - Azure Capacity & Enablement" } else { 'Azure Capacity & Enablement Dashboard' }
}

$metaBits = @()
if ($tenantName) { $metaBits += "Tenant <b>$(HtmlEnc $tenantName)</b>" + $(if ($tenantDomain) { " ($(HtmlEnc $tenantDomain))" } else { '' }) }
elseif ($acct)  { $metaBits += "Tenant $(HtmlEnc $acct.tenantId)" }
$metaBits += "primary analysis region <b>$(HtmlEnc $Location)</b> for SKU / quota / zone scans"
$metaBits += "multi-region footprint in the Regions tab"
$tenantLine = $metaBits -join ' &middot; '

if ($script:dataTimes.Count -gt 0) {
    $newest = ($script:dataTimes | Measure-Object -Maximum).Maximum
    $oldest = ($script:dataTimes | Measure-Object -Minimum).Minimum
    $refreshLine = "Data collected $($newest.ToString('yyyy-MM-dd HH:mm')) ($(DataAge $newest))"
    if ($oldest -lt $newest.AddMinutes(-5)) {
        $refreshLine += " &middot; oldest source $($oldest.ToString('yyyy-MM-dd HH:mm')) ($(DataAge $oldest))"
    }
    $staleHrs = ((Get-Date) - $newest).TotalHours
    $freshCls = if ($staleHrs -lt 12) { 'fresh-ok' } elseif ($staleHrs -lt 48) { 'fresh-warn' } else { 'fresh-bad' }
} else {
    $refreshLine = 'No source data files found in input folder'
    $freshCls = 'fresh-bad'
}

$js = @"
function switchTab(btn){
  document.querySelectorAll('.tab').forEach(function(t){t.classList.remove('active');});
  document.querySelectorAll('.tabpane').forEach(function(p){p.style.display='none';});
  btn.classList.add('active');
  var pane=document.getElementById(btn.dataset.target);
  if(pane){pane.style.display='block';}
}
function filterSub(v){
  document.querySelectorAll('tr[data-sub]').forEach(function(r){
    r.style.display=(v==='__all'||r.dataset.sub===v)?'':'none';
  });
  // mark panes whose every data-sub row is hidden
  document.querySelectorAll('.tabpane').forEach(function(p){
    var rows=p.querySelectorAll('tr[data-sub]');
    if(rows.length===0)return;
    var anyVisible=Array.prototype.some.call(rows,function(r){return r.style.display!=='none';});
    var note=p.querySelector('.emptynote');
    if(!anyVisible){
      if(!note){note=document.createElement('div');note.className='empty emptynote';note.textContent='No rows for the selected subscription in this view.';p.appendChild(note);}
    } else if(note){note.remove();}
  });
}
function filterCat(v){
  v=(v||'').toLowerCase();
  document.querySelectorAll('#catTable tbody tr').forEach(function(r){
    r.style.display=r.textContent.toLowerCase().indexOf(v)>-1?'':'none';
  });
}
function filterInv(v){
  v=(v||'').toLowerCase();
  document.querySelectorAll('#invTypeTable tbody tr').forEach(function(r){
    r.style.display=r.textContent.toLowerCase().indexOf(v)>-1?'':'none';
  });
}
function cellVal(td){
  if(!td)return '';
  var ds=td.getAttribute('data-sort');
  if(ds!==null&&ds!==''){var n=parseFloat(ds);return isNaN(n)?ds.toLowerCase():n;}
  var t=(td.textContent||'').trim();
  var num=parseFloat(t.replace(/[, %]+/g,''));
  return (t!==''&&!isNaN(num)&&/^[-+]?[\d.,]+%?$/.test(t))?num:t.toLowerCase();
}
function sortTable(th){
  var table=th.closest('table'), tbody=table.tBodies[0];
  if(!tbody)return;
  var idx=Array.prototype.indexOf.call(th.parentNode.children,th);
  var asc=!th.classList.contains('asc');
  th.parentNode.querySelectorAll('th').forEach(function(h){h.classList.remove('asc','desc');});
  th.classList.add(asc?'asc':'desc');
  var rows=Array.prototype.slice.call(tbody.querySelectorAll('tr'));
  rows.sort(function(a,b){
    var x=cellVal(a.children[idx]), y=cellVal(b.children[idx]);
    if(typeof x==='number'&&typeof y==='number')return asc?x-y:y-x;
    return asc?String(x).localeCompare(String(y)):String(y).localeCompare(String(x));
  });
  rows.forEach(function(r){tbody.appendChild(r);});
}
document.addEventListener('DOMContentLoaded',function(){
  document.querySelectorAll('table.sortable thead th').forEach(function(th){
    th.addEventListener('click',function(){sortTable(th);});
  });
});
"@

$html = @"
<!doctype html><html lang='en'><head><meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>$(HtmlEnc $Title)</title><style>$css</style></head>
<body>
<header>
<h1>$(HtmlEnc $Title)</h1>
<div class='meta'>$tenantLine</div>
<div class='refresh $freshCls'>&#x21bb; $refreshLine &middot; <span class='muted'>dashboard rendered $(Get-Date -Format 'yyyy-MM-dd HH:mm')</span></div>
<div class='toolbar'>
  <label for='subFilter'>Subscription</label>
  <select id='subFilter' onchange='filterSub(this.value)'>$subOpts</select>
  <span class='hint'>filters every per-subscription table at once</span>
</div>
<nav class='tabs'>$tabBtns</nav>
</header>
<main>
$panesHtml
</main>
<footer>Generated by the Azure Capacity &amp; Enablement Toolkit &middot; read-only (Reader access) &middot; quota does not guarantee capacity until deployed.</footer>
<script>$js</script>
</body></html>
"@

$html | Set-Content $OutPath -Encoding UTF8
Write-Host "Dashboard -> $OutPath" -ForegroundColor Green
