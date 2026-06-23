# Commands reference

Every script lives in `scripts/` and dot-sources `scripts/Common.ps1`. Run them from the repo
root (e.g. `.\scripts\Get-UsedSkus.ps1 …`).

## Common parameters

Most scripts accept:

- `-Location <region>` — e.g. `norwayeast`.
- `-SubscriptionIds <guid[]>` **or** `-SubscriptionCsv <path>` — omit both to scan **all visible**
  subscriptions. The CSV needs a `SubId` column (and optionally `Name`).
- `-OutPath` / `-OutDir` — where results are written (defaults to `output/`).

`Common.ps1` exposes the shared helpers: `Get-ScriptDir`, `Get-DefaultOutDir`, `Assert-AzLogin`,
`Resolve-Subscriptions` (explicit ids, a CSV, or *all visible*), `Get-ComputeSkus`,
`Resolve-SkuStatus` (parses `restrictions[]` → Regional/Zone status).

## Scenario → script map

| You need to… | Run | Key output |
|---|---|---|
| **Discover which SKUs are actually in use** (no guessing) | `Get-UsedSkus.ps1 [-SubscriptionCsv …] [-Top N]` | `used-skus-…csv` (VM/VMSS/AKS counts + family + zones) + `capacity-config.json` |
| **Complete sight: every family's enablement + quota + in-use** | `Get-SkuCatalogue.ps1 [-SubscriptionCsv …] [-OnlyRelevant]` | `sku-catalogue-…csv` (per-family coverage + summed quota + InUse) + `regional-totals-…csv` (Total Regional & Spot vCPUs per sub) |
| Check if SKU(s) are regional + zonal enabled across subs | `Scan-SkuEnablement.ps1 -Location <r> -Skus <list> [-SubscriptionCsv …]` | `<sku>_reg` = Enabled/BLOCKED, `<sku>_zones` = open logical zones |
| Resolve logical→physical zone mapping (per sub!) | `Get-ZoneMappings.ps1 -Location <r> [-SubscriptionCsv …]` | `logical1/2/3`, `Pattern` |
| Validate quota / headroom per family | `Get-QuotaUsage.ps1 -Location <r> -Families <list>` | `<fam>_used/_limit/_avail` + totals |
| Inventory AKS clusters tenant-wide | `Get-AksInventory.ps1 [-Location <r>]` | name, sub, rg, region, state, k8s, nodePools, nodeCount, node SKUs |
| **Inventory on-demand capacity reservations** (the guaranteed-capacity construct) | `Get-CapacityReservations.ps1 [-Location <r>] [-SubscriptionCsv …]` | `capacity-reservations-…csv` (per reservation: SKU, region, zone, reserved vs consumed, idle / over-allocated / at-capacity flags) |
| Review database (PostgreSQL/MySQL) zone + HA resilience | `Get-FlexServerZones.ps1 [-Location <r>]` | per-server SKU, tier, zone, HA mode, standby zone; single-zone flag |
| Sweep all zone-pinned resources for single-zone gaps | `Get-ZonalResourceInventory.ps1 [-Location <r>]` | every resource with a zone, by type, with SingleZone flag |
| **Complete overview: every resource type × sub × region** | `Get-ResourceInventory.ps1 [-SubscriptionIds …]` | `resource-inventory-…csv` (type, sub, region, count, zone-pinned count) |
| See which regions you run in + compare candidate regions | `Get-RegionFootprint.ps1 [-EvaluateRegions <list>] [-SubscriptionCsv …]` | per-region resource/AKS counts + `region-sku-comparison-…csv` + `region-quota-comparison-…csv` |
| **Score Spot allocation likelihood** for SKUs in candidate regions/zones ⚠️ needs Compute Recommendations Role | `Get-SpotPlacementScore.ps1 [-ConfigPath …] [-DesiredLocations <list>] [-DesiredCount N]` | `spot-placement-…csv` (High/Medium/Low per SKU×region×zone + `IsQuotaAvailable`, timestamped) |
| Draft a support ticket for Regional + Zonal enablement | `New-EnablementRequest.ps1 -Location <r> -Skus <list> [-SubscriptionCsv …]` | `enablement-request-…md` (paste-ready) + findings CSV |
| Read shared quota-group pools: type + members + pooled limits | `Get-QuotaGroups.ps1 [-Regions <list>] [-ManagementGroupId <id>]` | `quota-groups-…csv` (group type, member count, limits-set flag) + `quota-group-members-…csv` + `quota-group-limits-…csv` |
| **Model a pooled-quota design** (subscription Reader only) | `Get-QuotaGroupPlan.ps1 [-HeadroomFactor 1.3]` | `quota-group-plan-…csv` (pooled used/limit/free + stranded headroom + suggested pool) + `…-members-…csv` (per-sub posture) |
| Turn a quota report into a deploy-ready design ⚠️ PS7 | `New-QuotaGroupConfig.ps1 -SkeletonConfig <json> -QuotaReportCsv <csv> -OutputConfig <json>` | populated quota-groups config (auto-detects toolkit `quota-usage` CSV or external azure-quota-reports CSV) |
| **Provision** quota groups (the one opt-in write tool) ⚠️ PS7 | `Deploy-QuotaGroups.ps1 -ConfigPath <json> [-Action <phase>] [-WhatIf]` | creates groups, adds members, requests pooled limits, allocates quota — idempotent, `SupportsShouldProcess` |
| Watch for an enablement to land | `Watch-SkuEnablement.ps1 -SubscriptionIds … -Sku … [-WatchResourceIds <aksId>]` | rolling CSV log + error alerts |
| Render a visual HTML dashboard | `New-CapacityDashboard.ps1 [-Location <r>] [-SecondaryRegion <r>]` | self-contained `capacity-dashboard-…html` |
| **Try it offline — generate synthetic demo data** (no Azure access) | `New-DemoDataset.ps1 [-OutDir <path>] [-Company <name>] [-Seed <int>]` | a full set of fictional CSVs you can render with the dashboard |
| Produce a full status report | `New-CapacityReport.ps1 [-ConfigPath capacity-config.json] -Location <r> [-SecondaryRegion <r> -IncludeAks -IncludeZonal -IncludeCatalogue -IncludeInventory -IncludeQuotaGroups -Dashboard -EnablementRequest -EvaluateRegions <list>]` | combined CSV + Markdown (+ HTML / request / region compare / zonal resilience / full SKU catalogue / inventory / quota groups) |

