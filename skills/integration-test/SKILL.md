---
name: integration-test
description: Use after a workflow is scaffolded (or to add coverage to an existing one). Generates an xUnit integration test class using VNext.Testing.Sdk that asserts the workflow's lifecycle — start, transitions, final state. If tests/{Domain}/ is missing, hands off to /vnext-init.
---

# Integration Test

vNext ships an integration testing SDK (`VNext.Testing.Sdk`) that spins up the full Docker stack and drives a workflow through its API. Every workflow this plugin creates should have at least a smoke-level test; complex flows get full lifecycle coverage.

## Pre-check — does the test project exist?

The plugin doesn't run inside the test project — it writes to it. So first:

```
Look for tests/{Domain}/{Domain}.IntegrationTests.csproj  (Domain = PascalCase of vnext.config.json domain)

If missing:
  STOP. Tell the user:
  "The integration test project doesn't exist yet. Run /vnext-init and accept Step 8 (Integration test scaffold) — that will create tests/{Domain}/ with the SDK fixtures. Then come back to this skill."
  Do NOT proceed.

If present:
  Continue to Step 1.
```

See `references/concepts/integration-test-patterns.md` for the full SDK layout.

## Steps

### 1. Read the target workflow

From `vnext.config.json`: `componentsRoot`, `paths.workflows`, `domain`. The workflow JSON is at `{componentsRoot}/{paths.workflows}/{workflow-key}/{workflow-key}-workflow.json`.

Ask: "Which workflow should I generate tests for?" (Default to the most recently modified one if obvious.)

Read the workflow JSON. Extract:
- `attributes.startTransition` — the first transition fired automatically
- `attributes.states[]` — every state with its `stateType`, `isFinal`, `view`
- `attributes.transitions[]` — every transition with its `triggerType`, source/target, payload schema if any

### 2. Identify the test surface

For each state and transition, note:
- **Manual transitions (`triggerType: 0`)** — must be explicitly executed in tests
- **Auto transitions (`triggerType: 1`)** — fire automatically; test waits for them
- **Timer transitions (`triggerType: 2`)** — fire after duration; test waits with appropriate timeout
- **Event transitions (`triggerType: 3`)** — require external signal in test (use SDK helpers)
- **Final states** — assertions check `Instance.Status == "Completed"` and `currentState`

### 3. Decide test scope with the user

Ask:
- **Smoke-only?** One test: start instance → assert it transitioned past the initial state. Fastest, lowest coverage.
- **Happy path?** Execute every manual transition with valid payload → assert the expected Final state. **(Recommended for first test.)**
- **Full coverage?** Happy path + one unhappy-path test per branch (auto transition's "false" branch, error states). Best coverage, most code.

Default: Happy path. Add unhappy paths later as workflows mature.

### 4. Generate the test class

File path: `tests/{Domain}/{WorkflowName}Tests.cs` (PascalCase from workflow key).

Skeleton (Happy path):

```csharp
using System;
using System.Threading.Tasks;
using Xunit;
using VNext.Testing.Sdk;

namespace {Domain}.IntegrationTests;

[Collection("vnext-{domain-lower}")]
public class {WorkflowName}Tests : IntegrationTestBase
{
    public {WorkflowName}Tests(VNextTestEnvironment env) : base(env) { }

    [Fact]
    public async Task Happy_Path_Reaches_{FinalStateName}()
    {
        // Arrange: start a new instance (startTransition fires automatically)
        var instance = await Api.StartInstanceAsync("{workflow-key}", new
        {
            // Initial payload — match the workflow's master schema required fields
        });
        Assert.NotNull(instance.Id);

        // Act: execute each manual transition in order, with the payload its schema expects
        await Api.ExecuteTransitionAsync(
            "{workflow-key}", instance.Id, "{transition-key-1}",
            new { /* payload matching transition's input schema */ });

        await Api.ExecuteTransitionAsync(
            "{workflow-key}", instance.Id, "{transition-key-2}",
            new { /* payload */ });

        // (More transitions as the workflow has them. Auto/timer transitions are NOT executed here —
        //  they fire on their own; the test waits with WaitForStateAsync below.)

        // Wait for any auto/timer transitions and the final state to settle
        await Api.WaitForStateAsync(
            "{workflow-key}", instance.Id,
            expected: "{final-state-key}",
            timeout: TimeSpan.FromSeconds(30));

        // Assert
        var final = await Api.GetStateAsync("{workflow-key}", instance.Id);
        Assert.Equal("{final-state-key}", final.CurrentState);
        Assert.Equal("Completed", final.Status);

        // (Optional) Assert specific instance data fields were set as expected
        Assert.NotNull(final.Data);
        // Assert.Equal(expected, final.Data.someField);
    }
}
```

For Full coverage, add one `[Fact]` per branch — e.g. an auto transition's negative case where a different Final state is reached.

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

### Manual transition: {transition-key-1}
PATCH {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{{workflowKey}}/instances/{{instanceId}}/transitions/{transition-key-1}
Content-Type: application/json

{ /* transition payload */ }

### Manual transition: {transition-key-2}
PATCH {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{{workflowKey}}/instances/{{instanceId}}/transitions/{transition-key-2}
Content-Type: application/json

{ /* transition payload */ }
```

These are for human debugging; the xUnit tests are CI's source of truth.

### 6. Remind the user how to run

```bash
# 1. Ensure the runtime + MockLab stack is up
docker compose up -d

# 2. Restore NuGet packages (first time only)
dotnet restore

# 3. Run the test
dotnet test tests/{Domain}/{Domain}.IntegrationTests.csproj --filter "FullyQualifiedName~{WorkflowName}Tests"
```

If `VNext.Testing.Sdk` fails to restore, the package may be private — point them at `https://github.com/burgan-tech/vnext-integration-test` for source / `nuget.config` guidance.

### 7. (Optional) Update CI

If the repo has CI config (`.github/workflows/`, `.gitlab-ci.yml`), suggest adding a `dotnet test` step. Don't edit CI without explicit user confirmation — CI changes have outsized blast radius.

## Notes

- The SDK manages the Docker stack lifecycle through xUnit collection fixtures. Tests in the same collection share one container set; tests in different collections get isolated environments. Default: one collection per domain (`[Collection("vnext-{domain-lower}")]`).
- For tests that need specific MockLab behavior (e.g. simulate a 500 error from upstream), use the SDK helpers to push rules at the start of the test rather than relying on baseline seeds.
- `WaitForStateAsync` is the canonical way to handle auto/timer transitions. Don't sleep; the helper polls and exits as soon as the expected state is reached.
- Each `[Fact]` should be independent — don't rely on instance IDs from prior tests. Start fresh.

## References

- `references/concepts/integration-test-patterns.md` — full SDK pattern reference
- `https://github.com/burgan-tech/vnext-integration-test` — SDK source
- Working examples: `vnext-example/tests/Core/SmokeTests.cs`, `tests/Core/SchemaValidationTestWorkflowTests.cs`
- `.http` companion files: `vnext-example/api-tests/*.http`
