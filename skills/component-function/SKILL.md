---
name: component-function
description: Use when the user wants to create a vNext Function — a REST endpoint exposed by the runtime. Fetches function.json schema first, walks scope (D/I) and task composition (single-task vs multi-task), scaffolds the IMapping or IOutputHandler .csx using contracts from csx-contracts.md.
---

# Component Function

A Function is a REST endpoint hosted by the workflow runtime. It can be:
- **Single-task**: one HTTP / Script / Dapr task with an `IMapping`-typed handler.
- **Multi-task**: multiple `onExecutionTasks[]` aggregated by an `IOutputHandler`.

Common uses:
- LOV/lookup endpoints called by views (`x-lov`, `x-lookup`)
- BFF-style aggregation for clients
- Cross-domain gates and data fetches

## Canonical schema-first (mandatory pre-step)

> **Before asking about scope or composition, fetch `function.json` for the workspace's `schemaVersion`.** The `scope` enum, allowed composition shapes, and required fields come from the schema.

```
1. Read vnext.config.json → schemaVersion + domain + paths.functions + runtimeVersion
2. Fetch https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/function.json
   ├─ Fail → master → references/concepts/component-schemas.md snapshot
   └─ No snapshot → halt; never guess.
3. Parse:
   - properties.attributes.properties.scope.enum (typically D, I, possibly F)
   - oneOf for single-task vs multi-task (task vs onExecutionTasks[])
   - properties.attributes.properties.output (the IOutputHandler reference)
   - required[]
4. Drive AskUserQuestion + skeleton from this schema.
```

Also read `references/concepts/csx-contracts.md` before scaffolding mappings — `IMapping`, `IOutputHandler`, and `ScriptBase` signatures must match the NuGet contracts exactly.

## Steps

### 1. Resolve paths

From `vnext.config.json`: `componentsRoot`, `paths.functions`, `domain`.
Target folder: `{componentsRoot}/{paths.functions}/{function-key}/`. Inside: `{function-key}.json`, `src/` (for `.csx`), optional README.

### 2. Determine purpose

