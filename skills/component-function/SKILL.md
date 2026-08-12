---
name: component-function
description: Use when the user wants to create a vNext Function — a REST endpoint exposed by the runtime. Fetches function.json schema first, walks scope (D/F/I) and task composition (single-task vs multi-task), scaffolds the IMapping or IOutputHandler .csx using contracts from csx-contracts.md.
---

# Component Function

A Function is a REST endpoint hosted by the workflow runtime. It can be:
- **Single-task**: one HTTP / Script / Dapr task with an `IMapping`-typed handler.
- **Multi-task**: multiple `onExecutionTasks[]` aggregated by an `IOutputHandler`.

Common uses:
- LOV/lookup endpoints called by views (`x-lov`, `x-lookup`)
- BFF-style aggregation for clients
- **BFF View pages** — stateless single screens with no instance data (rate calculators, eligibility checks), where the function itself declares `inputView`/`inputSchema`/`outputView`/`outputSchema`
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

### 2. Determine purpose — and the mode: BFF API or BFF View

Ask:
- **What does this function do?** (One sentence — e.g. "List active branches for a given currency")
- **Who calls it?** (Client/BFF, another workflow, a view's `x-lov`/`x-lookup`?)
- **Does it need the workflow instance's data?** (Instance data → scope `I`; flow-scoped → `F`; stateless/domain-wide → `D`.)

Then decide the **mode** and get explicit user confirmation (`AskUserQuestion`):

> "Does this function need to render a screen to the user, or is it a pure API?"

- **BFF View** — the function serves a *page* (single input→output screen: a rate calculator, an
  eligibility check). It declares `inputView` (the form the client renders) and `outputView` (the
  result presentation), plus `inputSchema`/`outputSchema`. Propose this mode when the user's stated
  purpose is a screen/page.
- **BFF API (Recommended default when no view is mentioned)** — no screen involved: the function is
  called programmatically (client code, another workflow, `x-lov`/`x-lookup`). Design it **like an
  API**: verbs + optional `inputSchema`/`outputSchema` only, **no `inputView`/`outputView`**.

**Never add view fields to a function without the user confirming a view need — and never leave
them off when the user described a page.** The mode drives step 5 below.

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
- `F` — Flow-scoped. Bound to a workflow definition (not a specific instance). Served on the instance route — the domain route rejects `F`/`I` with 403.
- `I` — Instance-scoped. Receives instance context. URL: `/api/v{ver}/{domain}/workflows/{wf}/instances/{instanceId}/functions/{key}`. Use when the function depends on the specific instance's data.
- (Render whatever the schema's `scope` enum lists.)

### 5. Client contract — verbs, inputSchema/outputSchema, inputView/outputView

> Runtime support: post-v0.0.79. On older runtimes these fields are not enforced — check `runtimeVersion` first. Details: `references/function-mapping-pattern.md` § 9.

Driven by the **mode chosen in step 2**:

- **Both modes** — ask: **Which HTTP verbs should this function accept?** (e.g. `["POST"]`. Omit = every verb accepted. Mismatched verb → 405 + `Allow` header. There is no `QUERY` verb — body-carrying reads are `POST`.) And: **Should the request body be validated?** → `inputSchema` (a `sys-schemas` reference; failure → 400 with field errors). Do NOT declare `inputSchema` if the only verbs can't carry a body (e.g. GET-only) — that's a validation error.
- **BFF View mode only** — add `inputView` (the form the client renders) and/or `outputView` (result presentation), plus `outputSchema` (declarative response contract). Each slot accepts a single reference or rule-based entries (first match wins; a trailing rule-less entry is the fallback). Hand the view design off to `view-design` if the views don't exist yet.
- **BFF API mode** — **no `inputView`/`outputView`.** The contract is verbs + schemas, like any REST API.

Skip this step entirely for plain LOV/lookup functions — they need none of these fields.

### 6. Single-task or multi-task?

Ask: "Does this function call one upstream system, or does it aggregate multiple?"

- **Single-task** → `attributes.task` field with one task reference + `mapping` (one `.csx` implementing `IMapping`).
- **Multi-task** → `attributes.onExecutionTasks[]` array (each with `order`, `task`, `mapping`) + `attributes.output` (one `.csx` implementing `IOutputHandler` that aggregates results).

For most LOV functions, single-task is enough. Multi-task is for true aggregation (e.g. "fetch user + account + balance from three services, return one envelope").

### 7. Reference or create tasks

For each task this function will call:
- If a matching task already exists, reference it.
- Otherwise, hand off to `component-task` first; come back when it's ready.

### 8. Scaffold `.csx` mappings

For each task reference, scaffold an `IMapping` in `src/`. Inherit `ScriptBase` and read dynamic data ONLY through its helpers (`HasProperty`, `GetPropertyValue`) — direct dynamic access (`context.Body?.x`) throws `RuntimeBinderException` when the member is absent:

```csharp
using System.Threading.Tasks;
using BBT.Workflow.Scripting;
using BBT.Workflow.Scripting.Functions;
using BBT.Workflow.Definitions;

public class {ClassName}Mapping : ScriptBase, IMapping
{
    public Task<ScriptResponse> InputHandler(WorkflowTask task, ScriptContext context)
    {
        // Pull params via GetPropertyValue from context.QueryParameters, context.Headers, context.Body
        // (multi-source for GET-mode functions; there is NO context.QueryString)
        // Mutate the task config (e.g. HttpTask URL, body)
        return Task.FromResult(new ScriptResponse { /* … */ });
    }

    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        // The task's StandardTaskResponse is merged into context.Body (body.data, body.statusCode, …)
        // Unwrap one level to avoid double-wrapping LOV responses; probe with HasProperty
        // Tag with ["lov","success"] / ["lov","failure"] / ["lookup","not-found"]
        var payload = HasProperty(context.Body, "data")
            ? GetPropertyValue(context.Body, "data")
            : context.Body;
        return Task.FromResult(new ScriptResponse {
            Key = "{function-key}-result",
            Data = new { data = payload },
            Tags = new[] { "lov", "success" }
        });
    }
}
```

Multi-task variant: each task gets its own `IMapping`; add a final `IOutputHandler` in `src/` — the method is **`OutputHandler`**, not `Handler`:

```csharp
public class {FunctionName}Output : ScriptBase, IOutputHandler
{
    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        // TaskResponse[key] = each task's StandardTaskResponse (dynamic, camelCase keys)
        // OutputResponse[key] = each task's own output-mapping result, when it has one
        var taskA = context.TaskResponse.TryGetValue("taskKeyA", out var a)
            ? GetPropertyValue(a, "data") : null;
        var taskB = context.TaskResponse.TryGetValue("taskKeyB", out var b)
            ? GetPropertyValue(b, "data") : null;
        return Task.FromResult(new ScriptResponse {
            Data = new { user = taskA, account = taskB },
            Tags = new[] { "success" }
        });
    }
}
```

Follow `references/concepts/csx-contracts.md` for the exact signatures, the dynamic type model (ExpandoObject/`List<object?>`, camelCase), and the full `ScriptBase` helper list. Follow `references/concepts/mapping-types.md` for the unwrap rule (the most common bug).

### 9. Generate the function JSON

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

For multi-task: `onExecutionTasks[]` array + `output` field. Contract fields (`verbs`, `inputSchema`, `outputSchema`, `inputView`, `outputView`) go in `attributes` alongside `scope` when step 5 selected them. The exact shape comes from the schema.

`mapping.code` is left empty — the vNext VS Code extension auto-encodes the `.csx` file on save. **Never manually base64-encode.**

### 10. Write the file

Path: `{componentsRoot}/{paths.functions}/{function-key}/{function-key}.json`. The `.csx` files live in `src/` next to it.

### 11. Validate

Run `npm run validate`. Hand failures to `validate-and-fix`.

### 12. (If a view calls this function) Wire up the `x-lov` / `x-lookup`

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

- LOV/lookup functions are invoked via **GET**. Parameters arrive in `context.QueryParameters` or `context.Headers`, NOT `context.Body` (there is no `context.QueryString`). Use a multi-source resolver via `GetPropertyValue` in `InputHandler`.
- **Never access dynamic members directly** (`context.Body?.x`, `context.Instance.Data.y`) — an absent member throws at runtime. Inherit `ScriptBase`; use `HasProperty` / `GetPropertyValue`.
- The double-wrap bug: never set `ScriptResponse.Data = context.Body` raw — unwrap one level first.
- `scope: D` functions cannot access instance data; if you need it, use `I`.
- `mapping.location` paths are relative to the function's folder (e.g. `./src/MyMapping.csx`).
