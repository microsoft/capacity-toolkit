# 🛠️ Contributing to the Azure Capacity & Enablement Toolkit

Welcome, and thank you for your interest in contributing! Your time and effort are greatly
appreciated, no matter how big or small the contribution.

There are many ways to contribute beyond writing code. This page gives a high-level overview
of how to get involved.

On this page:

- [Asking questions](#asking-questions)
- [Suggesting features and reporting bugs](#suggesting-features-and-reporting-bugs)
- [Reviewing code changes](#reviewing-code-changes)
- [Making code changes](#making-code-changes)
- [External contributors](#external-contributors)
- [Toolkit conventions](#toolkit-conventions)
- [Contributor License Agreement](#contributor-license-agreement)

---

## Asking questions

Have a question? Please ask in **Discussions**. Avoid asking questions in issues to keep them
focused on bugs and features. If you're not sure, start a discussion and open an issue later
if needed.

## Suggesting features and reporting bugs

If you have an idea or notice a bug, [search open issues](../../issues) first to see if one
already exists.

- If you find your exact issue, add context in a comment and vote it up (👍) or down (👎)
  instead of "+1" comments.
- If you don't find it, create a **new issue per problem or feature request** (don't group
  several together). Include enough detail to reproduce: OS, PowerShell version, Azure CLI
  version, the exact command, and the error text.

> **Never paste live tenant data** (subscription IDs, resource names, tenant IDs) into a
> public issue. Redact it first — see [Sharing & security](docs/sharing-and-security.md).

## Reviewing code changes

If you'd like to help but aren't ready to write code yet, start by reviewing
[pull requests](../../pulls). Please don't approve unless you've reviewed, understand, and
agree with every change. Comments without approval are just as valuable — they improve quality.

## Making code changes

Not sure where to start? Scan [existing issues](../../issues) and use labels to narrow down.
If an issue is assigned, comment to check status before starting. If it's unassigned, you're
welcome to open a PR with a fix.

Typical flow:

1. Fork and branch (`feature/<short-name>` or `fix/<short-name>`).
2. Make your change following the [conventions](#toolkit-conventions) below.
3. Validate locally (syntax-check the scripts, regenerate the dashboard against sample data).
4. Open a PR describing **what** changed and **why**, linking the issue.

## External contributors

You're very welcome to contribute whether or not you work at Microsoft. Everyone contributes
through the same **fork-and-pull-request** model — nobody pushes directly to the default branch.

**How it works:**

1. **Fork** `microsoft/capacity-toolkit` to your own account.
2. Create a branch on your fork (`feature/<short-name>` or `fix/<short-name>`).
3. Make your change, following the [conventions](#toolkit-conventions) below.
4. Open a **pull request** from your fork back to this repo.
5. Sign the [CLA](#contributor-license-agreement) when the bot prompts you (one-time).
6. A maintainer reviews and, once approved and checks pass, merges it.

**What to expect:**

- You don't need — and won't be granted — write access to the repository. Contributing via a
  fork is the normal, fully-supported path; you can do everything from your fork.
- Every pull request is reviewed by a maintainer (see [CODEOWNERS](.github/CODEOWNERS)) and must
  pass the required checks before it can merge. This protects everyone and keeps `main` releasable.
- Keep PRs small and focused, and be patient and respectful during review — see the
  [Code of Conduct](CODE_OF_CONDUCT.md).
- Found a **security issue**? Do **not** open a public PR or issue — report it privately via the
  [Microsoft Security Response Center](https://aka.ms/opensource/security/create-report). See
  [SECURITY.md](SECURITY.md).

## Toolkit conventions

These keep the toolkit safe, generic and read-only by default:

- **Read-only by default.** Analysis scripts may only *read* (`az rest GET`, `az ... list`,
  Resource Graph, `az vm list-usage`). Never add create/update/delete calls, `New-Az*` /
  `Set-Az*` / `Remove-Az*`, or anything that mutates a tenant, to the analysis path. The only
  writes there are local files under `output/`. The lone sanctioned write tool is the existing
  opt-in quota-group rollout (`Deploy-QuotaGroups.ps1`); new mutating features need explicit
  maintainer agreement and must be opt-in, `-WhatIf`-supporting and `ShouldProcess`-guarded. See
  [AGENTS.md](AGENTS.md) for the full guardrails.
- **PowerShell 5.1 floor (analysis scripts).** Analysis scripts must run under Windows PowerShell
  5.1: no ternary `? :`, no null-coalescing `??`, and no inline `if(){}else{}` used *as a function
  argument* (precompute into a variable first). The opt-in quota-group rollout scripts are the
  exception — they declare `#Requires -Version 7.0`.
- **No secrets, no identifiers.** Never commit credentials, tenant IDs, subscription IDs,
  identifying names, or live `output/` data. The `.gitignore` excludes `output/` and
  `capacity-config.json` — keep it that way.
- **Defaults stay generic.** Region/SKU defaults must be neutral samples, not a specific
  tenant's footprint.
- **Document as you go.** New capabilities update the relevant page under `docs/`; new gotchas
  go in [Troubleshooting & FAQ](docs/troubleshooting.md).

## Contributor License Agreement

Most contributions require you to agree to a Contributor License Agreement (CLA) declaring
that you have the right to, and actually do, grant us the rights to use your contribution. For
details, visit <https://cla.opensource.microsoft.com>.

When you submit a pull request, a CLA bot will automatically determine whether you need to
provide a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow
the instructions provided by the bot. You will only need to do this once across all repos
using our CLA.

This project has adopted the
[Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For
more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/)
or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional
questions or comments.

---

## Thank you 🙏

Your contributions to open source, large or small, make projects like this possible. Thank you
for taking the time to contribute.
