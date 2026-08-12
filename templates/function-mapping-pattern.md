# vNext Function — Script Mapping Pattern

> **Audience**: Anyone writing `.csx` mappings for vNext **functions** (`sys-functions`) — single-task or multi-task. Pair with workflow `.csx` mappings, which use a similar but distinct contract (`ITransitionMapping`).
> **Goal**: Avoid the recurring "function returns a double-wrapped or raw `StandardTaskResponse`" bug, and pick the right input source for GET vs. POST function calls.

---

## 1. The two function shapes

vNext has two function shapes; each uses a different mapping interface.

### 1a. Single-task function — `IMapping`

```jsonc
{
  "attributes": {
    "scope": "D",                        // I = Internal, D = Domain-callable (from views, etc.)
    "task": {
      "order": 1,
      "task": { "key": "<task-key>", "domain": "core", "version": "1.0.0", "flow": "sys-tasks" },
      "mapping": { "location": "./src/<PascalCase>.csx", "code": "<base64; VS Code populates>" }
    }
  }
}
```

The `.csx` implements `IMapping` (both `InputHandler` and `OutputHandler` in one class).

### 1b. Multi-task function — `onExecutionTasks[]` + `attributes.output`

```jsonc
{
  "attributes": {
    "scope": "I",
    "onExecutionTasks": [
      { "order": 1, "task": {...}, "mapping": { "location": "./src/Task1Mapping.csx", "code": "..." } },
      { "order": 2, "task": {...}, "mapping": { "location": "./src/Task2Mapping.csx", "code": "..." } }
    ],
    "output": { "location": "./src/CompositeOutput.csx", "code": "..." }
  }
}
```

Each task gets its own `IMapping`. The final `output` mapping implements `IOutputHandler` — the method is **`OutputHandler(ScriptContext context)`** — and composes per-task results from two dictionaries (see `concepts/csx-contracts.md` § "TaskResponse vs OutputResponse"):

- `context.TaskResponse["camelCaseTaskKey"]` — each task's raw `StandardTaskResponse` (dynamic: `data`, `statusCode`, `isSuccess`, …).
- `context.OutputResponse["camelCaseTaskKey"]` — what each task's own output mapping returned (already shaped), when the task has one.

Both values are dynamic `ExpandoObject`s — probe with `HasProperty`/`GetPropertyValue`, and use `TryGetValue` on the dictionary itself (a task with no output has no entry).

Reference: `core/Functions/account-opening/multi-task-function-test.json` + `src/FunctionOutputMapping.csx`.

---

## 2. Input parameter sources — GET vs. POST

vNext functions can be invoked two ways:

| HTTP verb | Endpoint | Where parameters land in `ScriptContext` |
|---|---|---|
| `POST` | `/api/v1/{domain}/.../functions/{key}` + JSON body | `context.Body` |
| `GET` | `/api/v1/{domain}/.../functions/{key}?param=value` | `context.QueryParameters` and/or `context.Headers` |

There is **no `QueryString` property** on `ScriptContext` — the query string is `QueryParameters`.

**Renderer-initiated calls (x-lov, x-lookup, x-validation) typically use GET** — so reading from `context.Body` alone is **wrong** for those functions; the body is empty and the parameter is silently null.

### Recommended resolver pattern

Inherit `ScriptBase` and use `GetPropertyValue` — no reflection, no bare dynamic access:

```csharp
private string? ResolveParam(ScriptContext context, string name)
{
    // 1. GET function — query string (preferred for renderer-initiated calls)
    var qv = GetPropertyValue<string>(context.QueryParameters, name, null);
    if (!string.IsNullOrEmpty(qv)) return qv;

    // 2. Header fallback (renderer can pass filters as headers; keys are lowercased)
    var hv = GetPropertyValue<string>(context.Headers, name, null);
    if (!string.IsNullOrEmpty(hv)) return hv;

    // 3. POST function — invoke body (back-compat)
    return GetPropertyValue<string>(context.Body, name, null);
}
```

