# Task Types — The Full `type` Catalog (1–23)

> **Caveat.** `attributes.type` is a **numeric string** (`"6"`, not `6`). The runtime enum (`TaskType`) is the source of truth for membership; the vnext-schema package lags it (see §4). Runtime baseline for this file: **v0.0.97** (schema 0.0.54, vnext-meta 0.0.53).

## 1. Catalog

"Runs" is the v0.0.97 **shipped default** — where the prepared binding executes. It is host configuration, not a task field (§2).

| # | Name | Wire name | Runs (default) | Status | Notes |
|---|------|-----------|----------------|--------|-------|
| 1 | DaprHttpEndpoint | `daprhttpendpoint` | Remote (Execution) | stable | Dapr HTTPEndpoint component |
| 2 | DaprBinding | `daprbinding` | Remote | stable | Output bindings (queue, blob, SMTP, …) |
| 3 | DaprService | `daprservice` | **Local (Orchestration)** | stable | No `timeoutSeconds` field → §7 |
| 4 | DaprPubSub | `daprpubsub` | Remote | stable | Publish an event |
| 5 | Human | — | Orchestration **stub** | **do not author** | Returns 202 `"Pending"` and nothing else. The real HumanTask is **state `subType: 6` + the `human-task` function** (#1016, 0.0.94) — see `human-task.md` |
| 6 | Http | `http` | **Local** | stable | Default REST call. Since 0.0.94 already orchestrator-local → replaces 22 |
| 7 | Script | — | Orchestration | stable | Pure C# transform, no egress |
| 8 | Condition | — | **no executor** | do not author | Use auto-transition `rule` (`IConditionMapping`) |
| 9 | Timer | — | **no executor** | do not author | Use transition `triggerType: 2` |
| 10 | Notification | — | Orchestration | stable | Per-channel payload via `INotificationMapping` |
| 11 | StartTrigger | `starttrigger` | same domain in-process / cross-domain Remote | stable | `sync` default **`false`** since 0.0.86 (#917) — write `"sync": true` explicitly if you must block |
| 12 | DirectTrigger | `directtrigger` | same as 11 | stable | `version` is **deprecated/ignored** (vnext-meta `direct-trigger-task-version`); `sync` default `false` |
| 13 | GetInstanceData | `getinstancedata` | same as 11 | stable | Data only |
| 14 | SubProcess | `subprocess` | same as 11 | stable | **The only valid way to start a SubProcess** — state-level `subFlow.type: "P"` is a 400 at publish since 0.0.95 (#1026) |
| 15 | GetInstances | `getinstances` | same as 11 | stable | Filtered list |
| 16 | Soap | `soap` | **Local** | stable | SOAP 1.1/1.2 |
| 17 | StateStore | `statestore` | **Local** | stable (since 0.0.64) | get/set/delete on a Dapr state store; no `timeoutSeconds` |
| 18 | CacheAside | `cacheaside` | **Local** | stable | Read-through cache around a `sourceTask`; no `timeoutSeconds` |
| 19 | GetInstance | `getinstance` | same as 11 | stable | Full projection: metadata **and** data (13 returns data only) |
| 20 | DaprConversation | `daprconversation` | Remote | stable | LLM call through the Dapr Conversation building block |
| 21 | FanOut | — | **always Orchestration** | stable (meta since 0.0.80, shipped 0.0.85, #905) | N parallel copies of an inner task — see `fan-out.md` |
| 22 | ExternalHttp | — | Orchestration, outside the dispatcher | **deprecated 0.0.94** | Use **6**. Schema 0.0.54 rejects it; runtime still runs it |
| 23 | Python | `python` | Remote (`python` route) | **experimental** (meta since 0.0.80, docs 0.0.88) | Off unless `Python:Enabled=true` on Execution. Schema rejects it |

"—" in the wire column = the type never leaves the orchestrator (no invoker registration).

## 2. Where a task runs — the invocation routing seam (#1018, 0.0.94)

Every task with a prepared binding goes through `ITaskInvocationRouter`. Resolution order, first match wins:

1. Per-task override — a seam only (`config.executionMode`), **always `null` today**. The vnext-docs sentence "task-level `invocation` override > type mode > default" describes a field that does not exist; nothing you write in the task JSON changes the mode.
2. `Workflow:TaskInvocation:Modes:{wire}` (case-insensitive).
3. `Workflow:TaskInvocation:DefaultMode`.
4. Capability gate: `Local` with no registered local invoker silently degrades to `Remote`.

Shipped Orchestration `appsettings.json`:

```json
"Workflow": {
  "TaskInvocation": {
    "DefaultMode": "Remote",
    "Modes": { "http": "Local", "daprservice": "Local", "soap": "Local", "statestore": "Local", "cacheaside": "Local" }
  }
}
```

| Knob | Default | Meaning |
|------|---------|---------|
| `Workflow:TaskInvocation:LocalInvocationTimeoutSeconds` | **60** | Deadline around every in-process call; the only bound for 3/17/18 (no own `timeoutSeconds`) |
| `Workflow:TaskInvocation:MaxConnectionsPerServer` | 50 | Per-target connections for orchestrator HTTP/SOAP egress |
| `Python:Enabled` (Execution host) | `false` | Type 23 fails until enabled |

Timeout layering, local path: `task timeoutSeconds (http/soap only, default 30) ⊂ LocalInvocationTimeoutSeconds (60) ⊂ job budget (300)`. Options bind once at startup — a mode change needs an Orchestration restart; confirm from the `vnext.task.invocation.mode` span tag. What the local path loses: the Dapr sidecar circuit breaker, and isolation of state traffic (17/18 now share the orchestrator's Redis pool with platform caches).

## 3. Config essentials for the newer types

### 17 StateStore

```json
{ "type": "17", "config": { "command": "set", "key": "rates:USD", "value": { "rate": 34.2 }, "ttlInSeconds": 300 } }
```

`command` (`get` | `set` | `delete`, required); `key` (get/set/single delete), `keys[]` or `query` (bulk delete); `value`, `ttlInSeconds` (≥1) on set; `etag`, `concurrency` (`FirstWrite`|`LastWrite`), `consistency` (`Eventual`|`Strong`), `metadata`. `storeName` omitted → the **executing host's** `DAPR_STATE_STORE_NAME` — since 0.0.94 that host is the orchestrator. Keys are persisted with a `custom:` prefix. Dynamic key: `task.SetCacheKey(...)` in an `IMapping.InputHandler`.

### 18 CacheAside

```json
{ "type": "18", "config": {
  "key": "branches:all", "ttlInSeconds": 600, "bypassOnCacheError": true,
  "sourceTask": { "key": "get-branches-http", "domain": "core", "version": "1.0.0" } } }
```

`sourceTask` (required; `flow` defaults to `sys-tasks`) must be a remotely invokable type (6/16/1–4/13). Hit → return cached; miss → **re-enters the router** with `sourceTask`, caches the (optionally `sourceMapping`-shaped) result, returns it. `ttlInSeconds` absent or `0` = never expires. `bypassOnCacheError` default `true` (cache errors fall back to source instead of failing); `forceRefresh` skips the read; `keyExpression` (Dynamic Expresso) or `SetCacheKey` for dynamic keys.

### 19 GetInstance

`domain` + `flow` required; target by `key` or `instanceId`; optional `extensions[]`, `useDapr` (false), `headers`, `timeoutSeconds` (30), `validateSsl`, `acceptedStatusCodes`. Response: `{ id, key, flow, domain, status, currentState, createdAt, modifiedAt, data, extensions }`. Prefer 13 when you only need `data`; prefer `context.Related` when the target is this instance's parent/child.

### 20 DaprConversation

`componentName` required (the configured LLM component, e.g. `openai`); `inputs[]` of `{ role: user|system|assistant|developer|tool, content, scrubPII?, name? }`; `parameters` (string map — `model`, `maxTokens`), `metadata`, `contextId` (stateful thread), `temperature`, `scrubPII`, `timeoutSeconds` (30).

### 22 ExternalHttp — deprecated

Same config surface as 6. Existed only to skip the Execution hop; 6 does that by default now, with a per-type `Remote` fallback 22 never had. Existing definitions keep working; **write 6 for anything new**. Note the runtime doc `task-executors-and-invokers.md` calls it "type 21" in places — a typo; 21 is FanOut.

### 23 Python — experimental

```json
{ "type": "23", "config": { "script": { "type": "LOC", "encoding": "NAT", "code": "def main(input):\n    return {\"n\": len(input[\"items\"])}" }, "input": { "items": [] }, "timeoutSeconds": 20 } }
```

Contract `main(input) -> JSON`. Limits: code 256 KiB, input 2 MiB, output 2 MiB, stdout/stderr 32 KiB, `timeoutSeconds` default 30 / max 50 (`Python:MaxTimeoutSeconds`). `script.encoding` only `NAT`|`B64` — `REF`, global mapping references and filesystem paths are **rejected**. `executionMode` `pythonNet`|`process`|`container`; a disabled mode fails the task with **no fallback**. Failures enter the normal task-failure + error-boundary flow.

## 4. The schema-validation ceiling

vnext-schema **0.0.54** `task-definition.schema.json` enumerates `attributes.type` as `"1"`–`"21"`. Consequences:

| Type | `npm run validate` | runtime publish/run |
|------|--------------------|---------------------|
| 1–21 | passes | runs |
| 22 | **fails** (not planned to be added — deprecated) | runs |
| 23 | **fails** | runs if `Python:Enabled` |

Workaround: never author 22; for 23 keep the file outside the validated set until a schema release carries it. See `schema-runtime-gaps.md` D1.

## 5. Task & action history system functions (#981, 0.0.93)

Two read-only **system functions** expose the task journal — metadata only, no payloads:

| Call | Returns | Errors |
|------|---------|--------|
| `GET /{domain}/workflows/{flow}/instances/{id}/functions/tasks` | every `InstanceTasks` row, `StartedAt` ascending | — |
| `GET …/instances/{id}/functions/actions?taskId={guid}` | the row's `InstanceActions` sub-steps | missing/non-GUID → 400 `Instance:100039`; task not on this instance → 404 `Instance:100038` |

A domain function named `tasks` or `actions` is **shadowed**, like every other system function key.

## 6. Which task for which job

| Job | Use |
|-----|-----|
| Call a REST API | **6** |
| Call SOAP | 16 |
| Call another Dapr app by app-id | 3 (1 when an HTTPEndpoint component fronts it) |
| Publish an event / drive an output binding | 4 / 2 |
| SMS, e-mail, push with per-channel shaping | 10 |
| Transform data, no I/O | 7 |
| Read/write a cache key | 17 |
| Memoize another task's result | 18 |
| Start another instance and continue | 11 |
| Fire a transition on another instance | 12 |
| Read one instance: data only / full projection | 13 / 19 — parent or child of *this* instance → `context.Related` |
| Query many instances | 15 |
| Independent child, fire-and-forget | **14** (never state-level `P`) |
| Reusable nested sequence sharing data, wait for it | not a task: state `stateType: 4` + `subFlow.type: "S"` |
| N parallel copies, N known only at runtime | **21** — `fan-out.md` |
| Fixed parallel set known at design time | same `order`, **distinct task definitions** (journal key is transition+task+order) |
| LLM completion | 20 |
| Python snippet | 23 (opt-in, experimental) |
| Wait for a human | not a task: state `subType: 6` + `human-task` function |
| Wait for time | not a task: transition `triggerType: 2` |

## 7. Pitfalls

- **Dormant `errorTypes` rules now fire.** Before 0.0.94, `errorBoundary.onError[].errorTypes` never matched on the remote path (PascalCase/camelCase key mismatch). Fixed at both seams — audit boundaries whose `errorTypes` handlers have never run.
- **Task timeout has no status code.** A timeout surfaces as `Exception:TaskCanceledException` with `statusCode: null`; `errorCodes` written for HTTP codes miss it. Catch it with `"errorTypes": ["TaskCanceledException"]`.
- **`errorBoundary.onTimeout` is schema-only.** The runtime never reads it (`schema-runtime-gaps.md` D8). Use `errorTypes` as above.
- **Custom `storeName` breaks silently under Local.** A Dapr component scoped to the execution app-id resolved under `Remote` and fails at first execution under the new default, with no publish-time or startup signal. Re-scope it to the orchestrator app-id or set `"statestore": "Remote"` / `"cacheaside": "Remote"`.
- **3/17/18 have no `timeoutSeconds`.** `LocalInvocationTimeoutSeconds` (60 s) is their only bound; there is no per-task dial.
- **No task-level mode override**, whatever the docs say (§2).
- **Same-`order` parallel branches** sharing one task definition collide on the journal key — define distinct tasks.
- **12 ignores `version`.** Drop it; the deprecation is a warning today.
- **Human (5), Condition (8), Timer (9)** publish and validate fine and do nothing useful.

## Sources

- Runtime `vnext` @ `eca5b466` (v0.0.97): `src/BBT.Workflow.Domain/Definitions/Tasks/TaskEnums.cs`, `src/BBT.Workflow.Execution.Abstractions/TaskTypes.cs`, `src/BBT.Workflow.Application/Tasks/Invocation/{TaskInvocationRouter,TaskInvocationOptions}.cs`, `src/BBT.Workflow.Execution/Configuration/PythonOptions.cs`, `src/BBT.Workflow.Application/Execution/ErrorHandling/ErrorNormalizer.cs`, `src/BBT.Workflow.Application/Tasks/Executors/Human/HumanTaskExecutor.cs`, `src/BBT.Workflow.Domain/WorkflowErrorCodes.cs`
- Runtime docs: `docs/runtime/task-invocation-routing.md`, `task-executors-and-invokers.md`, `instance-task-and-action-history.md`, `state-store-task.md`, `cache-aside-task.md`, `get-instance-task.md`, `python-task.md`
- vnext-docs @ `adf9bf4`: `docs/components/tasks/{index,state-store,cache-aside,get-instance,dapr-conversation,external-http,python,trigger}.md`; release notes `blog/2026-09-21-v0-0-94.md` (#1018), `2026-09-14-v0-0-93.md` (#981), `2026-08-25-v0-0-86.md` (#917)
- vnext-schema @ `ac42026` (0.0.54): `schemas/task-definition.schema.json`
- vnext-meta 0.0.53: features `taskInvocationRouting` (0.0.94), `externalHttpTask` (0.0.88), `pythonTask` (0.0.80, experimental), `fanOutTask` (0.0.80), `taskAndActionHistory` (0.0.93), `stateStoreTask` (0.0.64); deprecations `external-http-task`, `direct-trigger-task-version`
- PRs: #905, #917, #981, #1016, #1018, #1026
