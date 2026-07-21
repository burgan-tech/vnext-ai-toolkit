---
description: Run an OWASP-inspired four-phase security audit (recon → hunt → verify → report) for the current vNext domain and write a report to security-report/SECURITY-REPORT.md
argument-hint: "[scope]"
allowed-tools: Read, Grep, Glob, Bash
---

# /security-audit

Run the `security-audit` skill's four-phase review of the current domain and produce a report
at `security-report/SECURITY-REPORT.md`. Follow the per-category checks, false-positive rules,
and severity/confidence rubric in `references/concepts/security-review-checklist.md`.

## Scope

- With no argument, audit the full workspace.
- With `changed` or `diff`, review only files changed in the current branch or working tree
  (`git diff --name-only` plus untracked files), reading enough surrounding context to judge
  each change.
- With a component key, audit that workflow/function and its closure (referenced tasks,
  views, schemas, mappings).

## Steps

1. **Recon** — map the target from `vnext.config.json` (exports, `allowedHosts`, strictness),
   `package.json`, and the component folders; note trust boundaries, entry points, outbound
   destinations, and where instance data reaches `.csx` logic. Write
   `security-report/architecture.md` (reuse it if it exists and is still current).
2. **Hunt** — work through the checklist categories: secrets, authn/authz (`roles`,
   `queryRoles`, `x-roles`, exports), injection and unsafe execution in `.csx`, SSRF and
   untrusted hosts, path traversal and file handling, weak crypto and data exposure,
   dependency/supply-chain risk, and misconfiguration. Collect raw candidates per category.
3. **Verify** — apply the rubric: reachability, existing mitigations, and context (MockLab
   seeds, test fixtures, and localhost dev URLs are usually not findings). Assign each
   surviving finding a confidence score (0–100) and cap severity by confidence. Merge
   duplicates. Never echo a real secret value — cite file and field only.
4. **Report** — write or update `security-report/SECURITY-REPORT.md` with a short summary, a
   findings table (ID, severity, confidence, category with CWE/OWASP reference, location,
   evidence, remediation), detailed Critical/High findings, and prioritized next steps.
5. Report the top verified findings directly in the chat, note how many candidates were
   dropped in verification, and point to the report file.

If a finding is ambiguous, mark it as a warning and explain the uncertainty.
