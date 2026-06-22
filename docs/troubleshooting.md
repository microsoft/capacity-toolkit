# Troubleshooting & FAQ

Common questions and platform gotchas you may hit when running the toolkit. Most of these are
behaviours of Azure / the CLI, not bugs in the scripts.

## Access & permissions

### `az account management-group list` says I have no access — but I'm sure I do

That command **first attempts** `Microsoft.Management/register/action` on a *subscription* scope and
fails with **AuthorizationFailed** even when you genuinely *can* read management groups. Don't
conclude "no MG access" from it. List management groups via the ARM REST endpoint instead:

```bash
az rest --method get --url "https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2021-04-01"
```

`Get-QuotaGroups.ps1` uses this REST path, which is why it discovers quota groups the `az account`
command would have hidden.

### Reader works for everything except `kubectl`?

Yes. Every read in this toolkit works with **Reader**. Pulling cluster credentials
(`listClusterUserCredential`) does **not** — so you get no pod/node-level visibility. Set
expectations accordingly and lean on VMSS instance views and the activity log for cluster health.
Inventorying AKS (via Resource Graph) is fine with Reader; inspecting *inside* a cluster needs
Cluster User/Admin.

## Quota & enablement

### I enabled a blocked SKU but my AKS cluster is still Failed

Enabling a previously-blocked SKU clears the restriction, but an AKS cluster already in a **Failed**
state stays Failed until *someone runs a reconcile* (`az aks update`, a nodepool operation, or
`az resource update`). Plan for an explicit reconcile step after enablement — and expect the system
node pool's node count to briefly surge during it (this is normal).

### My quota group has subscriptions but no limits — is it broken?

No. A group can enrol dozens of subscriptions (`groupType: AllocationGroup`) yet have **no**
`groupQuotaLimits` set in any region — members then draw on their own per-sub quota. *"Has a quota
group" ≠ "is actively pooling capacity."* Also note the `groupQuotaLimits` API **requires** a
`$filter=location eq '<region>'`; without it you get `BadRequest: $filter not found`. Report the
limits-set flag, not just the group's existence.

### Do I need one `skus` REST call per SKU?

No. **One `skus` call per subscription is enough** — it returns every SKU's restrictions for the
region in a single response. Filter client-side rather than calling per-SKU.

## Resource Graph

### My Resource Graph columns come back empty / pagination breaks

- `mv-expand` + `summarize` (and `mv-apply` projections) silently produced **empty columns** and
  broke pagination in testing. The reliable pattern is: `project` raw rows (including
  `tostring(properties.agentPoolProfiles)`), then aggregate in PowerShell.
- **Never build the KQL with a conditionally-empty line.** An empty `$(if …)` interpolation inside a
  here-string injects a blank line that truncates the query — it silently dropped the
  `where`/`project` and returned *all* resources. Build clauses as an array and `-join ' | '`.
- Paginate on `.total_records` (snake_case) with `--skip`, **not** `totalRecords`.

### My AKS node SKU counts look too low

Case matters. Resource Graph returns `vmSize` as `standard_b2s_v2` (lowercase); match
`(?i)Standard_…` case-insensitively or you'll under-count families badly.

## Scripts

### A script exits immediately with no output (exit code 1)

`$PSScriptRoot` is **empty** under `powershell.exe -File` during *param-default* evaluation. That
throws inside `Join-Path` and the script exits 1 *silently* (it once broke a scheduled task). Use
the `Get-ScriptDir` / `Get-DefaultOutDir` helpers in `Common.ps1` for default output paths instead
of `$PSScriptRoot`.

### Can I edit the scripts on a Windows PowerShell 5.1 machine?

Yes, but keep to the **PowerShell 5.1 floor**: no ternary `? :`, no null-coalescing `??`, and no
inline `if(){}else{}` used *as a function argument* (precompute into a variable first).

## Best practices

- **Discover before you guess.** Run `Get-UsedSkus.ps1` first so the report reflects the *real*
  SKUs/families in use, not the default sample.
- **Scope the blast radius early.** What looks like "a handful of clusters" is often hundreds of
  resources across many subscriptions once you query the whole tenant. Run `Get-AksInventory.ps1`,
  `Get-RegionFootprint.ps1` and `Get-ZonalResourceInventory.ps1` up front before you scope work or
  quote numbers.
- **Quote physical AZ labels** (AZ01/AZ02/AZ03), never logical zone numbers, in any report or
  support-facing message — logical zones differ per subscription.
- **Lead with quota ≠ capacity.** Set that expectation before a green region cell gets read as
  "deploy here tomorrow". Recommend a small test deployment before any migration commitment.
- **Sanitise before sharing.** Clear `output/` (and never commit it). See
  [Sharing & security](sharing-and-security.md).

For the conceptual background behind several of these, see [Concepts](concepts.md).
