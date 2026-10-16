# State Function Response — shape v14

> `GET /api/v1/{domain}/workflows/{wf}/instances/{id|key}/functions/state` — the one endpoint a
> client drives a workflow from. Runtime 0.0.100, `StateFunctionCache.ResponseShapeVersion = "v14"`
> (v13 in 0.0.98: `terminate: false` interaction block; v14 in 0.0.99: labels and transition targets).
> Wire names below are exact: the list is **`transitions`**, not `availableTransitions` (that is
> the internal/docs name). Transitions are executed with **`PATCH`** `…/instances/{id}/transitions/{key}`
> (`docs/contracts/api-and-service-contracts.md` says POST — stale).

## 1. Request

| Input | Where | Notes |
|-------|-------|-------|
| `If-None-Match` | header | conditional GET → 304 |
| `role`, `act_sub`, `sub` (+ `position`, `client_id`) | headers | caller credential; `role` (or `?role=`) is the role set under `default`; identity drives `$InstanceStarter` & co. (`roles-and-authorization.md`) |
| `version` | query | pin a flow version; bypasses cache |
| `extensions` | query | only carried into `data.href`; the state function never runs extensions |

## 2. Body (annotated)

```jsonc
{
  "data":   { "href": "/api/v1/core/workflows/loan/instances/{id}/functions/data" },
  "view":   { "href": "…/functions/view", "hasView": true, "loadData": true },
  "master": { "href": "…/functions/master" },
  "state": "waiting-approval",          // may be a role-aware alias label (workflow-types.md §2.1)
  "stateType": "intermediate",          // camelCase: initial|intermediate|finish|subFlow|wizard
  "stateSubType": "human",              // 0.0.99: none|success|error|terminated|suspended|busy|human|cancelled|timeout
  "stateLabels": [ { "language": "en-US", "label": "Waiting for approval" } ],   // 0.0.99; omitted when none
  "status": { "code": "A", "description": "Active" },   // = effectiveStatus: deepest active SubFlow's status

  "activeCorrelations": [ /* subset of correlations[] with isCompleted=false */ ],
  "correlations": [                     // active + completed, createdAt asc (#856)
    {
      "correlationId": "…", "parentState": "kyc", "subFlowInstanceId": "…",
      "subFlowType": "S", "subFlowDomain": "core", "subFlowName": "kyc-check", "subFlowVersion": "1.0.0",
      "isCompleted": true, "completedAt": "…", "terminalOutcome": "Completed",   // Completed|Faulted|Canceled
      "createdAt": "…", "status": { "code": "C" }, "currentState": "kyc-done", "stateChangedAt": "…",
      "href": "…/instances/{childId}/functions/state"
    }
  ],

  "transitions": [                      // role-filtered, availableIn-filtered; only for Active instances
    { "name": "approve", "kind": "stateTransition", "href": "…/transitions/approve",
      "labels": [ { "language": "en-US", "label": "Approve" } ],          // 0.0.99; omitted when none
      "target": { "key": "approved", "stateType": "intermediate", "stateSubType": "none",
                  "labels": [ { "language": "en-US", "label": "Approved" } ] },   // 0.0.99, $self resolved
      "view": { "href": "…", "hasView": true, "loadData": false },
      "schema": { "href": "…", "hasSchema": true },
      "annotations": { "ui/intent": "confirm", "ui/priority": "1" } },
    { "name": "leave-process", "kind": "exit", "href": "…" },        // configured key, never the alias
    { "name": "update-loan", "kind": "updateData", "href": "…" },
    { "name": "remind", "kind": "scheduled", "executeAtUtc": "2026-09-28T10:00:00Z",
      "href": "…" }                                                   // NOT callable; System actor fires it
  ],

  "functions": { "hasFunctions": true, "href": "…/functions/catalog" },
  "interaction": {                      // terminate:true → only while the ack is outstanding (with ack);
    "terminateLongPoll": true,          // terminate:false → whenever in the state, NO ack (0.0.98)
    "fallbackTimeoutSeconds": 60,
    "ack": { "href": "…/instances/{id}/longpoll/ack" }
  },
  "incident": { "hasActiveIncident": false, "history": { "href": "…/incidents" } },
  "timeout": {                          // workflow-level deadline; absent when not armed / terminal
    "key": "abandon",
    "target": { "key": "expired", "stateType": "finish", "stateSubType": "timeout" },   // object since 0.0.99 (was a string)
    "executeAtUtc": "…", "annotations": { "ui/countdown": "deadline" }
  },
  "etag": "\"3f9c…\"", "entityEtag": "\"a1b2…\""
}
```

