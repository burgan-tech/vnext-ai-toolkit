# Security review checklist

Use this checklist when the `security-audit` skill or the `security-reviewer` agent reviews a vNext domain.

## 1. Secrets and sensitive data

- Check for hardcoded credentials, tokens, API keys, connection strings, and private keys in component JSON, `.csx`, seed data, and config files.
- Verify that sample payloads and mock data do not expose real user data or credentials.
- Ensure logs and debug output do not contain secrets or PII.

## 2. Authentication and authorization

- Verify that workflow entry points and function execution paths enforce the expected roles or access constraints.
- Review `queryRoles`, exported visibility, and component-level exposure for over-broad access.
- Look for broken access control patterns such as IDOR or privilege escalation paths.

## 3. Injection and unsafe execution

- Review task/function mappings for unvalidated input reaching SQL, command execution, template rendering, or dynamic code execution.
- Check for unsafe deserialization, unsafe eval/exec patterns, or data flowing into interpreters or system calls.
- Validate that external data is normalized before use.

## 4. SSRF, traversal, and file handling

- Review HTTP tasks and outbound integrations for untrusted URLs or weak allow-listing.
- Check for path traversal or unrestricted file reads/writes.
- Inspect upload handling and file storage flows for validation and access control gaps.

## 5. Weak crypto and data protection

- Search for weak hashing, insecure encryption, plaintext secret storage, or insecure transport assumptions.
- Verify that sensitive data is handled with appropriate protections and that cryptographic choices are documented.

## 6. Dependency and supply-chain risk

- Review package dependencies for known risky or outdated choices.
- Check build and deployment scripts for leaking secrets or trusting unverified artifacts.
- Ensure third-party integrations are scoped and validated.

## 7. Misconfiguration and deployment hygiene

- Confirm that reference resolution and host allow-lists are not weakened without reason.
- Review Docker, Dapr, and other environment files for permissive settings.
- Validate that exported components and domain interfaces are intentionally scoped.
