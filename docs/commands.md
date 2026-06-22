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
| Review database (PostgreSQL/MySQL) zone + HA resilience | `Get-FlexServerZones.ps1 [-Location <r>]` | per-server SKU, tier, zone, HA mode, standby zone; single-zone flag |
| Sweep all zone-pinned resources for single-zone gaps | `Get-ZonalResourceInventory.ps1 [-Location <r>]` | every resource with a zone, by type, with SingleZone flag |
| **Complete overview: every resource type × sub × region** | `Get-ResourceInventory.ps1 [-SubscriptionIds …]` | `resource-inventory-…csv` (type, sub, region, count, zone-pinned count) |
| See which regions you run in + compare candidate regions | `Get-RegionFootprint.ps1 [-EvaluateRegions <list>] [-SubscriptionCsv …]` | per-region resource/AKS counts + `region-sku-comparison-…csv` + `region-quota-comparison-…csv` |
| Draft a support ticket for Regional + Zonal enablement | `New-EnablementRequest.ps1 -Location <r> -Skus <list> [-SubscriptionCsv …]` | `enablement-request-…md` (paste-ready) + findings CSV |
| Read shared quota-group pools: type + members + pooled limits | `Get-QuotaGroups.ps1 [-Regions <list>] [-ManagementGroupId <id>]` | `quota-groups-…csv` (group type, member count, limits-set flag) + `quota-group-members-…csv` + `quota-group-limits-…csv` |
| **Model a pooled-quota design** (subscription Reader only) | `Get-QuotaGroupPlan.ps1 [-HeadroomFactor 1.3]` | `quota-group-plan-…csv` (pooled used/limit/free + stranded headroom + suggested pool) + `…-members-…csv` (per-sub posture) |
| Watch for an enablement to land | `Watch-SkuEnablement.ps1 -SubscriptionIds … -Sku … [-WatchResourceIds <aksId>]` | rolling CSV log + error alerts |
| Render a visual HTML dashboard | `New-CapacityDashboard.ps1 [-Location <r>] [-SecondaryRegion <r>]` | self-contained `capacity-dashboard-…html` |
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
