<h1>
  <img src="assets/branding/logo.svg" width="64" align="absmiddle" alt="" />
  &nbsp;Azure Capacity &amp; Enablement Toolkit
</h1>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Access: Reader](https://img.shields.io/badge/Azure-Reader%20only-success.svg)](docs/getting-started.md)
[![Read-only](https://img.shields.io/badge/Mutations-none-critical.svg)](AGENTS.md)

> Read-only tools and a self-contained dashboard to analyze Azure regional capacity,
> availability-zone enablement, and quota — with only Reader access.

A **read-only** toolkit that shows you, in concrete numbers, what is actually enabled in an Azure
region: which VM SKUs are available regionally and per availability zone, how much quota and
headroom you have, how each subscription maps to the physical zones, and what your AKS and database
footprint looks like. It needs nothing more than **Reader** access.

It covers the questions that come up in a regional-capacity review — constrained VM SKUs,
regional-vs-zonal enablement gaps, per-subscription zone mapping, quota sizing across quota groups,
and AKS resilience — packaged as generic scripts plus a single, self-contained HTML dashboard.

## What it answers

- *Is SKU X enabled regionally? In which availability zones?*
- *Which of my subscriptions are missing enablement?*
- *How much quota / headroom do I have per VM family, and where is it stranded?*
- *How do logical zones (1/2/3) map to physical zones for each subscription?*
- *How many AKS clusters do we have, where, and on what node SKUs?*
- *Which regions do we run in, and is region X a viable alternative to deploy/move to?*
- *Do we have quota groups, how are they designed, and is there pooled headroom?*
- *Draft me the support request to enable SKU X regionally and in AZ01/AZ02/AZ03.*

## 60-second quick start

```powershell
# 1. Sign in to the target tenant
az login --tenant <TENANT_ID>

# 2. Discover what's actually in use → capacity-config.json
.\scripts\Get-UsedSkus.ps1 -Location norwayeast

# 3. Run the combined report + dashboard
.\scripts\New-CapacityReport.ps1 -ConfigPath .\output\capacity-config.json `
    -SecondaryRegion swedencentral `
    -IncludeAks -IncludeZonal -IncludeCatalogue -IncludeInventory -IncludeQuotaGroups `
    -Dashboard -EnablementRequest

# 4. Open output\capacity-dashboard-<date>.html
```

Full walkthrough: **[Getting started](docs/getting-started.md)**.

> ⚠️ **Quota ≠ capacity.** Available quota does not guarantee a region can place your VMs. Always
> validate a target region with a small test deployment before advising a migration. See
> [Concepts](docs/concepts.md).

## Documentation

| Page | What's in it |
|---|---|
| [Getting started](docs/getting-started.md) | Prerequisites, access, install, your first run |
| [Concepts](docs/concepts.md) | Capacity vs quota, regional vs zonal, zone mapping, quota groups, region readiness |
| [Commands reference](docs/commands.md) | Every script, its parameters and outputs, plus raw `az` one-liners |
| [Dashboard guide](docs/dashboard.md) | The HTML dashboard tabs and how to read them |
| [Troubleshooting & FAQ](docs/troubleshooting.md) | Common questions, platform gotchas, best practices |
| [Sharing & security](docs/sharing-and-security.md) | Read-only guarantees and how to sanitize before sharing |

> **Automating it with an AI agent?** [`AGENTS.md`](AGENTS.md) tells GitHub Copilot CLI (or any
> agent) how to drive the toolkit safely against a tenant.

## Why it's safe to run

- **Read-only.** Every script only reads; nothing is created, modified or deleted. The only writes
  are local CSV / HTML / JSON files under `output/`.
- **Reader access** covers everything except quota-group reads (management-group read) and `kubectl`
  inspection (Cluster User/Admin — out of scope).
- **No secrets, self-contained output.** It stores no credentials and the dashboard opens offline.

See [Sharing & security](docs/sharing-and-security.md) before sharing any generated output.

## Repository layout

```
Azure-Capacity-Enablement-Toolkit/
├─ README.md                     ← this file (front door)
├─ AGENTS.md                     ← AI-agent guide (read-only guardrails, workflow, interpretation)
├─ docs/                         ← full documentation (see the table above)
├─ scripts/                      ← the read-only PowerShell toolkit (Get-*, Scan-*, New-*)
├─ output/                       ← generated CSV / Markdown / HTML (git-ignored; placeholder README only)
├─ mkdocs.yml                    ← docs-site config
├─ CONTRIBUTING.md · SUPPORT.md · SECURITY.md · CODE_OF_CONDUCT.md · LICENSE
└─ .github/copilot-instructions.md ← short pointer to AGENTS.md for repo-scoped Copilot
```

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). For questions and bug reports,
see [SUPPORT.md](SUPPORT.md). Please keep the toolkit **read-only** and never commit live tenant
data.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of
Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion
or imply Microsoft sponsorship. Any use of third-party trademarks or logos is subject to those
third parties' policies.

## License

Licensed under the [MIT License](LICENSE). Copyright (c) Microsoft Corporation.