Use this helper inside `InputHandler` and feed the value into `httpTask.SetUrl(...)` (for query params) or `httpTask.SetBody(...)` (for POST tasks).

**Anti-patterns**:
- `var code = context.Body?.code?.ToString();` — fails for GET-invoked functions, **and** throws `RuntimeBinderException` when `code` is absent (`?.` does not guard a missing ExpandoObject member).
- `context.GetType().GetProperty("QueryString")` — the property doesn't exist; hand-rolled reflection is never needed, `ScriptBase` helpers cover it.

---

## 3. Output unwrapping — beat the StandardTaskResponse

When a function call completes, vNext serialises the upstream task's result as a `StandardTaskResponse`:

```jsonc
{
  "getBranches": {                       // function-level wrapper (runtime-generated)
    "data": <ScriptResponse.Data>,           //   ← what your OutputHandler returns
    "body": "<raw response body string>",
    "statusCode": 200,
    "isSuccess": true,
    "headers": { ... },
    "metadata": { "url": "...", "method": "GET", "reasonPhrase": "OK" },
    "executionDurationMs": 686,
    "taskType": "http",
    "json": "{}",  "normalizedJson": "{}",  "jsonElement": {}
  }
}
```

Inside `OutputHandler`, the engine has **merged the task's `StandardTaskResponse` into `context.Body`** (camelCased). So `context.Body.statusCode`, `context.Body.isSuccess` and `context.Body.data` are all readable — and `context.Body.data` is the parsed HTTP response body. If MockLab returns `{"data":[...]}`, the items array sits at `context.Body.data.data`.

Remember the runtime type: `context.Body` is an `ExpandoObject`, so probe with `HasProperty` before reading a level that may not exist.

### The double-wrap mistake

```csharp
// ❌ BAD — returns context.Body raw → response shape becomes data.data[*]
return Task.FromResult(new ScriptResponse { Key = "...", Data = context.Body });
```

Renderer's `x-lov` JsonPath `$.data[*].code` then fails silently because the array lives at `$.data.data[*]`.

### The clean shape

```csharp
public Task<ScriptResponse> OutputHandler(ScriptContext context)
{
    try
    {
        var statusCode = GetPropertyValue<int>(context.Body, "statusCode", 200);
        var payload = HasProperty(context.Body, "data")               // unwrap the StandardTaskResponse layer
            ? GetPropertyValue(context.Body, "data")
            : context.Body;
        var items = HasProperty(payload, "data")                      // some upstreams nest one more level
            ? GetPropertyValue(payload, "data")
            : payload;

        if (statusCode >= 200 && statusCode < 300 && items != null)
        {
            return Task.FromResult(new ScriptResponse
            {
                Key = "branches-lov",
                Data = new { data = items },                          // explicit envelope; predictable JsonPath
                Tags = new[] { "lov", "account-opening", "success" }
            });
        }

        return Task.FromResult(new ScriptResponse
        {
            Key = "branches-lov-failure",
            Data = new { error = "Failed", statusCode = statusCode },
            Tags = new[] { "lov", "account-opening", "failure" }
        });
    }
    catch (Exception ex)
    {
        return Task.FromResult(new ScriptResponse
        {
            Key = "branches-lov-exception",
            Data = new { error = ex.Message },
            Tags = new[] { "lov", "account-opening", "exception" }
        });
    }
}
```

**The renderer's `x-lov` then evaluates `$.data[*].code` against `getBranches.data.data` — clean and predictable.**

---

## 4. Why `Data = new { data = items }` and not `Data = items`?

If the upstream returns an array and you set `Data = items` directly, the StandardTaskResponse wrapper would expose `getBranches.data = [...]` — and `x-lov.valueField: "$.data[*].code"` would resolve, but `$.data` on its own (used by `x-lookup.resultField`) would be ambiguous for object results.

