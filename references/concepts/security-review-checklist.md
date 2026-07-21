# Security review checklist

Use this checklist when the `security-audit` skill or the `security-reviewer` agent reviews a
vNext domain. Each category lists what to check, concrete patterns to hunt for in this
component model, and what is **not** a finding. Findings should cite the matching OWASP/CWE
reference from the mapping table at the end and pass the verification rubric before being
reported.

## 1. Secrets and sensitive data

- Check for hardcoded credentials, tokens, API keys, connection strings, and private keys in
  component JSON, `.csx`, seed data, and config files.
- Verify that sample payloads and mock data do not expose real user data or credentials.
- Ensure logs and debug output do not contain secrets or PII.

Hunt patterns:

- Grep the domain for `password`, `secret`, `token`, `apikey`/`api_key`/`api-key`,
  `authorization`, `bearer`, `connectionstring`, `BEGIN RSA/EC/PRIVATE KEY`, and
  base64-looking literals in task `headers`, task config, and `.csx` string constants.
- Static `Authorization` headers in HTTP/SOAP task definitions.
- Credentials committed in `docker-compose.yml`, `.env`, or CI files.

Not a finding:

- Reads of environment variables or secret stores at runtime (a reference to a secret is the
  correct pattern, not a leak).
- Obvious placeholders (`<your-api-key>`, `changeme`, `dummy`, `example.com`) and MockLab
  seed values that are clearly synthetic — downgrade to Info at most.
- Never reprint a real secret value in any output; cite file and field only.

## 2. Authentication and authorization

- Verify that workflow entry points and function execution paths enforce the expected roles
  or access constraints.
- Review transition `roles`, state/flow `queryRoles`, schema `x-roles`, exported visibility,
  and component-level exposure for over-broad access (see
  [roles-and-authorization.md](roles-and-authorization.md)).
- Look for broken access control patterns such as IDOR or privilege escalation paths.

Hunt patterns:

- Privileged transitions (approve, cancel, override, admin-ish actions) with missing or
  wildcard `roles`.
- States holding sensitive data whose `queryRoles` (state-level, falling back to
  flow-level `attributes.queryRoles`) allow broader read access than the actor model intends.
- Sensitive schema fields (national ID, salary, limits) without restrictive `x-roles`.
- Functions with instance scope that accept an instance key but never constrain which caller
  may query it (IDOR via instance enumeration).
- A change that widens `roles`/`queryRoles`/exports beyond what the change itself needs.

Not a finding:

- Public-by-design entry transitions of a public workflow, when the rest of the flow is
  properly constrained.

## 3. Injection and unsafe execution

- Review task/function `.csx` mappings for unvalidated instance data reaching SQL, command
  execution, template rendering, or dynamic code execution.
- Check for unsafe deserialization, unsafe eval/exec patterns, or data flowing into
  interpreters or system calls.
- Validate that external data is normalized before use.

Hunt patterns in `.csx` (mappings receive untrusted data via `ScriptContext` — treat
`context.Instance.Data`, transition payloads, and headers as attacker-influenced):

- `Process.Start`, `System.Diagnostics`, shell invocation.
- SQL built by string concatenation/interpolation with instance data instead of parameters.
- `CSharpScript.EvaluateAsync`, `Activator.CreateInstance` on user-derived type names,
  reflection driven by instance data.
- String-concatenated XML/JSON/HTML bodies sent downstream without encoding.
- `JsonConvert.DeserializeObject` with `TypeNameHandling` other than `None`.

Not a finding:

- Parameterized queries, typed serializer usage, or values validated against the schema
  before use.

## 4. SSRF, traversal, and file handling

- Review HTTP tasks and outbound integrations for untrusted URLs or weak allow-listing.
- Check for path traversal or unrestricted file reads/writes.
- Inspect upload handling and file storage flows for validation and access control gaps.

Hunt patterns:

- Task URLs or `.csx` `HttpClient` destinations built from instance data (webhook URLs,
  callback URLs, "fetch this document" fields) — the core SSRF shape is *user-influenced
  input reaching the destination of an outbound call*.
- Hosts outside `referenceResolution.allowedHosts`, or code that follows redirects from an
  untrusted first hop.
- File paths in `.csx` composed from instance data (`../` reachable), archive extraction,
  or uploads stored without type/size checks.

Not a finding:

- Fully hardcoded outbound URLs with no user influence (may still be flagged under
  category 8 if the host is untrusted).
- `localhost` / MockLab URLs in development seeds and test configs.
- Note: an IP/host **blocklist** is weak protection (bypassable via rebinding, encoding,
  redirects) — only a strict allow-list counts as mitigation.

