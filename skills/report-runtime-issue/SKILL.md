---
name: report-runtime-issue
description: Use when a vNext problem looks runtime-caused rather than domain-caused and should be reported to the runtime team — triggers "runtime hatası", "runtime bug", "runtime sorunu", "issue aç", "vnext'e bildir", "report issue", or a hand-off from validate-and-fix, e2e triage, domain-check or the reviewer. Triages first (known issue? domain-side cause?), searches for duplicates, collects and redacts evidence, drafts an English issue for burgan-tech/vnext, and creates it with gh only after the user approves; falls back to a local draft plus a prefilled new-issue URL.
---

# Report a runtime issue to burgan-tech/vnext

Product teams build domains on vNext but have **no write access** to `vnext`, `vnext-example`,
`vnext-schema` or `vnext-docs`. When the runtime itself misbehaves, the path is a well-evidenced
issue on the public repo **`burgan-tech/vnext`** — not a patch, not a local runtime build, not a
script from the runtime repo. This skill gets the team from "something is wrong" to a filed,
reproducible, redacted issue, and refuses to file when the cause is known or domain-side.

Talk to the user in their language; the **issue itself is always English**.

## Hard rules

- **Target repo is `burgan-tech/vnext`.** Never create an issue anywhere else unless the user
  explicitly names another repo in chat.
- **Never auto-file.** No `gh` *write* call (`gh issue create`, `gh issue comment`, `gh api -X POST…`)
  before the user answers **yes** to the exact draft (step 6). Read-only calls (`gh issue list`,
  `gh issue view`, `gh search issues`, `gh auth status`) are fine at any time.
- **Redaction is mandatory** (step 4). Nothing leaves the machine unredacted — not the body, not the
  search keywords, not the prefilled URL.
- **Observed behaviour only.** The reporter has no runtime source access; do not invent class names,
  file paths or root causes. Public docs, schema clauses and vnext-meta ids may be cited.
- **Never auto-apply a workaround** to the domain. Suggest it; the user decides.

## 1. Triage — is it really the runtime?

Work through these in order and stop at the first conclusive answer.

1. **Validate.** `npm run validate`. A genuine validation error is an authoring issue →
   hand back to `validate-and-fix`. If the failure is a schema↔runtime disagreement, continue.
2. **Toolkit's known gaps.** Match the symptom (error text, member path, publish 400 message) against
   [references/concepts/schema-runtime-gaps.md](../../references/concepts/schema-runtime-gaps.md)
   (quick-lookup table, D-rows, publish-time rules, documentation drift). A matching row → give its
   **author workaround**, do not file.
3. **Live vnext-meta from vnext master** (the source of truth; the toolkit copy is only a snapshot):

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/vnext-meta-live.sh known-issues
   ${CLAUDE_PLUGIN_ROOT}/scripts/vnext-meta-live.sh deprecations
   ${CLAUDE_PLUGIN_ROOT}/scripts/vnext-meta-live.sh migrations
   ```

   - `known-issues.items[]`: match on `component`, `path`, `title`; check `affectedVersions` against
     the workspace `runtimeVersion` and `fixedIn`. Match with `fixedIn: null` → **known, open**: give
     the `workaround`, quote the `id`, do not file. Match with `fixedIn` ≤ a newer runtime → tell the
     user to bump `runtimeVersion` (`/vnext-ai-toolkit:vnext-update`), do not file.
   - `deprecations.items[]`: the field/behaviour is deprecated or removed (`deprecatedSince`,
     `removedAt`, `replacement`) → migrate, do not file.
   - `migrations.items[]`: an intentional behaviour change since `since` → explain the `action`,
     do not file (unless the new behaviour contradicts its own description — then it *is* a bug).
   - Exit code 3 (offline, no cache) → fall back to the snapshot
     [references/runtime-feature-matrix.md](../../references/runtime-feature-matrix.md) (Known issues /
     Deprecations / Migrations sections) and say the check used the snapshot.
4. **vnext-docs.** WebFetch the relevant page under `https://burgan-tech.github.io/vnext-docs/docs/…`
   (page map: [references/external-sources.md](../../references/external-sources.md)) and the release
   notes / breaking-change post for the workspace `runtimeVersion`. Behaviour that matches the docs is
   not a bug (at most an `enhancement`). Behaviour that **contradicts** the docs is reportable — cite
   the URL. Docs that are wrong while the runtime is right → label `documentation`.
