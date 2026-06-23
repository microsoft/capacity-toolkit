# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

[0.1.0]: https://github.com/microsoft/capacity-toolkit/releases/tag/v0.1.0
