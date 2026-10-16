---
name: e2e-local
description: Use when the user wants to run the domain's integration tests end to end on their machine — triggers "e2e", "integration testleri koş", "run the tests", "dotnet test", "uçtan uca test", or /vnext-ai-toolkit:e2e. Preflight, then Testcontainers with the runtime image pinned to vnext.config.json runtimeVersion (default) or — only if the user says a local runtime is running and gives its port — that runtime; validate, run per workflow, triage reds into environment / fixture / domain / runtime, record the run in TEST-SCENARIOS.md and the .claude/vnext-e2e.json stamp. Warn-only: never blocks other work.
---

# e2e-local — run the integration tests end to end

Product teams run **released** runtime images only: Testcontainers (default, same as CI) or a runtime
already running on their machine from [vnext-runtime](https://github.com/burgan-tech/vnext-runtime) or
vNext Forge. Never build the runtime, never run scripts from the vnext / vnext-example repos, never edit
vnext-runtime files. A runtime defect becomes an issue (`/vnext-ai-toolkit:report-issue`), not a patch.

Arguments: `[<workflow-key> | --all] [--mode container|local]` (default: workflows changed since the
last stamp, else `--all`; mode chosen in step 2).

References: `references/concepts/integration-test-patterns.md`, workspace `TEST-SCENARIOS.md`
(pre-run checklist and traps), `references/concepts/roles-and-authorization.md`,
`references/concepts/observability.md`, `references/concepts/incidents-and-retry.md`.

## 1. Preflight (read-only)

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/e2e-preflight.sh --mode container
```

Show the WARN/STOP lines (not the OK ones). Exit 3 = a STOP for that mode:

- no test project → offer the `integration-test` skill (it scaffolds); declined → stop with a warning;
- no Docker / .NET 10 → explain, offer local mode only if a runtime is already running;
- `VNEXT_BASE_URL` already resolves somewhere (env / `.local` / committed file) → tell the user which
  runtime the SDK would hit; container mode needs it unset (they decide; never edit the committed file
  silently).

Container-mode WARNs to fix (with the user's OK, by rendering `${CLAUDE_PLUGIN_ROOT}/templates/tests/*`):
image tag not pinned (`VNextImageVersion` → `runtimeVersion`), daprd/MockLab unpinned, system package not
loaded, `x-storage` binding missing, hard-coded `localhost` task URLs (→ `API_BASEURL` + `GetConfigValue`,
see `mocklab-spec.md`), `allowedAssemblies` (plugin suites need local mode).

## 2. Mode

Default **Testcontainers**: image `ghcr.io/burgan-tech/vnext/*:<runtimeVersion>` (no `v`), SDK Dapr
component overrides from `Infrastructure/DaprComponents/**` (incl. the blob binding when a master schema
has `x-storage`), system package via `LoadSystemPackageAsync`, MockLab seeds from
`etc/docker/config/seed/`.

Then **ask** (AskUserQuestion): "Do you have a local vNext runtime running (vnext-runtime or Forge)?"
- **No / not sure** → stay on Testcontainers.
- **Yes** → ask the port (default **4201**), then
  `${CLAUDE_PLUGIN_ROOT}/scripts/e2e-preflight.sh --mode local --port <p>`: `/health` must answer and its
  `domain` must equal `vnext.config.json` `domain` (STOP otherwise — wrong port); a `version` other than
  `runtimeVersion` is a warning to state in the report. Show the rendered
  `${CLAUDE_PLUGIN_ROOT}/templates/tests/test.runsettings.local.tmpl` (`{{runtimePort}}`, `{{domain}}`)
  and write `tests/<Domain>.IntegrationTests/test.runsettings.local` **only after approval**; confirm it
  is git-ignored. Local mode is also the answer for script-plugin suites and large file uploads.

Remember the choice for the session; to go back to Testcontainers, delete `test.runsettings.local`.

## 3. Validate, build

```bash
npm run validate                                   # schema gate — fix with validate-and-fix first
dotnet build tests/<Domain>.IntegrationTests -v q
```

Component changed since its last publish to the **same** runtime (local mode, or a reused DB)? Publish is
version-immutable — the same version with new content answers 409 `Instance:100002`: offer a **patch
bump** of the changed components (and every fully-versioned reference) before running.

## 4. Run per workflow

One filter per workflow class (keeps failures attributable):

```bash
dotnet test tests/<Domain>.IntegrationTests --filter "FullyQualifiedName~<WorkflowName>Tests" -v minimal \
  --logger "trx;LogFileName=e2e-<workflow>.trx"
```

`--all` runs them one after another (the first Testcontainers run pulls images — minutes). Collect
passed / failed / skipped per class. Skips are **expected** for absent optional dependencies
(`[optional-endpoint] … skip` lines) — report them, never count them as reds.

## 5. Triage every red

Cluster by error signature first, then classify each cluster — with evidence, never "flaky" by default:

| Cause | Typical evidence | Next step |
|---|---|---|
| **environment** | Docker/pull errors, `/health` down, wrong domain/port, MockLab unreachable, seed not re-imported (`down -v`), missing blob binding → 503 `Instance:100047`, plugin dir missing, system package missing, `localhost` URL from a container | fix the environment; re-run |
| **fixture** (the test) | trap list in `TEST-SCENARIOS.md`: waiting on status instead of state (parked Busy), discarded `RunAsync` status, 409 lock not retried, expecting 403 from a read, no `act_sub` for `$InstanceStarter`, payload not matching the transition schema, stale version → 409 `Instance:100002` | fix the test / bump the version |
| **domain** (the components) | task fault in `incidents/active` with a domain error (mapping exception, wrong URL/route, rule logic), wrong grant, schema rejection | fix the component (validate-and-fix / component skills) |
| **runtime** | behaviour contradicts the documented contract on the pinned version, reproducible on a clean instance, not in `schema-runtime-gaps.md` / vnext-meta known issues | offer **`/vnext-ai-toolkit:report-issue`** with the evidence below |

Evidence sources (quote numbers, not impressions):
- `GET …/instances/{id}/incidents/active` → `errorCode`, `errorLayer`, `traceId`; `GET …/functions/tasks`
  (task journal); `GET …/instances/{id}/transitions/{key}/metrics` (per-attempt tasks, `error`).
- `WorkflowTestBase.DescribeAsync` output in the failure message (state/status + active incident).
- MockLab `GET http://localhost:3001/_admin/logs` (the exact request the runtime sent) and the
  `X-Mocklab-Template-Error` response header (local mode; in container mode read the Testcontainers log).
- OpenObserve `http://localhost:5080` (vnext-runtime infra) by `x_request_id` / instance id.
- Testcontainers console lines `[TestEnv] …`, `[DomainPublisher] FAIL …`, `[<domain>-tests] WARNING …`.

## 6. Record

1. **`TEST-SCENARIOS.md`** (workspace root; create from `templates/tests/TEST-SCENARIOS.md.tmpl` if
   missing — ask first): add one row at the top of *Run record*:
   `| <date> | <mode> | <runtime version actually tested> | <scope> | P / F / S | <each red: test → cause> |`.
2. **Stamp** `.claude/vnext-e2e.json` (always, even when red):

   ```json
   { "runtimeVersion": "<vnext.config.json runtimeVersion>", "mode": "container|local",
     "passed": 0, "failed": 0, "skipped": 0, "date": "<YYYY-MM-DD>",
     "componentsHash": "<output of ${CLAUDE_PLUGIN_ROOT}/scripts/check-test-coverage.sh --hash>" }
   ```
   In local mode with a different runtime version, record `runtimeVersion` from `vnext.config.json`
   only if `/health` matched it; otherwise record the tested version (G4 will then warn — correct).
3. `${CLAUDE_PLUGIN_ROOT}/scripts/check-test-coverage.sh` → list remaining G1–G4 **warnings**.

## Report

- Mode, runtime image/version, base URL; per-workflow passed/failed/skipped table.
- Each red: test, cause class, one-line evidence, next step (runtime → `/vnext-ai-toolkit:report-issue`).
- Coverage warnings (G2/G3) and whether the stamp is now green (G4).
- "Not verified against traces" when OpenObserve was not consulted.

## Never

- Never edit or run anything inside vnext, vnext-example or vnext-runtime checkouts (reading is fine).
- Never write `test.runsettings.local` or change `test.runsettings` without approval.
- Never mark a red as flaky or skip it without a cause; never block other work because tests are red.
