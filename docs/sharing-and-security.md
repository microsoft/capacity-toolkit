# Sharing & security

This toolkit is safe to run in restricted environments, and its output is safe to share once
sanitized. This page explains *why* it's safe and *what* to do before sharing any output.

## Why it's safe to run

- **Read-only by default.** Every analysis script only reads — `az rest GET`, `az ... list`,
  `az vm list-usage`, Resource Graph queries, activity-log list. Nothing is created, modified or
  deleted, and the only writes are local files under `output/`. The single exception is the opt-in
  `Deploy-QuotaGroups.ps1` rollout tool (it provisions quota groups, supports `-WhatIf`, and is run
  only when you explicitly choose to). The full guardrails are in [`AGENTS.md`](../AGENTS.md).
- **No secrets stored.** The toolkit stores no credentials; it relies entirely on the operator's own
  `az login` context.
- **Self-contained outputs.** CSVs and the HTML dashboard are plain files with no external calls —
  the dashboard inlines all styling and opens offline.
- **What the analysis side cannot do.** The scans cannot *change* SKU/regional enablement or quota
  (that needs an Azure support request), and they cannot pull AKS cluster credentials (`kubectl`) —
  that needs Cluster User/Admin, not Reader. The only deliberate write is the opt-in quota-group
  rollout above.

## What the output contains

Generated CSVs, the Markdown report and the HTML dashboard contain **live tenant data**:
subscription names and IDs, resource names and counts, region footprint, and quota numbers. Treat
every file in `output/` as tenant-confidential.

## Sanitise before sharing

Before any generated file leaves your control — or before you reuse the repo for another tenant —
clear the output folder. Every file is regenerated on the next run.

```powershell
Remove-Item .\output\* -Recurse -Force -Exclude README.md
```

Confirm an `output\README.md` placeholder remains so the folder is preserved in source control.

## Keeping the repository clean

- The repo `.gitignore` excludes `output/*` (except the placeholder README), `capacity-config.json`
  and any internal-only files. **Never** commit live tenant data, tenant IDs, subscription IDs or
  other identifying names.
- The `capacity-config.json` produced by discovery may contain real subscription IDs — it is
  git-ignored for that reason. Don't force-add it.
- Reporting a bug? Redact identifiers from logs and screenshots first. Never paste live data into a
  public GitHub issue.

## Reporting a security issue

Do **not** open a public GitHub issue for security vulnerabilities. Follow the process in
[`SECURITY.md`](../SECURITY.md) (report to the Microsoft Security Response Center).
