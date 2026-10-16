---
name: integration-test
description: Use after a workflow is scaffolded or changed, or to add coverage to an existing one. Generates the xUnit integration test class for a workflow against the official VNext.Testing.Sdk — full scope by default (happy path to every Final state, one unhappy path per conditional auto pair, authorization verdicts when the flow has roles). Scaffolds the test project if missing (official template + toolkit infrastructure). Integration tests are expected for every workflow; a skipped or smoke-only test is reported as a warning, never a blocker.
---

# Integration Test

Every workflow is expected to have an integration test class (gates G1–G4, **warn-only**). This skill
writes it. Running the suite end to end is `/vnext-ai-toolkit:e2e` (skill `e2e-local`).

Reference: `references/concepts/integration-test-patterns.md` (modes, SDK surface, helpers, gates).
Authorization scenarios: `references/concepts/roles-and-authorization.md` § *Authorization integration tests*.

## Pre-check — test project

Look for a `*.csproj` referencing `VNext.Testing.Sdk` (usually `tests/<Domain>.IntegrationTests/`).

**Missing →** offer to scaffold it now (default **yes**; or hand off to `/vnext-ai-toolkit:vnext-init`
Step 7, which does the same). If the user declines, say once: "No test project — G1/G2 will be reported
as warnings by validate/review" and stop.

Scaffold (needs the .NET 10 SDK; Docker only to run):

```bash
dotnet new install VNext.Testing.Template::0.0.6          # 1.0.0 in GETTING_STARTED is not published
cd tests
dotnet new vnext-integration-test --DomainName <Domain> --AppDomain <domain> --SdkVersion 0.0.6
cd <Domain>.IntegrationTests && dotnet add package Xunit.SkippableFact
```

`<Domain>` = PascalCase of `vnext.config.json` `domain`. The project must live inside the workspace
(the SDK walks up to `vnext.config.json`). Then add the toolkit layer — render each
`${CLAUDE_PLUGIN_ROOT}/templates/tests/*.tmpl` with `{{domain}}`, `{{Domain}}` (and nothing else); a
file the template already generated is **diffed and confirmed**, never overwritten silently:

| Template | Target |
|---|---|
| `VNextTestEnvironment.cs.tmpl` | `Infrastructure/VNextTestEnvironment.cs` — image tag = `runtimeVersion`, daprd/MockLab pins, workspace seeds, system package, `<Domain>__ApiBaseUrl`, optional morph-idm |
| `WorkflowTestBase.cs.tmpl` | `Infrastructure/WorkflowTestBase.cs` |
| `OptionalDomainEndpoint.cs.tmpl` | `Infrastructure/OptionalDomainEndpoint.cs` |
| `test.runsettings.tmpl` | `test.runsettings` (VNEXT_BASE_URL **commented** — Testcontainers default) |
| `TEST-SCENARIOS.md.tmpl` | `TEST-SCENARIOS.md` at the workspace root |
| `gitignore.tmpl` | append missing lines to `.gitignore` (`*.runsettings.local`, …) |
| `DaprComponents/orchestration/vnext-blob-local.yaml.tmpl` | only if a master schema declares `x-storage` — one file per binding, `metadata.name` = binding |

Check the csproj prefers `test.runsettings.local` when present (`RunSettingsFilePath` condition, as in
vnext-example) and references `VNext.Testing.Sdk` **0.0.6**.

## Steps

### 1. Pick the workflow

From `vnext.config.json`: `paths.componentsRoot`, `paths.workflows`, `domain`. Default to the workflow
just scaffolded/edited; otherwise ask. Read its JSON: `startTransition`, `states[]` (`stateType`,
`subType`, `transitions[]`, `queryRoles`), `sharedTransitions`, master schema, transition schemas,
tasks (HTTP → MockLab mocks), `roles` on transitions.

### 2. Test surface

