# FanOut Task (type 21) — Dynamic Parallel Execution

FanOut resolves a collection from instance data **at runtime**, runs a referenced **inner task** once per item in parallel, and joins the per-item outcomes into **one task output and one instance-data write**. Shipped in v0.0.85 (PR #905; vnext-meta `fanOutTask`, since 0.0.80). Always runs on Orchestration.

## 1. When to use — and when not

| Use FanOut when | Do NOT use FanOut when |
|-----------------|------------------------|
| The item count comes from **data** (documents to sign, recipients, accounts to reconcile) | The count is **fixed at design time** — tasks sharing the same `order` already run in parallel; give each branch its own task definition |
| Each item is an independent call to a target with **no batch endpoint** | The downstream accepts a batch — one call beats N journal rows, N DI scopes, N invocations |
| Partial failure is acceptable as **data** the flow branches on | Item 2 depends on item 1's output (items run concurrently, unordered) |
| One write per batch is enough | You need per-item progress visible **before** the batch finishes (single-writer by design) |

Not a replacement for `$self` auto-loops when each iteration must observe the previous one's state.

## 2. Config (schema-valid, from the `vnext-example` fixture)

```json
{
  "key": "fan-out-documents-task",
  "version": "1.0.0",
  "domain": "core",
  "flow": "sys-tasks",
  "flowVersion": "1.0.0",
  "tags": ["fan-out", "task-type-21"],
  "attributes": {
    "type": "21",
    "config": {
      "mode": "inline",
      "itemsPath": "$.documents",
      "itemAlias": "document",
      "task": { "key": "process-document-task", "domain": "core", "flow": "sys-tasks", "version": "1.0.0" },
      "execution": { "maxDegreeOfParallelism": 3, "itemTimeoutSeconds": 15, "batchTimeoutSeconds": 60 },
      "join": { "policy": "allSettled", "resultKey": "documentResults", "ordered": true }
    }
  }
}
```

| Field | Default | Rules |
|-------|---------|-------|
| `mode` | `inline` | Only value accepted; `durable` is reserved and **rejected at parse** (400 on publish) |
| `itemsPath` | — | Must start with `$.`; dot property navigation only (no filters/wildcards/indices). Missing path → empty batch; non-array → throws. **XOR** with the mapping's `ItemSelector` — both or neither is an execution error the schema cannot express |
| `itemAlias` | `item` | Log/span label **only**; never affects binding |
| `task` | — | required; all four of `key/domain/flow/version`. Resolved once, **cloned per item**. Another type-21 task is rejected |
| `execution.maxDegreeOfParallelism` | 4 | ≥1; batch-local cap (global bulkhead on top, §6) |
| `execution.itemTimeoutSeconds` | 30 | ≥1 and **≤ `batchTimeoutSeconds`** (parse-time check) |
| `execution.batchTimeoutSeconds` | 120 | ≥1 |
| `join.policy` | `allSettled` | `all` \| `allSettled` \| `quorum` \| `firstSuccess` (case-insensitive) |
| `join.minSuccess` | — | **Required ≥1 for `quorum`**; silently ignored otherwise |
| `join.resultKey` | `fanOutResults` | Instance-data key of the default output |
| `join.ordered` | `true` | **No-op in inline mode** — results are always index-sorted |
| `errorBoundary` | none | A normal `onError[]` boundary applied **independently per item** (retry/fallback/ignore) |

Default per-item binding with no mapping: `branch.SetBody(item.Value)` — the inner task's script sees the item as its body. That is enough when the inner task reads only the body. It is **not** enough when the inner task's own config must change per item (an `HttpTask` URL, a SOAP envelope, a Dapr method) — then you need an `IFanOutMapping`.

## 3. Where the mapping lives — on the workflow binding, not the task

A type-21 component carries only `type` + `config`. The `IFanOutMapping` rides the **workflow's task binding**, the same `{ order, task, mapping }` slot every task uses (`onEntries[]`, `onExecutionTasks[]`). One FanOut component can therefore be bound with different mappings at different call sites. There is no `mapping` field on the task component — do not look for one.

```json
{ "order": 2,
  "task": { "key": "fan-out-documents-task", "domain": "core", "flow": "sys-tasks", "version": "1.0.0" },
  "mapping": { "location": "./src/FanOutDocumentsMapping.csx", "code": "<base64>" } }
```

## 4. `IFanOutMapping` — contract and skeleton

```csharp
public interface IFanOutMapping
{
    Task<IEnumerable<dynamic>?> ItemSelector(ScriptContext context) => Task.FromResult<IEnumerable<dynamic>?>(null); // null → use itemsPath
    Task<ScriptResponse> ItemInputHandler(WorkflowTask task, ScriptContext context, FanOutItem item);               // REQUIRED
    Task<ScriptResponse?> OutputHandler(ScriptContext context, FanOutResult result) => Task.FromResult<ScriptResponse?>(null); // null → default packaging
}

public sealed record FanOutItem(int Index, dynamic? Value, string ItemKey);            // ItemKey = item.id → item.key → index
public sealed record FanOutResult(int Total, int Succeeded, int Failed, bool TimedOut, IReadOnlyList<FanOutItemResult> Items);
public sealed record FanOutItemResult(int Index, string ItemKey, bool IsSuccess, dynamic? Data, string? ErrorCode, string? ErrorMessage, TimeSpan Duration);
```

Only `ItemInputHandler` is abstract — a mistyped name becomes a compile error instead of N identical unbound requests. Override the other two only when you need them; the fixture deliberately leaves `OutputHandler` out so the runtime's default shape is what downstream rules read.

```csharp
using System;
using System.Linq;
using System.Threading.Tasks;
using BBT.Workflow.Definitions;
using BBT.Workflow.Scripting;
using BBT.Workflow.Scripting.Functions;

public class FanOutDocumentsMapping : ScriptBase, IFanOutMapping
{
    // Runs once per item, in parallel, on a discarded branch context. PURE: read only, no instance-data writes.
    public Task<ScriptResponse> ItemInputHandler(WorkflowTask task, ScriptContext context, FanOutItem item)
    {
        if (task is HttpTask httpTask)
        {
            var baseUrl = GetConfigValue("Example:ApiBaseUrl", "http://localhost:3001");
            var documentId = item.ItemKey;                                    // = item.Value.id when present
            var mime = HasProperty(item.Value, "mimeType")
                ? GetPropertyValue<string>(item.Value, "mimeType", "application/pdf")
                : "application/pdf";

            httpTask.SetUrl($"{baseUrl}/documents/process?documentId={Uri.EscapeDataString(documentId)}");
            httpTask.SetBody(new { documentId, mime, source = "fan-out-documents" });
            LogInformation("FanOut item {index} → {id}", args: new object[] { item.Index, documentId });
        }
        return Task.FromResult(new ScriptResponse());                        // audit only — never merged
    }

    // Optional. Called ONCE after every item settled — the batch's single write point.
    public Task<ScriptResponse?> OutputHandler(ScriptContext context, FanOutResult result)
    {
        // result.Items is a typed IReadOnlyList<FanOutItemResult> — plain LINQ, no dynamic helpers needed here.
        var failedIds = result.Items.Where(i => !i.IsSuccess).Select(i => i.ItemKey).ToArray();
        return Task.FromResult<ScriptResponse?>(new ScriptResponse
        {
            Data = new { documentsFailedCount = result.Failed, documentsFailedIds = failedIds, documentsTimedOut = result.TimedOut }
        });
    }
}
```

Rules that follow from the contract: `ItemInputHandler` **mutates the cloned inner task**; its return value is audit data the executor discards. `item.Value` is the usual `ExpandoObject` model — go through `HasProperty` / `GetPropertyValue`. Never touch `context.Instance.Data` in the item handler; there is nothing to write to and a shared mutable field across items is a data race.

## 5. Single-write join semantics

Each item gets its own DI scope and branch `ScriptContext`, and runs through the **full task engine** — retry, per-item error boundary, journal row keyed `{taskKey}#{index}`. Its data write is **suppressed**. When every item has settled, the batch writes instance data **exactly once**:

```json
{
  "documentResults": [ { "index": 0, "itemKey": "DOC-1", "isSuccess": true, "data": { … }, "errorCode": null, "errorMessage": null, "duration": "00:00:00.41" } ],
  "documentResultsSummary": { "total": 3, "succeeded": 2, "failed": 1, "timedOut": false }
}
```

An overriding `OutputHandler` replaces this whole shape (a non-null response with `Data = null` still replaces it). Items are always sorted by index.

## 6. Join policies, error codes, limits

| Policy | Batch succeeds when | Early stop | Empty batch |
|--------|---------------------|------------|-------------|
| `all` | every item succeeded **and** no batch timeout | first failure cancels the rest (`FanOut:ItemCancelled`) | succeeds (vacuous) |
| `allSettled` (default) | **always** — even on batch timeout | none | succeeds |
| `quorum` | `succeeded >= minSuccess`, timeout irrelevant | none | **fails** |
| `firstSuccess` | `succeeded >= 1`, timeout irrelevant | first success cancels the rest | **fails** |

| Error code | Meaning |
|------------|---------|
| `FanOut:ItemTimeout` | item exceeded `itemTimeoutSeconds` (wins over the causes below) |
| `FanOut:BatchTimeout` | cut short by `batchTimeoutSeconds` |
| `FanOut:ItemCancelled` | cancelled by a join policy's early stop |
| `FanOut:ItemNotStarted` | cancelled while still queued for a slot, no deadline to blame |
| `FanOut:ItemFailed` | inner task failed with no more specific code — the inner task's own code passes through unchanged otherwise |

Limits: `Workflow:FanOut:MaxConcurrentItems` = **64 per pod**, a global bulkhead across all batches (effective concurrency = min(`maxDegreeOfParallelism`, free global slots)). **Nested fan-out is rejected** before the first item (it would deadlock against that bulkhead). Inner 14 SubProcess / 12 DirectTrigger are fine; inner 5 Human / 9 Timer are accepted by validation and cannot work inside a bounded window.

## 7. Recommended pattern — `allSettled` + branch on the summary

The FanOut task itself never fails; partial failure is **data**. After the state's onEntry tasks (order 60) the pipeline's `RunAutomaticTransitionsStep` (order **80**) evaluates the state's auto transitions — put the decision there, as a complementary pair:

```csharp
public class PartialFailureRule : ScriptBase, IConditionMapping
{
    public Task<bool> Handler(ScriptContext context)
    {
        if (!HasProperty(context.Instance.Data, "documentResultsSummary")) return Task.FromResult(false);
        var summary = GetPropertyValue(context.Instance.Data, "documentResultsSummary");
        return Task.FromResult(GetPropertyValue<int>(summary, "failed", 0) > 0);
    }
}
// AllSucceededRule: summary present && failed == 0  → documents-completed
```

Both rules must also treat "summary absent" as false so neither fires before the batch wrote. Use `all` only for genuinely atomic sets, `quorum` for scoring / multi-source lookups, `firstSuccess` for redundant sources.

## 8. Pitfalls

- **`itemsPath` and `ItemSelector` are XOR** at execution time — the schema cannot catch it. Returning non-null from `ItemSelector` while `itemsPath` is set fails the batch.
- **`minSuccess` outside `quorum` is ignored silently**; `quorum` without it fails to parse.
- **`ordered` does nothing** in inline mode; `mode: "durable"` is a 400.
- **`itemAlias` is cosmetic** — renaming it cannot change what the inner script reads.
- **A per-item `ignore` boundary action does not change the verdict** — the item still counts as failed for the join; it only stops the boundary from escalating.
- **`ItemKey` derivation**: `id` string → `key` string → index. Give items an `id` if you want stable correlation in logs and results.
- **The mapping compiles against `WorkflowTask`** — check `task is HttpTask` (or the concrete type) before mutating; a type mismatch silently leaves the clone unbound.
- **One inner task definition per batch** is correct here (unlike same-`order` fan-in, which needs distinct definitions) — the journal key includes `#{index}`.
- Schema support for `"21"` starts at vnext-schema **0.0.53**; older packages fail `npm run validate` while the runtime publishes fine.

## Sources

- Runtime `vnext` @ `eca5b466`: `src/BBT.Workflow.Domain/Definitions/Tasks/FanOutTask.cs`, `src/BBT.Workflow.Domain/Scripting/Contracts/IFanOutMapping.cs`, `src/BBT.Workflow.Application/Tasks/Executors/FanOut/{FanOutTaskExecutor,FanOutJoinEvaluator,FanOutItemsResolver,FanOutOptions,FanOutErrorCodes}.cs`; `docs/domain/fan-out-task.md`
- Fixtures `vnext-example` @ `3b5ebab`: `core/Tasks/fan-out-documents/*.json`, `core/Tasks/fan-out-config-matrix/*.json`, `core/Workflows/fan-out-documents/{fan-out-documents.json,src/FanOutDocumentsMapping.csx,src/PartialFailureRule.csx,src/AllSucceededRule.csx}`
- vnext-docs @ `adf9bf4`: `docs/components/tasks/fan-out.md`; release notes `blog/2026-08-24-v0-0-85.md` (#905)
- vnext-schema @ `ac42026` (0.0.54): `schemas/task-definition.schema.json` (type `"21"` block)
- vnext-meta 0.0.53: feature `fanOutTask` (since 0.0.80), `component-registry.json` task `fanout`
- PR #905
