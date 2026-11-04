# Task Types — The Full `type` Catalog (1–23)

> **Caveat.** `attributes.type` is a **numeric string** (`"6"`, not `6`). The runtime enum (`TaskType`) is the source of truth for membership; the vnext-schema package lags it (see §4). Runtime baseline for this file: **v0.0.103** (schema 0.0.59).

## 1. Catalog

"Runs" is the v0.0.103 **shipped default** — where the prepared binding executes. It is host configuration, not a task field (§2).

| # | Name | Wire name | Runs (default) | Status | Notes |
|---|------|-----------|----------------|--------|-------|
| 1 | DaprHttpEndpoint | `daprhttpendpoint` | Remote (Execution) | stable | Dapr HTTPEndpoint component |
| 2 | DaprBinding | `daprbinding` | Remote | stable | Output bindings (queue, blob, SMTP, …). Since 0.0.102 the output mapping sees the binding's answer and a mapping sets `operation` / `data` / `metadata` per call (§3) — the way to delete/read/list `x-storage` objects |
| 3 | DaprService | `daprservice` | **Local (Orchestration)** | stable | No `timeoutSeconds` field → §7 |
| 4 | DaprPubSub | `daprpubsub` | Remote | stable | Publish an event. `topic` is used **verbatim** — under Kafka it must sit inside `vnext.{domain}.*` (0.0.100, §3) |
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
| 18 | CacheAside | — (removed 0.0.99) | Orchestration executor; cache I/O follows `statestore`, the source follows **its own** type | stable | Read-through cache; the source runs as a real task (rewritten 0.0.99, #1053 — §3); no `timeoutSeconds` |
| 19 | GetInstance | `getinstance` | same as 11 | stable | Full projection: metadata **and** data (13 returns data only) |
| 20 | DaprConversation | `daprconversation` | Remote | stable | LLM call through the Dapr Conversation building block |
| 21 | FanOut | — | **always Orchestration** | stable (meta since 0.0.80, shipped 0.0.85, #905) | N parallel copies of an inner task — see `fan-out.md` |
| 22 | ExternalHttp | — | Orchestration, outside the dispatcher | **deprecated 0.0.94** | Use **6**. Schema ≥ 0.0.55 accepts it again; runtime still runs it |
| 23 | Python | — | **Orchestration → Dapr invoke** of the domain's own Python runtime (no Execution hop, outside the router) | **experimental** (meta since 0.0.80; handler contract **0.0.103**, #1157 — breaking) | Calls a named `handler` in the domain's runtime image. Without a runtime (`Workflow:PythonRuntime:AppId` empty) it fails with 503. Schema ≥ 0.0.59 validates it (§3, §4) |

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
    "Modes": { "http": "Local", "daprservice": "Local", "soap": "Local", "statestore": "Local" }
  }
}
```

`Modes:cacheaside` was **removed in 0.0.99** (#1053) — delete it from environment config; CacheAside cache I/O now follows `Modes:statestore`.

| Knob | Default | Meaning |
|------|---------|---------|
| `Workflow:TaskInvocation:LocalInvocationTimeoutSeconds` | **60** | Deadline around every in-process call; the only bound for 3/17 and CacheAside's cache I/O (no own `timeoutSeconds`; an 18 source keeps its own type's timeout) |
| `Workflow:TaskInvocation:MaxConnectionsPerServer` | 50 | Per-target connections for orchestrator HTTP/SOAP egress |
| `Workflow:TaskInvocation:PooledConnectionLifetimeSeconds` / `PooledConnectionIdleTimeoutSeconds` | 600 / 120 | (0.0.102, `httpTaskClientPool`) HTTP/SOAP tasks reuse warm TCP+TLS connections; lifetime bounds how long a DNS/gateway change goes unnoticed, keep idle below the gateway keep-alive. The Execution host reads the same three dials from `WorkflowHttpClient:*` (its cap was a hardcoded 10) — override both hosts together |
| `Workflow:PythonRuntime:AppId` (Orchestration) | empty | Dapr app-id of the domain's Python runtime (Helm `pythonRuntime` sets it). Empty → every type-23 task fails with **503**. Type 23 is not routed: no `python` entry belongs in `Modes` |
| `Workflow:PythonRuntime:InvokeMethod` / `TimeoutGraceSeconds` | `v1/invoke` / `5` | Invoke route of the contract; extra wait beyond the handler timeout so the runtime's own 504 arrives first |

Timeout layering, local path: `task timeoutSeconds (http/soap only, default 30) ⊂ LocalInvocationTimeoutSeconds (60) ⊂ job budget (300)`. Options bind once at startup — a mode change needs an Orchestration restart; confirm from the `vnext.task.invocation.mode` span tag. What the local path loses: the Dapr sidecar circuit breaker, and isolation of state traffic (17/18 now share the orchestrator's Redis pool with platform caches).

## 3. Config essentials for the newer types

### 17 StateStore

```json
{ "type": "17", "config": { "command": "set", "key": "rates:USD", "value": { "rate": 34.2 }, "ttlInSeconds": 300 } }
```

`command` (`get` | `set` | `delete`, required); `key` (get/set/single delete), `keys[]` or `query` (bulk delete); `value`, `ttlInSeconds` (≥1) on set; `etag`, `concurrency` (`FirstWrite`|`LastWrite`), `consistency` (`Eventual`|`Strong`), `metadata`. `storeName` omitted → the **executing host's** `DAPR_STATE_STORE_NAME` — since 0.0.94 that host is the orchestrator. Keys are persisted with a `custom:` prefix. Dynamic key: `task.SetCacheKey(...)` in an `IMapping.InputHandler`.

### 18 CacheAside (rewritten 0.0.99, #1053 — breaking)

```json
{ "type": "18", "config": {
  "key": { "location": "dynamicExpresso", "encoding": "NAT", "code": "\"customer:\" + context.Headers.customerid + \":profile\"" },
  "ttlInSeconds": 300, "bypassOnCacheError": true,
  "sourceTask": { "key": "get-customer-http", "domain": "core", "version": "1.0.0" },
  "sourceMapping": { "location": "./src/GetCustomerSourceMapping.csx", "code": "<base64>" } } }
