---
name: security-audit
description: Use when the user wants a security review of a vNext domain, a PR, a component change, or a release candidate. Runs a four-phase OWASP-inspired audit (recon → hunt → verify → report) for secrets, authentication and authorization, injection, SSRF, path traversal, insecure file handling, weak crypto, data exposure, dependency issues, and misconfiguration. Verifies findings with confidence scoring before reporting and writes the result under security-report/.
---

# Security audit

This toolkit already has schema validation and component review flows. This skill adds a
security-focused pass that looks for exploitable issues before a domain is shipped. It follows
a four-phase pipeline — reconnaissance, vulnerability hunting, verification, reporting — so the
final report contains verified, actionable findings rather than raw pattern matches.

The detailed per-category checks, false-positive rules, and severity/confidence rubrics live in
[references/concepts/security-review-checklist.md](../../references/concepts/security-review-checklist.md).
Read it before hunting.

## Scope

Review the current workspace as a security target, including:

- component JSON files under the domain folders
- workflow/task/function/extension/mapping definitions
- `.csx` mappings and scripts (`IMapping`, `IOutputHandler`, `sys-mappings` helpers)
- configuration files such as `vnext.config.json`, `package.json`, `docker-compose.yml`, and seed data
- build and deployment-related files when they are present

Scope modes:

- **full** (default) — the whole workspace
- **diff** — only files changed on the current branch / working tree (`git diff --name-only`
  plus untracked files); still read enough surrounding context to judge each change
- **component** — a single workflow/function key and its closure (referenced tasks, views,
  schemas, mappings)

## Phase 1 — Reconnaissance

If `security-report/architecture.md` already exists and the workspace has not changed
significantly since it was written, reuse it. Otherwise map the target first:

- `vnext.config.json` — domain, exports and their `visibility`, `referenceResolution.allowedHosts`,
  `strictMode` / `validateReferenceConsistency` settings
- `package.json` — dependencies, scripts, registries
- the component inventory: workflows, functions (public REST surface), tasks (outbound
  integrations), extensions, views, schemas
- authorization model in use: transition `roles`, state/flow `queryRoles`, schema `x-roles`
- external touch points: HTTP/SOAP/Dapr task endpoints, `scripts.helpers` / `encoding: "REF"`
  sources, MockLab seeds, Docker/Dapr deployment assets

Write the result to `security-report/architecture.md`: trust boundaries, entry points
(functions and workflow triggers), outbound destinations, and where untrusted instance data
flows into `.csx` logic.

## Phase 2 — Hunt for weaknesses, per category

Hunt each category separately and record raw findings in a per-category section or scratch
list. Categories (details and IS / IS-NOT rules in the checklist reference):

1. **Secrets and sensitive data** — hardcoded keys, passwords, connection strings, bearer
   tokens, or PII in JSON, `.csx`, seed data, or docs
2. **Authentication and authorization** — missing or over-broad `roles` / `queryRoles` /
   `x-roles`, exported components broader than needed, privileged transitions reachable
   without role checks, IDOR-style access via instance keys
3. **Injection and unsafe execution** — untrusted instance data reaching SQL, command
   execution, dynamic code evaluation, or template rendering inside `.csx` or task config
4. **SSRF and untrusted hosts** — task URLs or webhook destinations built from instance
   data, hosts outside `referenceResolution.allowedHosts`, redirect/proxy patterns
5. **Path traversal and file handling** — file paths derived from untrusted input,
   unrestricted reads/writes, upload handling without validation
6. **Weak crypto and data protection** — weak hashing, homegrown crypto, plaintext secret
   storage, `http://` where `https://` is expected, sensitive data in logs or view labels
7. **Dependency and supply chain** — risky or unpinned dependencies, untrusted `REF` /
   `allowedAssemblies` sources, build scripts leaking secrets
8. **Misconfiguration and exposure** — weakened `strictMode`, over-broad `exports`,
   permissive Docker/Dapr settings, MockLab or debug surfaces reachable in production config

For an incremental re-run, skip a category whose findings were already verified in the current
report and whose relevant files have not changed.

## Phase 3 — Verify before reporting

Not every suspicion is a finding. This phase is the quality gate: confirm each raw finding
with evidence before it may appear in the report.

For each candidate finding:

1. **Reachability** — is the component actually exported/wired into a workflow or function,
   or is it dead/unreferenced config? Is the `.csx` path reachable from a real transition?
2. **Existing mitigation** — does validation, an allow-list, role enforcement, or schema
   constraint already neutralize the issue on every path?
3. **Context** — is it test/mock content? MockLab seeds, integration-test fixtures, sample
   payloads, and `localhost` development URLs are usually not findings (see the
   false-positive list in the checklist reference).
4. **Confidence score (0–100)** — combine the above into a score and classify:
   Confirmed (90+), High probability (70–89), Probable (50–69), Possible (30–49),
   Informational (<30). Cap severity by confidence: below 30 → Info, 30–49 → at most Medium,
   50–69 → at most High.
5. **Merge duplicates** — same root cause across files becomes one finding with all locations.

Rules that always apply:

- Never print or echo a real secret value. Point to the file and the field only.
- Distinguish a confirmed issue from a likely one; label uncertain items as warnings.
- Record why a finding survived verification (or why candidates were dropped).

## Phase 4 — Produce a concise report

Write or update `security-report/SECURITY-REPORT.md`:

1. **Summary** — overall posture, risk level, and the top high-risk issues
2. **Findings table** — columns for ID, severity (Critical/High/Medium/Low/Info),
   confidence, category (with CWE/OWASP reference where it applies), location, evidence,
   and remediation
3. **Detailed findings** — for Critical/High: description, affected component(s), impact,
   and a concrete step-by-step fix; keep Medium/Low concise
4. **Recommended next steps** — prioritized by risk (immediate → short-term → hardening)
5. **Methodology and limitations** — note this is a static AI-assisted review, not a
   penetration test; confidence scores are estimates

## vNext-specific checks

In addition to generic OWASP-style review, verify the following for this project:

- `referenceResolution.allowedHosts` and strictness settings are not weakened accidentally
- workflows/functions/tasks do not broaden access beyond the scope of the change
- exported components remain intentionally scoped and do not leak internal functionality
- HTTP tasks or downstream integrations do not point to untrusted or hardcoded hosts
- `.csx` logic and task mappings handle untrusted `ScriptContext` instance data safely and do
  not log or expose sensitive content
- transition `roles`, state/flow `queryRoles`, and schema `x-roles` enforce the intended
  actor model (see [roles-and-authorization.md](../../references/concepts/roles-and-authorization.md))
- seed data and sample payloads do not include real credentials or privacy-sensitive content

## Output

When the audit finishes, report in chat:

- the highest-severity verified findings first, each with location, confidence, and a
  concrete remediation
- how many candidates were dropped in verification and why (one line)
- whether the workspace appears broadly safe or needs follow-up work before release, and a
  pointer to `security-report/SECURITY-REPORT.md`