| Element | Test |
|---|---|
| Final state (`stateType: 3`), Success/Error | a path that reaches it — `WaitForInstanceStateAsync(wf, id, "<key>")` + status `C` |
| Conditional auto pair (`triggerType: 1` with rules) | one test per branch; the false branch is the unhappy path |
| Manual transition (`0`) | `RunAcceptedAsync` (async, lock-retry); refusals asserted via `RunAsync` status |
| Timer (`2`) / event (`3`) | wait with a generous timeout / publish the event (Dapr) or mark as local-mode only |
| Entry tasks on the first state | `AssertNotFaultedAsync` right after `StartAsync` |
| HTTP task | MockLab mock in `etc/docker/config/seed/<domain>-collection.json` (success + one failure rule) |
| Fault path | MockLab 500 → `incidents/active` (`errorCode`, `traceId`) → fix rule → `RetryInstanceAsync` |
| Roles / grants | `AuthorizeAsync` verdicts + `GetOfferedTransitionsAsync` per the five scenarios (below) |
| Human state (`subType: 6`) | `GET /api/v1/<domain>/functions/human-task` with an allowed vs a denied `Caller` |
| SubFlow | `SubmitAsync` on the parent (it stays Busy), `WaitForObservedStateAsync` for the child |
| Long-poll `terminate: true` | `interaction.ack` in the state body → `POST …/longpoll/ack` |
| `x-storage` field | start with `{ name, mimeType, content }` → handle in `functions/data`; `functions/file?file=` |

### 3. Scope — full by default

Default **full**: every Success/Error Final state + one unhappy path per conditional auto pair +
authorization tests when any grant exists. The user may choose **smoke-only** (start + first state):
accept it, and state the warning "smoke-only: G3 will warn for <final states / branches>".

### 4. Generate the class

`tests/<Domain>.IntegrationTests/Tests/<WorkflowName>/<WorkflowName>Tests.cs` from
`${CLAUDE_PLUGIN_ROOT}/templates/tests/WorkflowTests.cs.tmpl` (`{{workflowKey}}`, `{{WorkflowName}}`,
`{{Domain}}`). Derive from `WorkflowTestBase`; the workflow key and every asserted state key appear as
string literals (the coverage gate reads them). Each `[Fact]` starts its own instance. Payloads must
satisfy the transition schemas (`StartAsync` fails with the runtime's 400 body otherwise).

Authorization — always send `sub` **and** `act_sub` (`Caller`):

| Scenario | Caller |
|---|---|
| role-header caller | `Caller.WithRole("maker", "u-ali")` |
| morph-idm caller (optional) | `Caller.MorphIdm("idm-maker")` — no role header; `[SkippableFact]` + `Skip.If(Environment.GetEnvironmentVariable("VNEXT_CALLER_ROLE_PROVIDER") != "morph-idm")`; seed `templates/etc/docker/config/seed/morph-idm-roles-collection.json` |
| behalf-of | start with `Caller.BehalfOf("u-agent", "c-acme")`; approver sends `sub: c-acme` → `$InstanceBehalfOfStarter` |
| role-less | `Caller.RoleLess("u-x")` — allow-lists refuse, identity grants match |
| four-eyes | `WithRole("maker","u-ayse")` submits → `authorize?transitionKey=approve` false for her, true for `WithRole("maker","u-bob")` |

Never assert authorization through a read's 200/403 or a PATCH status.

### 5. Optional dependencies skip, never time out

Anything not always present (a partner domain, MockLab admin API, morph-idm provider, script plugins)
is resolved with `OptionalDomainEndpoint.Resolve(...)` / an env check and `Skip.If(...)`
(`[SkippableFact]`). Add the suite's dependencies as a row in `TEST-SCENARIOS.md` § *Suite index*.

### 6. Companion `.http` (optional)

`api-tests/<workflow-key>.http` from `${CLAUDE_PLUGIN_ROOT}/templates/.http.tmpl`
(`@baseUrl = http://localhost:4201`) for manual probing. The xUnit class stays the source of truth.

### 7. Run (or hand over)

```bash
dotnet build tests/<Domain>.IntegrationTests
/vnext-ai-toolkit:e2e <workflow-key>     # preflight → Testcontainers (default) or your local runtime → triage
```

Direct run: `dotnet test tests/<Domain>.IntegrationTests --filter "FullyQualifiedName~<WorkflowName>Tests"`.
Component changes need a **patch bump** before re-running against the same runtime (publish is
version-immutable: 409 `Instance:100002`).

### 8. CI (recommended, not required)

Offer `${CLAUDE_PLUGIN_ROOT}/templates/tests/integration-tests.github.yml.tmpl` (Testcontainers on the
runner). Never edit CI without the user's confirmation.

## Report

- Files written; scope (full / smoke-only → **warning**); Final states and branches covered vs not.
- Output of `${CLAUDE_PLUGIN_ROOT}/scripts/check-test-coverage.sh --workflow <key>` (WARN lines only).
- If the user skipped the test entirely: "**Warning:** `<workflow-key>` has no integration test (G2)".
