# Function vs Extension vs Task — Choosing the Right Component

Three vNext components all run code, but their roles are distinct. Picking the wrong one leads to coupling problems, performance issues, or confused workflow design.

## Quick decision

| You need to… | Use |
|--------------|-----|
| …expose a REST endpoint (call from client, BFF, or another service) | **Function** |
| …enrich an instance's data on every read (e.g. attach user profile, branch detail) | **Extension** |
| …perform an action inside a workflow (HTTP call, script, message publish, sub-process start) | **Task** |

## 1. Function

**Role.** A REST endpoint hosted by the workflow runtime.

**Scope values** (from the schema):
- `D` — Domain-scoped. Stateless, workflow-independent. URL: `/api/v{ver}/{domain}/functions/{key}`.
- `I` — Instance-scoped. Receives instance context. URL: `/api/v{ver}/{domain}/workflows/{wf}/instances/{instanceId}/functions/{key}`.
- (Other scopes may exist; check `function.json` schema.)

**Composition.**
- Single-task function: one `task` field with `mapping` (single `IMapping` `.csx`)
- Multi-task function: `onExecutionTasks[]` (multiple tasks) + `output` (an `IOutputHandler` `.csx` that aggregates results)

**Use cases.**
- LOV/lookup endpoints called by views (`x-lov`, `x-lookup`)
- BFF-style aggregation calls from clients
- Cross-domain data fetch / gates

## 2. Extension

**Role.** Automatic instance data enrichment that runs on workflow read operations.

**Type × Scope matrix** (from the `extension.json` schema):

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

**Type values** (numeric — read the canonical `task.json` schema; baseline mapping):

| Value | Type | Purpose |
|-------|------|---------|
| `1`  | DaprHttpEndpoint | Dapr HTTP endpoint invocation |
| `2`  | DaprBinding | Dapr input/output binding |
| `3`  | DaprService | Dapr service-to-service call |
| `4`  | DaprPubSub | Publish to a Dapr topic |
| `5`  | HumanTask | Human-in-the-loop (manual step) |
| `6`  | HttpTask | Plain HTTP/REST call |
| `7`  | ScriptTask | Inline C# script |
| `8`  | ConditionTask | Branch decision (verify in schema) |
| `9`  | TimerTask | Scheduling/delay (verify in schema) |
| `10` | NotificationTask | Multi-channel notification (SMS, email, push) |
| `11` | StartFlowTask | Start a new workflow instance |
| `12` | TriggerTransitionTask | Fire a transition on another instance |
| `13` | GetInstanceDataTask | Fetch a single instance's data |
| `14` | SubProcessTask | Execute a SubProcess |
| `15` | GetInstancesTask | List/query instances |
| `16` | SoapTask | SOAP 1.1/1.2 call |

**Use cases (by type).**
- External REST API → HttpTask (6)
- Legacy SOAP → SoapTask (16)
- Internal service (Dapr mesh) → DaprService (3)
- Async messaging → DaprPubSub (4)
- Notification → NotificationTask (10) + `INotificationMapping`
- Pure C# logic with no external call → ScriptTask (7)

## Boundary cases & rules of thumb

- **"Should this be a Function or a Task?"** If the client calls it directly → Function. If a workflow calls it as part of state/transition logic → Task.
- **"Should this be an Extension or a Function?"** If it should run automatically on every read → Extension. If it should run only when the client asks → Function.
- **"Should this be a Task or a Function?"** If it's reused across multiple workflows → consider a Function (then call it from tasks if needed). If it's specific to one workflow's logic → Task.
- **Functions can be composed of Tasks.** A multi-task Function pipelines several Tasks and aggregates via `IOutputHandler`. This is how complex aggregations are built without bloating a workflow's transition logic.

## Sources

- Canonical schemas: `function.json`, `extension.json`, `task.json` at `vnext-schema/v{schemaVersion}/schemas/`
- Docs: `https://burgan-tech.github.io/vnext-docs/docs/components/{functions/index|extension|tasks/index}`
- Examples: `vnext-example/core/Functions/`, `core/Extensions/`, `core/Tasks/`
