---
name: integration-test
description: Use after a workflow is scaffolded (or to add coverage to an existing one). Generates an xUnit integration test class against the official VNext.Testing.Sdk that asserts the workflow's lifecycle — start, transitions, final state. If no test project exists, scaffolds one with the official VNext.Testing.Template (dotnet new vnext-integration-test) or hands off to /vnext-init.
---

# Integration Test

vNext ships an official integration testing **SDK** (`VNext.Testing.Sdk`) and a **dotnet project
template** (`VNext.Testing.Template`), both maintained by the platform team. The SDK spins up the
full Docker stack (PostgreSQL, Redis, Vault, Dapr, runtime, MockLab) via Testcontainers and drives a
workflow through its API. The toolkit does **not** hand-roll the test project — it scaffolds with the
official template, then writes test classes against the SDK.

> **Source of truth — fetch when unsure.** The SDK/template evolve; verify package versions, the
> `dotnet new` short name, override property names, and the API surface against
> `https://github.com/burgan-tech/vnext-integration-test/blob/master/GETTING_STARTED.md`
> (raw: `https://raw.githubusercontent.com/burgan-tech/vnext-integration-test/master/GETTING_STARTED.md`).
> Full layout reference: `references/concepts/integration-test-patterns.md`.

## Pre-check — does a test project exist?

```
Look for a *.IntegrationTests.csproj (typically under tests/<DomainName>.IntegrationTests/).

If present:  Continue to Step 1.
If missing:  Offer to scaffold it with the official template (below), OR hand off to /vnext-init
             (which runs the same template). Do NOT hand-write the project files.
```

### Scaffold (only if missing)

```bash
# Once per machine:
dotnet new install VNext.Testing.Template

# In the workspace's tests/ folder:
dotnet new vnext-integration-test \
  --DomainName <PascalCaseDomain> \   # from vnext.config.json domain, PascalCased (e.g. MorphFx)
  --AppDomain  <domain-slug>          # the lower-case vnext.config.json domain (e.g. morphfx)
  # optional: --VNextImage ghcr.io/burgan-tech/vnext   --SdkVersion 1.0.0
```

This generates `<DomainName>.IntegrationTests/` with `Config/`, `Infrastructure/`
(`IntegrationTestBase.cs`, `VNextTestEnvironment.cs`, `DaprComponents/`, `MocklabSeed/`),
`Helpers/TestDataBuilder.cs`, `Tests/SmokeTests.cs`, and `test.runsettings`. Requires the **.NET 10
SDK** and a running Docker Desktop. The SDK finds `vnext.config.json` by walking up the directory
tree, so the test project must live inside the domain workspace.

## Steps

### 1. Read the target workflow

From `vnext.config.json`: `componentsRoot`, `paths.workflows`, `domain`. The workflow JSON is at
`{componentsRoot}/{paths.workflows}/{workflow-key}/{workflow-key}-workflow.json`.

Ask: "Which workflow should I generate tests for?" (Default to the most recently modified one if obvious.)

Read the workflow JSON. Extract:
- `attributes.startTransition` — the first transition fired automatically
- `attributes.states[]` — every state with its `stateType`, `isFinal`, `view`
- `attributes.transitions[]` — every transition with its `triggerType`, source/target, payload schema

### 2. Identify the test surface

For each state and transition, note:
- **Manual transitions (`triggerType: 0`)** — explicitly fired in tests via `RunTransitionAsync`
- **Auto transitions (`triggerType: 1`)** — fire on their own; the test polls `GetInstanceAsync` until
  the expected state settles
- **Timer transitions (`triggerType: 2`)** — fire after a duration; poll with a generous timeout
- **Event transitions (`triggerType: 3`)** — need an external signal
- **Final states** — assert `GetCurrentState(...)` equals the final state key

### 3. Decide test scope with the user

Ask:
- **Smoke-only?** Start instance → assert it moved past the initial state. (`SmokeTests.cs` already
  covers health + ListInstances.)
- **Happy path?** Fire every manual transition with valid payload → assert the expected Final state.
  **(Recommended for the first test.)**
- **Full coverage?** Happy path + one unhappy-path test per branch (auto transition's "false" branch,
  error states).

Default: Happy path.

### 4. Generate the test class

File path: `tests/<DomainName>.IntegrationTests/Tests/{WorkflowName}Tests.cs` (PascalCase from key).

Skeleton (Happy path) — uses the **real** SDK API (`RunTransitionAsync`, `VNextApiResponse.Body`,
`GetCurrentState`; no `ExecuteTransitionAsync`/`WaitForStateAsync`/`GetStateAsync`):

