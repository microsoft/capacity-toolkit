# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Synthetic demo data generator** (`New-DemoDataset.ps1`) — produces a complete,
  self-consistent fictional dataset ("Zava Inc") from a deterministic seed, with no Azure
  access required, so the dashboard can be previewed entirely offline. The generated universe
  exercises a range of dashboard states (SKU blocks and zone gaps, near-capacity quota, a GPU
  crunch, a pooled quota group, AKS lifecycle states, zone-redundant HA databases).

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
