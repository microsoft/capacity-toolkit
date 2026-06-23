# Dashboard guide

`New-CapacityDashboard.ps1` (or `New-CapacityReport.ps1 -Dashboard`) renders a single,
self-contained `capacity-dashboard-<date>.html`. All styling is inlined, so it opens offline and
is safe to email or attach.

The title bar shows the **tenant display name** (resolved via Microsoft Graph when available) so the
report is self-identifying.

## Global controls

- **Subscription drop-down** — filters the region-scoped panes to a single subscription. Tenant-wide
  panes (AKS, zonal inventory, quota-group members) intentionally show everything you can read.
- **Sortable tables** — click a column header to sort.

## Tabs

Tabs are ordered so related views sit together, with **Overview** always first:

| Tab | What it shows | How to read it |
|---|---|---|
| **Overview** | KPI tiles + risk flags rolled up from every scan | Your executive summary — start here. Red/amber flags point you at the tab to investigate. |
| **SKU enablement** | Per-subscription regional + zonal status for the tracked SKUs | A SKU can be regional-enabled yet zone-blocked. Both signals are shown as consistent coloured pills. |
| **SKU catalogue** | Every VM family's enablement, open zones, quota and in-use flag | Spot **enabled-but-unused** head-room, **blocked** families a request must cover, and **in-use, low-quota** risks. |
| **Zone Mapping** | Each subscription's logical 1/2/3 → physical AZ | Chips are coloured by **physical** AZ, so the per-subscription scramble is obvious. Logical "1" is rarely the same physical zone across subs. |
| **Quota** | Used / limit / available per family + umbrella vCPU limits | Watch the `Total Regional vCPUs` and `Spot vCPUs` ceilings — they cap you independently of any single family. |
| **Quota Groups** | Existing allocation groups (type, member count, pooled-limits-set flag) + a modelled pooled design | "Group exists" ≠ "actively pooling". The design snapshot shows stranded head-room you could pool. |
| **Regions** | Tiered migration-readiness cards + per-region SKU & quota comparison matrices | Primary → chosen Secondary → candidates → footprint elsewhere, with ▲/▼/= deltas vs home. **Quota ≠ capacity** — verdicts are deliberately cautious. |
| **AKS** | Tenant-wide cluster inventory | Node SKUs render as chips. Lets you see how much of the fleet rides a constrained family. |
| **Flex servers** | PostgreSQL/MySQL Flexible Server SKU + zone + HA | Flags single-zone databases with no standby. |
| **Zonal** | Every zone-pinned resource, flagged when single-zone | Find resilience gaps (disks, gateways, IPs pinned to one zone). |
| **Inventory** | Every resource type × subscription × region | The complete footprint, including zone-pinned counts. |

> Some tabs only appear when you ran the matching scan / `-Include*` switch (e.g. Quota Groups
> requires `-IncludeQuotaGroups`, Regions requires `-EvaluateRegions` data).

## Reading the Regions tab

This is usually the tab that matters most. It answers "where can this workload live?"

- **Readiness cards** are tiered: **Primary (home)**, **chosen Secondary** (`-SecondaryRegion`),
  **other candidates** (`-EvaluateRegions`), and **footprint elsewhere**.
- Each card shows home-baseline **deltas** (▲ better / ▼ worse / = same) and a verdict such as
  `Viable target`, `Viable · zone gaps`, `Enabled · no quota`, or `Weak · not fully enabled`.
- The detail matrices below put **home first**, then the secondary (tinted), then candidates, so the
  comparison reads left-to-right in priority order.

Always pair the readout with the **quota ≠ capacity** caveat from [Concepts](concepts.md): a green
region still needs a real test deployment before you commit a migration.

## Before you share it

The dashboard embeds whatever was in `output/` — i.e. real subscription names and resource counts.
Clear `output/` (or regenerate against sanitised data) before handing it on. See
[Sharing & security](sharing-and-security.md).

## Further reading

For the official Microsoft documentation behind the concepts these tabs visualise (availability
zones, regions, quotas, quota groups, AKS / database reliability), see
[Concepts → Further reading](concepts.md#further-reading--official-microsoft-documentation).
