# Getting started

This page takes you from zero to a rendered capacity dashboard.

## Prerequisites

| Requirement | Notes |
|---|---|
| **PowerShell 5.1+** or **PowerShell 7+** | The toolkit targets the Windows PowerShell 5.1 floor; PS7 works too. |
| **Azure CLI** (`az`) | Logged in to the target tenant. Device-code login works fine for guest access. |
| **`resource-graph` az extension** | Used by AKS / footprint scans. Auto-installed on first use. |
| **Reader** role on the target subscriptions | Enough for everything below except the two exceptions in the next table. |

### Access requirements

| Capability | Minimum role | Notes |
|---|---|---|
| SKU restriction / zonal enablement scan | **Reader** | `Microsoft.Compute/skus` is a subscription-level read |
| Zone (logical→physical) mapping | **Reader** | per-subscription `locations` read |
| Quota / usage | **Reader** | `az vm list-usage` |
| AKS inventory (Resource Graph) | **Reader** | needs the `resource-graph` az extension (auto-installed) |
| Activity-log error scan | **Reader** | for watching reconciles / allocation errors |
| Region footprint / multi-region compare | **Reader** | Resource Graph + per-region skus read |
| Quota group (shared pool) read | **Management-group Reader** | subscription Reader is *not* enough |
| Enablement / quota **changes** | **Not covered** | requires an Azure support request to the capacity team |
| `kubectl` / node / pod inspection | **Cluster User / Admin** | Reader **cannot** pull cluster credentials |

> **Everything in this toolkit is read-only.** It never mutates a resource — every write is a local
> file under `output/`. The enablement-request generator only *drafts* the support ticket text;
> filing it is a manual step.

## Install

Clone or download the repository, then run scripts from the repo root:

```powershell
git clone <repo-url> capacity-toolkit
cd capacity-toolkit
```

No build step — these are plain PowerShell scripts that dot-source `scripts/Common.ps1`.

## Step 1 — Sign in

```powershell
az login --tenant <TENANT_ID>
# Confirm you're in the right place:
az account show --query "{tenant:tenantId, user:user.name}" -o table
```

## Step 2 — Discover what's actually in use (recommended)

Instead of guessing which SKUs to check, discover what's actually deployed. This writes a
`capacity-config.json` (location, SKUs, families, subscriptions) that the rest of the toolkit
consumes.

```powershell
# Omit -SubscriptionCsv to scan every subscription you can see.
.\scripts\Get-UsedSkus.ps1 -Location norwayeast [-SubscriptionCsv .\output\my-subs.csv]
```

Optional sub-list CSV format (`Name` is just a label):

```csv
Name,SubId
Prod-Sub-01,00000000-0000-0000-0000-000000000001
Test-Sub-01,00000000-0000-0000-0000-000000000002
```

## Step 3 — Run the combined report + dashboard

```powershell
# Uses the discovered SKUs / families / subscriptions:
.\scripts\New-CapacityReport.ps1 -ConfigPath .\output\capacity-config.json `
    -SecondaryRegion swedencentral `
    -IncludeAks -IncludeZonal -IncludeCatalogue -IncludeInventory -IncludeQuotaGroups `
    -Dashboard -EnablementRequest
```

Or specify everything explicitly (defaults to a B/D/E sample if you pass neither config nor SKUs):

```powershell
.\scripts\New-CapacityReport.ps1 -Location norwayeast `
    -SubscriptionCsv .\output\my-subs.csv `
    -IncludeAks -IncludeInventory -IncludeQuotaGroups -Dashboard -EnablementRequest `
    -SecondaryRegion swedencentral -EvaluateRegions swedencentral,westeurope
```

## Step 4 — Open the dashboard

Open `output\capacity-dashboard-<date>.html` in any browser. It is self-contained (all styling
inlined) and works offline. See the [Dashboard guide](dashboard.md) for how to read each tab.

## What you get in `output/`

| File | When | Contents |
|---|---|---|
| `combined-capacity-report-<region>-<date>.csv` | always | one row per subscription, all signals joined |
| `combined-capacity-report-<region>-<date>.md` | always | paste-ready executive summary + per-sub table |
| `capacity-dashboard-<date>.html` | `-Dashboard` | self-contained visual dashboard |
| `enablement-request-<region>-<date>.md` | `-EnablementRequest` | drafted support ticket |
| `resource-inventory-<date>.csv` | `-IncludeInventory` | complete resource overview |
| `quota-groups-…` / `quota-group-members-…` / `quota-group-plan-…` | `-IncludeQuotaGroups` | existing pools + modelled pooled design |
| `region-footprint-…` / `region-sku-comparison-…` / `region-quota-comparison-…` | `-EvaluateRegions` | multi-region comparison |
| `sku-enablement-…`, `zone-mappings-…`, `quota-usage-…`, `aks-inventory-…` | as scanned | the individual scan CSVs |

> **Config file (`capacity-config.json`).** Produced by `Get-UsedSkus.ps1`, consumed by
> `New-CapacityReport.ps1 -ConfigPath`. Hand-edit freely — explicit `-Skus` / `-Families` /
> `-SubscriptionIds` parameters always override the file. It is **not limited to B/D/E**; discovery
> fills it from VMs, VM Scale Sets and AKS node pools, so it adapts to any tenant's footprint.

Next: read the [Concepts](concepts.md) so the numbers mean what you think they mean — especially
**quota ≠ capacity**.
