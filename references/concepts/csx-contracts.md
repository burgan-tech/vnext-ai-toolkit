# `.csx` Contracts — Type Signatures & Standard Usings

`.csx` mapping files run against the `BBT.Workflow.*` NuGet packages. Skills generating `.csx` skeletons MUST use the exact `using` directives and method signatures defined here.

## NuGet packages

| Package | Provides | URL |
|---------|----------|-----|
| `BBT.Workflow.Scripting` | Mapping interfaces, `ScriptContext`, `ScriptResponse`, `ScriptBase` | https://www.nuget.org/packages/BBT.Workflow.Scripting/ |
| `BBT.Workflow.Domain` | Domain primitives (used through `BBT.Workflow.Definitions`) | https://www.nuget.org/packages/BBT.Workflow.Domain/ |
| `BBT.Workflow.Definitions` | Task type classes (`WorkflowTask`, `HttpTask`, `NotificationTask`), `TimerSchedule`, `StandardTaskResponse` | (companion to `BBT.Workflow.Domain`) |

Match the NuGet version to `vnext.config.json`'s `runtimeVersion` (or the closest compatible release).

## Standard usings

Every mapping file starts with:

```csharp
using System.Threading.Tasks;
using BBT.Workflow.Scripting;
using BBT.Workflow.Definitions;
```

Optional usings depending on the interface:

```csharp
using BBT.Workflow.Definitions.Timer;     // ITimerMapping / TimerSchedule helpers
using BBT.Workflow.Scripting.Functions;   // ScriptBase (lookup/function helpers like ResolveParam)
```

## Interface signatures

### `IMapping` — single-task input/output

```csharp
public class MyTaskMapping : IMapping
{
    public Task<ScriptResponse> InputHandler(WorkflowTask task, ScriptContext context)
    {
        // Cast `task` to the concrete task type (HttpTask, NotificationTask, etc.)
        // Pull data from context.Instance.Data, context.Body, context.QueryString, context.Headers
        // Mutate the task's config (URL, body, headers) or return ScriptResponse with prepared payload
        return Task.FromResult(new ScriptResponse { /* … */ });
    }

    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        // context.Body holds the upstream task's StandardTaskResponse
        // Unwrap, transform, return ScriptResponse
        return Task.FromResult(new ScriptResponse { /* … */ });
    }
}
```

### `IOutputHandler` — multi-task Function aggregation

```csharp
public class MyFunctionOutput : IOutputHandler
{
    public Task<ScriptResponse> Handler(ScriptContext context)
    {
        // context.TaskResponse["taskKeyA"] / ["taskKeyB"] gives each task's StandardTaskResponse
        // Merge, project, envelope, return
        return Task.FromResult(new ScriptResponse { /* … */ });
    }
}
```

### `IConditionMapping` — auto transition rule

```csharp
public class MyAutoRule : IConditionMapping
{
    public Task<bool> Handler(ScriptContext context)
    {
        // Inspect context.Instance.Data
        // Return true → engine fires this transition
        return Task.FromResult(/* boolean */);
    }
}
```

### `ITimerMapping` — dynamic timer schedule

```csharp
public class MyTimerRule : ITimerMapping
{
    public Task<TimerSchedule> Handler(ScriptContext context)
    {
        // Compute when the timer fires:
        //   TimerSchedule.FromDateTime(dt)
        //   TimerSchedule.FromDuration(TimeSpan.FromMinutes(15))
        //   TimerSchedule.Immediate
        return Task.FromResult(/* schedule */);
    }
}
```

### `ISubFlowMapping` — SubFlow data adapter

```csharp
public class MySubFlowMapping : ISubFlowMapping
{
    public Task<ScriptResponse> InputHandler(ScriptContext context)
    {
        // Build the payload that starts the child workflow
        return Task.FromResult(new ScriptResponse { /* … */ });
    }

    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        // Adapt child workflow result back into parent instance data
        return Task.FromResult(new ScriptResponse { /* … */ });
    }
}
```

### `INotificationMapping` — per-channel notification payload

```csharp
public class MyNotificationMapping : INotificationMapping
{
    public Task<NotificationMessage?> Handler(string channel, ScriptContext context)
    {
        // channel is one of "sms", "email", "push", ...
        // Return null to skip this channel for this instance
        return Task.FromResult<NotificationMessage?>(/* message or null */);
    }
}
```

## Key types

### `ScriptContext`

Surface of available data inside a mapping:

