# `.csx` Contracts — Type Signatures, Runtime Types & ScriptBase Helpers

`.csx` mapping files run against the `BBT.Workflow.*` NuGet packages. Skills generating `.csx` skeletons MUST use the exact `using` directives, interface method names, and access idioms defined here. Everything below is verified against the runtime source (`BBT.Workflow.Domain/Scripting/*` and `BBT.Workflow.Modules.Scripting/.../ScriptBase.cs`) — do not invent members that are not listed.

## Golden rules (read first)

1. **Never access a dynamic property directly.** `context.Instance.Data.customer?.id` **throws at runtime** when `customer` (or `id`) is absent — instance data is an `ExpandoObject`, and accessing a missing member raises `RuntimeBinderException`; `?.` does NOT save you. Always go through the `ScriptBase` helpers: `HasProperty(obj, "name")`, `GetPropertyValue<T>(obj, "name", defaultValue)`.
2. **Inherit `ScriptBase`.** Mapping classes should derive from `ScriptBase` to get the property/list/logging helpers. Do not hand-roll reflection.
3. **Repeated logic goes to `sys-mappings` first.** If the same `.csx` structure appears in more than one place, extracting a `sys-mappings` helper is the *primary* approach, not an afterthought. See `mappings-and-scripts.md`.
4. **`context.Related` is for correlation data only** (parent / subflow / subprocess of *this* instance, v0.0.79+). Any other cross-instance data must be fetched with a Task.
5. **Return delta-only output from mappings** (v0.0.79+ immediate-persistence write model): `ScriptResponse.Data` should contain **only the fields you changed**, never a full echo of the instance data — a full echo overwrites concurrent writers' fresher values with stale ones (this bites hardest under parallel branches and `updateData` storms).

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
using BBT.Workflow.Definitions.Timer;     // ITimerMapping / TimerSchedule
using BBT.Workflow.Scripting.Functions;   // ScriptBase (property/list/log helpers)
using BBT.Workflow.Filtering;             // IEventMapping's InstanceFilter / InstanceQuery
```

## The dynamic type model — why direct access hallucinates

Every `dynamic` on `ScriptContext` is built by serializing the source object to JSON (camelCase policy) and deserializing through `ExpandoObjectJsonConverter`. Consequences:

| JSON shape | Runtime CLR type |
|------------|------------------|
| object `{...}` | `ExpandoObject` (implements `IDictionary<string, object>`) |
| array `[...]` | `List<object?>` |
| string / number / bool | `string` / numeric / `bool` boxed as `object` |
| property names | **camelCase**, whatever the upstream casing was |

Rules that follow from this:

- **Missing member = `RuntimeBinderException`.** An `ExpandoObject` only has the keys the JSON had. `data.customer` on a payload without `customer` throws — it does not return `null`. Guard with `HasProperty` or use `GetPropertyValue<T>(obj, name, default)`.
- **`?.` does not protect against a missing member.** It only protects against the *object itself* being null.
- **Arrays are `List<object?>`, not typed lists.** Use `AsList` / `GetList` and the `List*` helpers. LINQ directly on a `dynamic` list with a lambda fails to compile (CS1977) — convert first:

```csharp
// ✗ CS1977 — dynamic argument + lambda in the same call
// ListAny(context.Instance.Data.items, x => x.status == "pending");