```

- **Source runs as a real task.** On a miss (or `forceRefresh: true`) `sourceTask` (required; `flow` defaults to `sys-tasks`) runs through **its own type's executor and routing** — any type except another CacheAside (rejected at execution, log 10177). It has no error boundary or journal row of its own; the boundary applies once, on the CacheAside task.
- **`sourceMapping` is the source task's full `IMapping`**: `InputHandler` configures the call (URL, body, `SetKey`), `OutputHandler` produces **the value that is cached**. No mapping → the raw source `data` is cached. Its side effects on the context are discarded.
- **Task-level mapping** (`onExecutionTasks[].mapping`): `InputHandler` may `SetCacheKey(...)`; `OutputHandler` runs on **hit and miss**, with `context.Body.metadata` = `CacheHit`, `Refreshed`, `Key` (`custom:`-prefixed), `StoreName`, `ETag`.
- **`key` is `string | ScriptCode`.** A string is used verbatim. A ScriptCode is a Dynamic Expresso expression (`location: "dynamicExpresso"`) or a Roslyn class implementing **`ICacheKeyMapping`** (`Task<string?> Handler(ScriptContext)`); encodings `NAT` / `B64` / `REF`, **default `B64`** — plain-text code needs `"encoding": "NAT"`. A non-blank script result overrides a `SetCacheKey` key; a blank key at invoke time fails the task.
- `ttlInSeconds` absent or `0` = never expires; `consistency` `Eventual`|`Strong`; `bypassOnCacheError` default `true` (cache errors fall back to the source, log 10176).
- **Removed:** `keyExpression`, the `cacheaside` wire type and `Modes:cacheaside`. Entries written by ≤ 0.0.98 hold raw values until their TTL expires; StateStore pre-warm writes must now write the **shaped** value.
- Not to be confused with the **function-level** `attributes.cache` block: that one still has its own `keyExpression` (a Dynamic Expresso ScriptCode, plus `generationKey` / `generationKeyExpression`) — unchanged.

### 2 DaprBinding — response and per-call shape (0.0.102, #1144)

- **Answer to the output mapping** (migration `daprbinding-task-output-mapping-data`): `Data` is the binding's
  body as JSON when it parses, else text, else base64 (`Metadata["DataEncoding"]` = `json|text|base64|none`);
  `Headers` = the binding's response metadata; a failure carries the sidecar's reason. An unmapped task still adds
  no instance data. Before 0.0.102 the response carried only `BindingName` / `Operation`.
- **Per-call shape** in the `InputHandler`: `((DaprBindingTask)task).SetOperation("delete" | "get" | "list" | …)`,
  `SetData(…)`, `SetMetadata(new() { ["key"] = FileObjectKey(fileId) })` (`fileName` for `bindings.localstorage`).
- **Reaching `x-storage` components:** they are scoped to the orchestration app-id while type 2 runs Remote by
  default — the platform sets `Workflow:TaskInvocation:Modes:daprbinding = Local` (orchestration sidecar) or
  scopes the component to Execution too. Recipe: `file-fields.md` § Deleting, reading and listing objects.

### 19 GetInstance

`domain` + `flow` required; target by `key` or `instanceId`; optional `extensions[]`, `useDapr` (false), `headers`, `timeoutSeconds` (30), `validateSsl`, `acceptedStatusCodes`. Response: `{ id, key, flow, domain, status, currentState, createdAt, modifiedAt, data, extensions }`. Prefer 13 when you only need `data`; prefer `context.Related` when the target is this instance's parent/child.

### 4 DaprPubSub — topic names (0.0.100, #1095)

`topic` (and domain `Subscription` topics) are used **verbatim** — the runtime adds no prefix. The runtime's own topics are now `vnext.{APP_DOMAIN}.{environment}.{event}.v{n}` (`environment` = lower-cased `ASPNETCORE_ENVIRONMENT`, default `production`). Under Kafka the broker ACL grants each domain only `vnext.{domain}.*`, so a domain topic such as `user-events` is rejected there — name it `vnext.{domain}.{environment}.{event}` unless the platform team grants it explicitly. Redis / RabbitMQ setups have no such ACL.

### 20 DaprConversation

`componentName` required (the configured LLM component, e.g. `openai`); `inputs[]` of `{ role: user|system|assistant|developer|tool, content, scrubPII?, name? }`; `parameters` (string map — `model`, `maxTokens`), `metadata`, `contextId` (stateful thread), `temperature`, `scrubPII`, `timeoutSeconds` (30).

### 22 ExternalHttp — deprecated

Same config surface as 6. Existed only to skip the Execution hop; 6 does that by default now, with a per-type `Remote` fallback 22 never had. Existing definitions keep working; **write 6 for anything new**. Note the runtime doc `task-executors-and-invokers.md` calls it "type 21" in places — a typo; 21 is FanOut.

### 23 Python — handler container (0.0.103, #1157 — breaking)

A type-23 task **references a handler** in the domain's own Python runtime image; it carries no code. Orchestration builds the request from the normal task mapping and calls the runtime through Dapr service invocation (`POST v1/invoke`, contract version 1). The error boundary and the transition pipeline treat it like any other task.

```json
{ "type": "23", "config": { "handler": "risk_score", "input": { "income": 85000 }, "timeoutSeconds": 20 } }
```

| Field | Required | Contract |
|-------|----------|----------|
| `handler` | yes | A handler registered in the runtime: `^[A-Za-z_][A-Za-z0-9_.-]{0,127}$` |
| `input` | no | Any JSON value — the default input; an input mapping may replace it. At most **2 MiB** as authored (publish checks it) |
| `timeoutSeconds` | no | 1–50, default 30. Orchestration waits `timeoutSeconds + Workflow:PythonRuntime:TimeoutGraceSeconds` (5) |

`config` is closed (`additionalProperties: false`): **`script` and `executionMode` are rejected** by schema 0.0.59 and at publish (deprecation `python-task-inline-script-config`, severity error; migration `python-task-handler-contract`). The Execution host's `Python:*` settings (`Python:Enabled`, `Python:ExecutionMode`, `Python:MaxTimeoutSeconds`, …) are ignored since 0.0.103 (`execution-python-settings`).

**Mapping** — the standard `IMapping` (`csx-contracts.md`). `InputHandler` replaces the authored input with `((PythonTask)task).SetInput(new { … })`; `OutputHandler` reads the handler output from `context.Body.data` (plus `isSuccess`, `statusCode`, `errorMessage`, `taskType` = `"python"`). Without a mapping the handler output is the task result as is.

**Failures** are failed tasks: `StatusCode` = the HTTP status, `ErrorMessage` = `"<code>: <message>"`, so `errorBoundary` rules can match either.

| HTTP | Code | From | Meaning |
|------|------|------|---------|
| 400 | `bad_request`, `unsupported_contract` | runtime | Body not a JSON object / contract version not `1` |
| 404 | `unknown_handler` | runtime | No handler with that name in the image |
| 413 | `request_too_large` | runtime / **Orchestration** | Body over 4 MiB at the runtime; mapped input over 2 MiB is refused by Orchestration before any call |
| 422 | `handler_error` | runtime | The handler raised |
| 422 | `invalid_output`, `output_too_large` | runtime | Result is not strict JSON (`NaN`, NumPy types) or over 4 MiB |
| 504 | `timeout` | runtime | Handler exceeded `timeoutSeconds` |
| 503 | — | **Orchestration** | The domain has no runtime (`AppId` empty); no call is made |
| 408 | — | **Orchestration** | No answer within `timeoutSeconds + TimeoutGraceSeconds` |

Design rules:
- Put an error boundary on the task for the codes the flow can handle (vnext-example uses a task-level Abort on `errorCodes: ["422"]`); 404 and 503 are deployment errors, not business outcomes.
- **Timeout layering:** handler timeout (≤ 50 s) < Orchestration wait (+5 s) < transition job budget (`WorkflowExecution:TransitionJobTimeoutSeconds`, 300). Nothing validates the last step — keep the job budget above the longest Python wait in the flow.
- Calls share one process per pod (`VNEXT_PYTHON_MAX_WORKERS`, default 4). A timed-out call keeps its worker thread until it returns, and CPU-bound work is limited by the GIL — scale with replicas, keep handlers well inside their timeout.
- The input is **raw instance data** (personal data included). Secrets come from the Dapr secret store or the pod environment, never from the task definition.

**Domain side** — the domain owns a runtime image built `FROM ghcr.io/burgan-tech/vnext/python-runtime:<runtimeVersion>` with its handlers and **hash-pinned** requirements (installed at build time, wheels only, nothing at container start). Handler shape:

```python
# python-runtime/handlers/calculations.py
from vnext_runtime import HandlerContext, handler

