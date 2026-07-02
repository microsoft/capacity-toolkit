# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Documentation site** (<https://microsoft.github.io/capacity-toolkit/>) — the existing `docs/`
  guides are now published as a searchable GitHub Pages site using the
  [`just-the-docs`](https://just-the-docs.com/) Jekyll theme (the same approach as the
  [FinOps toolkit](https://microsoft.github.io/finops-toolkit/)). Pages carry navigation
  front-matter, the site is served from `/docs` on `main`, and a `docs/Gemfile` supports local
  preview (`bundle exec jekyll serve`). No content moved — the Markdown remains the source of truth.

## [0.2.0] - 2026-07-02

### Added

- **Continuous integration** (`.github/workflows/ci.yml`) — runs on every push and pull
  request to `main`: parses every script under **Windows PowerShell 5.1** (the toolkit's
  compatibility target), scans for PowerShell 7-only syntax, and runs **PSScriptAnalyzer**
  against a checked-in `PSScriptAnalyzerSettings.psd1`. The build fails on any parse error
  or Error-severity finding; Warnings are surfaced as annotations for triage.
- **Subscription / RG structural-limit visibility** (`Get-SubscriptionLimits.ps1`) — a read-only
  collector for ARM control-plane limits that silently block deployments but are **not** capacity
  quotas. It counts live objects via Azure Resource Graph and the ARM control plane and compares
  each against the documented limit on Microsoft Learn: resource groups per subscription (vs 980),
  tags applied to the subscription (vs 50), and resources per resource group per type (vs 800,
  near/at-limit rows only). Opt-in switches add tags-per-resource density (`-IncludeTagDensity`,
  vs 50), subscription deployment history per location and distinct deployment locations
  (`-IncludeDeploymentHistory`, vs 800 / 10), role assignments at/below the subscription scope
  (`-IncludeRoleAssignments`, vs the fixed 4000), and an Informational resources-per-region
  inventory (`-IncludeRegionInventory`). Every row carries `LimitSource=MicrosoftLearnDocumented`,
  `IsTrueQuota=False` and a `DocReference` to the exact Learn article — these are documented ARM
  constants, not adjustable capacity quotas, and they do **not** feed the compute-only quota-groups
  feature. Reader-only. Resolves #16.
- **PaaS quota visibility** (`Get-PaasQuota.ps1`) — a read-only collector for the data-PaaS tier.
  **Azure SQL** is reported as true quota from the `Microsoft.Sql` usage APIs: subscription/region
  counters (`ServerQuota`, `VCoreQuota`, `RegionalVCoreQuotaForSQLDBAndDW`, Managed Instance vCore
  quotas, etc.) and per-logical-server DTU quota (`server_dtu_quota`), each emitted generically with
  used / limit / available / `PctUsed` and `OK` / `NearLimit` / `AtLimit` flags; free-tier /
  promotional countdown counters (`*Free*`, `*DaysLeft`) are classified `Informational` so a healthy
  "full" countdown is not mistaken for exhaustion. **Cosmos DB** has no verified subscription/region
  RU/s quota API, so it is reported honestly as inventory: the per-account configured
  `totalThroughputLimit` (a real limit only when positive) and, optionally
  (`-IncludeCosmosThroughputInventory`), provisioned RU/s per SQL-API database and container, all
  flagged `IsInformational`. Scope via `-Service AzureSQL|CosmosDB|All`; supports `-Location`,
  `-AllLocations` and the standard subscription selectors. Does **not** feed the compute-only
  quota-groups feature. Reader-only. Resolves #15.
- **Storage quota visibility** (`Get-StorageQuota.ps1`) — a read-only collector that reports the
  per-subscription, per-region **storage-account count** quota (the data behind
  `az storage account show-usage`, default limit 250) with used / limit / available / `PctUsed` and an
  OK / NearLimit / AtLimit flag (threshold via `-NearLimitPct`, default 80). Optionally
  (`-IncludeDiskCapacityInventory`) it adds an **informational** managed-disk capacity inventory —
  total provisioned GiB by region and disk SKU, summed from Resource Graph — explicitly flagged
  `IsQuota=False` / `Informational` with a blank limit, because Azure exposes no general
  per-subscription managed-disk capacity quota usage API. Supports `-Location`, `-AllLocations` and the
  standard subscription selectors. Reader-only. Resolves #14.
- **App Service quota visibility** (`Get-AppServiceQuota.ps1`) — a read-only collector that joins App
  Service Plan inventory (Resource Graph) with the subscription/region
  `Microsoft.Web/locations/{loc}/usages` and per-plan `Microsoft.Web/serverfarms/{name}/usages` APIs
  (api-version `2025-05-01`). Emits three row scopes — `SubscriptionRegion`, `AppServicePlan`, and an
  `InventoryDerived` row comparing each plan's current instance count to its documented tier scale-out
  ceiling (Basic 3 / Standard 10 / Premium v1 20 / Premium v2-v4 30 / Isolated 100) — with
  used / limit / available / `PctUsed`, `NearLimit` / `AtLimit` and `PlanAtInstanceCeiling` flags.
  True API-reported quota rows (`IsTrueQuota=True`) are kept distinct from documented/inventory rows via
  `LimitBasis`; SKUs without a fixed ceiling (Consumption / Flex Consumption) are flagged
  `HasUnknownLimit` rather than given a fabricated limit. Supports `-Location`, `-AllLocations` and the
  standard subscription selectors. Reader-only. Resolves #7.
- **Network quota visibility** (`Get-NetworkQuota.ps1`) — a read-only collector that reports
  per-subscription, per-region **Microsoft.Network** usage vs limit (the data behind
  `az network list-usages` / the `Microsoft.Network/locations/{loc}/usages` API): Virtual Networks,
  Public IP Addresses, Network Interfaces, Load Balancers, NAT Gateways and the rest. Networking quota
  is a common, silent deployment blocker — you cannot create a VM if the subscription is out of public
  IPs or NICs in the region, regardless of compute headroom. Each counter is emitted with
  used / limit / available / `PctUsed` and `NearLimit` / `AtLimit` flags (threshold via
  `-NearLimitPct`, default 80). Counters the API returns with the placeholder `2147483647` limit are
  marked `IsUnbounded` (no fabricated math); per-VNet sub-counters (`…PerVirtualNetwork`) are flagged
  `PerResourceScope`. Supports `-Location`, `-AllLocations`, and the standard subscription selectors.
  Reader-only. Resolves #13.
- **AKS scale-headroom check** (`Get-AksScaleHeadroom.ps1`) — a read-only derivation that answers
  "*if every node pool scaled to its autoscaler `maxCount`, would we run out of family quota?*" It
  joins data the toolkit already reads — AKS node pools (Resource Graph), `Microsoft.Compute/skus`
  (VM size → family + vCPUs) and `az vm list-usage` (per-family used/limit) — to compute the
  **incremental vCPUs** each pool needs to reach its target, aggregates per VM family, and flags
  families that **cannot fully scale** within current quota. Pools in the same family are summed
  before comparison; **Spot pools are checked against the separate regional low-priority pool**, never
  the regular family quota; autoscale-disabled pools target their current count. Emits a per-pool
  detail CSV and a per-family rollup CSV, with `Finding` codes
  (`OK` / `QuotaShortfall` / `MissingSkuMetadata` / `MissingQuotaFamily` / `SpotQuotaCheckNeeded`).
  Reader-only. Resolves #12.
- **Capacity Reservation inventory** (`Get-CapacityReservations.ps1`) — a read-only collector that
  enumerates `Microsoft.Compute/capacityReservationGroups` and their child `capacityReservations`
  across visible subscriptions (ARM read, api-version `2024-07-01`, `$expand=instanceView`) and reports,
  per reservation, the SKU, region, zone, reserved instance count, the capacity actually reserved at
  runtime, how many instances are consuming it, and **idle / over-allocated / at-capacity** flags. This
  closes the loop on the one construct that *guarantees* capacity (as distinct from quota), which
  `docs/concepts.md` already teaches. Reader-only; empty and unreadable (shared-scope) groups are
  surfaced as explicit rows. Resolves #11.
- **Spot Placement Score lens** (`Get-SpotPlacementScore.ps1`) — a read-only collector that calls the
  Azure Spot Placement Score API (`Microsoft.Compute/locations/.../placementScores/spot/generate`,
  api-version `2025-06-05`) to return an allocation-likelihood signal (`High` / `Medium` / `Low`) per
  VM size × region × zone — the closest programmatic answer to the toolkit's "quota ≠ capacity"
  caveat. It scores **Spot** capacity (a proxy for regional pressure, not an on-demand guarantee), is
  time-sensitive (every row timestamped), and needs the read-only built-in **"Compute Recommendations
  Role"** in addition to Reader. Chunks requests to the API limits (≤8 regions × ≤5 sizes) and handles
  throttling / missing-role responses gracefully.
- **Quota Group rollout (opt-in write tool)** — `Deploy-QuotaGroups.ps1`, a generic,
  config-driven, idempotent engine that provisions Azure Quota Groups
  (`Microsoft.Quota/groupQuotas`) from a JSON design: registers providers, creates groups at
  a management-group scope, adds members, requests pooled group limits, and allocates quota to
  subscriptions. Requires PowerShell 7+, supports `-WhatIf`, and is guarded by `ShouldProcess`.
  This is the toolkit's only write capability and is kept separate from the read-only scans.
- **Quota Group config bridge** (`New-QuotaGroupConfig.ps1`) — turns a quota report into a
  deploy-ready design, auto-detecting either the toolkit-native wide `quota-usage` CSV (from
  `Get-QuotaUsage.ps1`) or an external azure-quota-reports CSV; computes allocations and
  pooled group limits with a configurable headroom buffer.
- Synthetic `examples/quota-groups.sample.json` design and a [Quota Groups rollout](docs/quota-groups.md)
  guide; a "Services & coverage" matrix in the README.
- **AI & agent governance** section in `AGENTS.md` — states the toolkit runs no AI models and sends
  no data to any model or third party; the only AI relationship is an agent *operating* it under the
  file's read-only-by-default guardrails.
- **Synthetic demo data generator** (`New-DemoDataset.ps1`) — produces a complete,
  self-consistent fictional dataset ("Zava Inc") from a deterministic seed, with no Azure
  access required, so the dashboard can be previewed entirely offline. The generated universe
  exercises a range of dashboard states (SKU blocks and zone gaps, near-capacity quota, a GPU
  crunch, a pooled quota group, AKS lifecycle states, zone-redundant HA databases).

### Changed

- **Positioning reframed to "read-only by default."** Docs, badges and templates no longer claim
  zero mutations now that the opt-in `Deploy-QuotaGroups.ps1` rollout ships: the README badge reads
  `Mutations: opt-in only`, and AGENTS.md / contributor guidance keep the analysis path strictly
  read-only while documenting the single opt-in write tool (Validate + `-WhatIf` + confirm before
  any execute run). No behaviour change to the analysis scripts.
- **Official Microsoft Learn references** added throughout the docs — inline links at first mention
  of each concept (availability zones, regions, vCPU quotas, quota groups, VM sizes, Spot, Resource
  Graph, AKS / PostgreSQL / MySQL reliability) plus a consolidated "Further reading" table in
  `concepts.md` and pointers from the README, dashboard and quota-groups guides.
- **Documentation aligned across the expanded feature set.** The README services matrix now lists
  Spot placement (`Get-SpotPlacementScore`) with an RBAC footnote; the "what it answers" lists in
  the README, `docs/index.md` and `AGENTS.md` now cover the non-compute quota surface (networking,
  App Service, storage, SQL/Cosmos, subscription/RG limits), capacity reservations and Spot; the
  `concepts.md` "Further reading" table gains Learn links for those services; and the
  "Reader-only" claims are clarified to note Spot placement needs the read-only Compute
  Recommendations Role.
- **Removed dead code** surfaced by PSScriptAnalyzer — unused `$allRegions` in
  `Get-RegionFootprint.ps1` (the region set is recomputed as `$compareRegions` in the
  comparison pass) and an unused `$subCount` in `Get-SkuCatalogue.ps1`. No behaviour change.

### Fixed

- **`Deploy-QuotaGroups.ps1` no longer breaks the Windows PowerShell 5.1 parser.** The opt-in
  rollout tool used PowerShell 7-only ternary (`? :`) and null-coalescing (`??`) operators in
  seven places, so it failed to even tokenise under 5.1 and tripped the new CI parse gate. All
  were rewritten as 5.1-safe `if`/`else` expressions. (Executing a real rollout still requires
  PowerShell 7+, as before — this only ensures the script parses cleanly everywhere.)
- **`New-EnablementRequest.ps1` now parses under Windows PowerShell 5.1.** The file contained a
  single non-ASCII em-dash without a byte-order mark, which Windows PowerShell 5.1 decoded as
  ANSI and mis-tokenised, breaking the script. Replaced with an ASCII hyphen so the file stays
  pure ASCII like the rest of the toolkit. Also caught by the new CI parse gate.

## [0.1.0] - 2026-06-22

First release.

### Added

- **Read-only capacity & enablement scans** (Reader access only):
  - SKU discovery (`Get-UsedSkus.ps1`) and full SKU catalogue with enablement, open
    zones, quota and in-use flags (`Get-SkuCatalogue.ps1`).
  - Regional + zonal SKU enablement scan (`Scan-SkuEnablement.ps1`) and a watcher
    (`Watch-SkuEnablement.ps1`).
  - Per-subscription logical-to-physical zone mapping (`Get-ZoneMappings.ps1`).
  - Quota / headroom per family (`Get-QuotaUsage.ps1`).
  - Tenant-wide AKS inventory (`Get-AksInventory.ps1`).
  - PostgreSQL / MySQL Flexible Server zone + HA resilience (`Get-FlexServerZones.ps1`).
  - Zone-pinned resource sweep (`Get-ZonalResourceInventory.ps1`) and full resource
    inventory (`Get-ResourceInventory.ps1`).
  - Region footprint and multi-region comparison (`Get-RegionFootprint.ps1`).
  - Quota-group read + pooled-design modelling (`Get-QuotaGroups.ps1`,
    `Get-QuotaGroupPlan.ps1`).
- **Enablement request drafting** (`New-EnablementRequest.ps1`) — paste-ready support
  ticket with physical AZ labels.
- **Orchestrator** (`New-CapacityReport.ps1`) — runs the core scans and joins them into a
  combined CSV + Markdown summary, with optional dashboard and `-Include*` panes.
- **Self-contained HTML dashboard** (`New-CapacityDashboard.ps1`) — offline, all styling
  inlined, tabbed views for SKU enablement, catalogue, zone mapping, quota, quota groups,
  regions, AKS, Flexible Servers, zonal and inventory.
- **Documentation set** (MkDocs): getting started, concepts, commands reference, dashboard
  guide, troubleshooting/FAQ and sharing/security.
- **Agent guide** (`AGENTS.md`) describing how to drive the toolkit safely and read-only.

[Unreleased]: https://github.com/microsoft/capacity-toolkit/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/microsoft/capacity-toolkit/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/microsoft/capacity-toolkit/releases/tag/v0.1.0