// ✓ convert first
var items = GetList(context.Instance.Data, "items");
var hasPending = ListAny(items, x => x.status == "pending");
```

- **Property names are camelCase** even if the upstream API returned PascalCase. `TaskResponse` keys are also normalized to valid camelCase variable names.

## `ScriptContext` — the verified surface

The real, complete surface (from `BBT.Workflow.Domain/Scripting/Models.cs`). There is **no `QueryString` property** — the query string lives in `QueryParameters`.

| Property | Type | What it holds |
|----------|------|---------------|
| `Body` | `dynamic?` | Request payload and/or merged task results (camelCased). After a task runs, the task's `StandardTaskResponse` is **merged into** `Body`. |
| `Headers` | `dynamic?` | HTTP headers, **keys lowercased** (`context.Headers.authorization`). Guard with `HasProperty`. |
| `RouteValues` | `dynamic?` | URL path segments + routing values. |
| `QueryParameters` | `dynamic?` | URL query string parameters (GET-mode function calls arrive here). |
| `EventPayload` | `dynamic?` | Raw inbound pub/sub / binding payload. Non-null only inside `IEventMapping`. |
| `RawBody` | `string?` | The original request body as a literal string (not camelCased, not re-serialized). For JWS/mTLS signature verification. |
| `Instance` | `Instance?` | The workflow instance snapshot: `Instance.Data` (dynamic), `Instance.Key`, current state, etc. |
| `Incident` | `ScriptIncidentInfo?` | Error-boundary awareness: `HasActiveIncident`, `ActiveIncident`, `TotalIncidentCount`. |
| `Related` | `IRelatedInstanceAccessor` | Correlated-instance reads (v0.0.79+, see below). Never null. |
| `Workflow` | `Definitions.Workflow?` | The workflow definition (states, transitions, tasks). |
| `Runtime` | `IRuntimeInfoProvider` | Environment/runtime info. |
| `Transition` | `Transition` | The transition being executed. |
| `CurrentTransition` | `ScriptTransitionRequest?` | The **original** transition request: `.Data` (body as sent) and `.Header` (lowercased keys) — unaffected by later task-response merges into `Body`. Null outside transition task steps. |
| `Definitions` | `Dictionary<string, dynamic>` | Shared definitions/templates. |
| `TaskResponse` | `Dictionary<string, dynamic?>` | Per-task `StandardTaskResponse` results, keyed by camelCase task key. |
| `OutputResponse` | `Dictionary<string, dynamic?>` | Per-task **OutputHandler results** (what each task's `IMapping.OutputHandler` returned), keyed by task key. Not merged into `Body`. |
| `MetaData` | `Dictionary<string, dynamic>` | Execution metadata. |
| `Mutations` | `InstanceMutations` | Controlled instance mutations (e.g. `Stage`), applied atomically after the script. |

### `TaskResponse` vs `OutputResponse` vs `Body` — the exact semantics

For each executed task the engine calls `SetStandardResponse(response, taskKey)`:
- the camelCased `StandardTaskResponse` is **merged into `context.Body`**, and
- the same value is stored in `context.TaskResponse[taskKey]`.

Separately, when a task's own `IMapping.OutputHandler` returns a `ScriptResponse`, its `Data` is stored in `context.OutputResponse[taskKey]` (NOT merged into `Body`).

So in a multi-task Function's final `IOutputHandler`:
- `context.TaskResponse["myTask"]` → the raw task result: `{ data, statusCode, isSuccess, errorMessage, headers, metadata, executionDurationMs, taskType, body }` (camelCase dynamic).
- `context.OutputResponse["myTask"]` → whatever that task's own output mapping returned (already unwrapped/shaped, if the task had one).
- `context.Body` → the accumulated merge of the request body + every task's StandardTaskResponse; in a **single-task** `IMapping.OutputHandler`, `context.Body` therefore looks like the StandardTaskResponse (`context.Body.data`, `context.Body.statusCode`, …).

Access both dictionaries with `TryGetValue`/`ContainsKey` or `GetPropertyValue` on the values — a task that produced no output has no entry (or a null one).

### `StandardTaskResponse` (what `TaskResponse[key]` / merged `Body` contains)

```csharp
public sealed class StandardTaskResponse
{
    public dynamic? Data { get; set; }                       // → body.data (camelCase)
    public int? StatusCode { get; set; }
    public bool IsSuccess { get; set; }                       // default true
    public string? ErrorMessage { get; set; }
    public Dictionary<string, string>? Headers { get; set; }
    public Dictionary<string, object>? Metadata { get; set; }
    public long? ExecutionDurationMs { get; set; }
    public string? TaskType { get; set; }
    public string? Body { get; set; }  // raw response string (SOAP XML / raw JSON); ParseXml(Body) for XML
}
```

**Unwrap rule.** In an `OutputHandler`, the task payload is `context.Body?.data` (guard with `HasProperty` when the shape is uncertain). For LOV functions whose upstream nests one more level: check `HasProperty(payload, "data")` before reaching for `payload.data`.

### `ScriptResponse` (the return envelope)

```csharp
public sealed class ScriptResponse
{
    public string? Key { get; set; }
    public dynamic? Data { get; set; }        // merged into instance data (OutputHandler) or used as subflow input, etc.
    public dynamic? Headers { get; set; }
    public int? StatusCode { get; set; }      // override the function HTTP status (e.g. 400/404/410)
    public dynamic? RouteValues { get; set; }
    public string[] Tags { get; set; }        // defaults to empty array
}
```

## `ScriptBase` helpers — always use these

Mapping classes inherit `ScriptBase` (namespace `BBT.Workflow.Scripting.Functions`). Its helpers are the sanctioned way to touch dynamic data.

### Property access (the core four)

```csharp
bool  HasProperty(object obj, string propertyName)                    // ExpandoObject key check or reflection; case-insensitive for CLR types
object? GetPropertyValue(object obj, string propertyName)             // null when absent
T?    GetPropertyValue<T>(object obj, string propertyName)            // + Convert.ChangeType, default(T) on failure
T     GetPropertyValue<T>(object obj, string propertyName, T defaultValue)  // preferred form
```

```csharp
// ✓ the canonical read idiom
var customerId = GetPropertyValue<string>(context.Instance.Data, "customerId", "");
if (HasProperty(context.Instance.Data, "customer"))
{
    var customer = GetPropertyValue(context.Instance.Data, "customer");
    var limit = GetPropertyValue<decimal>(customer, "creditLimit", 0m);
}
```

### List helpers (arrays are `List<object?>`)

```csharp
List<object?> AsList(object? list)                        // safe cast, empty list fallback
List<object?> GetList(object? obj, string propertyName)   // GetPropertyValue + AsList
List<object?> ListFilter(object? list, Func<dynamic,bool> predicate)   // .Where()
dynamic? ListFirst(object? list, Func<dynamic,bool>? predicate = null) // .FirstOrDefault()
dynamic? ListLast(object? list, Func<dynamic,bool>? predicate = null)  // .LastOrDefault()
bool  ListAny(object? list, Func<dynamic,bool>? predicate = null)      // .Any()
int   ListCount(object? list, Func<dynamic,bool>? predicate = null)    // .Count()
List<TResult> ListSelect<TResult>(object? list, Func<dynamic,TResult> selector) // .Select()
void  ListAdd(object? list, object? item)
int   ListRemove(object? list, Func<dynamic,bool> predicate)           // RemoveAll
```

> **CS1977 reminder:** never pass a raw dynamic expression + lambda to these in one call. `var items = AsList(context.Instance.Data.items);` first (or `GetList(context.Instance.Data, "items")`), then filter.

### Building dynamic data

```csharp
dynamic CreateObject()                                     // new ExpandoObject
List<object?> CreateList()                                 // Instance.Data-compatible list
void SetProperty(object obj, string propertyName, object? value)   // creates the key on ExpandoObject
bool RemoveProperty(object obj, string propertyName)               // ExpandoObject only
Dictionary<string, object?> ToDictionary(object? obj)              // enumerate/inspect
```

```csharp
dynamic item = CreateObject();
SetProperty(item, "id", Guid.NewGuid().ToString());
SetProperty(item, "status", "pending");
var items = GetList(context.Instance.Data, "items");
ListAdd(items, item);
SetProperty(context.Instance.Data, "processedAt", DateTime.UtcNow);
```

### XML helpers (SOAP tasks)

```csharp
XmlDocument? ParseXml(string? xmlString)      // null on parse failure, never throws
string? XmlToString(XmlDocument? xmlDoc)
string? EscapeXml(string? value)              // escape user input embedded in SOAP bodies
```

### Logging — `args:` must be named

```csharp
LogTrace / LogDebug / LogInformation / LogWarning / LogError / LogCritical
```

The signature has `[CallerFilePath]`/`[CallerMemberName]`/`[CallerLineNumber]` parameters before `params object[] args`, so **structured-log arguments must use the named form**:

```csharp
LogInformation("Status: {status}", args: new object[] { GetPropertyValue<string>(context.Instance.Data, "status", "?") });
```

### Configuration & secrets

```csharp
string? GetConfigValue(string key)                       // ':'-separated nested keys
string  GetConfigValue(string key, string defaultValue)
T?      GetConfigValue<T>(string key)
T       GetConfigValue<T>(string key, T defaultValue)
string? GetConnectionString(string name)
bool    ConfigExists(string key)
Task<string> GetSecretAsync(string storeName, string secretStore, string secretKey)   // Dapr secret store
Task<Dictionary<string,string>> GetSecretsAsync(string storeName, string secretStore)
// sync wrappers: GetSecret / GetSecrets
```

## `context.Related` — correlated instance access (v0.0.79+)

Mapping scripts can read a **related** instance's data directly: one hop up (the parent that started this instance as a SubFlow/SubProcess) or one hop down (this instance's own correlations). Lazy + memoized per context; nothing is pre-fetched.

**Use only for correlation relationships.** If a script needs data from an arbitrary other instance, that is a Task (e.g. GetInstances / HTTP), not `Related`.

```csharp
public interface IRelatedInstanceAccessor
{
    bool HasParent { get; }   // metadata only, no data read
    Task<IReadOnlyList<string>> SubKeysAsync(CancellationToken ct = default);       // correlation keys, no data read
    Task<RelatedInstanceView?> ParentAsync(CancellationToken ct = default);         // null = no parent
    Task<RelatedInstanceView?> SubAsync(string subFlowKey, CancellationToken ct = default);   // newest match, null = none
    Task<IReadOnlyList<RelatedInstanceView>> SubsAsync(string? subFlowKey = null, CancellationToken ct = default); // oldest first
}
```

`RelatedInstanceView` fields: `InstanceId`, `Key`, `Domain`, `Flow`, `FlowVersion`, `Status` (A/B/C/F/P), `CurrentState`, `IsCompleted`, `CorrelationCompleted` (bool?, null for the parent direction), `TerminalOutcome` (Completed/Faulted/Canceled), `SubFlowType` ("S"/"P", null for parent), `Data` (dynamic — same ExpandoObject model, use the helpers).

```csharp
// input binding on a subflow — read the parent
var parent = await context.Related.ParentAsync();
var limit  = GetPropertyValue<decimal>(parent?.Data, "creditLimit", 0m);

