# Incidents and Retry — why an instance faulted, and how to recover it

> Runtime 0.0.92+ (`stateIncident`, PR #972). An **incident** is the persisted record of one
> error-boundary verdict or pipeline failure on an instance: which state/transition/task, which
> error, what the boundary decided, and the `traceId` to find it in logs/APM. Storage is the
> `InstanceIncidents` table (one row per failure, unbounded history, cascade-deleted with the
> instance); `Instances.HasActiveIncident` is a denormalized flag the pipeline reads first.

## 1. Where clients see it — the `incident` link block

Three surfaces return the **identical** block, byte-for-byte:

- State function body (`GET …/instances/{id}/functions/state`, long-poll) → top-level `incident`
- `GET …/instances/{id}` → `metadata.incident`
- `GET …/instances` → each item's `metadata.incident`

```jsonc
"incident": {
  "hasActiveIncident": true,
  "active":  { "href": "/credit/workflows/loan/instances/{id}/incidents/active" },   // only while true
  "history": { "href": "/credit/workflows/loan/instances/{id}/incidents" }           // always
}
```

Links, not content: the body never embeds message/code. Reason: `hasActiveIncident` is a member of
the state fingerprint ETag, so opening or resolving an incident without a state change still breaks
a parked long-poller's `304`; the client then re-fetches `active.href`. No surface returns a stack
trace. Response shape version **v9**.

**Active subflow:** `active.href` points at the **subflow that owns** the incident; `history.href`
always points at the polled instance ("what went wrong on the thing I asked about").

## 2. Endpoints

| Endpoint | Returns |
|---|---|
| `GET …/instances/{id}/incidents/active` | Newest **unresolved** incident (`IncidentDetailDto`). **404 `Instance:100037` is normal** — a retry may have resolved it between the poll and the follow-up; treat as "re-read state", not an error. 403 = gateway `authorize?queryRoles=true` denied. |
| `GET …/instances/{id}/incidents?page=1&pageSize=20` | `{ hasActiveIncident, items: IncidentDetailDto[], page, pageSize, hasNext }`, newest first. `pageSize` clamped to **≤ 100** (default 20). |
| `POST …/instances/{id}/retry?sync=true|false` | Body optional `TransitionDataInput` `{ key?, tags?, attributes?, stage? }` — `attributes` merged into instance data before the retried transition's OnExecute. Returns `{ id, status, retriedTransitionId }`. |

Since 0.0.95 the two GETs do not evaluate `queryRoles` themselves; the Internal Gateway asks
`GET …/functions/authorize?queryRoles=true` first (see `roles-and-authorization.md`).

### `IncidentDetailDto`

| Field | Type | Notes |
|---|---|---|
| `id`, `createdAt` | uuid, ISO-8601 UTC | |
| `state`, `transition` | string | where it happened |
| `task` | string \| null | faulting task key; `null` for pipeline-level failures |
| `message` | string | human-readable |
| `errorCode` | string \| null | normalized, e.g. `Task:Http:503`, `JOB_EXECUTION_FAILED` |
| `errorLayer` | `Transport` \| `Task` \| `Pipeline` \| null | |
| `statusCode` | int \| null | HTTP status when applicable |
| `boundaryAction` | `Abort` \| `Retry` \| `Rollback` \| `Notify` \| `Log` \| `Ignore` \| null | matched `errorBoundary.onError[].action`; `null` = no rule matched |
| `boundaryLevel` | `Task` \| `State` \| `Global` \| null | which boundary level matched |
| `traceId` | string \| null | OpenTelemetry trace id — the debugging handle |
| `isResolved`, `resolvedAt` | bool, ISO \| null | |
| `retryCount` | int | **always `0`** today (engine does not feed the resolved retry policy into the result). Track attempts yourself in instance data if needed. |

## 3. Relation to `errorBoundary`

Each boundary verdict (Task → State → Global, by `priority`) that ends in `Abort`, `Retry`
(exhausted), `Rollback` or `Notify` writes **one** incident carrying `boundaryAction` +
`boundaryLevel`. An unhandled failure with no matching rule writes one incident with
`boundaryAction: null`. `Ignore` and `Log` write **nothing**. Before 0.0.92 an abort produced two
rows (verdict + a `Pipeline`/`ErrorBoundaryAbort` duplicate that hid the real one) — gone.

On `rollback`/`notify` a brief `hasActiveIncident: true` window is visible while the instance is
`Busy`, until `FinalizeTransitionStep` closes the row. Accepted side effect.

## 4. Retry rules

| Rule | Detail |
|---|---|
| Faulted only | Instance (or its active subflow) must be `F`; otherwise **400 `Instance:100027`** `InstanceNotFaulted`. |
| Success closes everything | A successful retry (unfault) resolves **all** open incidents, recomputes the flag; history rows stay, marked resolved. `incident.active` disappears. |
| Re-fault stays `F` | If the retried work faults again: **200** with `"status":"F"`, a new incident, and the instance is retryable again (pre-0.0.92 the ambient UoW overwrote `F` with `A` and the instance was stuck). |
| One incident per failure | See §3. |
| Active subflow | Retry on the parent probes the child; a `Faulted` child is retried through the gateway (cross-domain OK). A **missing** child is restarted. |
| Failed subflow start (#1026, 0.0.95) | `StartSubflowJob` failure no longer strands the parent in `Busy`: parent → `Faulted` + incident; `POST …/retry` **re-runs the subflow start**. Same release: a pre-reserved transition job failing with a non-lock error faults the instance (`JOB_EXECUTION_FAILED`). |
| `?sync=true` | Waits for the retried transition to settle; default async returns as soon as the retry is accepted. |

Known issue `pre-reserved-job-failure-can-strand-busy`: a job re-entry failing with a non-lock
`Result` error can still leave `Busy` with no owner — retry requires `F`, so recover with
cancel/exit (see `runtime-operations.md`).

## 5. Script side — `context.Incident`

Mappings read `ScriptIncidentInfo`: `HasActiveIncident`, `ActiveIncident` (newest unresolved),
`TotalIncidentCount` (materialized only — not full history), `IncidentsLoaded`. Useful in a
compensation transition's mapping to branch on `errorCode`/`boundaryAction`.

## 6. Debugging hand-off

Take `active.traceId` (or `history.items[0].traceId`) → search APM/logs by trace id, or by
`x_request_id`; then `functions/tasks` + `functions/actions?taskId=` for step detail. Full recipe,
span names and correlation headers: **`observability.md`**.

## 7. `.http` snippet

```http
### Why is it faulted?
GET {{baseUrl}}/api/v1/{{domain}}/workflows/{{workflow}}/instances/{{instanceId}}/incidents/active
Accept: application/json
# 200 → IncidentDetailDto | 404 Instance:100037 → nothing open, re-read state

### Full history, newest first
GET {{baseUrl}}/api/v1/{{domain}}/workflows/{{workflow}}/instances/{{instanceId}}/incidents?page=1&pageSize=20

### Retry (Faulted only), optionally patching data first
POST {{baseUrl}}/api/v1/{{domain}}/workflows/{{workflow}}/instances/{{instanceId}}/retry?sync=true
Content-Type: application/json

{ "attributes": { "customer": { "phone": "+905551112233" } } }
# 200 { id, status: "A"|"C"|"F"|…, retriedTransitionId } | 400 Instance:100027 not Faulted

### Confirm the block cleared
GET {{baseUrl}}/api/v1/{{domain}}/workflows/{{workflow}}/instances/{{instanceId}}/functions/state
# incident.hasActiveIncident == false, no incident.active
```

## Sources

- Runtime: `src/BBT.Workflow.Domain/Instances/{InstanceIncident,Instance}.cs` (`Unfault`, `Resolve`),
  `src/BBT.Workflow.Domain/Instances/DTOs/GetInstanceOutput.cs` (`IncidentInfoDto`, `IncidentDetailDto`, `GetInstanceIncidentsOutput`),
  `src/BBT.Workflow.Application/Instances/{InstanceRetryAppService,InstanceQueryAppService}.cs`,
  `src/BBT.Workflow.Application/Instances/DTOs/{RetryInstanceInput,RetryInstanceOutput,GetInstanceInput}.cs`,
  `src/BBT.Workflow.Domain/Definitions/InstanceUrlTemplates.cs`, `src/BBT.Workflow.Domain/WorkflowErrorCodes.cs` (`Instance:100027`, `Instance:100037`)
- vnext-docs: `concepts/incidents.md`, `how-to/error-handling.md`, `components/functions/built-in.md`
- PRs: #972 (0.0.92 incidents table + link block), #1026 (0.0.95 failed subflow start faults parent)
- vnext-meta: feature `stateIncident`; migrations `instance-incidents-moved-to-separate-table`,
  `incident-and-retry-behaviour-corrections`; known issue `pre-reserved-job-failure-can-strand-busy`
- Related: `observability.md` (trace recipe), `runtime-operations.md` (lock model, Busy recovery),
  `transition-pipeline.md` (error boundary steps), `instance-query.md`
