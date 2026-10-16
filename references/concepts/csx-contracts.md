# `.csx` Contracts — Type Signatures, Runtime Types & ScriptBase Helpers

`.csx` mapping files run against the `BBT.Workflow.*` NuGet packages. Skills generating `.csx` skeletons MUST use the exact `using` directives, interface method names, and access idioms defined here. Everything below is verified against the runtime source (`BBT.Workflow.Domain/Scripting/*` and `BBT.Workflow.Modules.Scripting/.../ScriptBase.cs`) — do not invent members that are not listed.

## Golden rules (read first)

1. **Never access a dynamic property directly.** `context.Instance.Data.customer?.id` **throws at runtime** when `customer` (or `id`) is absent — instance data is an `ExpandoObject`, and accessing a missing member raises `RuntimeBinderException`; `?.` does NOT save you. Always go through the `ScriptBase` helpers: `HasProperty(obj, "name")`, `GetPropertyValue<T>(obj, "name", defaultValue)`.
2. **Inherit `ScriptBase`.** Mapping classes should derive from `ScriptBase` to get the property/list/logging helpers. Do not hand-roll reflection.
3. **Repeated logic goes to `sys-mappings` first.** If the same `.csx` structure appears in more than one place, extracting a `sys-mappings` helper is the *primary* approach, not an afterthought. See `mappings-and-scripts.md`.
4. **`context.Related` is for correlation data only** (parent / subflow / subprocess of *this* instance, v0.0.79+). Any other cross-instance data must be fetched with a Task.
5. **Return delta-only output from mappings** (v0.0.79+ immediate-persistence write model): `ScriptResponse.Data` should contain **only the fields you changed**, never a full echo of the instance data — a full echo overwrites concurrent writers' fresher values with stale ones (this bites hardest under parallel branches and `updateData` storms).
6. **`InputHandler` is not a gate** (#1087). Its return value is audit-only; the task runs whatever it returns. Validate *before* the task, or `throw`. See `IMapping` below.
7. **Encrypted fields arrive as tokens** (0.0.99+). Open them with `await context.Instance.DecryptAsync(path, context.CancellationToken)`, never by copying the token. See § Encrypted fields.

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
| `Instance` | `Instance?` | The workflow instance snapshot: `Instance.Data` (dynamic, **as stored** — `x-encryption` `encrypt` fields hold their token since 0.0.99), `Instance.Key`, current state, `DecryptAsync(path, ct)` (see § Encrypted fields). |
| `Incident` | `ScriptIncidentInfo?` | Error-boundary awareness: `HasActiveIncident`, `ActiveIncident`, `TotalIncidentCount`, `IncidentsLoaded`. On **0.0.93–0.0.98** `ActiveIncident` was `null` and `TotalIncidentCount` `0` even with an active incident (known issue `script-context-incident-not-loaded`); populated since **0.0.99** — don't branch on `ActiveIncident` in error-boundary mappings on older runtimes. |
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
| `CancellationToken` | `CancellationToken` | **0.0.100+** (#1090). The request / transition-job / event-delivery token. Pass it to your own I/O (a plugin DB driver, `DecryptAsync`) so an abandoned operation stops the call. `CancellationToken.None` when the context was built without one. A property, not a handler parameter — interface signatures are unchanged. |

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

### File fields — `GetFileAsync` (0.0.100+)

Reads the bytes behind an `x-storage` file handle (the master schema's file field; schema side in `file-fields.md`). The handle in instance data carries `owner.domain`, `owner.flow`, `owner.instance` and `file` — pass those, not the instance you happen to be in:

```csharp
protected Task<ScriptFile> GetFileAsync(string domain, string flow, string instance, string file)   // no CancellationToken parameter

public sealed record ScriptFile(byte[] Content, string? Name, string? MimeType, long Size, string ETag);  // ETag = SHA-256 hex
```

- **No authorization check.** Neither `queryRoles` nor `x-roles` is evaluated — it is a service-to-service read. **Your mapping must enforce who may get the bytes** before returning or forwarding them.
- **Cross-domain.** Works for a handle owned by another domain (internal route, network isolation only). The handle must be in that instance's **latest** data.
- Throws `InvalidOperationException` when no file reader is available or the read fails; blank arguments throw `ArgumentException`.
- **Bytes stay in memory and land wherever you put them.** Copying `Content` into a task request stores it in that task record (known issue `file-in-task-record`). Pass the handle through mappings; fetch bytes only in the mapping of the task that needs them, and don't echo them into responses.

## Encrypted fields — `context.Instance.DecryptAsync` (0.0.99+)

A field marked `x-encryption: { "type": "encrypt" }` is stored as a token (`ENCRYPTED:AES256:…`). Scripts see the **token**, not the plaintext: in `context.Instance.Data`, `LatestData.Data` / `FindData(version).Data`, and in a `context.Body` the runtime fills with instance data (extensions, view rules, output and timeout mappings). Schema side and roles: `field-protection.md`.

```csharp
// Instance.DecryptAsync(string path, CancellationToken cancellationToken = default) → Task<string?>
var iban = await context.Instance.DecryptAsync("customer.iban", context.CancellationToken);   // dot path
if (iban is null) { /* not an encrypt token at that path, unknown path, or unopenable */ }
```

- **Own instance only.** It opens a token at `path` in **this** instance's latest data. A token that reached the script any other way (request body, task response, another instance, `context.Related`) returns `null`. Passing a token instead of a path returns `null`.
- **Never copy a token into another field** — the write is refused (`EncryptedValueReservedException`).
- **The plaintext is yours to protect.** Writing it into a non-encrypted field, a task request, a log line or a response stores or exposes it in clear. Transition bodies, task records and some caches already hold plaintext copies (known issue `field-encryption-plaintext-copies`) — don't add more.
- **DynamicExpresso rules, dynamic role grants and human-task text see the token.** Move a condition on an encrypt field to a C# `IConditionMapping` that calls `DecryptAsync`.
- Unchanged: a SubFlow `OutputHandler`'s `Body` (child data, opened by the child) and a transition task's own request `Body` are plaintext.

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
        // The return value is AUDIT-ONLY — it never stops the task. To prevent the call: throw.
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

**`InputHandler` cannot reject the task** (#1087, documented behaviour on every version). Whatever it returns — `Data["error"]`, a `StatusCode`, an empty response — goes only into the task's audit record, and the task is then invoked as configured. For a write task (StartTrigger, DirectTrigger, SubProcess, HTTP POST, publish) the write happens even when the handler found the input invalid. Instead:

- **Validate before the task** — a transition `rule`, an auto transition to an error state, or a preceding validation step decides whether the task runs at all (preferred).
- **Or `throw`** from `InputHandler` as a last resort: the task fails as a task execution error, `OutputHandler` does not run, and `AcceptedStatusCodes` do not apply (it is not a business response) — the error boundary handles it.

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

### `IFanOutMapping` — per-item binding for a FanOut task (type 21, v0.0.85+)

Attached on the **workflow's task binding** (`onEntries[]` / `onExecutionTasks[]` `mapping`), never on the type-21 component itself. Only `ItemInputHandler` is abstract; the other two members carry defaults whose `null` return means "use the runtime behaviour" (`itemsPath` / default output packaging). Full guide: `fan-out.md`.

```csharp
public interface IFanOutMapping
{
    Task<IEnumerable<dynamic>?> ItemSelector(ScriptContext context)                                   // optional; null → itemsPath. XOR with itemsPath
        => Task.FromResult<IEnumerable<dynamic>?>(null);
    Task<ScriptResponse> ItemInputHandler(WorkflowTask task, ScriptContext context, FanOutItem item);   // REQUIRED, once per item, in parallel
    Task<ScriptResponse?> OutputHandler(ScriptContext context, FanOutResult result)                     // optional; null → default {resultKey, resultKeySummary}
        => Task.FromResult<ScriptResponse?>(null);
}

public sealed record FanOutItem(int Index, dynamic? Value, string ItemKey);   // ItemKey: item.id → item.key → index
public sealed record FanOutResult(int Total, int Succeeded, int Failed, bool TimedOut, IReadOnlyList<FanOutItemResult> Items);
public sealed record FanOutItemResult(int Index, string ItemKey, bool IsSuccess, dynamic? Data, string? ErrorCode, string? ErrorMessage, TimeSpan Duration);
```

```csharp
public class MyFanOutMapping : ScriptBase, IFanOutMapping
{
    public Task<ScriptResponse> ItemInputHandler(WorkflowTask task, ScriptContext context, FanOutItem item)
    {
        // Mutate the CLONED inner task for this item; item.Value is the usual ExpandoObject model.
        if (task is HttpTask http)
            http.SetUrl($"{http.Url}?id={Uri.EscapeDataString(item.ItemKey)}");
        return Task.FromResult(new ScriptResponse());   // audit only — the executor discards it
    }
}
```

Semantics you must not get wrong:

- **`ItemInputHandler` mutates the cloned inner task; its return value is audit-only.** Nothing it returns reaches instance data.
- **Per item = pure.** It runs N times concurrently on discarded branch contexts. No instance-data writes, no shared mutable state across items.
- **`OutputHandler` is the single write point** of the whole batch — its `Data` is merged once. `result.Items` is a typed list (plain LINQ), not a dynamic — the `List*` helpers are for `item.Value` / `Data`, not for `Items`.

### `ICacheKeyMapping` — CacheAside key script (0.0.99+)

A CacheAside task's (type 18) `config.key` is `string | ScriptCode`. A string is used verbatim. A `ScriptCode` with `location: "dynamicExpresso"` is a Dynamic Expresso expression; any other `location` compiles a Roslyn class implementing:

```csharp
public interface ICacheKeyMapping            // namespace BBT.Workflow.Scripting
{
    Task<string?> Handler(ScriptContext context);   // null / whitespace → keep the key resolved earlier
}

public class CustomerProfileKey : ScriptBase, ICacheKeyMapping
{
    public Task<string?> Handler(ScriptContext context) =>
        Task.FromResult<string?>($"customer:{GetPropertyValue<string>(context.Instance.Data, "customerId", "")}:profile");
}
```

- `encoding` accepts `NAT`, `B64` and `REF`; **the default is `B64`**, so a hand-written plain-text expression needs `"encoding": "NAT"` or the task fails decoding it.
- A non-blank result **overrides** a key set earlier with `SetCacheKey` in the task mapping's `InputHandler`.
- `keyExpression` was removed in 0.0.99 — move it to `key: { "location": "dynamicExpresso", "encoding": "NAT", "code": "…" }`. (Function-level `cache.keyExpression` is a different feature and unchanged.) Task config: `task-types.md`.

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

Common concrete types: `HttpTask`, `ScriptTask`, `NotificationTask`, `SoapTask`, `DaprServiceTask`, `DaprPubSubTask`, `GetInstancesTask`, `GetInstanceTask`, `StateStoreTask`, `CacheAsideTask` (`SetCacheKey`; a `key` script overrides it — see `ICacheKeyMapping`), `DaprConversationTask`, `FanOutTask` (its per-item binding is `IFanOutMapping`, not `IMapping`). Catalog: `task-types.md`.

### Outbound headers the runtime fills for you (0.0.99+)

When an `InputHandler` sets headers (`SetHeaders`) on an outbound task, know which ones the runtime fills **only if your mapping leaves them absent or empty** — a non-empty mapping value always wins:

| Header | Filled with | Applies to |
|--------|-------------|------------|
| `sub`, `act_sub`, `position`, `client_id`, `role` | The calling request's own credential headers (`sub`/`act_sub` fall back to trace baggage). `role` only as the caller **sent** it — a role resolved by morph-idm is never forwarded. | HTTP, SOAP, DaprService, DaprHttpEndpoint, GetInstance/GetInstances/GetInstanceData, StartTrigger, SubProcess, DirectTrigger — same-domain and cross-domain |
| `X-Request-Id` | vNext's own request id (the originating request's `X-Request-Id`). | Every HTTP-shaped task type, StartTrigger and SubProcess |

- **The task runs as its caller by default.** To call as a service identity (e.g. a role on an `x-roles` / `x-encryption` allow list), set that header to a non-empty value in the mapping. An **empty** value no longer suppresses the header — it is filled from the request.
- **Need a fresh UUID per call** (e.g. OHVPS/BKM APIs)? Set it yourself: `["X-Request-Id"] = Guid.NewGuid().ToString()`. On **0.0.80–0.0.98** a mapping-set `X-Request-Id` was silently dropped (known issue `task-binding-x-request-id-dropped`).
- `X-Workflow-Instance-Id` and `X-Correlation-Id` are always set by the runtime; a mapping value is overwritten.

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

## Runtime notes that bite scripts (v0.0.81 – v0.0.87)

### Numeric precision — carry money as strings (PR #907, 0.0.85)

Instance-data appends reformat every number through int/double: integers above **2^53** and decimals beyond **~15 significant digits** lose precision on write (vnext-meta known issue `instance-data-numeric-precision-loss`). The lossless path is **opt-in**:

```json
{ "WorkflowExecution": { "InstanceDataWrite": { "PreserveNumericPrecision": true } } }
```

Default **`false`** — flipping it changes affected instances' content hash once, so operators decide. Author-side rule until your environment enables it: **serialize money, IBAN-like numerics and 64-bit ids as strings** in `ScriptResponse.Data`, and parse with `decimal.Parse` when you need arithmetic. The same release pinned four behaviours as deliberate (vnext-meta migrations `script-context-shared-tree-visibility`, `script-context-setbody-preserves-expando-keys`, `parallel-merge-conflict-order-insensitive`, `script-body-cycles-throw-instead-of-being-dropped`): mutations are visible within the transition, `SetBody` keeps expando keys, parallel-merge conflicts resolve order-insensitively, and a **cyclic expando now throws** instead of being pruned.

### Secret cache — 30 s staleness is the contract (PR #899, 0.0.85)

`GetSecret*` / `GetSecrets*` read through an in-process `ScriptSecretCache` keyed by `(storeName, secretStore)`: `Scripting:SecretCache` `{ Enabled: true, TtlSeconds: 30 }`. A rotated secret keeps returning the **old value for up to `TtlSeconds` per replica**; misses still block on the sync wrappers, so miss-heavy scripts should prefer `GetSecretAsync`. Never `IDistributedCache` — secret material does not transit Redis.

### `using` directives — pre-0.0.87 runtimes dropped yours (PR #888 / #920)

Before **v0.0.87** the compiler replaced the script's using list with the platform list, so an author's `using System.Text;` was silently discarded and `StringBuilder` failed at **runtime** with `CS0246` — despite the import being right there. Since 0.0.87 author usings are **merged** (aliases and `using static` included). Two rules still hold on every version: the default usings are `System`, `System.Collections.Generic`, `System.Linq`, `System.Threading.Tasks`, `System.Text.Json`; anything from an assembly outside the default reference set needs `scripts.allowedAssemblies` regardless of the `using`. A `CS0246` for a namespace you clearly imported on a workspace pinned below 0.0.87 is this bug, not your code.

## Runtime notes that bite scripts (v0.0.98 – v0.0.100)

### `allowedAssemblies` must resolve at publish (0.0.99, #1069)

Every simple name under `scripts.allowedAssemblies` (flow level or any script slot of a workflow, task, function or extension) must resolve in the publishing runtime — a framework assembly or a DLL in the environment's plugin directory. Otherwise **publish returns 400 naming the field**, e.g. `sys-flows.states[0].onEntries[1].mapping.scripts.allowedAssemblies[0]`. This holds even where the sandbox is disabled (where the grant used to be harmless). Fix: drop the unused/misspelled name, use the simple name without `.dll`, or ask the platform team / environment owner to mount the assembly, then publish again. The check does not compile: an assembly the script needs but never declares still fails only at run time.

### `foreach` over an `ExpandoObject` under the sandbox (fixed 0.0.99)

`System.ObjectModel` is in the sandbox baseline since 0.0.99. On **0.0.26–0.0.98**, where the environment enables the sandbox, a mapping that `foreach`-es over an `ExpandoObject` failed to compile with `CS0012` (known issue `sandbox-baseline-missing-system-objectmodel`). Workaround on older runtimes: grant `"System.ObjectModel"` in `scripts.allowedAssemblies`, or read the expando through `as IDictionary<string, object>` instead of enumerating the expando itself.

### Script plugins (0.0.100, #1090)

A plugin is a DLL (e.g. a database driver) the **platform team** mounts in the environment's plugin directory (`Scripting:Sandbox:PluginDirectory`); a mapping uses it by listing its name in `scripts.allowedAssemblies`. Product teams do not control this directory or runtime config — ask the platform team / environment owner.

- **Loaded once per process**, shared by every script and helper set: one copy, one static state, one connection pool.
- **Usable from a helper-less mapping.** Before 0.0.100 only `sys-mappings` helper sets loaded plugins; a mapping that used a plugin type directly compiled, then failed at run time with `FileNotFoundException`. On older runtimes, wrap plugin calls in a `sys-mappings` helper.
- **Added DLL:** picked up without a restart (re-read on a miss, at most every `PluginRescanIntervalSeconds`, default 30). A component rejected at publish before the DLL arrived must be published again. **Replacing or removing** a loaded DLL needs a runtime restart.
- **Pass `context.CancellationToken`** to driver calls so a cancelled request/job stops the query.
- The banned-namespace analyzer checks your script, not the plugin: a mounted DB driver gives network access to every mapping that lists it. Working example: vnext-example `core/Functions/script-plugin-lab/` + `plugins/ScriptPluginLab.Sql`.

If a script fails in a way these notes don't explain and the runtime is at fault, draft an issue with `/vnext-ai-toolkit:report-issue`.

## Class naming

- File name: `kebab-case.csx`
- Class name: `PascalCase` matching the file: `payment-success-rule.csx` → `class PaymentSuccessRule`
- **One class per file** (the runtime expects this).
- The VS Code extension base64-encodes the file into `mapping.code` on save. **Never manually base64-encode.**

## Sources

- Runtime source of truth: `BBT.Workflow.Domain/Scripting/Models.cs` (ScriptContext, `CancellationToken`), `Scripting/Contracts/*.cs` (interfaces, incl. `IFanOutMapping.cs`, `ICacheKeyMapping.cs`, `IMapping.cs`), `Domain/Instances/Instance.cs` (`DecryptAsync`), `BBT.Workflow.Modules.Scripting/.../ScriptBase.cs` + `ScriptFile.cs` (helpers, `GetFileAsync`), `Scripting/Related/*.cs` (Related API), `Modules.Scripting/.../Evaluators/CSharpEvaluator.cs` (using-merge), `Modules.Scripting/.../Functions/SecretCacheOptions.cs`, `Application/BackgroundJobs/Options/WorkflowExecutionOptions.cs` (`PreserveNumericPrecision`), `Execution.Abstractions/HttpTaskInvocation.cs` (outbound header fill), vnext `docs/custom-script-helpers.md` §3–§4 (sandbox, plugins)
- Release notes: vnext-docs `blog/2026-08-20-v0-0-81-84.md` (#888), `blog/2026-08-24-v0-0-85.md` (#899, #905, #907), `blog/2026-08-31-v0-0-87.md` (#920), `blog/2026-10-05-v0-0-99.md` (#1053, #1054, #1059, #1060, #1069), `blog/2026-10-15-v0-0-100.md` (#1087, #1090, file fields); vnext-docs `docs/configuration/scripting.md`, `docs/components/tasks/cache-aside.md`; vnext-meta known issues `instance-data-numeric-precision-loss`, `script-context-incident-not-loaded`, `sandbox-baseline-missing-system-objectmodel`, `task-binding-x-request-id-dropped`, `field-encryption-plaintext-copies`, `file-in-task-record`; migrations `script-sees-encrypt-tokens`, `task-caller-credential-forwarded`, `publish-rejects-unavailable-allowed-assemblies`, `cacheaside-source-as-task-and-script-key`; feature `scriptSecretCache` (0.0.80)
- Working examples:
  - `vnext-example/core/Workflows/payments/src/SendPaymentNotificationSmsMapping.csx` — IMapping
  - `vnext-example/core/Workflows/payments/src/PaymentSuccessRule.csx` — IConditionMapping
  - `vnext-example/core/Workflows/payments/src/PaymentDueTimerRule.csx` — ITimerMapping
  - `vnext-example/core/Workflows/payments/src/PaymentProcessMapping.csx` — ISubFlowMapping
  - `vnext-example/core/Functions/account-opening/src/GetBranchDetailLookupMapping.csx` — IMapping + ScriptBase
  - `vnext-example/core/Workflows/fan-out-documents/src/FanOutDocumentsMapping.csx` — IFanOutMapping (item binding only, default output)
  - `vnext-example/core/Functions/script-plugin-lab/src/SplDirectQueryMapping.csx` — helper-less plugin call with `context.CancellationToken`