```csharp
public class ScriptContext
{
    public dynamic Body { get; }            // request body OR upstream task result
    public dynamic Headers { get; }          // HTTP headers (lowercased keys)
    public dynamic QueryString { get; }      // URL query string
    public dynamic QueryParameters { get; }  // alias / typed access (verify in NuGet)
    public Instance Instance { get; }        // .Data, .Status, .Id, .Workflow
    public IDictionary<string, dynamic> TaskResponse { get; }  // multi-task results
    public Mutations Mutations { get; }      // atomic instance mutation API
    // (more fields may exist — read the NuGet symbol package for the full set)
}
```

### `ScriptResponse`

The return envelope for `InputHandler` / `OutputHandler` / `Handler` (in IMapping / IOutputHandler):

```csharp
public class ScriptResponse
{
    public string? Key { get; set; }
    public object? Data { get; set; }
    public IDictionary<string, string>? Headers { get; set; }
    public int? StatusCode { get; set; }
    public string[]? Tags { get; set; }
    // …
}
```

### `StandardTaskResponse`

What a Task returns to its consumer (read out of `context.Body` in OutputHandler):

```csharp
public class StandardTaskResponse
{
    public int StatusCode { get; set; }
    public dynamic Data { get; set; }
    public IDictionary<string, string> Headers { get; set; }
    public bool IsSuccess { get; }
    // …
}
```

**Unwrap rule.** In `OutputHandler`, `context.Body` IS the `StandardTaskResponse`. To get the inner payload: `context.Body?.data`. To get an items array nested one level deeper (typical for LOV functions): `context.Body?.data?.data ?? context.Body?.data`.

### `WorkflowTask` and concrete task types

`InputHandler(WorkflowTask task, …)` receives the task definition; cast to the concrete type to mutate config:

```csharp
if (task is HttpTask httpTask)
{
    httpTask.Config.Url = $"{baseUrl}/customers/{id}";
    httpTask.Config.Headers["X-Correlation-Id"] = correlationId;
    httpTask.Config.Body = JsonSerializer.Serialize(payload);
}
```

Common concrete types: `HttpTask`, `ScriptTask`, `NotificationTask`, `SoapTask`, `DaprServiceTask`, `DaprPubSubTask`, `GetInstancesTask`. (Verify the full set against the `BBT.Workflow.Definitions` symbols.)

### `ScriptBase` helpers

When inheriting `ScriptBase` (typical for lookup/function mappings), helpers like `ResolveParam(context, "key")` traverse QueryString → Headers → Body in one call. Use this for GET-mode functions.

## Function envelope: `rawResponse`

Functions have a top-level `attributes.rawResponse` boolean (separate from the `.csx` mapping):

| Value | Effect |
|-------|--------|
| `false` (default) | Runtime wraps `ScriptResponse.Data` under the function key: `{ "{functionKey}": { ...Data... } }` |
| `true` | Runtime returns `Data` raw: `{ ...Data... }` |

**Required `true`** for any function whose output a view binds directly (`dataSchema`, `x-lov.source`, `x-lookup.source`, `$lov.X` / `$lookup.X` expressions). With `false`, JsonPath like `$.data[*]` silently misses the array under the function-name wrapper and the view shows an empty result with no error.

Full failure-mode walkthrough in `references/function-mapping-pattern.md` § 5. Working examples: `core/Functions/account-opening/get-branches.json` (LOV) and `get-branch-detail.json` (lookup).

## Class naming

- File name: `kebab-case.csx`
- Class name: `PascalCase` matching the file: `payment-success-rule.csx` → `class PaymentSuccessRule`
- **One class per file** (the runtime expects this).
- The VS Code extension base64-encodes the file into `mapping.code` on save. **Never manually base64-encode.**

## Sources

- NuGet symbol packages: pull `.nupkg` and inspect `lib/net*/BBT.Workflow.Scripting.xml` for IntelliSense docs
- Working examples:
  - `vnext-example/core/Workflows/payments/src/SendPaymentNotificationSmsMapping.csx` — IMapping
  - `vnext-example/core/Workflows/payments/src/PaymentSuccessRule.csx` — IConditionMapping
  - `vnext-example/core/Workflows/payments/src/PaymentDueTimerRule.csx` — ITimerMapping
  - `vnext-example/core/Workflows/payments/src/PaymentProcessMapping.csx` — ISubFlowMapping
  - `vnext-example/core/Functions/account-opening/src/GetBranchDetailLookupMapping.csx` — IMapping + ScriptBase
