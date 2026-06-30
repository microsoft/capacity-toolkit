# Concepts

Understand these before you read the numbers — they are the difference between a correct and a
dangerously confident answer.

## Quota ≠ capacity

This is the single most important idea in the toolkit.

An approved [**quota**](https://learn.microsoft.com/en-us/azure/quotas/view-quotas) only raises the
*ceiling* on how many cores you are *allowed* to allocate. It does **not** reserve physical capacity —
the capacity is only held once it is actually *consumed*. A region can show full quota headroom and
still refuse to place your VMs because the datacentre is constrained.

Practical consequences:

- A green "quota available" cell is **not** a guarantee you can deploy there tomorrow.
- Always validate a target region with a **small test deployment** before advising a migration or
  failover plan.
- State it plainly in any report: "N cores of quota granted" ≠ "N cores reserved".
- If you need a *guarantee* that capacity is held, that is
  [on-demand capacity reservation](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-overview),
  which is a separate construct from quota. `Get-CapacityReservations.ps1` inventories what you have
  actually reserved (SKU, region, zone) and how much of it is consumed vs sitting idle — closing the
  loop on the one construct that truly holds capacity. Note it is **not** the same as a
  [Reserved Instance](https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations),
  which is a billing discount with no capacity guarantee.

## Placement score — the closest signal to "will it actually deploy?"

Because quota does not prove capacity, the one *programmatic* signal Azure offers is the
[**Spot Placement Score**](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/spot-placement-score):
for a given VM size, region/zone and desired instance count it returns `High` / `Medium` / `Low`,
derived from real Spot allocation probability. `Get-SpotPlacementScore.ps1` collects it.

Read it carefully:

- It scores **Spot** capacity. There is **no public placement-score API for on-demand** VMs — treat a
  Spot score as a *proxy* for regional capacity pressure (Spot is squeezed first), never a guarantee
  for on-demand allocation.
- A score is valid **only at the moment it is requested** — Spot shifts intra-day. The toolkit
  timestamps every row; never present a stale score as current.
- `High` / `Medium` still does **not** guarantee allocation or freedom from eviction — validate a
  target with a small test deployment (the rule that never changes).
- The API also returns an `isQuotaAvailable` flag per result — a handy cross-check against the
  toolkit's own family-quota numbers.

This needs the read-only built-in **"Compute Recommendations Role"** (a single
`Microsoft.Compute/locations/placementScores/generate/action`, no mutations) in addition to Reader.

## AKS scale-headroom — will a node pool hit a quota wall?

Quota is consumed when nodes are *created*, so a node pool with
[**cluster autoscaler**](https://learn.microsoft.com/en-us/azure/aks/cluster-autoscaler) enabled can
silently outgrow its VM-family [vCPU quota](https://learn.microsoft.com/en-us/azure/virtual-machines/quotas)
on a scale-out — a risk that usually only surfaces during an incident. `Get-AksScaleHeadroom.ps1`
joins three reads the toolkit already does — node pools (Resource Graph), `Microsoft.Compute/skus`
(size → family + vCPUs) and `az vm list-usage` (per-family used/limit) — to compute the *incremental*
vCPUs each pool needs to reach its `maxCount`, aggregates per family, and flags families that cannot
fully scale. Two rules it bakes in: pools in the same family are **summed before** the comparison, and
**Spot pools draw on the separate regional low-priority pool**, never the regular family quota. As
always, clearing quota is necessary but not sufficient — it is not guaranteed physical capacity.

## Network quota — the silent deployment blocker

VM-family vCPU quota gets all the attention, but a deployment can fail just as hard when a
subscription runs out of **networking** quota in a region: no more
[Public IP Addresses](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#networking-limits),
Network Interfaces, Load Balancers or NAT gateways means no new VMs, regardless of compute headroom.
`Get-NetworkQuota.ps1` reads the regional `Microsoft.Network/locations/{loc}/usages` API (the data
behind `az network list-usages`) and reports every counter's used / limit / available with
`NearLimit` / `AtLimit` flags. Two honesty rules it bakes in: counters the API returns with the
placeholder `2147483647` limit are marked `IsUnbounded` (no fabricated percentage), and per-VNet
sub-counters (`…PerVirtualNetwork`) are flagged `PerResourceScope` so they are not mistaken for a
saturation scan of every VNet. As everywhere else in the toolkit, quota cleared is not capacity
guaranteed.

## App Service quota — plan limits and scale-out ceilings

App Service capacity pressure is invisible to the compute-vCPU view: an App Service Plan can hit its
per-region / per-resource-group plan limit, or a dedicated plan can reach its **tier scale-out
instance ceiling** (Basic 3, Standard 10, Premium v1 20, Premium v2/v3/v4 30, Isolated 100), and a
deploy or scale-out fails. `Get-AppServiceQuota.ps1` reads three sources the platform already exposes —
App Service Plans (Resource Graph), the subscription/region
[`Microsoft.Web/locations/{loc}/usages`](https://learn.microsoft.com/en-us/rest/api/appservice/get-usages-in-location/list)
API, and per-plan
[`serverfarms/{name}/usages`](https://learn.microsoft.com/en-us/rest/api/appservice/app-service-plans/list-usages) —
and emits three row scopes: `SubscriptionRegion`, `AppServicePlan`, and an `InventoryDerived` row that
compares each plan's current instance count to its documented ceiling. True API-reported quota rows
(`IsTrueQuota=True`) are kept distinct from documented/inventory rows via the `LimitBasis` column, and
SKUs without a fixed ceiling (Consumption, Flex Consumption) are flagged `HasUnknownLimit` rather than
given a fabricated limit. The standing caveat applies: quota is not guaranteed physical capacity.

## Storage quota — account count, and why disk capacity is inventory not quota

The number of **storage accounts per subscription per region** is a real, adjustable Azure quota
([default 250](https://learn.microsoft.com/en-us/azure/storage/common/scalability-targets-standard-account))
and a common, silent blocker for storage-heavy or multi-tenant platforms. `Get-StorageQuota.ps1`
reads the regional storage usage API (behind `az storage account show-usage`) and reports
`StorageAccounts` with Used / Limit / Available / `PctUsed` and an OK / NearLimit / AtLimit flag.
Managed-disk *capacity* is a different story: Azure exposes **no general per-subscription managed-disk
capacity quota usage API** the way it does for compute vCPUs, so the optional
`-IncludeDiskCapacityInventory` rows sum provisioned `diskSizeGB` from Resource Graph and are labelled
`IsQuota=False` / `Informational` with a blank limit — they are an inventory aid, never a compliance
signal. (Disk SKU *availability* is `Microsoft.Compute/skus` metadata; per-disk size maxima are
documented per-resource constants.) Quota cleared is still not capacity guaranteed.

## PaaS quota — true quota for SQL, honest inventory for Cosmos

The data-PaaS tier splits cleanly into "has a real quota API" and "doesn't". **Azure SQL** exposes
genuine quota through the `Microsoft.Sql` usage APIs — subscription/region counters (`ServerQuota`,
`VCoreQuota`, `RegionalVCoreQuotaForSQLDBAndDW`, Managed Instance vCore quotas) and per-logical-server
DTU quota (`server_dtu_quota`) — so `Get-PaasQuota.ps1` emits each row as true quota
(`IsInformational=False`). It deliberately classifies free-tier / promotional **countdown** counters
(`*Free*`, `*DaysLeft`) as informational, because a "full" countdown is healthy, not exhausted —
flagging those as at-limit would be a false alarm. **Cosmos DB** is the opposite: there is no verified
subscription/region RU/s quota usage API, so the script reports the per-account configured
`totalThroughputLimit` (a real limit only when positive) and, optionally, provisioned RU/s per
database and container as **inventory** — never a fabricated quota. None of this feeds the
compute-only quota-groups feature. As always, quota is not guaranteed physical capacity.

## Subscription &amp; resource-group structural limits — documented, not a usage API

Many "quota exceeded" surprises are not capacity quotas at all — they are fixed **ARM structural
limits** on object counts: 980 resource groups per subscription, 800 resources per resource group
per type, 50 tags per scope, 800 subscription deployments per location (and 10 distinct locations),
4000 role assignments per subscription. Azure exposes no per-subscription *usage* API for these, so
`Get-SubscriptionLimits.ps1` counts the live objects (via Azure Resource Graph and the ARM control
plane) and compares each count against the value **documented on Microsoft Learn**. Because the
limit is a documented constant rather than an API reading, every row carries
`LimitSource=MicrosoftLearnDocumented`, `IsTrueQuota=False` and a `DocReference` link — most of
these limits are fixed and cannot be raised by a quota request, and none of them feed the
compute-only quota-groups feature. High-cardinality checks (resources per RG/type, tag density)
emit only near/at-limit rows; region inventory is purely informational. A structural limit is a
ceiling on object count, not a guarantee of physical capacity.

## Regional vs zonal enablement

A SKU's availability has **two independent signals**:

- **Regional enablement** — is the SKU offered in the region at all?
- **Zonal enablement** — within the region, which [**availability zones**](https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview) is it open in?

A SKU can be open regionally but blocked in specific zones (or the reverse). Reporting only
"enabled" without qualifying the zones is misleading. The toolkit always reports both — e.g. one
family open in all 3 zones while another is open in only 2.

Under the hood, each SKU carries a `restrictions[]` array:

- `type == "Location"` → the SKU is **not enabled** in the region.
- `type == "Zone"` → `restrictionInfo.zones` lists the **blocked logical zones**.
- `locationInfo[0].zones` → the logical zones the SKU is *offered* in.

## Logical zones are per-subscription

Availability zones are presented to each subscription as **logical** numbers `1`, `2`, `3` — but
those logical numbers map to **different physical datacentres** in each subscription. Logical
zone "1" in subscription A may be a different physical zone than logical "1" in subscription B.
(Microsoft documents this as
[physical and logical availability zones](https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview#physical-and-logical-availability-zones).)

Why it matters:

- Never assume zone alignment across subscriptions. A "zone-redundant" design spread across
  logical 1/2/3 in several subs could still be sitting in the same physical datacentre.
- Resolve the mapping **per subscription** (`Get-ZoneMappings.ps1`) before reasoning about
  co-location or spread.
- In any report or support-facing message, quote the **physical** AZ labels (AZ01/AZ02/AZ03),
  not the logical zone numbers. `New-EnablementRequest.ps1` does this translation for you, and the
  dashboard colours its chips by the physical zone so the scramble is visible at a glance.

## One SKU restriction governs every VM-backed service

`Microsoft.Compute/skus` restrictions (and the
[`az vm list-usage` family quota](https://learn.microsoft.com/en-us/azure/virtual-machines/quotas))
apply not just to VMs / VM Scale Sets / AKS, but to **Batch, Service Fabric, Azure ML compute,
Databricks, Azure Red Hat OpenShift, App Service Environment, Spring Apps** and more — they all draw
from the same [SKU](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/overview)/quota
pool. Enabling a SKU family unblocks all of them at once.

The notable exception is **database Flexible Servers** (PostgreSQL / MySQL), which have their own
compute tiers — **Burstable** (B-series), **General Purpose** (D-series) and **Memory Optimized**
(E-series) — plus an independent availability-zone selection. `Get-FlexServerZones.ps1` covers them
and reports whatever SKU and tier each server actually runs, so it is not limited to a fixed list.
See the reliability guides for
[PostgreSQL](https://learn.microsoft.com/en-us/azure/reliability/reliability-database-postgresql) and
[MySQL](https://learn.microsoft.com/en-us/azure/reliability/reliability-database-mysql) Flexible
Server.

## Complete sight — what the toolkit covers

The toolkit gives a **complete view of VM compute capacity**, which is what regional/zonal
enablement and quota actually gate:

- **Every VM SKU family in the region**, not just the ones you use. `Get-SkuCatalogue.ps1`
  enumerates the whole catalogue and tags each family **Enabled / blocked**, its **open zones**, its
  **quota** (used / limit / available), and whether it is **in use** today. That surfaces three
  things a used-SKU-only view misses:
    - **enabled-but-unused families** — latent head-room you already hold,
    - **blocked families** — what a support request must cover,
    - **in-use families low on quota** — risk.
- **The umbrella limits** — `Total Regional vCPUs` (`cores`) and
  [`Spot/Low-priority vCPUs`](https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms)
  (`lowPriorityCores`) per subscription, which cap you independently of any single family.
- **Zonal footprint of non-compute resources** — `Get-ZonalResourceInventory.ps1` (disks, public
  IPs, NAT gateways, app gateways, Kusto…) and `Get-FlexServerZones.ps1`.

Intentionally **out of scope** (different quota providers — add later if needed):
**network quota** (public IPs, LB rules, NAT gateways), **storage account limits**, and
**PaaS-specific quotas** (App Service plans, Cosmos RU/s, SQL DTU/vCore). The pattern is identical —
enumerate provider usages and join to enablement — so these slot in as future `Get-NetworkQuota.ps1`
/ `Get-StorageQuota.ps1` scripts.

## Region readiness model

When evaluating where a workload can live, the dashboard ranks
[regions](https://learn.microsoft.com/en-us/azure/reliability/regions-overview) as a **tiered
hierarchy** rather than a flat list:

1. **Primary (home)** — your current region (`-Location`).
2. **Chosen secondary** — your stated failover / migration target (`-SecondaryRegion`).
   If you don't name one, the strongest candidate is auto-picked.
3. **Other candidates** — regions you ask it to score (`-EvaluateRegions`).
4. **Footprint elsewhere** — regions where you already run something.

Each tier shows home-baseline **deltas** (▲ better / ▼ worse / = same) and a *capacity-honest*
verdict (e.g. `Viable target`, `Viable · zone gaps`, `Enabled · no quota`, `Weak · not fully
enabled`). Because **quota ≠ capacity**, the verdicts are deliberately cautious and always paired
with the recommendation to validate with a test deployment.

## Quota groups (allocation groups)

A **quota group** pools several subscriptions under a management group so they can share a quota
allocation (the [Azure Quota Groups](https://learn.microsoft.com/en-us/azure/quotas/quota-groups)
feature). Two things to know:

- A group can enrol dozens of subscriptions (`groupType: AllocationGroup`) yet have **no pooled
  limit set** in any region — in which case members still draw on their own per-subscription quota.
  *"Has a quota group" ≠ "is actively pooling capacity."* Always report the limits-set flag, not
  just the group's existence.
- When you only have subscription Reader (not the pooled-limit data), `Get-QuotaGroupPlan.ps1`
  **models** a pooled design from per-sub quota CSVs: pooled used/limit/free, **stranded headroom**
  (idle capacity in under-utilised subs) and a suggested pool size.

## Worked example (reference scenario)

A representative shape of the situation this toolkit is built to analyse — names and numbers removed:

- **Region:** a single constrained region. **Constraint:** specific VM SKU families limited by
  capacity for subscriptions created after a cut-off date.
- **Enablement scope:** a few dozen subscriptions; a pooled core grant distributed via **quota
  groups**, required to be split across two SKU families (capacity for only one was available).
- **Finding:** regional enablement ≠ zonal enablement — one family was open in all 3 zones, another
  in only 2; a handful of subscriptions had been missed entirely. The cross-region check showed
  alternative regions with full multi-zone enablement, informing a relocation conversation.
- **AKS footprint:** the great majority of clusters ran the constrained (smaller) SKU family — which
  is why *enabling* that family was the critical path rather than forcing a migration.
- **Recovery:** clusters already in a **Failed** state did not self-heal when the SKU was enabled;
  each needed an explicit reconcile afterwards (see [Troubleshooting & FAQ](troubleshooting.md)).

## Further reading — official Microsoft documentation

Authoritative references for the concepts above (Microsoft Learn):

| Topic | Microsoft Learn |
|---|---|
| Availability zones (physical vs logical) | [What are Azure availability zones?](https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview) |
| Azure regions | [What are Azure regions?](https://learn.microsoft.com/en-us/azure/reliability/regions-overview) |
| VM vCPU quotas | [vCPU quotas — Azure Virtual Machines](https://learn.microsoft.com/en-us/azure/virtual-machines/quotas) |
| Viewing & managing quotas | [View quotas — Azure Quotas](https://learn.microsoft.com/en-us/azure/quotas/view-quotas) |
| Quota ≠ capacity (guaranteed capacity) | [On-demand capacity reservation](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-overview) |
| VM sizes / SKU families | [Virtual machine sizes overview](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/overview) |
| Spot / low-priority capacity | [Azure Spot Virtual Machines](https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms) |
| Quota Groups (pooled quota) | [Share quota across subscriptions with Azure Quota Groups](https://learn.microsoft.com/en-us/azure/quotas/quota-groups) |
| AKS reliability & availability zones | [Reliability in Azure Kubernetes Service](https://learn.microsoft.com/en-us/azure/reliability/reliability-aks) |
| PostgreSQL Flexible Server reliability / HA | [Reliability in Azure Database for PostgreSQL](https://learn.microsoft.com/en-us/azure/reliability/reliability-database-postgresql) |
| MySQL Flexible Server reliability / HA | [Reliability in Azure Database for MySQL](https://learn.microsoft.com/en-us/azure/reliability/reliability-database-mysql) |
| Azure Resource Graph (inventory queries) | [Azure Resource Graph overview](https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview) |
