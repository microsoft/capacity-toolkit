# AGENTS.md — Azure Capacity & Enablement Toolkit

> Instructions for an AI agent (e.g. GitHub Copilot CLI) driving this **read-only-by-default**
> toolkit against an Azure tenant. If you are an agent: read this file fully before running anything.

## 0. Golden rules (read first, never break)

This toolkit is **READ-ONLY BY DEFAULT**. You exist to *observe and report*. It contains exactly one
write tool — `Deploy-QuotaGroups.ps1`, which provisions Azure Quota Groups — and you must treat it as
**off by default**: never run it unless the human explicitly asks you to provision quota groups *in
this run* and confirms after a `-WhatIf` preview.

- **NEVER** create, modify, delete, scale, move or restart any Azure resource **with the analysis
  scripts**, and never run `az ... create/update/delete/set`, `New-Az*`, `Set-Az*`, `Remove-Az*`,
  `terraform apply`, `kubectl apply/delete`, or anything else that mutates state on your own
  initiative. The only writes the analysis side performs are **local CSV / HTML / JSON files** under
  `output/`.
- The `Get-*`, `Scan-*`, `Watch-*` and `New-*Report/Dashboard/EnablementRequest` scripts are
  **read-only** and always in scope. `New-EnablementRequest` only **drafts text** — it does not submit
  anything.
- `Deploy-QuotaGroups.ps1` and `New-QuotaGroupConfig.ps1` are the **opt-in write path**. Only touch
  them on explicit human instruction. Always run `Deploy-QuotaGroups.ps1 -Action Validate` then
  `-WhatIf`, show the planned changes, and get an explicit OK **before** any execute run. See
  `docs/quota-groups.md`.
- **Confirm before logging in or switching tenant/subscription.** Show the user which tenant/account you are about to use and wait for an explicit OK. Never silently change their active `az` context.
- **Minimum access is Reader** (plus management-group *read* for quota groups). If a command fails with `AuthorizationFailed`, report it as a missing-permission finding — do **not** try to escalate or work around RBAC.
- Treat all discovered data (subscription names, GUIDs, resource names) as **tenant-confidential**. Do not send it to third-party services. Before a generated dashboard is shared externally, clear `output/` (see §6).

## 1. What this toolkit does

Answers, in concrete numbers and with only Reader access:
- Is a VM SKU enabled **regionally**, and in which **availability zones**?
- Which subscriptions are **missing** enablement?
- How much **quota / headroom** per VM family? Where is it stranded?
- How do **logical zones (1/2/3) map to physical zones** per subscription?
- How many **AKS clusters**, where, on what node SKUs?
- Which regions do we run in, and is region X a **viable alternative** to deploy/move to?
- Do we have **quota groups**, how are they designed, and is there pooled headroom?

Output is a set of CSVs plus one **self-contained interactive HTML dashboard**.

## 2. Access required (verify, never escalate)

| Capability | Minimum role |
|---|---|
| SKU / zonal enablement, zone mapping, quota/usage, AKS & resource inventory | **Reader** on the target subscriptions |
| Quota groups (pooled quota) | **Reader** + **management-group read** |

If the user lacks a role, list the affected scenario and stop — do not attempt the scan.

## 3. Standard workflow

Run from the `scripts/` directory. PowerShell 5.1+ or 7+. Azure CLI logged in (`az login`).

**Step 1 — Confirm context.** Show `az account show` (tenant + signed-in user) and the target region(s). Get the user's OK.

**Step 2 — Discover what's actually in use** (produces a config tailored to the tenant's real footprint):
```powershell
.\Get-UsedSkus.ps1 -Location <homeRegion>
# -> output\capacity-config.json  { location, skus[], families[], subscriptions[] }
```

**Step 3 — Run the full report + dashboard** off that config:
```powershell
.\New-CapacityReport.ps1 `
    -ConfigPath ..\output\capacity-config.json `
    -SecondaryRegion <secondaryRegion> `
    -EvaluateRegions <secondaryRegion>,<otherCandidate> `
    -IncludeAks -IncludeZonal -IncludeQuotaGroups -IncludeInventory -IncludeCatalogue `
    -Dashboard
