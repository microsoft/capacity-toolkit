<!--
  Thanks for contributing to the Azure Capacity & Enablement Toolkit!
  Keep PRs focused and small. Fill in the sections below and tick every box that applies.
-->

## Summary

<!-- What does this PR do, and why? Link the issue it closes. -->

Closes #

## Type of change

- [ ] 🐛 Bug fix
- [ ] 💡 New feature / capability
- [ ] 📝 Documentation
- [ ] 🧹 Refactor / maintenance (no behaviour change)

## How was this tested?

<!-- Which script(s) did you run, against what region/scope (Reader only)? Paste redacted output if useful. -->

-

## Toolkit standards checklist

- [ ] **Read-only by default:** analysis changes add no `create/update/delete/set`, `New-Az*`,
      `Set-Az*`, `Remove-Az*`, `terraform apply`, `kubectl apply/delete`, or other state-mutating
      call; only local files under `output/` are written. (Any change to the opt-in
      `Deploy-QuotaGroups.ps1` write path keeps it opt-in, `-WhatIf`-supporting and
      `ShouldProcess`-guarded.)
- [ ] **Access:** analysis runs with Reader access (plus management-group read for quota-group
      reads); failures on missing RBAC are reported, not worked around. The quota-group rollout
      documents its elevated roles.
- [ ] **PowerShell 5.1 compatible (analysis scripts):** no ternary `? :`, no null-coalescing `??`,
      no inline `if(){}else{}` used as a function argument. (The opt-in quota-group rollout scripts
      may require PS7 via `#Requires -Version 7.0`.)
- [ ] **No telemetry / no third-party calls:** nothing phones home; only the user's own authenticated `az` calls are made.
- [ ] **No secrets or tenant data:** no credentials, tenant/subscription IDs, real subscription names, or `output/` data added to the repo. Defaults stay generic.
- [ ] **Docs updated:** relevant page under `docs/` (and `README.md`/`AGENTS.md` if behaviour changed) reflects this change.
- [ ] **Syntax-checked:** changed scripts parse cleanly and were run at least once.

## Contributor License Agreement

- [ ] I confirm this contribution is covered by the [Microsoft CLA](https://cla.opensource.microsoft.com/)
      (the CLA bot will guide first-time contributors).

## Screenshots (optional, redacted)

<!-- For dashboard/UI changes. REMOVE all tenant data, IDs and names before attaching. -->
