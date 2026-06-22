# Azure Capacity & Enablement Toolkit

A reusable, **read-only** toolkit for validating **regional / zonal SKU enablement, quota,
capacity, zonal resilience and AKS / database footprint** in any Azure tenant — using nothing
more than **Reader** access. It shows you, in concrete numbers, what is actually enabled in a
region when you hit regional capacity or availability-zone constraints.

## What it answers

- *Is SKU X enabled regionally? In which availability zones?*
- *Which of my subscriptions are missing enablement?*
- *How much quota / headroom do I have per VM family, and where is it stranded?*
- *How do logical zones (1/2/3) map to physical zones for each subscription?*
- *How many AKS clusters do we have, where, and on what node SKUs?*
- *Which regions do we run in today, and is region X a viable alternative to deploy/move to?*
- *Do we have quota groups, how are they designed, and is there pooled headroom?*
- *Draft me the support request to get SKU X enabled regionally and in AZ01/AZ02/AZ03.*

## Documentation map

| Page | What's in it |
|---|---|
| [Getting started](getting-started.md) | Prerequisites, access, install, your first run |
| [Concepts](concepts.md) | Capacity vs quota, regional vs zonal, zone mapping, quota groups, region readiness |
| [Commands reference](commands.md) | Every script, its parameters and outputs, plus raw `az` one-liners |
| [Dashboard guide](dashboard.md) | The HTML dashboard tabs and how to read them |
| [Troubleshooting & FAQ](troubleshooting.md) | Common questions, platform gotchas, best practices |
| [Sharing & security](sharing-and-security.md) | Read-only guarantees and how to sanitize before sharing |

> **Automating it with an AI agent?** [`AGENTS.md`](../AGENTS.md) tells GitHub Copilot CLI (or any
> agent) how to drive the toolkit safely against a tenant.

## At a glance

- **Read-only.** Every script only reads; nothing is created, modified or deleted. The only
  writes are local CSV / HTML / JSON files under `output/`.
- **Reader access** is enough for everything except quota-group reads (management-group read) and
  `kubectl` inspection (Cluster User/Admin — out of scope).
- **Self-contained output.** CSVs and a single interactive HTML dashboard that opens offline.

See the repository [README](../README.md) for a one-minute overview and the
[LICENSE](../LICENSE) (MIT).
