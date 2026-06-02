# Integration Test Patterns

vNext ships a testing SDK that runs the full runtime stack against a real workflow and asserts on lifecycle behavior. Every workflow created by this plugin should have at least a smoke-level integration test; complex workflows get full lifecycle assertions.

## SDK

- Repo: `https://github.com/burgan-tech/vnext-integration-test`
- NuGet package: `VNext.Testing.Sdk` (version pinned to the runtime release; reference example uses `0.0.3`)
- Test framework: xUnit + `Microsoft.NET.Test.Sdk`

The SDK provides:
- A test-environment fixture that spins up the Docker stack (runtime + MockLab + Dapr sidecar)
- `VNextApiClient` — typed HTTP client wrapping the runtime API
- xUnit collection fixture base class for test isolation

## Repo layout (generic)

```
{workspace-root}/
├── tests/
│   └── {Domain}/                          # e.g. Banking, Core, Payments
│       ├── {Domain}.IntegrationTests.csproj
│       ├── Infrastructure/
│       │   ├── VNextTestEnvironment.cs    # Domain-specific env setup
│       │   └── IntegrationTestBase.cs     # xUnit collection fixture + ApiClient
│       ├── SmokeTests.cs                  # health endpoint + ListInstances
│       ├── {Workflow}Tests.cs             # one per workflow under test
│       └── test.runsettings               # xUnit config (timeouts, parallelism)
└── api-tests/                             # REST Client `.http` files for manual probing
    └── {workflow-key}.http
```

## `.csproj` essentials

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <IsPackable>false</IsPackable>
    <IsTestProject>true</IsTestProject>
    <RootNamespace>{Domain}.IntegrationTests</RootNamespace>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />
    <PackageReference Include="xunit" Version="2.9.*" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.*" />
    <PackageReference Include="VNext.Testing.Sdk" Version="0.0.3" />
  </ItemGroup>
</Project>
```

## `VNextTestEnvironment.cs` (domain-specific)

```csharp
using VNext.Testing.Sdk;

public class VNextTestEnvironment : VNextTestEnvironmentBase
{
    public override string Domain  => "{domain}";          // lowercase
    public override string DbName  => "vnext_{domain}_test";
    public override string ImageTag => "latest";
    // Override other hooks (seed paths, MockLab config) as needed.
}
```

## `IntegrationTestBase.cs`

```csharp
using Xunit;
using VNext.Testing.Sdk;

[CollectionDefinition("vnext-{domain}")]
public class VNextCollection : ICollectionFixture<VNextTestEnvironment> { }

[Collection("vnext-{domain}")]
public abstract class IntegrationTestBase
{
    protected readonly VNextTestEnvironment Env;
    protected readonly VNextApiClient Api;

    protected IntegrationTestBase(VNextTestEnvironment env)
    {
        Env = env;
        Api = env.CreateApiClient();
    }
}
```

## `SmokeTests.cs` (always present)

```csharp
public class SmokeTests : IntegrationTestBase
{
    public SmokeTests(VNextTestEnvironment env) : base(env) { }

    [Fact]
    public async Task Runtime_Is_Healthy()
    {
        var ok = await Api.HealthAsync();
        Assert.True(ok);
    }

    [Fact]
    public async Task Can_List_Instances()
    {
        var result = await Api.ListInstancesAsync(workflowKey: "account-opening");
        Assert.NotNull(result);
    }
}
```

## Workflow lifecycle test (per workflow)

```csharp
public class AccountOpeningTests : IntegrationTestBase
{
    public AccountOpeningTests(VNextTestEnvironment env) : base(env) { }

    [Fact]
    public async Task Happy_Path_Completes_In_Success_State()
    {
        // 1. Start
        var instance = await Api.StartInstanceAsync("account-opening", new { });
        Assert.NotNull(instance.Id);

        // 2. Execute each manual transition with its payload
        await Api.ExecuteTransitionAsync(
            "account-opening", instance.Id, "select-account-type",
            new { accountType = "savings" });

        await Api.ExecuteTransitionAsync(
            "account-opening", instance.Id, "confirm-account-type",
            new { confirmed = true });

        // 3. Wait for any auto/timer transitions to settle
        await Api.WaitForStateAsync(
            "account-opening", instance.Id,
            expected: "account-created", timeout: TimeSpan.FromSeconds(30));

        // 4. Assert final state
        var final = await Api.GetStateAsync("account-opening", instance.Id);
        Assert.Equal("account-created", final.CurrentState);
        Assert.Equal("Completed", final.Status);
    }
}
```

## Test data & seeds

- MockLab seeds (`etc/docker/config/seed/`) provide the upstream HTTP responses tests rely on. The `VNextTestEnvironment` mounts these into the MockLab container.
- For dynamic per-test data, use MockLab's admin API to push rules at the start of each test (the SDK exposes helpers).

## `test.runsettings`

Controls xUnit parallelism, test categories, and per-test timeout. Defaults (verify against the SDK README):

```xml
<RunSettings>
  <RunConfiguration>
    <ResultsDirectory>./TestResults</ResultsDirectory>
    <TestSessionTimeout>600000</TestSessionTimeout>
  </RunConfiguration>
  <xunit>
    <ParallelizeAssembly>false</ParallelizeAssembly>
    <ParallelizeTestCollections>false</ParallelizeTestCollections>
    <MaxParallelThreads>1</MaxParallelThreads>
  </xunit>
</RunSettings>
```

A `test.runsettings.local` (gitignored) lets developers override settings locally — image tag, DB connection, runtime port.

## `.http` companion files

The `api-tests/` folder has REST Client `.http` files per workflow for ad-hoc probing. Pattern:

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

### Get state
GET {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{{workflowKey}}/instances/{{instanceId}}/functions/state

### Execute transition
PATCH {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{{workflowKey}}/instances/{{instanceId}}/transitions/select-account-type
Content-Type: application/json

{ "accountType": "savings" }
```

`.http` files are for human exploration; the C# integration tests are CI's source of truth.

## Skill behavior

`integration-test` skill flow:

1. Check that `tests/{Domain}/` exists. If not, hand off to `/vnext-init` with a focused message: "Integration test project missing — run `/vnext-init` to scaffold it."
2. Read the target workflow JSON to enumerate states and transitions.
3. Generate `{Workflow}Tests.cs` with:
   - A happy-path test calling each manual transition in sequence.
   - One assertion per Final state in the workflow.
4. Suggest 1–2 unhappy-path tests (e.g. an auto transition that takes the error branch when a MockLab rule returns 500).
5. Remind the user: `dotnet test` runs the full suite; ensure Docker stack is up.

## Sources

- SDK source: `https://github.com/burgan-tech/vnext-integration-test`
- Reference workspace: `vnext-example/tests/Core/` (this layout is what we templatize)
- Example tests: `vnext-example/tests/Core/SchemaValidationTestWorkflowTests.cs`, `tests/Core/SmokeTests.cs`
- Companion `.http` files: `vnext-example/api-tests/*.http`