Ask:
- **What does this function do?** (One sentence — e.g. "List active branches for a given currency")
- **Who calls it?** (Client/BFF, another workflow, a view's `x-lov`/`x-lookup`?)
- **Does it need the workflow instance's data?** (If yes → scope `I`. If no → scope `D`.)

### 3. Will any view bind to this function's output? (controls `rawResponse`)

Ask the user:

> "Will any view bind to this function's output directly — through `dataSchema`, `x-lov.source`, `x-lookup.source`, or `$lov.X` / `$lookup.X` expressions?"

- **Yes** → set `attributes.rawResponse: true` in the function JSON. This is REQUIRED. Without it, the runtime wraps the response under the function key (`{ "{functionKey}": {...} }`) and JsonPath bindings like `$.data[*]` silently miss the data → empty dropdowns / null lookups with no error.
- **No** (consumed only by workflow logic, another function, or a programmatic caller that knows the function name) → leave it off (default `false`).

When in doubt, set `true`. Programmatic callers can unwrap one extra level themselves; the reverse breaks views invisibly.

Full reference: `references/function-mapping-pattern.md` § 5.

### 4. Choose scope (from schema)

Render the `scope` enum from `function.json`. Annotate:
- `D` — Domain-scoped. Stateless. URL: `/api/v{ver}/{domain}/functions/{key}`. Use for cross-workflow utilities and LOV/lookup endpoints.
- `I` — Instance-scoped. Receives instance context. URL: `/api/v{ver}/{domain}/workflows/{wf}/instances/{instanceId}/functions/{key}`. Use when the function depends on the specific instance's data.
- (Other scopes may exist in the schema — render them all.)

### 4. Single-task or multi-task?

Ask: "Does this function call one upstream system, or does it aggregate multiple?"

- **Single-task** → `attributes.task` field with one task reference + `mapping` (one `.csx` implementing `IMapping`).
- **Multi-task** → `attributes.onExecutionTasks[]` array (each with `order`, `task`, `mapping`) + `attributes.output` (one `.csx` implementing `IOutputHandler` that aggregates results).

For most LOV functions, single-task is enough. Multi-task is for true aggregation (e.g. "fetch user + account + balance from three services, return one envelope").

### 5. Reference or create tasks

For each task this function will call:
- If a matching task already exists, reference it.
- Otherwise, hand off to `component-task` first; come back when it's ready.

### 6. Scaffold `.csx` mappings

For each task reference, scaffold an `IMapping` in `src/`:

```csharp
using System.Threading.Tasks;
using BBT.Workflow.Scripting;
using BBT.Workflow.Definitions;

public class {ClassName}Mapping : IMapping
{
    public Task<ScriptResponse> InputHandler(WorkflowTask task, ScriptContext context)
    {
        // Pull params from context.QueryString, context.Headers, context.Body (multi-source for GET-mode functions)
        // Mutate the task config (e.g. HttpTask URL, body)
        // Return ScriptResponse with prepared payload
        return Task.FromResult(new ScriptResponse { /* … */ });
    }

    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        // context.Body is the upstream task's StandardTaskResponse
        // Unwrap one level (context.Body?.data) to avoid double-wrapping LOV responses
        // Tag with ["lov","success"] / ["lov","failure"] / ["lookup","not-found"]
        dynamic payload = context.Body?.data ?? context.Body;
        return Task.FromResult(new ScriptResponse {
            Key = "{function-key}-result",
            Data = new { data = payload },
            Tags = new[] { "lov", "success" }
        });
    }
}
```

Multi-task variant: each task gets its own `IMapping`; add a final `IOutputHandler` in `src/`:

```csharp
public class {FunctionName}Output : IOutputHandler
{
    public Task<ScriptResponse> Handler(ScriptContext context)
    {
        var taskA = context.TaskResponse["taskKeyA"]?.data;
        var taskB = context.TaskResponse["taskKeyB"]?.data;
        // Merge, project, envelope
        return Task.FromResult(new ScriptResponse {
            Data = new { user = taskA, account = taskB },
            Tags = new[] { "success" }
        });
    }
}
```

Follow `references/concepts/csx-contracts.md` for the exact signatures and standard `using` directives. Follow `references/concepts/mapping-types.md` for the unwrap rule (the most common bug).

### 7. Generate the function JSON

Envelope (single-task):

```json
{
  "key": "{function-key}",
  "version": "1.0.0",
  "domain": "{domain}",
  "flow": "sys-functions",
  "flowVersion": "1.0.0",
  "tags": [],
  "attributes": {
    "scope": "D",
    "task": {
      "order": 1,
      "task": { "key": "{task-key}", "domain": "{domain}", "flow": "sys-tasks", "version": "1.0.0" },
      "mapping": { "location": "./src/{ClassName}Mapping.csx", "code": "" }
    }
  }
}
```

For multi-task: `onExecutionTasks[]` array + `output` field. The exact shape comes from the schema.

`mapping.code` is left empty — the vNext VS Code extension auto-encodes the `.csx` file on save. **Never manually base64-encode.**

### 8. Write the file

Path: `{componentsRoot}/{paths.functions}/{function-key}/{function-key}.json`. The `.csx` files live in `src/` next to it.

### 9. Validate

Run `npm run validate`. Hand failures to `validate-and-fix`.

### 10. (If a view calls this function) Wire up the `x-lov` / `x-lookup`

If this function backs a view's LOV or lookup, the schema field that references it needs:

```jsonc
"x-lov": {
  "source": {
    "function": { "domain": "{domain}", "key": "{function-key}", "version": "1.0.0" },
    "method": "GET",
    "params": [ { "name": "...", "value": "$form.X" } ],
    "responsePath": "$.data[*]",
    "valueField": "code",
    "labelField": "name"
  }
}
```

(For `x-lookup`, similar shape but `responsePath` selects one object and the consumer reads via `$lookup.{propertyName}.field`.)

See `references/concepts/schema-vocabularies.md` for the full vocabulary.

## Notes

- LOV/lookup functions are invoked via **GET**. Parameters arrive in `context.QueryString` or `context.Headers`, NOT `context.Body`. Use a multi-source resolver in `InputHandler`.
- The double-wrap bug: never set `ScriptResponse.Data = context.Body` raw — unwrap one level first.
- `scope: D` functions cannot access instance data; if you need it, use `I`.
- `mapping.location` paths are relative to the function's folder (e.g. `./src/MyMapping.csx`).
