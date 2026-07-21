---
description: Run an OWASP-inspired security audit for the current vNext domain and write a report to security-report/SECURITY-REPORT.md
argument-hint: "[scope]"
allowed-tools: Read, Grep, Glob, Bash
---

# /security-audit

Run a security-focused review of the current domain and produce a report at `security-report/SECURITY-REPORT.md`.

## Scope

- With no argument, audit the full workspace.
- With `changed` or `diff`, review only files changed in the current branch or working tree.
- With a component key, audit that workflow/function and its closure.

## Steps

1. Inspect the project shape from `vnext.config.json`, `package.json`, and the component folders.
2. Review the domain for secrets, authz issues, injection risks, SSRF/path traversal/file handling concerns, weak crypto, dependency issues, and misconfiguration.
3. Write or update `security-report/SECURITY-REPORT.md` with a short summary, a finding table, and prioritized remediation advice.
4. Report the top findings directly in the chat and point to the report file.

If a finding is ambiguous, mark it as a warning and explain the uncertainty.
