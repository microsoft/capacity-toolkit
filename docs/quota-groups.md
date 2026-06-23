# Quota Groups rollout

Most of this toolkit is **read-only by default**. This page covers the one **opt-in write**
capability: provisioning **Azure Quota Groups** (`Microsoft.Quota/groupQuotas`) from a
JSON design file. It is a deliberately separate tool — it requires elevated quota roles,
supports `-WhatIf`, and is guarded by `ShouldProcess`.

A quota group lets a set of subscriptions **share a pooled vCPU quota**: instead of every
subscription holding stranded headroom, the group holds the pool and you allocate from it
to members as demand moves. See [Concepts](concepts.md) for the model.

> ⚠️ **This is the write path.** Reader access is enough to *analyze* quota groups
> (`Get-QuotaGroups.ps1`, `Get-QuotaGroupPlan.ps1`). *Creating* them needs the roles below.
> Always dry-run with `-WhatIf` first.

## Scripts

| Script | Role | Access |
|---|---|---|
| `Get-QuotaGroups.ps1` | Read existing groups, members, pooled limits | Reader (management-group read) |
| `Get-QuotaGroupPlan.ps1` | Model a pooled design from usage | Subscription Reader |
| `New-QuotaGroupConfig.ps1` | Bridge: quota report CSV → populated design file | Reader |
| `Deploy-QuotaGroups.ps1` | **Provision** the design (the write tool) | see [Permissions](#permissions) |

Both write-path scripts require **PowerShell 7+** (`#Requires -Version 7.0`).

## Requirements

- **PowerShell 7+** (`pwsh`). The analysis scripts run on 5.1+, the rollout scripts do not.
- Azure CLI, signed in to the target tenant: `az login --tenant <TENANT_ID>`.

## Permissions

Per scope, only for `Deploy-QuotaGroups.ps1`:

| Phase | Role | Scope |
|---|---|---|
| Register providers | Contributor | each member subscription |
| Create / delete groups | GroupQuota Request Operator | the anchor Management Group |
| Allocate quota | Quota Request Operator | each member subscription |

Billing access is only needed to request **new** quota beyond the pooled total.

## End-to-end pipeline

```powershell
# 0. (analysis) collect quota usage with the toolkit — Reader only
.\scripts\Get-QuotaUsage.ps1 -Location norwayeast -Families standardBsv2Family,standardDadv6Family `
    -OutPath .\output\quota-usage.csv

# 1. Turn a quota report into a populated design (PS7)
.\scripts\New-QuotaGroupConfig.ps1 -SkeletonConfig .\examples\quota-groups.sample.json `
    -QuotaReportCsv .\output\quota-usage.csv -OutputConfig .\output\my-design.json

# 2. Validate the design (no API writes)
.\scripts\Deploy-QuotaGroups.ps1 -ConfigPath .\output\my-design.json -Action Validate

# 3. Dry-run the whole rollout (shows every change without making it)
.\scripts\Deploy-QuotaGroups.ps1 -ConfigPath .\output\my-design.json -WhatIf

# 4. Execute (all phases, idempotent) — or one phase with -Action
.\scripts\Deploy-QuotaGroups.ps1 -ConfigPath .\output\my-design.json
```

## The bridge: `New-QuotaGroupConfig.ps1`

Takes a **skeleton** config (groups + members + `managementGroupId`, with empty
`groupLimits`/`allocations`) plus a quota report, and fills in the numbers. It
**auto-detects** the report format from its columns:

- **Toolkit-native** — the wide `quota-usage-*.csv` from `Get-QuotaUsage.ps1`. Per-family
  columns `<short>_used` / `<short>_limit` (e.g. `Bsv2_limit`) are unpivoted back to the
  Quota API family token `standard<short>family`. The wide CSV has no per-row location, so
  the region comes from `-Locations` (single region; default `norwayeast`).
- **External** — the long CSV from
  [azure-quota-reports](https://github.com/martinopedal/azure-quota-reports) with
  `Provider` / `QuotaId` / `Limit` / `CurrentUsage` columns.

For each group it computes:

- **allocations** = each member's current `Limit` (preserves existing capacity; no
  subscription loses quota). Use `-PreserveExistingLimits:$false` to allocate current
  usage instead (tighter).
- **groupLimits** per family = sum of member limits + `-HeadroomPercent` (default 20%) —
  the shared pool the group can move between members.

Only VM families (`-FamilyFilter`, default `Family$`) with usage above `-MinUsage` on at
least one member are included.

## Phases (`-Action`)

Run in order with `All` (default), or one at a time:

1. `RegisterProviders` — registers `Microsoft.Quota` + `Microsoft.Compute` on members.
2. `CreateGroups` — creates each group at its Management Group scope.
3. `AddSubscriptions` — adds member subscriptions to each group.
4. `SetGroupLimits` — submits group-level pooled quota limit requests.
5. `Allocate` — allocates quota from the group to individual subscriptions.

`Validate` runs schema + subscription-resolution checks only. Every phase is **idempotent**
(it checks for existing objects first) and honours `-WhatIf`.

> **Heads-up — `SetGroupLimits` may escalate.** A pooled group-limit request can return an
> async `Escalated` state, meaning the platform opened a support ticket for approval. The
> other phases (create group, add members, allocate) complete inline. This is expected
> platform behaviour, not an error in the engine.

## Config schema

See [`examples/quota-groups.sample.json`](https://github.com/microsoft/capacity-toolkit/blob/main/examples/quota-groups.sample.json)
(fully synthetic "Zava Inc" design). Key points:

- `groups[].name` must match `^[a-z][a-z0-9]{2,62}$` — lowercase alphanumeric, starts with
  a letter, no hyphens/underscores (an Azure constraint on the resource name). Put the
  friendly label in `displayName`.
- `members` accept subscription **IDs or display names** (names are resolved against the
  current `az` context).
- A subscription can belong to **only one** quota group.
- `groupLimits` / `allocations` use VM **family** quota names (e.g. `standardbsv2family`,
  `standardesv5family`).

Never commit a config containing real tenant subscription IDs or management-group names.
