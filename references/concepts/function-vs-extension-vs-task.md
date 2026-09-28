# Function vs Extension vs Task — Choosing the Right Component

Three vNext components all run code, but their roles are distinct. Picking the wrong one leads to coupling problems, performance issues, or confused workflow design.

## Quick decision

| You need to… | Use |
|--------------|-----|
| …expose a REST endpoint (call from client, BFF, or another service) | **Function (BFF API mode)** |
| …serve a stateless single page — one input → one output, nothing persisted (calculator, eligibility check) | **Function (BFF View mode)** — not a workflow |
| …enrich an instance's data on every read (e.g. attach user profile, branch detail) | **Extension** |
| …perform an action inside a workflow (HTTP call, script, message publish, sub-process start) | **Task** |

## 1. Function

**Role.** A REST endpoint hosted by the workflow runtime — vNext's BFF surface. It has **two modes**, and the mode must be settled with the user before designing:

- **BFF API** (the original purpose): a pure endpoint called programmatically — verbs + optional `inputSchema`/`outputSchema`, **no view fields**. When no screen is involved, design the function like an API.
- **BFF View**: a stateless single page with no instance data (e.g. a loan-rate calculator) — the function itself declares the form (`inputView`), the validation contract (`inputSchema`), and the result presentation (`outputView`).

**Design rule (confirm-first).** When a user describes a stateless single input→output page, **propose a Function (BFF View), not a workflow**, and get their confirmation. Conversely, when a function has no view need, **propose designing it as a plain BFF API** (no `inputView`/`outputView`) and confirm — never attach view fields on a hunch.

**Scope values** (from the schema):
- `D` — Domain-scoped. Stateless, workflow-independent. URL: `/api/v{ver}/{domain}/functions/{key}`.
- `F` — Flow-scoped. Bound to a workflow definition (not a specific instance). Served on the instance route (the domain route rejects `F`/`I` with 403).
- `I` — Instance-scoped. Receives instance context. URL: `/api/v{ver}/{domain}/workflows/{wf}/instances/{instanceId}/functions/{key}`.

**Composition.**
- Single-task function: one `task` field with `mapping` (single `IMapping` `.csx`)
- Multi-task function: `onExecutionTasks[]` (multiple tasks) + `output` (an `IOutputHandler` `.csx` that aggregates results)

**Client contract fields** (runtime ≥ 0.0.79 for verbs/schemas/views and `/info`; `catalog` + `functions.href` in the state response later; multi-task slot isolation 0.0.95 — see `references/function-mapping-pattern.md` § 9):
- `verbs` — accepted HTTP verbs (absent = all; mismatch → 405 + `Allow`)
- `inputSchema` — request body validated before tasks run (failure → 400); `outputSchema` — declarative only
- `inputView` / `outputView` — the views a client renders to collect input / present output; all four slots accept a single reference or rule-based entries (first match wins, rule-less tail = fallback)
- `rawResponse`, `cache`, `roles` (DENY overrides ALLOW)
- Discovery: `GET .../functions/{fn}/info` (+ `view`/`schema?target=input|output`) answers "may I run this, with which verb, which view/schema applies" — 403 for unauthorized callers; `GET …/instances/{id}/functions/catalog` lists the role-filtered functions of an instance's workflow (`{name, version, scope, href}`); no ETag on any of them.
- Multi-task: results land in `TaskResponse[ToVariableName(key)]` (isolated copies since 0.0.95); keys that normalise to the same variable (`user-info` / `user_info`) are **rejected at publish** — § 9.

**Use cases.**
- LOV/lookup endpoints called by views (`x-lov`, `x-lookup`)
- BFF-style aggregation calls from clients
- BFF View pages (stateless single screens: calculators, eligibility checks)
- Cross-domain data fetch / gates

## 2. Extension

**Role.** Automatic instance data enrichment that runs on workflow read operations. The point is to
**reduce client / BFF round-trips**: when the runtime returns instance data, an extension augments it
inline so the consumer (a client, or whatever renders a view) gets enriched data in one read instead
of issuing follow-up calls. An extension can normalize/denormalize or compute over the existing
instance data, *and/or* call remote tasks to fetch additional data.

**When to use vs a Function.** If a view at a given state needs enriched or remote data rendered
inline, an extension fits. But for **`x-lov` / `x-lookup`-style inputs** (dropdown sources, per-key
lookups), use a **Function** — those are request-time, input-bound resolutions, not read-time
enrichment of the whole instance.

**Type × Scope matrix** (from `extension-definition.schema.json`):

| Type | Behavior |
|------|----------|
| `1` Global | Runs on every workflow's read endpoints |
| `2` GlobalAndRequested | Type 1 + can also be requested explicitly |
| `3` DefinedFlows | Runs only on workflows that reference it |
| `4` DefinedFlowAndRequested | Type 3 + can also be requested explicitly |

| Scope | Endpoint set |
|-------|--------------|
| `1` | GetInstance (single instance read) |
| `2` | GetAllInstances (list query) |
| `3` | Everywhere (all endpoints) |

