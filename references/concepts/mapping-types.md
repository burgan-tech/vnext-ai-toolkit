# Mapping Types — `.csx` Interface Inventory

vNext runs C# scripts (`.csx` files) as "mappings" — input/output adapters between workflow instance data and tasks/transitions. Each mapping kind implements a specific interface from `BBT.Workflow.Scripting`.

> **Interface contracts come from the NuGet packages.** See `csx-contracts.md` for the exact type signatures, the `ScriptContext` API, and standard `using` directives. This file gives the conceptual map: when do you write which interface?

## Interface inventory

| Interface | When to write it | Where it's referenced |
|-----------|------------------|------------------------|
| `IMapping` | Adapt instance data ↔ a single task's input/output | `transition.onExecutionTasks[].mapping`, `state.onEntries[].mapping`, `function.task.mapping` |
| `IOutputHandler` | Aggregate results from multiple tasks in one Function (method: `OutputHandler(ScriptContext)`) | `function.output` (when the function has `onExecutionTasks[]` with >1 task) |
| `IConditionMapping` | Evaluate a boolean for an auto transition's `rule` | `transition.rule.mapping` when `triggerType: 1` and `triggerKind ≠ 10` |
| `ITimerMapping` | Compute a dynamic schedule for a timer transition | `transition.timer.mapping` when `triggerType: 2` and the timer is dynamic |
| `ISubFlowMapping` | Adapt data flowing into/out of a SubFlow (S) invocation | `state.subFlow.mapping` when `stateType: 4` |
| `ISubProcessMapping` | Prepare input for a fire-and-forget SubProcess (input only — no output handler) | `state.subFlow.mapping` when the subflow type is SubProcess (P) |
| `INotificationMapping` | Produce per-channel notification payload (method: `ChannelHandler(string channel, ScriptContext)`; return null to skip a channel) | `task.mapping` for NotificationTask (type 10) |
| `IStateNotificationMapping` | Enrich the platform-managed `state` channel's Dapr metadata (optional; same `.csx` file as `INotificationMapping`) | picked up automatically when the notification mapping class also implements it |
| `IEventMapping` | Map an inbound pub/sub / binding payload to a correlation key + body (`EventMappingResult`) | `event.mapping` on a workflow or transition |
| `ITransitionMapping` | Transform transition data (`Handler(ScriptContext)` → `dynamic`) | reusable transition mappings (e.g. `sys-mappings` `initial-mapping`) |

## Reuse: `sys-mappings` helpers + `REF` — the primary approach

**When the same mapping structure repeats, extracting a `sys-mappings` helper is the primary method — not an afterthought.** Don't duplicate `.csx` logic across components. Extract a reusable utility into a **`sys-mappings`**
component (a plain `public static class`) and reference it from a consumer's `scripts.helpers` (listing
any external assembly in `scripts.allowedAssemblies`); the helper's static methods are then callable by
class name in the consumer's mapping. A whole reusable mapping can be referenced with `encoding: "REF"`
instead of inlining it. See `references/concepts/mappings-and-scripts.md`.

## IMapping vs IOutputHandler

These two confuse newcomers most often.

| Aspect | `IMapping` | `IOutputHandler` |
|--------|------------|------------------|
| Used in | Single-task contexts (one Task per call site) | Function with multiple `onExecutionTasks[]` |
| Methods | `InputHandler(WorkflowTask task, ScriptContext context)` + `OutputHandler(ScriptContext context)` | `OutputHandler(ScriptContext context)` |
| Sees | One task's input/output | All tasks' results aggregated |
| Returns | `ScriptResponse` (single value) | `ScriptResponse` (merged value) |

**Rule.** A Function with one task uses `IMapping`. A Function with multiple `onExecutionTasks[]` uses one `IMapping` per task + an `IOutputHandler` for the final output. Don't mix.

## ScriptContext — the data surface

Every mapping receives a `ScriptContext`. The fields you'll use most (there is **no `QueryString`** property — the query string is `QueryParameters`):

| Field | Source | Used in |
|-------|--------|---------|
| `context.Body` | Request body, with each task's `StandardTaskResponse` **merged in** as tasks complete | InputHandler / OutputHandler |
| `context.Headers` | HTTP headers (lowercased keys) | InputHandler (auth tokens, correlation IDs) |
| `context.QueryParameters` | URL query string (Function calls in GET mode) | InputHandler for GET-mode functions |
| `context.RouteValues` | URL path segments / routing values | InputHandler |
| `context.Instance.Data` | The workflow instance's current data (**dynamic — use `HasProperty`/`GetPropertyValue`**) | All handlers |
| `context.CurrentTransition` | The **original** transition request (`.Data`, `.Header`) — unaffected by task merges into `Body` | Any transition-pipeline handler |
| `context.TaskResponse` | Each task's `StandardTaskResponse` (dictionary keyed by camelCase task key) | OutputHandler / IOutputHandler |
| `context.OutputResponse` | Each task's own output-mapping result (not merged into `Body`) | IOutputHandler |
| `context.EventPayload` | Raw inbound event payload (non-null only in `IEventMapping`) | IEventMapping |
| `context.Related` | Correlated instance reads — parent / subflows / subprocesses (v0.0.79+; correlation data ONLY, otherwise use a task) | Any handler |
| `context.Incident` | Active error-boundary incident info | Compensation / error-aware logic |
| `context.Mutations` | Atomic instance mutations API | OutputHandler when you want to patch instance data |

**All `dynamic` values are `ExpandoObject`/`List<object?>` with camelCase keys — a missing property access throws at runtime (`?.` does not save you).** Read via the `ScriptBase` helpers. See `csx-contracts.md` for the full verified surface, the dynamic type model, and the helper reference.

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

**Rule.** Unwrap one level and re-envelope — probing with `HasProperty`, never with bare dynamic access:

```csharp
// context.Body is dynamic (ExpandoObject); a missing member THROWS — probe first.
var payload = HasProperty(context.Body, "data")
    ? GetPropertyValue(context.Body, "data")
    : context.Body;
var items = HasProperty(payload, "data")            // some upstreams nest one more level
    ? GetPropertyValue(payload, "data")
    : payload;
return Task.FromResult(new ScriptResponse {
  Key  = "...",
  Data = new { data = items },
  Tags = new[] { "lov", "success" }
});
```

## GET-mode functions: parameter sources

When a view's `x-lov` or `x-lookup` calls a function, the runtime issues a GET — parameters arrive in `context.QueryParameters` or `context.Headers`, NOT `context.Body`. Resolve across all three with the `ScriptBase` helpers:

```csharp
string val = GetPropertyValue<string>(context.QueryParameters, "currency", null)
          ?? GetPropertyValue<string>(context.Headers, "x-currency", null)
          ?? GetPropertyValue<string>(context.Body, "currency", "");
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
