# Integration Test Patterns

vNext ships an official testing SDK **and a dotnet project template** maintained by the platform
team. The toolkit does **not** hand-roll the test project — it scaffolds via the official template,
then writes test classes against the SDK's API. Every workflow created by this plugin should have at
least a smoke-level test; complex workflows get full lifecycle assertions.

## Source of truth (fetch when in doubt)

- **Getting started (authoritative)**: `https://github.com/burgan-tech/vnext-integration-test/blob/master/GETTING_STARTED.md`
  (raw: `https://raw.githubusercontent.com/burgan-tech/vnext-integration-test/master/GETTING_STARTED.md`)
- SDK + template source: `https://github.com/burgan-tech/vnext-integration-test`

The SDK/template evolve — when method names, override properties, or versions look off, fetch the
getting-started doc and the template source rather than guessing.

## Packages

| Artifact | Name | Install |
|----------|------|---------|
| SDK NuGet | `VNext.Testing.Sdk` | `dotnet add package VNext.Testing.Sdk` (template references it) |
| Project template | `VNext.Testing.Template` | `dotnet new install VNext.Testing.Template` |

- Test framework: xUnit + `Microsoft.NET.Test.Sdk`. Docker stack via **Testcontainers**.
- **TargetFramework: `net10.0`.**
- Container registry: `ghcr.io/burgan-tech/vnext` (orchestrator/execution) + `ghcr.io/burgan-tech/mocklab`.

## Scaffolding (use the official template — do not hand-write the project)

```bash
# 1. Install the template once (per machine)
dotnet new install VNext.Testing.Template

# 2. Scaffold a test project (short name: vnext-integration-test)
#    Run inside tests/ (or wherever the workspace keeps tests).
dotnet new vnext-integration-test \
  --DomainName <PascalCaseDomain> \   # C# namespace + project prefix, e.g. MorphFx
  --AppDomain  <lower-domain-slug> \   # vNext API path + container env, e.g. morphfx
  [--VNextImage ghcr.io/burgan-tech/vnext] \
  [--SdkVersion 1.0.0]
```

`sourceName` is `MyDomain` / `mydomain` → the template replaces those with your `--DomainName` /
`--AppDomain`. `preferNameDirectory` is on, so it lands in a directory named after `--DomainName`.

### What the template generates

```
<DomainName>.IntegrationTests/
├── <DomainName>.IntegrationTests.csproj   # net10.0, VNext.Testing.Sdk, xunit, coverlet
├── test.runsettings                       # (+ test.runsettings.local, git-ignored, takes precedence)
├── Config/
│   ├── appsettings.orchestration.json     # ApplicationName, ConnectionStrings.Default, Redis, ExecutionApi.AppId (vnext-execution-app-{domain}), WorkingHours
│   ├── appsettings.execution.json         # OrchestrationApi.AppId (vnext-app-{domain}), Redis, Dapr.Notification.ComponentName
│   └── appsettings.db-migrator.json       # ConnectionStrings.Default, Runtime.EnableSchemaMigration=true, Redis
├── Helpers/
│   └── TestDataBuilder.cs                 # per-domain payload builders
├── Infrastructure/
│   ├── IntegrationTestBase.cs             # [Collection("VNextIntegration")] + CreateApiClient
│   ├── VNextTestEnvironment.cs            # Domain / DatabaseName / VNextImage overrides
│   ├── DaprComponents/{orchestration,execution,db-migrator}/*.yaml   # override SDK defaults (keep REDIS_HOST/VAULT_HOST placeholders)
│   └── MocklabSeed/                       # host dir bind-mounted to /app/seed in MockLab
└── Tests/
    └── SmokeTests.cs                      # health + ListInstances
```

> `vnext.config.json` is discovered by the SDK's `LocalDomainPublisher` by **walking up the directory
> tree** from the test project — so the test project must live inside the domain workspace.

## Fixtures, base class, environment

**Base class** — inherit the template's `IntegrationTestBase` (which wraps
`VNext.Testing.Sdk.Infrastructure.IntegrationTestBase<TEnvironment>`). It auto-applies
`[Collection("VNextIntegration")]`, so all test classes share one Docker stack.

```csharp
using <DomainName>.IntegrationTests.Infrastructure;

namespace <DomainName>.IntegrationTests.Tests;

public class MyWorkflowTests : IntegrationTestBase
{
    public MyWorkflowTests(VNextTestEnvironment environment) : base(environment) { }
    // ... [Fact] methods
}
```

**Environment** — `Infrastructure/VNextTestEnvironment.cs` subclasses
`VNext.Testing.Sdk.Infrastructure.VNextTestEnvironment`. Required overrides:

```csharp
protected override string Domain       => "mydomain";              // APP_DOMAIN
protected override string DatabaseName => "vNext_MyDomain_Test";   // PostgreSQL DB
protected override string VNextImage   => "ghcr.io/burgan-tech/vnext";
```

Optional overrides (commented in the template): `VNextImageVersion`, `DbMigratorImage`,
`MocklabImage`, `MocklabSeedDirectory`, `EnableMocklab`, `EnableDomainPublish`,
`OnAfterEnvironmentReadyAsync()`, `GetVaultSecrets()`, `GetOrchestratorEnvironment()`.

## API surface (`Api`, type `VNextApiClient`)