@handler("risk_score")
def risk_score(input, context: HandlerContext):          # context is optional
    return {"score": min(100, input["income"] // 1000)}  # must pass json.dumps(allow_nan=False)
```

`HandlerContext`: `domain`, `workflow`, `workflow_version`, `instance_id`, `task_key`, `correlation_id`, `timeout_ms`. Every module of the `handlers` package is imported at start; `GET v1/manifest` lists the registered handler names, `GET v1/health` is the probe. Scaffold: `templates/python-runtime/` (Dockerfile, requirements, handlers) and `templates/etc/runtime/docker-compose.python.override.yml.tmpl` for a local runtime; shared environments enable the Helm chart's `pythonRuntime` block (it sets `Workflow:PythonRuntime:AppId` to `vnext-<domain>-python-runtime-app`). Building and pushing the image is the domain's pipeline, not the toolkit's.

## 4. The schema-validation ceiling

vnext-schema `task-definition.schema.json` enumerates `attributes.type`:

| Schema package | Enum | Type 23 |
|----------------|------|---------|
| 0.0.54 | `"1"`–`"21"` | fails validate |
| 0.0.55 – 0.0.58 | `"1"`–`"22"` | fails validate (and the runtime < 0.0.103 ran the old inline-`script` form) |
| **0.0.59+** | `"1"`–`"23"` | validates **only** the handler contract above; `script` / `executionMode` fail `additionalProperties` |

| Type | `npm run validate` (schema ≥ 0.0.59) | runtime publish/run (≥ 0.0.103) |
|------|--------------------|---------------------|
| 1–21 | passes | runs |
| 22 | passes (still **deprecated** — write 6) | runs |
| 23 | passes with `handler` | runs when the domain's Python runtime is deployed; 503 otherwise |

A workspace pinned to schema < 0.0.59 or runtime < 0.0.103 cannot use the handler contract — bump both together (`runtime-feature-matrix.md`). See `schema-runtime-gaps.md` D1 for the history.

## 5. Task & action history system functions (#981, 0.0.93)

Two read-only **system functions** expose the task journal — metadata only, no payloads:

| Call | Returns | Errors |
|------|---------|--------|
| `GET /{domain}/workflows/{flow}/instances/{id}/functions/tasks` | every **completed** `InstanceTasks` row, `StartedAt` ascending. Since 0.0.102 (`bookkeepingCommitReduction`) a row is written once, at completion — a **running** task is no longer listed, and a task interrupted by a crash leaves no row (it re-runs on retry) | — |
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
| Fixed parallel set known at design time | same `order`; the same task twice needs a distinct `variableKey` on one entry (0.0.99, §7) |
| LLM completion | 20 |
| Python computation (NumPy, pandas, a scoring model) | 23 — a handler in the domain's Python runtime image (experimental; runtime ≥ 0.0.103) |
| Wait for a human | not a task: state `subType: 6` + `human-task` function |
| Wait for time | not a task: transition `triggerType: 2` |

## 7. Pitfalls

- **Dormant `errorTypes` rules now fire.** Before 0.0.94, `errorBoundary.onError[].errorTypes` never matched on the remote path (PascalCase/camelCase key mismatch). Fixed at both seams — audit boundaries whose `errorTypes` handlers have never run.
- **Task timeout has no status code.** A timeout surfaces as `Exception:TaskCanceledException` with `statusCode: null`; `errorCodes` written for HTTP codes miss it. Catch it with `"errorTypes": ["TaskCanceledException"]`.
- **`errorBoundary.onTimeout` is schema-only.** The runtime never reads it (`schema-runtime-gaps.md` D8). Use `errorTypes` as above.
- **Custom `storeName` breaks silently under Local.** A Dapr component scoped to the execution app-id resolved under `Remote` and fails at first execution under the new default, with no publish-time or startup signal. Re-scope it to the orchestrator app-id or set `"statestore": "Remote"` (CacheAside cache I/O follows it since 0.0.99).
- **3/17/18 have no `timeoutSeconds`.** `LocalInvocationTimeoutSeconds` (60 s) is their only bound; there is no per-task dial.
- **No task-level mode override**, whatever the docs say (§2).
- **Parallel same-domain reads (fixed 0.0.103, #1166).** On runtime ≤ 0.0.102, two or more same-domain `GetInstances` / `GetInstance` / `GetInstanceData` tasks (or DirectTrigger by key) at the **same `order`** shared one database context and failed with `A second operation was started on this context instance` — silently wrong without an error boundary. On older runtimes put them at different `order`s; 0.0.103 gives each read its own unit of work.
- **Same-`order` parallel branches** are merged by response slot = `variableKey ?? camelCase(task.key)`. Listing the same task twice at one order used to throw `Parallel tasks produced conflicting output…`; since **0.0.99** (#1072) give at least one entry a `variableKey` (`^[A-Za-z_][A-Za-z0-9_]*$`, ≤ 100 chars). Publish rejects a slot collision within one order (workflows: `onEntries`, `onExits`, `onExecutionTasks`) and across all `onExecutionTasks` (functions); a later order may reuse a slot and overwrites it.
- **CacheAside `keyExpression` is gone** (0.0.99). The runtime no longer reads it (deprecation `cacheaside-key-expression-removed`, severity error) — move it into `key` as a ScriptCode with `"encoding": "NAT"`.
- **12 ignores `version`.** Drop it; the deprecation is a warning today.
- **Human (5), Condition (8), Timer (9)** publish and validate fine and do nothing useful.

## Sources

- Runtime `vnext` @ `f06961ec` (v0.0.100): `src/BBT.Workflow.Domain/Definitions/Tasks/{TaskEnums,CacheAsideTask}.cs`, `src/BBT.Workflow.Application/Tasks/Executors/Cache/CacheAsideTaskExecutor.cs`, `src/BBT.Workflow.Application/Tasks/Invocation/{TaskInvocationRouter,TaskInvocationOptions}.cs`, `orchestration/BBT.Workflow.Orchestration.HttpApi.Host/appsettings.json` (`Workflow:TaskInvocation`), `src/BBT.Workflow.Domain/WorkflowErrorCodes.cs`
- Runtime docs: `docs/runtime/task-invocation-routing.md`, `task-executors-and-invokers.md`, `instance-task-and-action-history.md`, `state-store-task.md`, `cache-aside-task.md`, `get-instance-task.md`, `python-task.md`
- vnext-docs: `docs/components/tasks/{index,state-store,cache-aside,dapr-pubsub,get-instance,dapr-conversation,external-http,python,trigger}.md`, `how-to/event-driven-workflows.md`; release notes `blog/2026-10-05-v0-0-99.md` (#1053, #1072), `2026-10-15-v0-0-100.md` (#1095), `2026-09-21-v0-0-94.md` (#1018), `2026-09-14-v0-0-93.md` (#981)
- vnext-schema 0.0.59: `schemas/task-definition.schema.json` (type enum `"1"`–`"23"`, type-23 handler config, vnext-schema #165)
- Runtime `vnext` @ `74587011` (v0.0.103): `docs/runtime/python-task.md`, `docs/integration/vnext-ai-toolkit/python-task-container.md`, `runtimes/python/` (base image, `vnext_runtime`, example domain image); vnext-example `labs/python-runtime/`, `core/Tasks/python-task-lab/` (#49)
- vnext-meta (master): features `taskInvocationRouting`, `taskVariableKey` (0.0.99), `pythonTask` (experimental), `fanOutTask`; deprecations `cacheaside-key-expression-removed`, `external-http-task`, `direct-trigger-task-version`
- PRs: #905, #917, #981, #1016, #1018, #1026, #1053, #1072, #1095, #1157
