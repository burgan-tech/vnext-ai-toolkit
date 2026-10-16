# Integration Test Patterns

vNext ships an official testing SDK (`VNext.Testing.Sdk`) and a dotnet project template
(`VNext.Testing.Template`). The toolkit scaffolds with the template, then layers its own
infrastructure (`templates/tests/**`) and writes one test class per workflow. **Integration tests are
expected for every workflow** — missing ones are reported as **warnings** (gates G1–G4 below), never
as blockers.

Audience: product teams. Everything here runs released runtime images (Testcontainers, or
[vnext-runtime](https://github.com/burgan-tech/vnext-runtime) / vNext Forge on the developer machine).
Nothing here asks you to build the runtime or change the vnext, vnext-example or vnext-runtime repos.

## Source of truth

- SDK + template: `https://github.com/burgan-tech/vnext-integration-test` (`GETTING_STARTED.md`).
- Published versions (nuget.org, verified 2026-10-16): **`VNext.Testing.Sdk` 0.0.6**,
  **`VNext.Testing.Template` 0.0.6** (net10.0, Testcontainers 4.7.0, xUnit 2.9.3). The getting-started
  page still shows `::1.0.0` / `--SdkVersion 1.0.0` — **1.0.0 is not published**; use 0.0.6.
- Working example: vnext-example `tests/Core.IntegrationTests/` (read-only reference).

## Two modes — decided by `VNEXT_BASE_URL`

The SDK resolves `VNEXT_BASE_URL` as **process env > `test.runsettings.local` > `test.runsettings`**
(it parses the files itself).

| | **Testcontainers** (default, CI) | **Local runtime** (opt-in) |
|---|---|---|
| `VNEXT_BASE_URL` | unset | `http://localhost:<port>` (default port **4201**) in git-ignored `test.runsettings.local` |
| Stack | SDK starts PostgreSQL, Redis, Vault, Dapr placement/scheduler, orchestrator, execution, inbox, outbox (+ sidecars), db-migrator, MockLab | whatever is running: vnext-runtime (`make up-vnext DOMAIN=<d>`) or Forge |
| Image | `ghcr.io/burgan-tech/vnext/{orchestrator,execution,inbox,outbox,db-migrator}:<VNextImageVersion>` — **SDK default `latest`**; the toolkit pins it to `vnext.config.json` `runtimeVersion` (tags have no `v`: `0.0.100`) | the running one — check `GET /health` → `domain`, `version` |
| Domain publish | `LocalDomainPublisher` (walks up to `vnext.config.json`, POSTs every component to `/api/v1/definitions/publish`, rewrites `domain`) | same |
| System package `@burgan-tech/vnext-core-runtime` | **not loaded by the SDK** (0.0.6 has no init container) → toolkit `VNextTestEnvironment.LoadSystemPackageAsync` runs the released `vnext/init` image once | vnext-runtime loads it (`vnext-init` + `vnext-component-publisher`) |
| `OnAfterEnvironmentReadyAsync` | called after publish | **never called** — do not put setup there that local mode needs |
| MockLab | SDK container `test-mocklab:5000` (`MocklabHost`), seeds from `MocklabSeedDirectory` | workspace `docker-compose.yml` (`mocklab:5000` in-network, `localhost:3001` from the host) |

The `e2e-local` skill (`/vnext-ai-toolkit:e2e`) runs Testcontainers by default, then asks whether a
local runtime is running; only with a yes (and the port) does it write `test.runsettings.local`.

## Project layout (template + toolkit layer)

```
tests/<Domain>.IntegrationTests/
├── <Domain>.IntegrationTests.csproj   # net10.0, VNext.Testing.Sdk 0.0.6, Xunit.SkippableFact,
│                                      # RunSettingsFilePath → test.runsettings.local if present
├── test.runsettings                   # committed — VNEXT_BASE_URL commented (container default)
├── test.runsettings.local             # git-ignored — written by /e2e local mode after approval
├── Config/appsettings.{orchestration,execution,inbox,outbox,db-migrator}.json   # template
├── Infrastructure/
│   ├── IntegrationTestBase.cs         # template: [Collection("VNextIntegration")], CreateApiClient
│   ├── VNextTestEnvironment.cs        # toolkit: image pin, Dapr/MockLab pins, seeds, system package,
│   │                                  #          <Domain>__ApiBaseUrl, optional morph-idm env
│   ├── WorkflowTestBase.cs            # toolkit: Caller/Headers, async transitions, waits, authorize
│   ├── OptionalDomainEndpoint.cs      # toolkit: skip (not time out) when a dependency is absent
│   └── DaprComponents/<role>/*.yaml   # template copies of SDK defaults (+ x-storage binding)
└── Tests/<Workflow>/<Workflow>Tests.cs
TEST-SCENARIOS.md                      # workspace root: pre-run checklist, suite index, run record
.claude/vnext-e2e.json                 # stamp of the last /e2e run (G4)
```

Toolkit templates: `templates/tests/{VNextTestEnvironment,WorkflowTestBase,OptionalDomainEndpoint,WorkflowTests}.cs.tmpl`,
`test.runsettings(.local).tmpl`, `TEST-SCENARIOS.md.tmpl`, `gitignore.tmpl`,
`DaprComponents/orchestration/vnext-blob-local.yaml.tmpl`, `integration-tests.github.yml.tmpl`.
Placeholders: `{{domain}}`, `{{Domain}}` (PascalCase), `{{workflowKey}}`, `{{WorkflowName}}`, `{{runtimePort}}`.

## SDK surface (0.0.6, verified from the package)

`Api` (`VNextApiClient`) — every method takes an optional headers dictionary:
`StartInstanceAsync(wf, body, headers)`, `RunTransitionAsync(wf, id, transition, body, headers)` (both
**hard-code `?sync=true`**), `GetInstanceAsync`, `ListInstancesAsync`, `GetInstanceTransitionsAsync`,
`RetryInstanceAsync`, `CallFunctionAsync`, `CallWorkflowFunctionAsync`,
`CallInstanceFunctionAsync(wf, id, fn, query, headers)`, `GetRawAsync(path, headers)`,
`WaitForHealthyAsync`. `VNextApiResponse`: `StatusCode`, `Headers`, `Body` (`JsonElement`), `RawBody`,
`IsSuccessStatusCode`. `GetCurrentState(body)` reads `currentState` / `metadata.currentState`.

`VNextTestEnvironment` overridables: `Domain`, `DatabaseName`, `VNextImage`, **`VNextImageVersion`**
(the image pin knob, also drives inbox/outbox/db-migrator), `DbMigratorImage`, `DaprSidecarImage`,
`DaprPlacementImage`, `DaprSchedulerImage`, `MocklabImage`, `MocklabSeedDirectory`, `MocklabHost`,
`EnableMocklab`, `EnableDomainPublish`, `Get{Orchestrator,Execution,Inbox,Outbox,DbMigrator}Environment()`,
`GetVaultSecrets()`, `PrepareDaprComponentsAsync(role)`, `ApplyDaprComponentSubstitutions`,
`ApplyAppSettingsSubstitutions`, `OnAfterEnvironmentReadyAsync()`; protected field `_network`;
`OrchestratorBaseUrl` (public). `DisposeAsync`/`Dispose` are **not** overridable.

SDK limits worth knowing: no wait/poll helper; no `If-None-Match`/`Range`/`HEAD`; container daprd runs
without `--max-body-size` (4Mi default); no way to bind-mount a script-plugin directory into the
orchestrator (plugin suites → local mode).

## `WorkflowTestBase` (toolkit)

| Helper | Why |
|---|---|
| `Caller` + `Headers(caller)` | credential headers `sub`, `act_sub` (always both), optional `role`, `position`, `client_id`. `x-roles` / `user_reference` are not read by authorization |
| `StartAsync` | start + fail with the runtime's body on refusal |
| `RunAsync` | `PATCH …/transitions/{key}?sync=false` (202), retries **only** 409 `Failed to acquire lock` (5 × 200 ms) |
| `RunAcceptedAsync` / `SubmitAsync` | assert accepted (then settle / don't wait — a parent stays Busy while its SubFlow runs) |
| `WaitForInstanceStateAsync` | waits for the **state**, fails fast on status `F` with the active incident |
| `WaitForObservedStateAsync` | state function view — the deepest active SubFlow |
| `AssertNotFaultedAsync` | after a start whose first state runs entry tasks |
| `AuthorizeAsync(wf, id, "transitionKey=x", caller)` | 200 → true, 403 → false — the authorization verdict |
| `GetOfferedTransitionsAsync` | state function `transitions[].name` for a caller |
| `SendRawAsync` | exact headers (including none) / verbatim JSON |

## Workflow test class (one per workflow)

`templates/tests/WorkflowTests.cs.tmpl`. Default scope = **full**: happy path to every Success/Error
Final state, one unhappy path per conditional auto pair, authorization verdicts when the flow has roles.
Smoke-only is allowed but reported as a warning.

```csharp
public class OrderApprovalTests : WorkflowTestBase
{
    private const string Workflow = "order-approval";
    public OrderApprovalTests(VNextTestEnvironment environment) : base(environment) { }
    protected override Caller DefaultCaller => Caller.WithRole("maker", "u-maker");

    [Fact]
    public async Task HappyPath_Reaches_Completed()
    {
        var id = await StartAsync(Workflow, new { amount = 100 });
        await AssertNotFaultedAsync(Workflow, id);
        await RunAcceptedAsync(Workflow, id, "submit", new { });
        await RunAcceptedAsync(Workflow, id, "approve", new { }, Caller.WithRole("approver", "u-bob"));
        await WaitForInstanceStateAsync(Workflow, id, "completed");
    }
}
```

## Authorization tests

Follow the five scenarios in `roles-and-authorization.md` § *Authorization integration tests* (role-header
caller, morph-idm caller without a role header, behalf-of, role-less, four-eyes) — `Caller.WithRole`,
`Caller.MorphIdm`, `Caller.BehalfOf`, `Caller.RoleLess`, and two `WithRole` callers with the same role
and different `act_sub`. Assert **`authorize` verdicts** and **`transitions[]`**, never read 200s or a
PATCH status: reads do not enforce `queryRoles` in-process and transitions are not role-gated at
execution (no gateway locally).

```csharp
// four-eyes: [allow maker, deny allOf[maker, $PreviousUser]]
var ayse = Caller.WithRole("maker", "u-ayse"); var bob = Caller.WithRole("maker", "u-bob");
var id = await StartAsync(Workflow, new { }, ayse);
await RunAcceptedAsync(Workflow, id, "submit", new { }, ayse);
Assert.False(await AuthorizeAsync(Workflow, id, "transitionKey=approve", ayse));
Assert.True(await AuthorizeAsync(Workflow, id, "transitionKey=approve", bob));
```

**morph-idm (optional).** Seed `templates/etc/docker/config/seed/morph-idm-roles-collection.json`
(MockLab `get-roles` keyed on `header.sub`). Testcontainers: set `VNEXT_CALLER_ROLE_PROVIDER=morph-idm`
and the toolkit `VNextTestEnvironment` adds `CallerRoleProvider__Provider=morph-idm`,
`CallerRoleProvider__MorphIdm__BaseUrl=http://<MocklabHost>:5000`,
`CallerRoleProvider__MorphIdm__GetRolesPath=/api/1/morph-idm/functions/get-roles` to orchestrator and
execution. Local mode: the same three variables in the domain's vnext-runtime env
(`domains/<d>/.env.orchestration` / `.env.execution`), plus `VNEXT_CALLER_ROLE_PROVIDER` in
`test.runsettings.local`. Tests gate themselves with `Skip.If(... != "morph-idm")`.

## MockLab URLs — `API_BASEURL` + `GetConfigValue`

`localhost` inside a container is that container: a task URL `http://localhost:3001/…` works only with a
runtime run as a host process. Ship the placeholder and resolve it in the task's input mapping:

```jsonc
"config": { "url": "API_BASEURL/api/{{domain}}/orders/create", "method": "POST" }
```

```csharp
if (task is HttpTask http)
    http.SetUrl(http.Url.Replace("API_BASEURL", GetConfigValue("{{Domain}}:ApiBaseUrl", "http://mocklab:5000")));
```

`{{Domain}}__ApiBaseUrl` is set per environment: Testcontainers → `http://<MocklabHost>:5000` (toolkit
`VNextTestEnvironment`); vnext-runtime → default `http://mocklab:5000` (MockLab compose alias on
`vnext-development`) or env in `domains/<d>/.env.orchestration`/`.env.execution`; real environments →
the real upstream. Details: `mocklab-spec.md`.

## `x-storage` (file fields) in tests

A master schema with `"x-storage": { "binding": "<name>" }` needs that Dapr binding on the
**orchestration** sidecar, otherwise start/transition answer 503 `Instance:100047`.
Testcontainers: `Infrastructure/DaprComponents/orchestration/<name>.yaml` from
`templates/tests/DaprComponents/orchestration/vnext-blob-local.yaml.tmpl` (`rootPath: /tmp/blobs`,
uploads ≤ ~3 MiB). Local: `templates/etc/runtime/**` overlay (`--max-body-size 64Mi`). Contract:
`file-fields.md`.

## Runtime surfaces worth asserting (0.0.100)

Paths are `/api/v1/{domain}/workflows/{wf}/instances/{id}/…`; endpoints without an SDK method go through
`CallInstanceFunctionAsync`, `GetRawAsync` or `SendRawAsync`.

| Surface | Path | Assert |
|---|---|---|
| Observed state | `…/functions/state` → `state`, `status`, `transitions[]`, `activeCorrelations` | poll the state, not `status` (parked auto-chains rest in Busy) |
| State ETag / 304 | `…/functions/state` + `If-None-Match` | 304, empty body (own `HttpClient`; SDK cannot send it) |
| Busy admission | second transition while Busy | 409 `Instance:100031` (not retried) |
| SubFlow proxy | transition on the parent for a child's transition | leaf validates; 400/403/409 synchronous |
| Incidents | `…/incidents/active` | `errorLayer`, `errorCode`, `traceId`; 404 `Instance:100037` when none |
| Retry | `RetryInstanceAsync` | 200; status `F` again = still failing |
| Long-poll ack | `POST …/longpoll/ack` | 200; instance leaves Busy |
| Authorize | `…/functions/authorize?transitionKey=…` / `queryRoles=true` / `functionKey=…` / `ack=true` | 200 allowed / 403 denied |
| Human-task list | `GET /api/v1/{domain}/functions/human-task` | filtered by caller roles (fail-closed) |
| Task journal | `…/functions/tasks` | executed task keys and outcomes |
| Correlations | `…/functions/instance-correlation` | SubFlow/SubProcess tree |
| File | `…/functions/file?file=<guid>` | bytes + headers; state `queryRoles` deny → 403 (enforced here); `x-roles`-hidden or foreign handle → 404 |
| Filter + sort | `…/instances?filter={json}&sort={json}` | `x-filterOperators` declaration names; filtered fields `x-indexed` |

## Gates G1–G4 (warn-only)

| Gate | Rule | Checked by |
|---|---|---|
| G1 | a test project exists and builds | `scripts/check-test-coverage.sh [--build]`, validator (`dotnet build`) |
| G2 | every workflow key is referenced by a test class | check-test-coverage, PostToolUse hook on `*/Workflows/*.json` |
| G3 | every Success/Error Final state asserted; one unhappy path per conditional auto pair (heuristic: the state key appears in the test) | check-test-coverage |
| G4 | `.claude/vnext-e2e.json`: `failed == 0`, `runtimeVersion` = `vnext.config.json`, `componentsHash` = current | check-test-coverage; written by `/e2e` |

Stamp: `{ "runtimeVersion", "mode", "passed", "failed", "skipped", "date", "componentsHash" }` —
`componentsHash` = `scripts/check-test-coverage.sh --hash`.

Report wording: **WARN**, never FAIL/blocker. The user may skip tests; the skip is recorded as a warning.

## Traps

Pre-run checklist and traps live in the workspace `TEST-SCENARIOS.md` (template
`templates/tests/TEST-SCENARIOS.md.tmpl`): parked Busy, lock-contention 409, discarded `RunAsync` status,
reads not enforcing `queryRoles`, deny not bought back, `act_sub` for `$InstanceStarter`, publish
immutability (patch bump on 409 `Instance:100002`), cold MockLab, green-without-traces.

## Sources

- `VNext.Testing.Sdk` 0.0.6 (nuget.org; members verified from the package metadata), `GETTING_STARTED.md`
- vnext-example `tests/Core.IntegrationTests/` (`WorkflowTestBase`, `OptionalDomainEndpoint`,
  `TEST-SCENARIOS.md` § pre-run check), `etc/docker/config/seed/morph-idm-roles-collection.json`
- vnext-runtime `vnext/docker/docker-compose.yml` (network `vnext-development`, `VNEXT_VERSION`,
  `vnext-init` + `vnext-component-publisher`)
- Runtime 0.0.100 docs: `docs/testing/integration-testing.md`, `docs/runtime/file-storage.md`
