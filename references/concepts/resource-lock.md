# Resource Lock — `transition.resourceLock` (business-resource mutex across instances)

> Transition-level `resourceLock` serialises **different instances** that touch the same business
> resource (an account, a limit, a customer). It is not the instance mutex — one instance is already
> serialised by Busy (`transition-pipeline.md` §3). Conflict policy `Reject`, error-boundary rerouting,
> commit-time release, the Postgres lease provider and the publish rules in §5 are runtime **0.0.106+**
> (vnext #1143, features `resourceLockConflictPolicy`, `pipelineErrorBoundaryRouting`,
> `resourceLockPostgresProvider`), schema package **0.0.61+** for `onConflict: "Reject"`.

## 1. Contract

```json
"resourceLock": {
  "keyExpression": { "location": "./src/LimitLockKey.csx", "code": "<base64>" },
  "action": "Acquire",
  "ttlSeconds": 120,
  "onConflict": "Reject"
}
```

| Field | Values | Notes |
|---|---|---|
| `keyExpression` | script slot (required) | Compiled as **`ITransitionMapping`**; `Handler(ScriptContext)` returns the key (`result.ToString()`). Empty / whitespace → `Execution:200011`; a throw → `Execution:200012`. Both fault the instance. Build the key from instance data / body, prefix it with the resource kind (`limit:{customerNo}`). |
| `action` | `Acquire` · `Release` · `Extend` (required) | Owner is the **instance id**. |
| `ttlSeconds` | integer, default 300 | Safety net for abandoned locks. Must be **> 0** for `Acquire` / `Extend` (publish error since 0.0.106; `Release` is exempt). Size it to the whole protected section. |
| `onConflict` | `Abort` (default) · `Reject` (schema 0.0.61+) | What losing the `Acquire` race means — §2. |

Allowed on start, state-level and shared transitions (the schema says so). The step runs at pipeline
order 25 (`transition-pipeline.md` §2), **before** OnExecute, ChangeState and OnEntry: a lost race never
leaves partial work behind.

`context.Caller` is not available in `keyExpression` (it is an `ITransitionMapping` —
`csx-contracts.md` § Caller roles).

## 2. Losing the race — pick the policy

| Policy | Instance afterwards | Caller gets | Use when |
|---|---|---|---|
| `Abort` (default) | **Faulted** (`F`); the contended work is lost | `409 Execution:200010` | Losing really is a failure, and a new instance is the retry |
| `Reject` (0.0.106+) | **Untouched** — same state, Active, no incident, Busy handed back | `409 Execution:200014` (log 10263) | Losing is a normal "not your turn"; the client repeats the **same** call later |
| `Abort` + `errorBoundary` rule for `Execution:200010` with a `transition` (0.0.106+) | **Rerouted** — the target transition runs as the next hop from the state the instance never left; an incident with `errorLayer: Pipeline` is written (log 10264) and resolved when the reroute lands | no 409 — the chain continues | The process should wait on its own: route to a parking state with a scheduled retry |

Client guidance for the two 409s — they look alike and mean opposite things:

- `Execution:200010` → the instance is dead. Start a new instance (or `retry` it after an incident review).
- `Execution:200014` → nothing happened. Back off and send the identical request again.

`Reject` and rerouting are runtime 0.0.106+. On an older runtime `onConflict: "Reject"` fails
`npm run validate` (schema ≤ 0.0.60 enum is `["Abort"]`), and a boundary rule naming
`Execution:200010` never fires — lock conflicts bypassed the boundary engine and always faulted.

### 2.1 Rerouting through `errorBoundary`

```json
"errorBoundary": {
  "onError": [
    { "errorCodes": ["Execution:200010"], "action": 2, "transition": "wait-for-limit", "priority": 10 }
  ]
}
```

- Only `Execution:200010` is boundary-routable (`BoundaryRoutableErrorCodes`). `200011`/`200012`/
  `200013` (key/action failures) still fault; `200014` is never routed (it is not a failure).
- Same chain as task errors: state boundary first, then the workflow's. Task boundaries are not
  consulted (a lock conflict never comes from a task).
- Any matching rule that names a `transition` reroutes — usually `Rollback` (2) or `Notify` (4). A
  matching rule without a transition, or no match, faults as before.
- **Retry is refused at publish** for a rule naming `Execution:200010` or `Execution:200014`: the step
  would re-run while the lock is still held and fail the same way until the budget runs out.
- A **state** boundary may only route to a transition available **from that state** (declared on it, a
  shared transition whose `availableIn` holds it or is empty, or the workflow's `cancel`/`exit`/
  `updateData`). For a rule naming a lock code this is a publish **error**; for other rules a warning.
- The **ErrorBoundary pipeline profile skips the ResourceLock step**: a `resourceLock` on the target
  transition never runs when it is reached through the boundary (publish **warning**). Put the
  re-acquire on the transition that leaves the parking state instead.
- The profile keeps the Schedule step, so the parking state's timer is armed — that is the pattern:

```
[reserve] --(Acquire, Abort)--> [reserved]
    │ 200010 → boundary → wait-for-limit
    ▼
[waiting-for-limit] --(timer PT30S, Acquire again)--> [reserved]
```