## The orchestrator: `New-CapacityReport.ps1`

The recommended entry point. It runs the core scans, joins them into one CSV + a Markdown summary,
and optionally adds the dashboard, enablement request and the various `-Include*` panes.

| Parameter | Purpose |
|---|---|
| `-ConfigPath <path>` | Use a `capacity-config.json` (from `Get-UsedSkus.ps1`) for SKUs/families/subs. |
| `-Location <region>` | Home/primary region (default `norwayeast`). |
| `-SecondaryRegion <region>` | Your chosen failover/migration target; drives the tiered readiness cards. Auto-picked if omitted. |
| `-EvaluateRegions <list>` | Extra candidate regions to score. |
| `-IncludeAks` | Append tenant-wide AKS inventory. |
| `-IncludeZonal` | Append the zone-pinned resource sweep. |
| `-IncludeCatalogue` | Append the full SKU catalogue (complete sight). |
| `-IncludeInventory` | Append the every-resource overview. |
| `-IncludeQuotaGroups` | Read existing quota groups + model a pooled-quota design. |
| `-Dashboard` | Generate the HTML dashboard. |
| `-EnablementRequest` | Draft the enablement support ticket. |

Explicit `-Skus` / `-Families` / `-SubscriptionIds` always override the config file.

## Raw command reference

Use these directly if you can't or don't want to run the scripts. All confirmed live with Reader.

**SKU restrictions (regional + zonal blocks):**

```bash
az rest --method get --url "https://management.azure.com/subscriptions/<SUB>/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location eq 'norwayeast'"
```

Parse each SKU's `restrictions[]`:

- `type == "Location"` → **regional block** (SKU not enabled in the region at all).
- `type == "Zone"` → `restrictionInfo.zones` lists the **blocked logical zones**.
- `locationInfo[0].zones` = the logical zones the SKU is *offered* in.

**Logical → physical zone mapping (differs per subscription!):**