## 5. Weak crypto and data protection

- Search for weak hashing (MD5/SHA-1 for security purposes), homegrown encryption, plaintext
  secret storage, or insecure transport assumptions (`http://` endpoints for real services).
- Verify that sensitive data is handled with appropriate protections and that cryptographic
  choices are documented.
- Check that `.csx` logging and view labels/content do not emit tokens, credentials, or PII.

Not a finding: MD5/CRC used for non-security checksums or cache keys.

## 6. Dependency and supply-chain risk

- Review `package.json` dependencies for known risky, unpinned, or abandoned choices.
- Check build and deployment scripts for leaking secrets or trusting unverified artifacts.
- Verify `scripts.helpers` / `encoding: "REF"` sources and `allowedAssemblies` point only to
  trusted, allow-listed origins — externally referenced code executes inside the runtime.
- Ensure third-party integrations are scoped and validated.

## 7. Misconfiguration and deployment hygiene

- Confirm `referenceResolution.allowedHosts`, `strictMode`, and
  `validateReferenceConsistency` are not weakened without a documented reason.
- Review Docker, Dapr, and other environment files for permissive settings (exposed ports,
  privileged containers, default credentials, debug flags).
- Validate that `exports` and their `visibility` are intentionally scoped — internal
  components must not leak cross-domain.
- Confirm MockLab and other test surfaces are not wired into production configuration.

## Verification rubric

Raw pattern matches are candidates, not findings. Before reporting, score each candidate:

1. **Reachability** — is the component exported/referenced and the code path reachable from a
   real transition or function call? Unreferenced/dead config drops confidence sharply.
2. **Mitigation** — does schema validation, an allow-list, or role enforcement already cover
   every path to the sink?
3. **Context** — test fixtures, MockLab seeds, examples, and generated files are usually
   informational only.

Assign a **confidence score (0–100)**: Confirmed 90+, High probability 70–89, Probable 50–69,
Possible 30–49, Informational <30. Cap severity by confidence (<30 → Info; 30–49 → max
Medium; 50–69 → max High). Merge duplicates that share a root cause into one finding listing
all locations.

Common false positives in this toolkit:

- MockLab seed data and integration-test fixtures flagged as secrets or PII
- `localhost`/`host.docker.internal` URLs in dev config flagged as SSRF or untrusted hosts
- Environment-variable or secret-store references flagged as hardcoded secrets
- Schema-validated fields flagged as injection sources (validation is the mitigation —
  verify the constraint actually restricts the dangerous characters)
- Sample domains (`example.com`, `acme`) in docs and templates

## Severity and OWASP/CWE mapping

| Severity | Meaning in a vNext domain | Typical examples |
|----------|---------------------------|------------------|
| Critical | Direct compromise of the runtime or another domain's data, no auth required | Real credentials in committed config; untrusted `REF` code source; unauthenticated privileged transition |
| High | Sensitive data exposure or privilege gain with minor preconditions | Over-broad `queryRoles` on sensitive states; SSRF from instance data; SQL built from instance data |
| Medium | Exploitable with user interaction or unusual conditions | Missing `x-roles` on sensitive fields; PII in logs; weakened `strictMode` |
| Low | Hardening gaps, best-practice violations | `http://` internal endpoint; unpinned dependency without known CVE |
| Info | Confidence <30, positive observations, defense-in-depth advice | Placeholder secrets in seeds; documentation gaps |

| Checklist category | OWASP Top 10 (2021) | Common CWE |
|--------------------|---------------------|------------|
| 1. Secrets | A05 Security Misconfiguration / A02 Cryptographic Failures | CWE-798 |
| 2. AuthN/AuthZ | A01 Broken Access Control / A07 Identification & Auth Failures | CWE-284, CWE-639 |
| 3. Injection / unsafe execution | A03 Injection | CWE-89, CWE-78, CWE-94, CWE-502 |
| 4. SSRF / traversal / files | A10 SSRF / A01 | CWE-918, CWE-22, CWE-434 |
| 5. Crypto / data protection | A02 Cryptographic Failures | CWE-327, CWE-319, CWE-532 |
| 6. Dependencies / supply chain | A06 Vulnerable & Outdated Components / A08 Software & Data Integrity Failures | CWE-1104, CWE-829 |
| 7. Misconfiguration | A05 Security Misconfiguration | CWE-16 |

For function/API surfaces, the OWASP API Security Top 10 (2023) analogues apply: BOLA
(API1) for instance-key access without caller constraints, and broken function-level
authorization (API5) for missing transition/function role checks.