All return `VNextApiResponse`.

| Method | Signature |
|--------|-----------|
| Start instance | `StartInstanceAsync(workflowName, payload, headers?)` |
| Get instance | `GetInstanceAsync(workflowName, instanceId)` |
| Run transition | `RunTransitionAsync(workflowName, instanceId, transitionName, body)` |
| Get transitions | `GetInstanceTransitionsAsync(workflowName, instanceId)` |
| List instances | `ListInstancesAsync(workflowName)` |
| Retry instance | `RetryInstanceAsync(workflowName, instanceId)` |
| Call function | `CallFunctionAsync(functionName, queryParams)` |
| Call workflow function | `CallWorkflowFunctionAsync(workflowName, functionName, queryParams)` |
| Raw request | `GetRawAsync(path)` |

**`VNextApiResponse`**: `StatusCode` (HttpStatusCode), `Headers`, `Body` (`JsonElement`), `RawBody`
(string), `IsSuccessStatusCode` (bool).

**State helper** (from `IntegrationTestBase`): `GetCurrentState(response.Body)` → current state key.

> There is **no** `ExecuteTransitionAsync`, `WaitForStateAsync`, or `GetStateAsync`. Use
> `RunTransitionAsync` to fire a transition and `GetInstanceAsync` + `GetCurrentState(...)` to read
> state. For auto/timer transitions, **poll** `GetInstanceAsync` until the expected state (or a
> timeout) — do not assume a built-in wait helper exists.

## `SmokeTests.cs` (generated)

```csharp
public class SmokeTests : IntegrationTestBase
{
    public SmokeTests(VNextTestEnvironment environment) : base(environment) { }

    [Fact]
    public async Task HealthEndpoint_Returns200()
    {
        var response = await Api.GetRawAsync("/health");
        Assert.Equal(System.Net.HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task ListInstances_ReturnsValidResponse()
    {
        var response = await Api.ListInstancesAsync("my-workflow");
        Assert.True(response.Body.ValueKind != System.Text.Json.JsonValueKind.Null);
    }
}
```

## Workflow lifecycle test (per workflow)

```csharp
public class AccountOpeningTests : IntegrationTestBase
{
    private const string Workflow = "account-opening";

    public AccountOpeningTests(VNextTestEnvironment environment) : base(environment) { }

    [Fact]
    public async Task Happy_Path_Reaches_Account_Created()
    {
        // 1. Start (startTransition fires automatically)
        var started = await Api.StartInstanceAsync(Workflow, TestDataBuilder.NewAccount());
        Assert.True(started.IsSuccessStatusCode);
        var id = started.Body.GetProperty("id").GetString()!;

        // 2. Fire each manual transition with its payload
        await Api.RunTransitionAsync(Workflow, id, "select-account-type", new { accountType = "savings" });
        await Api.RunTransitionAsync(Workflow, id, "confirm-account-type", new { confirmed = true });

        // 3. Read state. For auto/timer settle, poll GetInstanceAsync until expected (with a timeout).
        var instance = await Api.GetInstanceAsync(Workflow, id);
        Assert.Equal("account-created", GetCurrentState(instance.Body));
    }
}
```

## Test data & seeds

- MockLab seeds live in the test project's `Infrastructure/MocklabSeed/` (bind-mounted to `/app/seed`).
  Point `MocklabSeedDirectory` elsewhere to reuse the workspace's `etc/docker/config/seed/`.
- For dynamic per-test data use MockLab's admin API to push rules at the start of a test.

## `.http` companion files (manual probing only)

The workspace's `api-tests/` folder holds REST Client `.http` files per workflow for ad-hoc probing.
These are for humans; the C# integration tests are CI's source of truth. Pattern:

```http
@baseUrl = http://localhost:4201
@apiVersion = 1
@domain = {domain}
@workflowKey = account-opening

### Start
# @name start
POST {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{{workflowKey}}/instances/start

###
@instanceId = {{start.response.body.$.id}}

### Run transition
PATCH {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{{workflowKey}}/instances/{{instanceId}}/transitions/select-account-type
Content-Type: application/json

{ "accountType": "savings" }
```

## Skill behavior

`integration-test` skill flow:

1. Check for an existing test project (`*.IntegrationTests.csproj`, typically under `tests/`).
   If missing, scaffold via the official template (`dotnet new vnext-integration-test ...`) or hand
   off to `/vnext-init`, which runs the same template.
2. Read the target workflow JSON to enumerate states and transitions.
3. Generate `Tests/{Workflow}Tests.cs` using the real API surface above:
   - A happy-path test firing each manual transition (`RunTransitionAsync`) in sequence.
   - One assertion per Final state (`GetCurrentState` on `GetInstanceAsync`).
4. Suggest 1–2 unhappy-path tests (e.g. an auto transition's error branch when a MockLab rule returns 500).
5. Remind the user: `dotnet test` runs the suite (Testcontainers manages the Docker stack; ensure
   Docker Desktop is running). `VNEXT_BASE_URL=... dotnet test` runs against an external environment.

## Sources

- Getting started: `https://github.com/burgan-tech/vnext-integration-test/blob/master/GETTING_STARTED.md`
- SDK + template source: `https://github.com/burgan-tech/vnext-integration-test`
- Reference workspace examples: `vnext-example/tests/`
