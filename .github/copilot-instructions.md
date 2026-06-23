# Copilot instructions — Azure Capacity & Enablement Toolkit

This repository is a **read-only-by-default** Azure capacity/enablement toolkit. The full agent
guidance lives in [`../AGENTS.md`](../AGENTS.md) — **read it before running anything**.

Non-negotiable rules:

- **READ-ONLY BY DEFAULT.** With the analysis scripts, never create, modify, delete, scale or
  restart any Azure resource — the only writes are local files under `output/`. No
  `az ... create/update/delete/set`, no `New-Az*` / `Set-Az*` / `Remove-Az*`, no `terraform apply`,
  no `kubectl apply/delete` on your own initiative.
- **One opt-in write tool.** `Deploy-QuotaGroups.ps1` (with `New-QuotaGroupConfig.ps1`) provisions
  quota groups. Only run it on explicit human instruction, always `-Action Validate` + `-WhatIf`
  first, and confirm before any execute run. See `../docs/quota-groups.md`.
- **Confirm tenant/subscription before login or context switch.** Show `az account show` and wait
  for explicit user approval. Never silently change the active `az` context.
- **Minimum access is Reader** (plus management-group read for quota groups). On
  `AuthorizationFailed`, report it as a finding — do not escalate or work around RBAC.
- Treat all discovered data as **tenant-confidential**; never send it to third parties. Clear
  `output/` before sharing any generated CSV/HTML.

Standard flow: `Get-UsedSkus.ps1` (discover) → `New-CapacityReport.ps1 -ConfigPath ... -Dashboard`
(report + dashboard) → open `output/capacity-dashboard-<date>.html`. See `AGENTS.md` §3–§6 for
parameters, platform quirks, the interpretation guide, and the pre-share sanitization sweep.