```bash
az rest --method get --url "https://management.azure.com/subscriptions/<SUB>/locations?api-version=2022-12-01"
# → value[?name=='norwayeast'].availabilityZoneMappings → {logicalZone, physicalZone}
# e.g. logical "1" → "norwayeast-az2"
```

**Quota / usage per family:**

```bash
az vm list-usage -l norwayeast -o table
# name.value e.g. standardBsv2Family ; currentValue / limit
```

**Spot placement score (allocation-likelihood; needs the Compute Recommendations Role):**

```bash
az rest --method post \
  --url "https://management.azure.com/subscriptions/<SUB>/providers/Microsoft.Compute/locations/norwayeast/placementScores/spot/generate?api-version=2025-06-05" \
  --headers "Content-Type=application/json" \
  --body '{"availabilityZones":true,"desiredCount":10,"desiredLocations":["norwayeast"],"desiredSizes":[{"sku":"Standard_D4s_v5"}]}'
# → placementScores[]: { region, availabilityZone, sku, score (High/Medium/Low/DataNotFoundOrStale/RestrictedSkuNotAvailable), isQuotaAvailable }
```

**AKS inventory (Resource Graph — paginate, project raw, aggregate locally):**

```bash
az graph query --first 1000 -q "resources | where type =~ 'microsoft.containerservice/managedclusters' | project name, subscriptionId, resourceGroup, location, provState=tostring(properties.provisioningState), k8s=tostring(properties.kubernetesVersion), pools=tostring(properties.agentPoolProfiles) | order by subscriptionId asc"
# loop --skip 0,1000,… until rows >= .total_records
```

**Quota groups (management-group scoped — use ARM REST, not `az account management-group list`):**

```bash
az rest --method get --url "https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2021-04-01"
# Pooled limits require a location filter:
az rest --method get --url "https://management.azure.com/providers/Microsoft.Management/managementGroups/<MG>/providers/Microsoft.Quota/groupQuotas/<GROUP>/resourceProviders/Microsoft.Compute/groupQuotaLimits?api-version=2023-06-01-preview&\$filter=location eq 'norwayeast'"
```

**Activity-log error scan (watch a reconcile / allocation failure):**

```bash
az monitor activity-log list --resource-id <RESOURCE_ID> --start-time 2026-06-19T00:00:00Z \
  --query "[?level=='Error' || level=='Critical' || status.value=='Failed']"
```

See [Troubleshooting & FAQ](troubleshooting.md) for the gotchas behind several of these.

## Preview the dashboard offline (synthetic demo data)

Want to see what the dashboard looks like without an Azure tenant, login, or any real data?
`New-DemoDataset.ps1` generates a complete, self-consistent **fictional** dataset (default
company "Zava Inc") from a deterministic seed — it reads nothing from Azure and produces the
same CSV schemas the collector scripts do.

```powershell
# 1) Generate the demo CSVs (default -> output/)
.\scripts\New-DemoDataset.ps1 -OutDir .\demo-output

# 2) Render the dashboard from them (no az login needed)
.\scripts\New-CapacityDashboard.ps1 -InputDir .\demo-output `
  -Location norwayeast -SecondaryRegion swedencentral `
  -Title "Zava Inc - Azure Capacity & Enablement" -OutPath .\demo-dashboard.html
```

The generated universe deliberately exercises a range of dashboard states: SKU enablement
blocks and availability-zone gaps, near-capacity quota (general-purpose + burstable families),
a GPU capacity crunch (NCads H100 v5), a regional vCPU ceiling under pressure, one actively
pooled quota group and one that is not, AKS clusters in `Failed` / `Upgrading` / `Canceled`
states, and zone-redundant HA flexible servers alongside single-zone ones.

| Parameter | Purpose |
|---|---|
| `-OutDir <path>` | Where to write the CSVs (default `output/`). |
| `-Company <name>` | Fictional company display name (default `Zava Inc`). |
| `-Prefix <token>` | Short token used in resource/subscription names (default `Zava`). |
| `-Location` / `-SecondaryRegion` | Primary / comparison regions to populate. |
| `-Seed <int>` | Reproducibility seed — same seed produces identical files. |

Because the data is invented, it is safe to commit, screenshot or share. (Real `output/` data is
git-ignored.)