Wrapping under `{ data: items }` keeps a **uniform envelope** across LOV (array) and lookup (object) results. Schema authors write JsonPath against `$.data` or `$.data[*]` without having to know whether the upstream returned a list or a single record.

This matches the MockLab seed convention (`{"data": [...] }` for LOV, `{"data": {...}}` for lookup).

---

## 5. `rawResponse: true` — required for view-bound functions

When a function's output is **bound directly into a view** (via `dataSchema`, `x-lov.source`, `x-lookup.source`, or any expression like `$lov.{functionKey}.X` / `$lookup.{property}.X`), the function definition MUST set `attributes.rawResponse: true`.

### What `rawResponse` controls

`rawResponse` lives at `attributes.rawResponse` on the function (same level as `scope`). It tells the runtime whether to wrap the function's `ScriptResponse.Data` under the function's key or expose it directly.

| Setting | Response shape returned to the caller | When to use |
|---------|--------------------------------------|-------------|
| `false` (default) | `{ "{functionKey}": { ...your Data... } }` — wrapped under the function name | Programmatic callers (workflow-internal, BFF-style) that explicitly know the function name |
| `true` | `{ ...your Data... }` — raw, no wrapper | **View bindings**, LOV/lookup `source` fields, anything that uses JsonPath like `$.data[*]` to read the result |

### The failure mode (silent)

A view declares:

```jsonc
"x-lov": {
  "source": {
    "function": { "key": "get-branches", ... },
    "responsePath": "$.data[*]",
    "valueField": "code"
  }
}
```

If `get-branches.attributes.rawResponse` is missing (or `false`):
- Runtime envelope: `{ "get-branches": { "data": [ ... ] } }`
- `$.data[*]` resolves against the wrapper → finds nothing → **dropdown silently empty**
- No error logged; the user sees an empty list and assumes the upstream returned nothing.

With `rawResponse: true`:
- Runtime envelope: `{ "data": [ ... ] }`
- `$.data[*]` resolves correctly → dropdown populated.

### The function shape

```jsonc
{
  "key": "get-branches",
  "version": "1.0.0",
  "domain": "{{domain}}",
  "flow": "sys-functions",
  "flowVersion": "1.0.0",
  "tags": ["lov"],
  "attributes": {
    "scope": "D",
    "rawResponse": true,             // ← required for view-bound functions
    "task": {
      "order": 1,
      "task": { "key": "get-branches-http-task", "domain": "{{domain}}", "flow": "sys-tasks", "version": "1.0.0" },
      "mapping": { "location": "./src/GetBranchesLovMapping.csx", "code": "" }
    }
  }
}
```

### Decision rule

When creating a function, ask: **"Will any view bind to this function's output directly (dataSchema / x-lov / x-lookup / $lov / $lookup)?"**

- **Yes** → `rawResponse: true`. The skill should set this automatically and confirm with the user.
- **No** (consumed only by workflow logic or another function) → `rawResponse: false` (omit; default).

When in doubt, set `rawResponse: true` — programmatic callers that need the wrapper can still unwrap one level by reading `{functionKey}` themselves. The reverse (`false` for a view-bound function) creates the silent-empty bug above.

### Reference

Working examples in `core/Functions/account-opening/get-branches.json` and `get-branch-detail.json` (both `rawResponse: true`).

---

## 6. Tags + error semantics

Use `ScriptResponse.Tags` for downstream filtering (`success`, `failure`, `exception`, `not-found`). Match on HTTP status from `GetPropertyValue<int>(context.Body, "statusCode", 200)`:

- `2xx` + non-null payload → success path
- `4xx` (esp. 404) → not-found / failure path
- exception → exception path with `error` field

Renderer doesn't currently branch on Tags, but log aggregators and downstream tasks do.

---

## 7. HTTP task helpers (`HttpTask` injection)