5. **Domain-side causes** — rule these out explicitly before calling it a runtime bug:
   - **Roles / headers:** is the caller sending `sub`, `act_sub`, `role`, `position`, `client_id` as
     the role provider expects (`default` reads `role`; `morph-idm` needs `act_sub`/`sub`/`position`
     or a non-blank `role`)? Wrong header names (`x-roles`, `user_reference` are not read by the
     runtime) are domain-side. See [references/concepts/roles-and-authorization.md](../../references/concepts/roles-and-authorization.md).
   - **`queryRoles` / `roles` grants** on the workflow, function or transition; long-poll `ack` roles.
   - **Mappings / scripts:** exception inside a `.csx`, wrong `ScriptResponse` shape, missing
     `SetKey`, wrong encoding (B64 vs `NAT`) — check `functions/actions?taskId=` output.
   - **Schema role / attributes:** `attributes.type` role mismatch, `x-roles` pruning a field on read,
     master schema filtering.
   - **Downstream dependency:** MockLab rule missing, real service 5xx (`errorLayer: Transport`,
     `errorCode: Task:Http:5xx`) — that is the dependency, not the runtime.

   Domain-side → explain the cause and the fix, then **stop**. Hand back to the calling skill if any.

Only when none of the above explains it, continue. If it is still ambiguous, say so and offer to
file with label `needs-info` alongside `bug` rather than guessing.

## 2. Duplicate search (read-only)

Build 2–4 keyword sets from the **redacted** symptom: component/feature name, error code
(`Instance:100037`, `Transition:100017`), endpoint (`functions/data`), task type name. Never put
customer data, internal hosts or names in a query — search terms go to a public API.

```bash
gh issue list --repo burgan-tech/vnext --search "<keywords>" --state all --limit 20
gh issue view <n> --repo burgan-tech/vnext          # read the promising ones
```

Without gh (or unauthenticated):
`curl -s "https://api.github.com/search/issues?q=repo:burgan-tech/vnext+<url-encoded keywords>"`.

- **Duplicate found (open):** give the link and a one-line summary. Offer to draft a **comment**
  that adds only new evidence (another version, another repro). The comment goes through the same
  redaction and approval gate (steps 4 and 6); create it with
  `gh issue comment <n> --repo burgan-tech/vnext --body-file <file>` only after **yes**.
- **Closed as fixed:** name the version it shipped in; suggest bumping `runtimeVersion`.
- **Closed as not planned / by design:** tell the user, do not reopen-by-new-issue unless there is
  materially new evidence — then reference the old issue in the new body.

## 3. Collect evidence

Gather the minimum that lets a maintainer reproduce it. Prefer facts the user already has; ask for
the rest. Base URL: the workspace `.http` `@baseUrl` (local vnext-runtime: `http://localhost:4201`).

| Evidence | Source |
|---|---|
| `runtimeVersion`, `schemaVersion`, domain name | `vnext.config.json`; installed schema `node_modules/@burgan-tech/vnext-schema/package.json` |
| Toolkit version | `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` `.version` |
| Role provider | `default` or `morph-idm` (`CallerRoleProvider:Provider`) — ask if unknown |
| Deployment | local vnext-runtime (docker compose, image tag), Testcontainers (VNext.Testing.Sdk), or a shared env (name it generically: "shared test env") |
| Component excerpts | the **smallest** JSON fragment that triggers it (one state + transition + task), not whole files; `.csx` only the relevant method |
| Request / response | method, path, status, response body (trimmed), `X-Request-Id`, `X-Trace-Id` / `traceparent`, `X-Workflow` |
| Incident | `GET …/instances/{id}/incidents/active` → `errorCode`, `errorLayer`, `statusCode`, `boundaryAction`, `traceId` |
| Step detail | `GET …/instances/{id}/functions/tasks`, `…/functions/actions?taskId=` |
| Metrics (0.0.99+) | `GET …/instances/{id}/transitions/{key}/metrics`, `…/states/{key}/metrics` |
| Logs | `WorkflowLogs` EventIds and message text around the `x_request_id` (e.g. `JobFailed` 40075) |
| Repro | numbered minimal steps; does it reproduce on Testcontainers / a clean local runtime? every time or intermittently? |

Recipes: [references/concepts/observability.md](../../references/concepts/observability.md) §5
(failed transition) and §6 (stuck / Busy),
[references/concepts/incidents-and-retry.md](../../references/concepts/incidents-and-retry.md).
Read-only HTTP calls against the user's **local** runtime are fine; never call a shared environment
without the user asking.

## 4. Redact (mandatory)

Before anything is shown as a draft, scrub every collected artefact and **list what was redacted**
(category + count, never the original value):

