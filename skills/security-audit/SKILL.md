---
name: security-audit
description: Use when the user wants a security review of a vNext domain, a PR, a component change, or a release candidate. Runs an OWASP-inspired audit for secrets, authentication and authorization, injection, SSRF, path traversal, insecure file handling, weak crypto, data exposure, dependency issues, and misconfiguration. Produces a concise report under security-report/.
---

# Security audit

This toolkit already has schema validation and component review flows. This skill adds a security-focused pass that looks for exploitable issues before a domain is shipped.

## Scope

Review the current workspace as a security target, including:

- component JSON files under the domain folders
- workflow/task/function/extension/mapping definitions
- `.csx` mappings and scripts
- configuration files such as `vnext.config.json`, `package.json`, `docker-compose.yml`, and seed data
- build and deployment-related files when they are present

## Review workflow

### 1. Reconnaissance

Start by reading the project shape:

- `vnext.config.json` for domain, exports, reference rules, and strict-mode settings
- `package.json` for dependencies and scripts
- any workflow/task/function metadata that influences runtime behavior
- relevant configuration for Docker, Dapr, MockLab, or deployment assets

Map the likely trust boundaries: public entry points, external HTTP tasks, function execution paths, and any data that crosses component boundaries.

### 2. Hunt for common weaknesses

Check for the following classes of issues:

- Secrets and sensitive data: hardcoded keys, passwords, connection strings, bearer tokens, or PII in JSON, `.csx`, seed data, or docs
- Authentication and authorization: weak or missing role checks, over-broad `queryRoles` / `roles`, broken access expectations, or missing checks before privileged actions
- Injection and unsafe execution: SQL/command injection, unsafe template rendering, dynamic code execution, or untrusted data reaching task/function logic
- SSRF, path traversal, and file handling: unvalidated URL targets, path manipulation, file upload abuse, or unrestricted file access
- Weak crypto and data handling: insecure hashing, plaintext secrets, insecure transport assumptions, or unsafe logging of sensitive content
- Dependency and supply-chain issues: outdated or risky dependencies, weak package provenance, or exposed build-time secrets
- Misconfiguration and exposure: broad `exports`, permissive configuration, or untrusted hosts outside the allowed reference policy

### 3. Verify before reporting

Not every suspicion is a finding. Confirm the issue with evidence from the code or configuration before raising it. Prefer actionable findings over speculative warnings.

- Never print or echo a real secret value. Point to the file and the field only.
- Distinguish between a likely issue and a confirmed issue.
- If a component is only a potential risk, label it as a warning rather than a confirmed vulnerability.

### 4. Produce a concise report

Write or update a report at `security-report/SECURITY-REPORT.md`.

Use this structure:

1. Summary: overall posture and high-risk issues
2. Findings table with columns for severity, location, evidence, and remediation
3. Recommended next steps, prioritized by risk

## vNext-specific checks

In addition to generic OWASP-style review, verify the following for this project:

- `referenceResolution.allowedHosts` and strictness settings are not weakened accidentally
- workflows/functions/tasks do not broaden access beyond the scope of the change
- exported components remain intentionally scoped and do not leak internal functionality
- HTTP tasks or downstream integrations do not point to untrusted or hardcoded hosts
- `.csx` logic and task mappings handle untrusted input safely and do not log or expose sensitive data
- seed data and sample payloads do not include real credentials or privacy-sensitive content

## Output

When the audit finishes, report:

- the highest-severity findings first
- the affected files or components
- a concrete remediation suggestion for each finding
- whether the workspace appears broadly safe or needs follow-up work before release