In `InputHandler`, cast the `WorkflowTask` to `HttpTask` and mutate before invocation:

| Method | Purpose |
|---|---|
| `httpTask.SetUrl(string)` | Replace the URL (template substitution, query string append, etc.) |
| `httpTask.SetHeaders(Dictionary<string, string?>)` | Replace request headers |
| `httpTask.SetBody(object)` | Replace the request body (POST/PUT/PATCH) |

Always wrap in `try/catch` and check for `null` on the cast — script tasks (non-HTTP) won't cast.

---

## 8. Minimal LOV function template

```csharp
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using BBT.Workflow.Scripting;
using BBT.Workflow.Scripting.Functions;
using BBT.Workflow.Definitions;

public class GetMyLovMapping : ScriptBase, IMapping
{
    public Task<ScriptResponse> InputHandler(WorkflowTask task, ScriptContext context)
    {
        try
        {
            var httpTask = task as HttpTask;
            if (httpTask == null)
                throw new InvalidOperationException("Task must be an HttpTask");

            var filterValue = ResolveParam(context, "filterParamName");
            if (!string.IsNullOrEmpty(filterValue))
            {
                var sep = httpTask.Url.Contains("?") ? "&" : "?";
                httpTask.SetUrl($"{httpTask.Url}{sep}filterParamName={filterValue}");
            }

            httpTask.SetHeaders(new Dictionary<string, string?>
            {
                ["Accept"] = "application/json",
                ["X-Request-Id"] = GetPropertyValue<string>(context.Headers, "x-request-id", Guid.NewGuid().ToString())
            });

            return Task.FromResult(new ScriptResponse());
        }
        catch (Exception ex)
        {
            return Task.FromResult(new ScriptResponse
            {
                Key = "my-lov-input-error",
                Data = new { error = ex.Message }
            });
        }
    }

    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        try
        {
            var statusCode = GetPropertyValue<int>(context.Body, "statusCode", 200);
            var payload = HasProperty(context.Body, "data")
                ? GetPropertyValue(context.Body, "data")
                : context.Body;
            var items = HasProperty(payload, "data")
                ? GetPropertyValue(payload, "data")
                : payload;

            if (statusCode >= 200 && statusCode < 300 && items != null)
            {
                return Task.FromResult(new ScriptResponse
                {
                    Key = "my-lov",
                    Data = new { data = items },
                    Tags = new[] { "lov", "success" }
                });
            }

            return Task.FromResult(new ScriptResponse
            {
                Key = "my-lov-failure",
                Data = new { error = "Failed", statusCode = statusCode },
                Tags = new[] { "lov", "failure" }
            });
        }
        catch (Exception ex)
        {
            return Task.FromResult(new ScriptResponse
            {
                Key = "my-lov-exception",
                Data = new { error = ex.Message },
                Tags = new[] { "lov", "exception" }
            });
        }
    }

    private string? ResolveParam(ScriptContext context, string name)
    {
        var qv = GetPropertyValue<string>(context.QueryParameters, name, null);
        if (!string.IsNullOrEmpty(qv)) return qv;

        var hv = GetPropertyValue<string>(context.Headers, name, null);
        if (!string.IsNullOrEmpty(hv)) return hv;

        return GetPropertyValue<string>(context.Body, name, null);
    }
}
```

Working examples in `core/Functions/account-opening/src/GetBranchesLovMapping.csx` (LOV cascade) and `GetBranchDetailLookupMapping.csx` (lookup).

---

## 9. Function BFF contract — verbs, inputSchema, outputSchema, inputView, outputView