```csharp
using <DomainName>.IntegrationTests.Infrastructure;
// using <DomainName>.IntegrationTests.Helpers;   // TestDataBuilder, if you add builders

namespace <DomainName>.IntegrationTests.Tests;

public class {WorkflowName}Tests : IntegrationTestBase   // carries [Collection("VNextIntegration")]
{
    private const string Workflow = "{workflow-key}";

    public {WorkflowName}Tests(VNextTestEnvironment environment) : base(environment) { }

    [Fact]
    public async Task Happy_Path_Reaches_{FinalStateName}()
    {
        // Arrange + Act: start (startTransition fires automatically)
        var started = await Api.StartInstanceAsync(Workflow, new
        {
            // initial payload — match the workflow's master schema
        });
        Assert.True(started.IsSuccessStatusCode);
        var id = started.Body.GetProperty("id").GetString()!;

        // Fire each manual transition with the payload its schema expects
        await Api.RunTransitionAsync(Workflow, id, "{transition-key-1}", new { /* payload */ });
        await Api.RunTransitionAsync(Workflow, id, "{transition-key-2}", new { /* payload */ });

        // Read state. (Auto/timer transitions are NOT fired here — poll GetInstanceAsync until the
        //  expected state if the flow auto-advances. Don't assume a built-in wait helper.)
        var instance = await Api.GetInstanceAsync(Workflow, id);

        // Assert
        Assert.Equal("{final-state-key}", GetCurrentState(instance.Body));
    }
}
```

For Full coverage, add one `[Fact]` per branch — e.g. an auto transition's negative case reaching a
different Final state.

### 5. Generate a companion `.http` file (optional but useful)

For manual exploration, drop a REST Client file at `api-tests/{workflow-key}.http`:

```http
@baseUrl = http://localhost:4201
@apiVersion = 1
@domain = {domain}
@workflowKey = {workflow-key}

### Start
# @name start
POST {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{{workflowKey}}/instances/start
Content-Type: application/json

{ /* initial payload */ }

###
@instanceId = {{start.response.body.$.id}}

### Get state
GET {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{{workflowKey}}/instances/{{instanceId}}/functions/state

### Run transition: {transition-key-1}
PATCH {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{{workflowKey}}/instances/{{instanceId}}/transitions/{transition-key-1}
Content-Type: application/json

{ /* transition payload */ }
```

These are for human debugging; the xUnit tests are CI's source of truth.

### 6. Remind the user how to run

```bash
# .NET 10 SDK + Docker Desktop required. Testcontainers manages the stack — no manual docker compose.
dotnet test tests/<DomainName>.IntegrationTests --filter "FullyQualifiedName~{WorkflowName}Tests"

# Against an external environment instead of Testcontainers:
VNEXT_BASE_URL=http://localhost:5000 dotnet test
```

If `VNext.Testing.Sdk` or the template fails to resolve, point the user at
`https://github.com/burgan-tech/vnext-integration-test/blob/master/GETTING_STARTED.md` (feed /
version guidance).

### 7. (Optional) Update CI

If the repo has CI config (`.github/workflows/`, `.gitlab-ci.yml`), suggest adding a `dotnet test`
step. Don't edit CI without explicit user confirmation.

## Notes

- The template's `IntegrationTestBase` auto-applies `[Collection("VNextIntegration")]` — **one**
  shared Docker stack across all test classes in the project (not per-domain collections).
- `VNextTestEnvironment` overrides are `Domain`, `DatabaseName`, `VNextImage` (required) plus optional
  `VNextImageVersion`, `MocklabImage`, `MocklabSeedDirectory`, `EnableMocklab`, `EnableDomainPublish`,
  `OnAfterEnvironmentReadyAsync`, `GetVaultSecrets`, `GetOrchestratorEnvironment`.
- Read instance state with `GetCurrentState(response.Body)`; read fields with
  `response.Body.GetProperty("…")`. `VNextApiResponse` exposes `Body` (JsonElement), `RawBody`,
  `StatusCode`, `IsSuccessStatusCode`, `Headers`.
- For specific MockLab behavior (e.g. simulate a 500), push rules via MockLab's admin API at the start
  of the test, or place seeds in the test project's `Infrastructure/MocklabSeed/`.
- Each `[Fact]` should be independent — start a fresh instance; don't reuse IDs across tests.

## References

- `references/concepts/integration-test-patterns.md` — full SDK + template pattern reference
- `https://github.com/burgan-tech/vnext-integration-test/blob/master/GETTING_STARTED.md` — official setup guide
- Working examples: `vnext-example/tests/`
