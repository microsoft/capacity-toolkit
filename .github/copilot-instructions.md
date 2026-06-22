# Copilot instructions — Azure Capacity & Enablement Toolkit

This repository is a **read-only** Azure capacity/enablement toolkit. The full agent guidance
lives in [`../AGENTS.md`](../AGENTS.md) — **read it before running anything**.

Non-negotiable rules:

- **READ-ONLY.** Never create, modify, delete, scale or restart any Azure resource. The only
  writes are local files under `output/`. No `az ... create/update/delete/set`, no `New-Az*` /
  `Set-Az*` / `Remove-Az*`, no `terraform apply`, no `kubectl apply/delete`.
- **Confirm tenant/subscription before login or context switch.** Show `az account show` and wait
  for explicit user approval. Never silently change the active `az` context.
- **Minimum access is Reader** (plus management-group read for quota groups). On
  `AuthorizationFailed`, report it as a finding — do not escalate or work around RBAC.
- Treat all discovered data as **tenant-confidential**; never send it to third parties. Clear
  `output/` before sharing any generated CSV/HTML.

Standard flow: `Get-UsedSkus.ps1` (discover) → `New-CapacityReport.ps1 -ConfigPath ... -Dashboard`
(report + dashboard) → open `output/capacity-dashboard-<date>.html`. See `AGENTS.md` §3–§6 for
parameters, platform quirks, the interpretation guide, and the pre-share sanitization sweep.