### `transitions[].kind`

| kind | Source | Callable |
|------|--------|----------|
| `stateTransition` | current state's `transitions[]` | yes |
| `sharedTransition` | `sharedTransitions[]` | yes |
| `cancel` / `exit` / `updateData` | workflow-level well-known transitions, listed by **configured key** | yes |
| `scheduled` | active timer jobs of the current state, appended last, **not** role-filtered | **no** — informational (`executeAtUtc`) |

A state passed through by an auto winner never shows `scheduled` entries (Auto 80 runs before
Schedule 90 — `transition-pipeline.md`). While in a SubFlow state, the **parent's** cancel/exit/
updateData are merged into the child's list.

### Labels and targets (v14, 0.0.99, PR #1070)

- `stateSubType` / `stateLabels` describe the **displayed** state (the active SubFlow's state while one
  runs, like `stateType`). Labels are the definition's full `[{ language, label }]` list — the client
  picks the language; omitted when the definition declares none.
- Every `transitions[]` entry, `scheduled` ones included, carries `labels` and
  `target { key, stateType, stateSubType, labels, subFlow }`. `$self` is resolved to the listing state;
  `subFlow` (the started flow's key) appears only when the target is a SubFlow state; an unresolvable
  target keeps the raw `key` with every other member null.
- `timeout.target` is the **same object**, no longer a string — clients reading `timeout.target` as
  text break on 0.0.99+.
- View, schema and master functions return the component's `labels`; catalog `functions[]` entries
  carry `labels`. Schema/master function caches have their own shape version (**v2**).

### `status`

`status` is the client-visible status = the **deepest active SubFlow's** status (`EffectiveStatus`,
#983). There is no separate `effectiveStatus` field in this body; it lives in instance GET/list
`metadata`. `A` Active, `B` Busy, `C` Completed, `F` Faulted, `P` Passive.

### `incident`

`hasActiveIncident`, optional `active: { href }` (points at the **owning** instance — a faulted
child's href goes to the child), `history: { href }` (always the polled instance). Details in
`incidents-and-retry.md`.

## 3. ETag, 304 and polling

- Response headers: `ETag` (body fingerprint) and `X-Entity-ETag` (instance-data ETag). Send
  `If-None-Match: <ETag>` → **304** when unchanged.
- ETag material (`ComputeEtagCore`): shape version, id, effective state, status, effective status,
  flow version, caller-scope hash (roles, actor `act_sub`, subject `sub` (0.0.99), extensions, headers,
  version), displayed SubFlow
  state/status, correlation counts, last correlation completed-at / state-changed-at,
  `hasActiveIncident`.
- **Known gap #864:** scheduled-job changes are **not** in the ETag. A same-state timer re-arm can
  leave `scheduled.executeAtUtc` stale behind a 304. Re-fetch without `If-None-Match` when the
  countdown matters.
- `entityEtag` can be stale after `updateData` (data is not in the state fingerprint).
- **The server never holds the request open.** "Long-poll" means: client sends conditional GET,
  gets 200/304 immediately, waits, repeats. Stop when `status.code` is terminal, or when
  `interaction.terminateLongPoll` is true (then ack — `long-poll-interaction.md`). With
  `terminateLongPoll: false` keep polling for `interaction.fallbackTimeoutSeconds`.
- A shape-version bump (v12 → v13 → v14) changes every ETag once: clients parked behind a 304 get a
  single 200 after an upgrade.
- Instances with an active SubFlow skip the 304 fast path and serve a ≤500 ms snapshot
  (`ActiveSubflowTtlMilliseconds`); correctness comes from the `EffectiveStatus` fingerprint.
- Rule-gated `interaction` bodies are never stored in the shared body cache.

## 4. `metadata` on instance GET / list

`GET …/instances/{id}` and `GET …/instances` return `metadata` (`InstanceMetadataDto`):

| Field | Meaning |
|-------|---------|
| `currentState`, `effectiveState` | this instance's state / deepest active child's state |
| `status`, `effectiveStatus` | raw vs clamped: `Status.IsTerminal || EffectiveStatus.IsTerminal ? Status : EffectiveStatus` |
| `type` | `R` root, `S` SubFlow child, `P` SubProcess child — set once at creation; list filter column is `instanceType` |
| `currentStateType/SubType`, `effectiveStateType/SubType` | e.g. `subType` 6 = human task (`human-task.md`) |
| `stage`, `createdAt`, `modifiedAt`, `completedAt`, `duration` (seconds) | |
| `createdBy`, `createdByBehalfOf`, `modifiedBy`, `modifiedByBehalfOf` | |
| `incident` | same block as the state body |

Async `202` transition responses do **not** carry `effectiveStatus`; poll the state function.

## 5. Client loop (reference)

1. Start (`POST …/instances/start?sync=true`) → read `id`.
2. GET state with `If-None-Match`. 304 → wait, repeat.
3. 200: render `view.href` if `hasView`; offer `transitions[]` where `kind ≠ "scheduled"`; show
   countdowns from `scheduled.executeAtUtc` / `timeout.executeAtUtc`.
4. `interaction.terminateLongPoll === true` → stop, render, POST `ack.href`, resume polling;
   `false` → keep polling, window = `fallbackTimeoutSeconds`.
5. `incident.hasActiveIncident` → read `incident.active.href`, offer retry.
6. User picks a transition → **PATCH** `href` with the body validated by `schema.href`.
7. Stop when `status.code ∈ {C, F, P}`.

## Pitfalls

- Reading `availableTransitions` → undefined; the property is `transitions`.
- Calling a `kind: "scheduled"` href → error; it is not a user transition.
- `interaction` missing does not mean the state has no `longPoll`: for `terminate: true` nothing is
  pending, and for either mode the caller may have failed the `rule` / `roles` gate.
- Expecting `ack` on a `terminateLongPoll: false` block → it is never there; nothing is armed.
- Treating `timeout.target` as a string → it is an object since 0.0.99; read `timeout.target.key`.
- Rendering `target.labels` / `stateLabels` as one string → they are arrays per language.
- `status` on a parent with a running child is the **child's** status; use `metadata.status` for
  the parent's own row.
- `timeout` is absent (not `null`) when no deadline is armed; it ignores child deadlines.

## Sources

- Runtime `vnext` @ `f06961ec` (0.0.100): `src/BBT.Workflow.Application/Instances/DTOs/{GetInstanceStateOutput,InstanceInteractionOutput,InstanceTimeoutOutput}.cs`,
  `src/BBT.Workflow.Domain/Shared/HrefBase.cs` (`TransitionItem`, `TransitionTarget`), `Caching/{InstanceSchemaFunctionCache,CallerScopeHash}.cs`, `src/BBT.Workflow.Domain/Instances/DTOs/GetInstanceOutput.cs` (`InstanceMetadataDto`),
  `InstanceQueryAppService.BuildInstanceStateOutputAsync`, `Caching/StateFunctionCache.cs` (`ResponseShapeVersion`, `ComputeEtagCore`),
  `orchestration/.../StateFunctionHandler.cs`, `orchestration/.../InstanceController.cs` (`HttpPatch …/transitions/{transitionKey}`),
  `docs/runtime/state-function-cache-and-etag.md`, `docs/domain/well-known-transitions.md`
- vnext-docs: `components/functions/built-in.md`, `how-to/async-sync.md`, `blog/2026-10-01-v0-0-98.md`, `blog/2026-10-05-v0-0-99.md`
- PRs: #856 (correlations history), #859 (well-known kinds), #864 (scheduled ETag gap, accepted), #983 (effectiveStatus), #1021/#1029 (timeout block), #1051 (v13), #1070 (v14 labels/targets)
- vnext-meta: `wellKnownTransitionDiscovery` 0.0.79, `stateCorrelationHistory` 0.0.77, `stateScheduledTransitions` 0.0.80, `stateIncident` 0.0.92, `stateWorkflowTimeout` 0.0.95, `stateAnnotations` 0.0.95, `instanceEffectiveStatus` 0.0.94, `instanceStartType` 0.0.94