> Runtime support: added after v0.0.79 (vnext PRs #679, #858, #868). On older runtimes these fields are simply not enforced — check `vnext.config.json`'s `runtimeVersion` before relying on them.

Functions are vNext's **BFF surface**, in two modes — settle the mode with the user before designing (`AskUserQuestion`):

- **BFF API** (the original purpose): a pure programmatic endpoint. Design it **like an API** — verbs + optional schemas, **no `inputView`/`outputView`**. This is the default when no screen is mentioned; propose it and confirm.
- **BFF View**: a whole single stateless page that needs no instance data (e.g. a loan-rate calculator) — the function declares the page's form and result views itself. Propose this when the user's stated purpose is a screen.

The declarable client contract:

| Field | Type | Runtime behavior |
|-------|------|------------------|
| `verbs` | `string[]` (e.g. `["POST"]`) | Whitelist of accepted HTTP verbs. Absent/empty = every verb accepted (back-compat). A non-matching verb → **405** with an `Allow` header listing the declared verbs. No `QUERY` verb — declaring it is a validation error; model body-carrying reads as `POST`. |
| `inputSchema` | `sys-schemas` reference or rule-based entries | Request body is **validated** before any task runs; failure → **400** with field-level errors. Not validated when absent or when the request has no body. |
| `outputSchema` | `sys-schemas` reference or rule-based entries | **Declarative only** — the runtime never validates responses against it. Documents the response shape for clients. |
| `inputView` | `sys-views` reference or rule-based entries | The view a client renders to **collect** this function's input (the BFF View form). |
| `outputView` | `sys-views` reference or rule-based entries | The view a client renders to **present** this function's output. |
| `rawResponse` | `bool` | See § 5. |
| `cache` | object | Optional read-through cache: response served from cache on hit (tasks skipped), written on miss. |

Validation rule: declaring `inputSchema` alongside verbs that can never carry a body (e.g. `verbs: ["GET"]` only) is a definition-time **error**.

### Rule-based contract slots

Each of the four contract slots accepts either a single component reference or an **array of rule entries** — same concept as state/transition views: declaration order, **first match wins**, a trailing rule-less entry is the fallback. A rule that fails to evaluate is logged and skipped. A slot where nothing matches is "no contract", not an error (validation skips; content routes return 404).

```jsonc
"attributes": {
  "scope": "D",
  "verbs": ["POST"],
  "inputSchema": { "key": "loan-calc-input", "domain": "core", "flow": "sys-schemas", "version": "1.0.0" },
  "inputView":  { "key": "loan-calc-form",  "domain": "core", "flow": "sys-views",   "version": "1.0.0" },
  "outputView": { "key": "loan-calc-result","domain": "core", "flow": "sys-views",   "version": "1.0.0" },
  "task": { /* … */ }
}
```

### Discovery endpoints

Clients discover a function's contract without invoking it:

```
GET {domain}/functions/{fn}/info
GET {domain}/functions/{fn}/view?target=input|output
GET {domain}/functions/{fn}/schema?target=input|output
GET {domain}/workflows/{wf}/instances/{id}/functions/{fn}/info      (+ view/schema variants)
```

`/info` answers "may I run this, with which verb, at which URL, and which view/schema applies right now" — scope and role checks apply (denial is **403**; an unauthorized caller learns nothing about the shape). Built-in system functions (`state`, `view`, `data`, …) have no component and 404 from `/info`. The instance **state response** also carries the workflow's function links (`functions` array / catalog href, version-dependent) so a polling client discovers them without an extra round trip.

### Designing a BFF View

For a stateless single page (rate calculator, eligibility check…):
1. One `sys-functions` component, `scope: "D"`, `verbs: ["POST"]` (or `["GET"]` for parameterless reads).
2. `inputView` → the form the client renders; `inputSchema` → server-side validation of the submitted body.
3. `outputView` → the result presentation; `outputSchema` → documented response shape.
4. `rawResponse: true` if any view binds the output directly.
5. No workflow, no instance, no state — the function IS the page.

When a user asks for such a page during workflow design, **propose the Function (BFF View) instead of
a workflow** and get confirmation. And the mirror rule: a function with **no view need gets no view
fields** — design it as a plain BFF API (verbs + schemas), confirmed with the user.
