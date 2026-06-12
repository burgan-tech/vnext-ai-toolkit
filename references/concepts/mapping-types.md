# Mapping Types — `.csx` Interface Inventory

vNext runs C# scripts (`.csx` files) as "mappings" — input/output adapters between workflow instance data and tasks/transitions. Each mapping kind implements a specific interface from `BBT.Workflow.Scripting`.

> **Interface contracts come from the NuGet packages.** See `csx-contracts.md` for the exact type signatures, the `ScriptContext` API, and standard `using` directives. This file gives the conceptual map: when do you write which interface?

## Interface inventory

| Interface | When to write it | Where it's referenced |
|-----------|------------------|------------------------|
| `IMapping` | Adapt instance data ↔ a single task's input/output | `transition.onExecutionTasks[].mapping`, `state.onEntries[].mapping`, `function.task.mapping` |
| `IOutputHandler` | Aggregate results from multiple tasks in one Function | `function.output` (when the function has `onExecutionTasks[]` with >1 task) |
| `IConditionMapping` | Evaluate a boolean for an auto transition's `rule` | `transition.rule.mapping` when `triggerType: 1` and `triggerKind ≠ 10` |
| `ITimerMapping` | Compute a dynamic schedule for a timer transition | `transition.timer.mapping` when `triggerType: 2` and the timer is dynamic |
| `ISubFlowMapping` | Adapt data flowing into/out of a SubFlow (S) invocation | `state.subFlow.mapping` when `stateType: 4` |
| `INotificationMapping` | Produce per-channel notification payload (SMS/email/push…) | `task.mapping` for NotificationTask (type 10), keyed by channel |

## Reuse: `sys-mappings` helpers + `REF`

Don't duplicate `.csx` logic across components. Extract a reusable utility into a **`sys-mappings`**
component (a plain `public static class`) and reference it from a consumer's `scripts.helpers` (listing
any external assembly in `scripts.allowedAssemblies`); the helper's static methods are then callable by
class name in the consumer's mapping. A whole reusable mapping can be referenced with `encoding: "REF"`
instead of inlining it. See `references/concepts/mappings-and-scripts.md`.

## IMapping vs IOutputHandler

These two confuse newcomers most often.

| Aspect | `IMapping` | `IOutputHandler` |
|--------|------------|------------------|
| Used in | Single-task contexts (one Task per call site) | Function with multiple `onExecutionTasks[]` |
| Methods | `InputHandler(WorkflowTask task, ScriptContext context)` + `OutputHandler(ScriptContext context)` | `Handler(ScriptContext context)` |
| Sees | One task's input/output | All tasks' results aggregated |
| Returns | `ScriptResponse` (single value) | `ScriptResponse` (merged value) |

**Rule.** A Function with one task uses `IMapping`. A Function with multiple `onExecutionTasks[]` uses one `IMapping` per task + an `IOutputHandler` for the final output. Don't mix.

## ScriptContext — the data surface

Every mapping receives a `ScriptContext`. The fields you'll use most:

| Field | Source | Used in |
|-------|--------|---------|
| `context.Body` | Request body OR upstream task result body | InputHandler / OutputHandler |
| `context.Headers` | HTTP headers (lowercased keys) | InputHandler (auth tokens, correlation IDs) |
| `context.QueryString` / `context.QueryParameters` | URL query string (Function calls in GET mode) | InputHandler for GET-mode functions |
| `context.Instance.Data` | The workflow instance's current data | All handlers |
| `context.TaskResponse` | Completed task results (dictionary keyed by task name) | OutputHandler / IOutputHandler |
| `context.Mutations` | Atomic instance mutations API | OutputHandler when you want to patch instance data |

See `csx-contracts.md` for the full type definitions.

## Output unwrapping — the most common bug

Tasks (especially HTTP) wrap their response in a `StandardTaskResponse`:

```jsonc
{
  "statusCode": 200,
  "data": { /* the actual payload */ },
  "headers": { /* response headers */ }
}
```

If you do `ScriptResponse.Data = context.Body` inside an `OutputHandler` for a function called by `x-lov`/`x-lookup`, the response **double-wraps**: the client expects `$.data[*].code` but the payload sits at `$.data.data[*].code` and the JsonPath fails.

**Rule.** Unwrap one level and re-envelope:

```csharp
dynamic payload = context.Body?.data ?? context.Body;
dynamic items = null;
try { items = payload?.data ?? payload; } catch { items = payload; }
return Task.FromResult(new ScriptResponse {
  Key  = "...",
  Data = new { data = items },
  Tags = new[] { "lov", "success" }
});
```

## GET-mode functions: parameter sources

When a view's `x-lov` or `x-lookup` calls a function, the runtime issues a GET — parameters arrive in `context.QueryString[…]` or `context.Headers[…]`, NOT `context.Body`. Use a multi-source resolver:

```csharp
string val = context.QueryString?["currency"]?.ToString()
          ?? context.Headers?["x-currency"]?.ToString()
          ?? context.Body?.currency?.ToString();
```

Reading from `context.Body` alone breaks renderer-initiated lookups.

## Tagging convention

`ScriptResponse.Tags` is a free-form string array; the LOV/lookup convention is:

- `["lov", "success"]` — normal LOV result
- `["lov", "failure"]` — upstream failure surfaced to the client
- `["lookup", "not-found"]` — explicit 404 case (often when statusCode = 404)
- `["exception"]` — transport / unexpected error

The client filters on these tags.

## Sources

- Type definitions: `csx-contracts.md` (this folder)
- Pattern guide: `function-mapping-pattern.md` (top-level `references/`)
- NuGets: `BBT.Workflow.Scripting`, `BBT.Workflow.Domain`, `BBT.Workflow.Definitions`
- Working examples: `vnext-example/core/Workflows/payments/src/*.csx`, `vnext-example/core/Functions/account-opening/src/*.csx`