| Category | Replace with |
|---|---|
| Secrets, API keys, tokens, JWTs, `Authorization` / cookie headers, passwords, client secrets | `<redacted-token>` |
| Connection strings, Dapr secret-store values, certificates | `<redacted-connection-string>` |
| PII — TCKN / national ids, IBAN / account / card numbers, phone, e-mail, person names, addresses, birth dates | `<tckn>`, `<iban>`, `<phone>`, `<email>`, `<name>` … |
| Internal hosts, IPs, internal URLs, cluster / namespace names | `<internal-host>` (keep `localhost:4201` and public GitHub/docs URLs) |
| Customer / business data in instance payloads | shape-preserving placeholders (`"amount": 0`, `"customerNo": "<id>"`) |
| `sub` / `act_sub` / `position` / `client_id` values | `<user-1>`, `<operator-1>`, `<client-1>` (keep them consistent across the body) |

Keep what a maintainer needs: status codes, error codes, EventIds, component keys, field paths,
versions, trace/request ids (random UUIDs are not PII). If redaction would remove the very thing
that shows the bug, describe it instead ("the IBAN field is returned unmasked although `x-masking`
is declared"). The user sees only the redacted draft.

## 5. Draft (English)

Read [TEMPLATE.md](TEMPLATE.md) for the title rules, body template and worked examples.

- Title: `[bug] …` / `[enhancement] …` (also `[docs] …`, `[performance] …`), ≤ 72 chars, states the
  observable behaviour, not a guessed cause.
- Labels: one of `bug`, `enhancement`, `documentation`, `performance`; add `needs-info` when the
  repro is incomplete.
- Body sections: Summary, Impact, Steps to Reproduce, Expected, Actual, Environment, Evidence,
  Suspected area, Workaround, then the footer `Reported via vnext-ai-toolkit vX.Y.Z`.
- One problem per issue; split unrelated findings.

## 6. Approval gate

Write the draft to `.vnext/issues/<yyyy-mm-dd>-<slug>.md` in the workspace (title on the first line
as `# <title>`, a `<!-- labels: … -->` line, then the body), then show:

```
────────────────────────────────────────
  RUNTIME ISSUE DRAFT → burgan-tech/vnext
────────────────────────────────────────
Title:   <title>
Labels:  <labels>
Redacted: <category: count, …>
Duplicates checked: <queries> → <none | #n …>

<body>
────────────────────────────────────────
Create this issue? (yes / edit / cancel)
────────────────────────────────────────
```

- **yes** → step 7 · **edit** → apply, re-redact, show again · **cancel** → keep the draft file,
  stop. Approval covers this exact draft only; any later change needs a new **yes**.

## 7. Create

```bash
gh auth status
gh issue create --repo burgan-tech/vnext --title "<title>" --label "<label>" --body-file <body file>
```

`<body file>` is the body part of the draft (without the `# title` / labels lines) — write it next
to the draft as `<slug>.body.md`. Reporters without triage rights may get a label permission error:
retry the **same approved** content once without `--label` and say so (the title prefix carries the
type; maintainers add labels).

**gh missing or not authenticated** — do not ask for a token and do not try to log in for the user:

1. Keep the draft at `.vnext/issues/<yyyy-mm-dd>-<slug>.md`.
2. Give a prefilled URL, URL-encoding each value:
   `https://github.com/burgan-tech/vnext/issues/new?title=<title>&labels=<label>&body=<body>`.
   If the encoded URL would exceed ~6000 characters, drop `&body=` and tell the user to paste the
   draft file's body. Labels in the URL apply only for users with triage rights.
3. Mention `gh auth login` as the faster path next time.

## 8. Inform the user

- The issue link (or the draft path + URL), title and labels.
- What happens next: runtime maintainers triage on GitHub; watch the issue for `needs-info`
  questions; the fix ships in a runtime release — then bump `runtimeVersion`
  (`/vnext-ai-toolkit:vnext-update`) and re-test.
- **Interim workaround as a suggestion only** — e.g. a comment/note on the affected component or a
  `.http` reminder; never edit domain components automatically.
- Optional: if the workspace keeps notes (`NOTES.md`, `docs/`, `.vnext/notes.md`), offer to record
  the issue link next to the affected component.

## Hand-offs into this skill

`validate-and-fix` (schema↔runtime gap not in the known list), e2e / integration-test triage
("domain is right, runtime is not"), `domain-check`, and the reviewer (runtime behaviour contradicts
docs) can invoke this skill. They pass their findings as the starting evidence; this skill still
runs triage step 1 (cheaply, from what is already known) before drafting.