Cap the loop (a counter in instance data plus a give-up transition) — a lock that never frees otherwise
keeps the instance parking forever.

## 3. Release, Extend and lifetime

- **Acquire** records the key on the instance (`resource.locks` metadata, plus the acquisition time
  in `resource.locks.acquiredAt` since 0.0.106).
- **Release** is best-effort and never fails the transition: an expired / already-released lock is a
  no-op, a lock owned by someone else is logged (10104), not faulted.
- **Terminal cleanup:** when the instance reaches a final state every tracked lock is released. Since
  0.0.106 this runs **after the commit** of the terminal transition (unit-of-work `OnCompleted`), not
  through the outbox → inbox cancel-cleanup event (that path stays as an idempotent backstop). Before
  0.0.106 a stalled event chain left locks standing until their TTL. An explicit `Release` is still the
  clearer design when the protected section ends before the flow does.
- **Extend** fails with `Execution:200010` (faulting, or boundary-routable) when it cannot extend —
  `onConflict` does not apply to it. With the **Dapr** provider (default) Extend cannot work while the
  lock is held: the Redis lock component uses `SET NX`, so it fails as long as the lock is alive and only
  "succeeds" after the TTL expired (a new race, not an extension). Size `ttlSeconds` for the whole
  section instead, or run the **Postgres** provider (§4), where Extend is one atomic
  `owner AND not expired` update.
- A rolled-back transition keeps an acquired lock until its TTL (the key was never persisted).

## 4. Provider (operations, 0.0.106+)

`ResourceLock:Provider` (env `ResourceLock__Provider`) = `dapr` (default, Dapr lock building block,
`DAPR_LOCK_STORE_NAME`) or `postgres` (leases in `sys_queues."DistributedLocks"`, `wfres:` key prefix,
no Dapr lock component; needs `ConnectionStrings:Default`). Any other non-empty value **fails host
startup** ("Unknown ResourceLock:Provider"). The domain does not choose this — it is a platform
deployment value (vnext-helm-charts handoff `resource-lock-provider.md`). A flow that relies on
`Extend` must say so in its README so operations runs `postgres`.

## 5. Publish rules (runtime 0.0.106+, not in the schema)

| Rule | Severity |
|---|---|
| `ttlSeconds` ≤ 0 on `Acquire` / `Extend` | error |
| `errorBoundary` rule with `action: 1` (Retry) whose `errorCodes` name `Execution:200010` / `Execution:200014` | error |
| State boundary rule naming a lock code routes to a transition not available from that state | error (warning for other codes) |
| Boundary rule routes to a transition that declares `resourceLock` (the lock never runs that way) | warning |

`npm run validate` checks none of them (`schema-runtime-gaps.md` § Publish-time rules); domain-check
check 22 flags them offline.

## 6. Observability

- Histogram `workflow_resource_lock_hold_duration_ms` (tags `vnext.domain`, `vnext.flow.key`) —
  acquire → release. Alert on upper percentiles **approaching `ttlSeconds`**: that is a release that
  only happened when the TTL ran out, and every queued instance burns its retries against nobody.
  Instances started before 0.0.106 have no acquisition time and are skipped.
- Logs: 10100 acquired, 10101 conflict, 10102 release no-op, 10103 released, 10104 release failed,
  10105 auto-release errored, 10263 rejected without faulting, 10264 rerouted by error boundary.

## 7. Design checklist

1. Is the lock protecting a cross-instance resource? (Not the instance itself — Busy does that.)
2. Key = resource kind + business id, never the instance id.
3. Losing the race: dead (`Abort`), retry-the-call (`Reject`), or wait in the process (Abort + boundary)?
4. `ttlSeconds` covers the whole section (Extend only with the Postgres provider).
5. Where is it released — explicit `Release` transition, or terminal cleanup?
6. Boundary target has no `resourceLock` of its own; parking loop has an exit.
7. Tests: one instance holds, a second one gets the chosen outcome (`integration-test-patterns.md`
   § Resource-lock conflicts).

## Sources

- Runtime `vnext` @ `10d0e387` (v0.0.106): PR #1143 — `ResourceLockStep.cs`, `HandleFinishStep.cs`,
  `TransitionPipeline.cs` (`NonFaultingErrorCodes`, `BoundaryRoutableErrorCodes`,
  `TryRouteByErrorBoundary`), `WorkflowValidator.ValidateResourceLocks`, `WorkflowErrorCodes.cs`,
  `DaprResourceLockService.cs`, `NpgsqlResourceLockService.cs`, `WorkflowMetrics.cs`;
  `docs/integration/vnext-helm-charts/resource-lock-provider.md`
- vnext-schema 0.0.61: `workflow-definition.schema.json` `#/definitions/resourceLockDefinition` (PR #162)
- vnext-meta 0.0.106: features `resourceLockConflictPolicy`, `pipelineErrorBoundaryRouting`,
  `resourceLockPostgresProvider`
- vnext-docs `how-to/resource-lock.md` (describes the pre-0.0.106 behaviour at the time of writing)