**Performance.** Type 1 + Scope 3 fires on every endpoint hit across the runtime — use sparingly. Type 3 + Scope 1 is the lightweight default (specific workflow, single-instance enrichment).

**Use cases.**
- Attaching user session details to every workflow instance
- Joining a related entity (customer profile, branch info) into the response
- Cross-cutting metadata (audit, permissions)

## 3. Task

**Role.** A discrete action invoked inside a workflow — typically inside a transition's `onExecutionTasks[]`, a state's `onEntries[]` / `onExits[]`, or a function's task list.

**Most-used types** (`attributes.type` is a numeric **string**; the schema enum is `"1"`–`"21"`, the runtime knows 1–23 — see `schema-runtime-gaps.md` D1):

| Value | Type | Purpose |
|-------|------|---------|
| `6`  | HttpTask | Plain HTTP/REST call. Runs orchestrator-local by default since 0.0.94 (`Workflow:TaskInvocation`) — also the replacement for deprecated type 22 |
| `7`  | ScriptTask | Inline C# (`IMapping`) — pure logic, no external call |
| `10` | NotificationTask | Multi-channel notification (SMS, email, push) + `INotificationMapping` |
| `12` | DirectTrigger | Fire a transition on another instance (cross-instance / cross-domain) |
| `14` | SubProcessTask | Start a fire-and-forget child (`P`) and create the correlation — the **only** way to start a SubProcess (state-level `subFlow.type: "P"` is rejected at publish since 0.0.95) |
| `15` | GetInstancesTask | List/query instances (filters, paging) |
| `18` | CacheAsideTask | Read-through cache around an inner task |
| `21` | FanOutTask | Run one inner task once per item of a data-driven collection, in parallel, with a join policy (`all` / `allSettled` / `quorum` / `firstSuccess`) — `IFanOutMapping` |

Full catalog including Dapr types (1–4), Condition/Timer (8/9), StartTrigger (11), GetInstanceData (13), Soap (16), StateStore (17), GetInstance (19), DaprConversation (20), ExternalHttp (22, deprecated) and Python (23), plus which types run Local vs Remote: **`task-types.md`**. A **human approval step is not a task** — it is a state with `subType: 6` + `queryRoles` served by the built-in `human-task` function: **`human-task.md`**.

**Use cases (by type).**
- External REST API → HttpTask (6)
- Legacy SOAP → SoapTask (16)
- Internal service (Dapr mesh) → DaprService (3)
- Async messaging → DaprPubSub (4)
- Notification → NotificationTask (10) + `INotificationMapping`
- Pure C# logic with no external call → ScriptTask (7)
- Same call for every element of a list (documents, accounts, recipients) → FanOutTask (21) — `fan-out.md`
- Independent background child process → SubProcessTask (14) — `workflow-types.md` §5

## Boundary cases & rules of thumb

- **"Should this be a Function or a Task?"** If the client calls it directly → Function. If a workflow calls it as part of state/transition logic → Task.
- **"Should this be an Extension or a Function?"** If it should run automatically on every read → Extension. If it should run only when the client asks → Function.
- **"Should this be a Task or a Function?"** If it's reused across multiple workflows → consider a Function (then call it from tasks if needed). If it's specific to one workflow's logic → Task.
- **Functions can be composed of Tasks.** A multi-task Function pipelines several Tasks and aggregates via `IOutputHandler`. This is how complex aggregations are built without bloating a workflow's transition logic.
- **"One call per item of a list?"** That is a **FanOutTask (21)** wrapping the per-item task — not a loop of transitions, not N tasks in `onExecutionTasks`. The join policy decides success; branch on the `{resultKey}Summary` counters with auto transitions. Nested fan-out is rejected at runtime.
- **"Start a child that the parent does not wait for?"** A **SubProcessTask (14)** on a transition. A state-level `subFlow` is always `type: "S"` (blocking SubFlow); `"P"` there is a publish-time error since 0.0.95.
- **Function catalog and key collisions.** Clients find a workflow's functions through `…/functions/catalog` (role-filtered); a multi-task function's task keys must stay distinct after `ToVariableName` normalisation or publish fails — `function-mapping-pattern.md` § 9.

## Sources

- Canonical schemas: `function-definition.schema.json`, `extension-definition.schema.json`, `task-definition.schema.json` — resolve as described in `component-schemas.md`
- Runtime: `src/BBT.Workflow.Domain/Definitions/Tasks/TaskEnums.cs` (v0.0.97), `WorkflowValidator.ValidateStateSubFlowType`, `FunctionComponentValidator.ValidateTaskKeysDistinct`
- Related references: `task-types.md`, `fan-out.md`, `human-task.md`, `schema-runtime-gaps.md`
- Docs: `https://burgan-tech.github.io/vnext-docs/docs/components/{functions/index|extension|tasks/index}`
- Examples: `vnext-example/core/Functions/`, `core/Extensions/`, `core/Tasks/`