```

**Step 4 — Open & interpret** `output\capacity-dashboard-<date>.html` for the user (see §5).

**Optional — draft an enablement support request** (text only, never submitted):
```powershell
.\New-CapacityReport.ps1 -ConfigPath ..\output\capacity-config.json -EnablementRequest
```

### Key parameters
- `-Location` — the **home / primary** region (default `norwayeast`).
- `-SecondaryRegion` — the **chosen** failover/migration target (e.g. `swedencentral`). Drives the tiered readiness cards. If omitted, the strongest candidate is auto-picked.
- `-EvaluateRegions` — extra regions to score as migration candidates.
- `-Include*` switches — add AKS, zonal-resource, quota-group, inventory and SKU-catalogue panes.
- `-Dashboard` — generate the HTML dashboard.
- `-OutDir` — override output folder (default `output/`).

## 4. Known platform quirks (handle gracefully)

- **`az account management-group list` returns `AuthorizationFailed` even with valid MG read** — it first attempts a register action on a subscription. The toolkit instead uses the ARM REST endpoint
  `az rest --method get --url "https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2021-04-01"`. Do not conclude the user lacks MG access from the CLI error alone.
- **Quota-group compute limits require a location filter** — `groupQuotaLimits` returns `BadRequest` without `$filter=location eq '<region>'`, and `{}` when no pooled limit is set. An `AllocationGroup` may pool members yet have **no** pooled limit (members then rely on their own per-sub quota).
- **PowerShell 5.1 constraints** if you edit scripts: no ternary `? :`, no `??`, no inline `if(){}else{}` as a *function argument* (precompute into a variable first).

## 5. How to read the dashboard (interpretation guide)

- **Quota ≠ capacity.** Full quota in a region does **not** guarantee the region can actually place the VMs (e.g. `westeurope` often shows full quota yet is capacity-constrained in practice). Always recommend a **small test deployment** to confirm before committing a migration.
- **Zone mapping is per-subscription.** Logical zone `1/2/3` maps to **different physical AZs** in each subscription — the dashboard colours chips by *physical* AZ so the scramble is visible. Never assume "zone 1" means the same datacentre across subscriptions.
- **Migration readiness tiers**: Primary (home) → chosen Secondary → other candidates → footprint elsewhere, with deltas (▲/▼/=) vs home. Verdicts are capacity-honest (`Viable target`, `Viable·zone gaps`, `Enabled·no quota`, `Weak·not fully enabled`).
- **Quota groups**: an existing group with "pooled limits set = No" means members do **not** share a pooled limit yet — design opportunity, not a current pool.

## 6. Sanitization before sharing (always remind)

Generated CSVs/HTML contain **live tenant data**. Before anything is shared externally:
```powershell
Remove-Item ..\output\* -Recurse -Force -Exclude README.md
```
Confirm an `output\README.md` placeholder remains. Never commit `output/` data to a shared repo.

## 7. AI & agent governance

What an AI agent — and anyone reviewing this for compliance — should know about how "AI" relates to
this toolkit:

- **The toolkit itself runs no AI/ML.** It is PowerShell + the Azure CLI (`az`) + a static HTML
  dashboard. It makes **no calls to any language model or inference service**, contains no embedded
  models, and produces no model-generated output. There is nothing to "govern" at the model layer
  because there is no model.
- **No data egress.** It sends tenant data to **no third party** — not to a model, telemetry
  endpoint, or analytics service. The only network calls are the operator's own authenticated `az` /
  ARM / Microsoft Graph reads. All output stays in local files under `output/`.
- **The only AI relationship is operation, not inference.** An AI agent (e.g. GitHub Copilot CLI)
  may *drive* this toolkit. When it does, this entire file is the governance contract: read-only by
  default, the one opt-in write tool requires explicit human instruction + `-WhatIf` + confirmation
  (§0), Reader-minimum access with no RBAC escalation (§2), confirm before any login/tenant switch
  (§0), and the §6 sanitization sweep before sharing.
- **Human accountability stays with the operator.** Any action the agent proposes — especially the
  opt-in quota-group rollout — is the human operator's decision to approve and own. The agent must
  surface findings and planned changes; it must not act on the tenant beyond read-only analysis
  without that explicit approval.
- **Outputs are advisory.** Capacity/quota readouts inform decisions; they are not a guarantee.
  Always honour the *quota ≠ capacity* caveat (§5) and validate with a test deployment before any
  migration or commitment.

---

## Operator notes

- For analysis you only need **Reader** (and management-group read for quota groups). The analysis
  scripts cannot break anything — they are read-only. The opt-in `Deploy-QuotaGroups.ps1` rollout is
  the one exception and needs elevated quota roles; do not run it without explicit instruction.
- Start at §3 Step 1. If a step errors with `AuthorizationFailed`, that scope is simply skipped; the rest still works.
- Drive discovery first (`Get-UsedSkus`) so the report reflects the tenant's *real* SKUs/families, not the defaults.
- Set `-SecondaryRegion` to the stated DR/migration target so the readiness tiers answer the actual question; add `-EvaluateRegions` for "what about region X?" asks.
- The single most useful artifact is the HTML dashboard (§3 Step 4). Open it in any browser; it is self-contained (no internet needed). Lead the readout with the **Migration readiness** cards and the **quota ≠ capacity** caveat; recommend a test deployment before any commitment.
- Use the **Subscription** drop-down to filter region-scoped panes. Tenant-wide panes (AKS, zonal) show all subscriptions you can read.
- Run the §6 sanitization sweep before sharing the dashboard or attaching it anywhere.