// view condition on a parent — is the KYC child done?
var kyc = await context.Related.SubAsync("kyc-flow");
return kyc?.IsCompleted == true;

// aggregate over repeated subprocesses
var uploads = await context.Related.SubsAsync("doc-upload");
return uploads.Count(u => u.CorrelationCompleted == true) >= 3;
```

Semantics you must not conflate:

- **`IsCompleted` vs `CorrelationCompleted`** are different facts: the first is the *target instance's* status, the second is whether the *relationship* is closed. During the subflow-completion window they disagree.
- **Absence is data, failure is a fault.** No parent / no matching correlation / instance gone ⇒ `null` or empty list. A read failure or exceeding the per-context resolution cap (default 10, `Workflow:Scripting:RelatedAccess:MaxResolutionsPerContext`) ⇒ `RelatedInstanceAccessException`.
- **Reads are unfiltered** (no `x-roles` field filtering, no extensions). Copying a related instance's restricted field into this instance's data exposes it to anyone who can read this instance — copy only what you intend to expose.
- `SubAsync("x")` matches the **sub workflow key** (`InstanceCorrelation.SubFlowName`); newest correlation wins. Completed correlations remain readable.

## Interface signatures

All interfaces live in `BBT.Workflow.Scripting`. Class naming: file `kebab-case.csx` → class `PascalCase`, one class per file, inherit `ScriptBase`.

### `IMapping` — task input/output binding

```csharp
public class MyTaskMapping : ScriptBase, IMapping
{
    public Task<ScriptResponse> InputHandler(WorkflowTask task, ScriptContext context)
    {
        // Cast `task` to the concrete type (HttpTask, NotificationTask, …) and mutate its config.
        // Read data via GetPropertyValue(context.Instance.Data, ...), context.Headers, context.QueryParameters.
        return Task.FromResult(new ScriptResponse { /* audit data */ });
    }

    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        // context.Body now contains the merged StandardTaskResponse (body.data, body.statusCode, …).
        // The returned ScriptResponse.Data is merged into instance data.
        return Task.FromResult(new ScriptResponse { /* … */ });
    }
}
```

### `IOutputHandler` — multi-task Function aggregation

> The method is named **`OutputHandler`**, not `Handler`.

```csharp
public class MyFunctionOutput : ScriptBase, IOutputHandler
{
    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        // context.TaskResponse["taskKeyA"] → each task's StandardTaskResponse (dynamic, camelCase)
        // context.OutputResponse["taskKeyA"] → each task's own output-mapping result (if any)
        // ScriptResponse.Data becomes the function response payload; StatusCode can override HTTP status.
        return Task.FromResult(new ScriptResponse { /* … */ });
    }
}
```

### `IConditionMapping` — auto transition rule

```csharp
public class MyAutoRule : ScriptBase, IConditionMapping
{
    public Task<bool> Handler(ScriptContext context)
    {
        // Stateless, side-effect free. true → the auto transition fires.
        var status = GetPropertyValue<string>(context.Instance.Data, "status", "");
        return Task.FromResult(status == "approved");
    }
}
```

### `ITimerMapping` — dynamic timer schedule

```csharp
public class MyTimerRule : ScriptBase, ITimerMapping
{
    public Task<TimerSchedule> Handler(ScriptContext context)
    {
        // TimerSchedule.FromDateTime(dt) / FromCronExpression("0 9 * * *") /
        // TimerSchedule.FromDuration(TimeSpan.FromMinutes(15)) / TimerSchedule.Immediate()
        return Task.FromResult(/* schedule */);
    }
}
```

### `ISubFlowMapping` — SubFlow data adapter

```csharp
public class MySubFlowMapping : ScriptBase, ISubFlowMapping
{
    public Task<ScriptResponse> InputHandler(ScriptContext context)
    {
        // ScriptResponse.Data = initial data for the child instance
        return Task.FromResult(new ScriptResponse { /* … */ });
    }

    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        // Called on child completion; ScriptResponse.Data is merged into the PARENT instance
        return Task.FromResult(new ScriptResponse { /* … */ });
    }
}
```

### `ISubProcessMapping` — SubProcess input (fire-and-forget)

Subprocesses run independently; there is **only** an input handler — provide everything the child needs.

```csharp
public class MySubProcessMapping : ScriptBase, ISubProcessMapping
{
    public Task<ScriptResponse> InputHandler(ScriptContext context)
    {
        return Task.FromResult(new ScriptResponse { /* Data = full init payload */ });
    }
}
```

### `INotificationMapping` — per-channel notification payload

> The method is named **`ChannelHandler`**, not `Handler`. The `state` channel never reaches this interface — the platform handles it; implement `IStateNotificationMapping` (in the same file) to enrich it.

```csharp
public class MyNotificationMapping : ScriptBase, INotificationMapping
{
    public Task<NotificationMessage?> ChannelHandler(string channel, ScriptContext context)
    {
        // channel: "sms" | "email" | "push" | "hub" | …  (never "state")
        // Return null to skip this channel.
        if (channel != "sms") return Task.FromResult<NotificationMessage?>(null);
        return Task.FromResult<NotificationMessage?>(new NotificationMessage
        {
            Data = new { phone = GetPropertyValue<string>(context.Instance.Data, "phone", ""), text = "…" },
            Metadata = new Dictionary<string, string> { ["operation"] = "create" }
        });
    }
}
```

`NotificationMessage`: `required object Data`, `Dictionary<string,string> Metadata` (Dapr binding metadata; HTTP bindings → headers, Kafka/MQTT → `topic`), `string Operation = "create"`.

### `IStateNotificationMapping` — state channel metadata enrichment (optional)

```csharp
public class MyNotificationMapping : ScriptBase, INotificationMapping, IStateNotificationMapping
{
    public Task<StateNotificationMetadata> EnrichAsync(ScriptContext context)
    {
        return Task.FromResult(new StateNotificationMetadata
        {
            Metadata = new Dictionary<string, string> { ["x-tenant"] = "…" },
            Operation = "create"
        });
    }
    // + ChannelHandler(...)
}
```

### `IEventMapping` — inbound external event → workflow action

Maps a pub/sub / input-binding payload to a correlation key + body. Deterministic, side-effect free.

```csharp
public class MyEventMapping : ScriptBase, IEventMapping
{
    public Task<EventMappingResult> Handler(ScriptContext context)
    {
        var payload = context.EventPayload;   // raw inbound event (dynamic)
        return Task.FromResult(new EventMappingResult
        {
            InstanceKey = GetPropertyValue<string>(payload, "orderId", null),
            Body = payload
            // Selector: optional InstanceFilter fallback when InstanceKey is unavailable (transition only)
        });
    }
}
```

`EventMappingResult`: `string? InstanceKey`, `dynamic? Body`, `InstanceFilter? Selector` (fluent `InstanceQuery`; ignored when `InstanceKey` is set, no effect for `action=start`).

### `ITransitionMapping` — transition data transform

```csharp
public class MyTransitionMapping : ScriptBase, ITransitionMapping
{
    public Task<dynamic> Handler(ScriptContext context)
    {
        return Task.FromResult<dynamic>(/* transformed data */);
    }
}
```

### `WorkflowTask` and concrete task types

`InputHandler(WorkflowTask task, …)` receives the task definition; cast to the concrete type to mutate config:

```csharp
if (task is HttpTask httpTask)
{
    httpTask.SetUrl($"{baseUrl}/customers/{id}");
    httpTask.SetHeaders(headers);
    httpTask.SetBody(payload);
}
```

Common concrete types: `HttpTask`, `ScriptTask`, `NotificationTask`, `SoapTask`, `DaprServiceTask`, `DaprPubSubTask`, `GetInstancesTask`.

## Function envelope: `rawResponse`

Functions have a top-level `attributes.rawResponse` boolean (separate from the `.csx` mapping):

| Value | Effect |
|-------|--------|
| `false` (default) | Runtime wraps `ScriptResponse.Data` under the function key: `{ "{functionKey}": { ...Data... } }` |
| `true` | Runtime returns `Data` raw: `{ ...Data... }` |

**Required `true`** for any function whose output a view binds directly (`dataSchema`, `x-lov.source`, `x-lookup.source`, `$lov.X` / `$lookup.X` expressions). With `false`, JsonPath like `$.data[*]` silently misses the array under the function-name wrapper and the view shows an empty result with no error.

Full failure-mode walkthrough in `references/function-mapping-pattern.md` § "rawResponse". Working examples: `core/Functions/account-opening/get-branches.json` (LOV) and `get-branch-detail.json` (lookup).

## `sys-mappings` helpers (shared code) — the primary reuse mechanism

**If a mapping structure repeats across components, extract it into `sys-mappings` first.** This is the default, not an optimization.

A `sys-mappings` component is **not** an `IMapping` — it's typically a plain **`public static class`**
holding reusable methods:

```csharp
namespace Acme.Helpers;

public static class RsaCryptoHelper
{
    public static string Encrypt(string plain, string publicKeyBase64) { /* ... */ }
}
```

A consumer references it in its mapping's (or workflow's) `scripts.helpers` and lists any external
assembly in `scripts.allowedAssemblies` (e.g. `System.Security.Cryptography`, `Newtonsoft.Json`); the
helper's static class is then callable by name in the consumer's `.csx` (`RsaCryptoHelper.Encrypt(...)`,
`JsonHelper.Serialize(...)`). A whole reusable mapping can also be referenced via `encoding: "REF"`.
See `references/concepts/mappings-and-scripts.md`.

> A reusable *mapping* (vs a static helper) may implement a mapping interface — the example
> `initial-mapping` uses **`ITransitionMapping`** (`Handler(ScriptContext)` → `dynamic`).

## Class naming

- File name: `kebab-case.csx`
- Class name: `PascalCase` matching the file: `payment-success-rule.csx` → `class PaymentSuccessRule`
- **One class per file** (the runtime expects this).
- The VS Code extension base64-encodes the file into `mapping.code` on save. **Never manually base64-encode.**

## Sources

- Runtime source of truth: `BBT.Workflow.Domain/Scripting/Models.cs` (ScriptContext), `Scripting/Contracts/*.cs` (interfaces), `BBT.Workflow.Modules.Scripting/.../ScriptBase.cs` (helpers), `Scripting/Related/*.cs` (Related API)
- Working examples:
  - `vnext-example/core/Workflows/payments/src/SendPaymentNotificationSmsMapping.csx` — IMapping
  - `vnext-example/core/Workflows/payments/src/PaymentSuccessRule.csx` — IConditionMapping
  - `vnext-example/core/Workflows/payments/src/PaymentDueTimerRule.csx` — ITimerMapping
  - `vnext-example/core/Workflows/payments/src/PaymentProcessMapping.csx` — ISubFlowMapping
  - `vnext-example/core/Functions/account-opening/src/GetBranchDetailLookupMapping.csx` — IMapping + ScriptBase
