# Transition Pipeline — Order, Admission, `updateData`, Annotations

> Author-facing view of what happens between `PATCH …/transitions/{key}` and the next state
> function response. Runtime 0.0.97. For the state-function body itself see
> `state-function-response.md`; for locking error codes see `runtime-operations.md`.

## 1. Lifecycle order (`LifecycleOrder.cs`)

| Order | Step | What an author sees |
|------:|------|---------------------|
| 5 | Preflight | `cancel`/`exit` detection; already-terminal instance short-circuits |
| 10 | ForwardToActiveSubflow | Parent transition is forwarded to the open SubFlow child. **Never** forwards `updateData` or a parent shared `$self` transition |
| 19 | SetBusy | Instance → Busy for the rest of the chain (Normal kind only) |
| 20 | CreateTransition | Transition record; duplicate-job guard |
| 21 | UpdateDataDataOnly | `updateData` on a parent with an open SubFlow correlation: write data, jump to Finalize |
| 25 | ResourceLock | Business resource lock acquire/release/extend |
| 30 | OnExecute | `transition.onExecutionTasks` |
| 38 | ApplyTimeoutState | Workflow `timeout` fired: set target before exit hooks |
| 39 | CancelScheduledJobs | Tear down the abandoned state's timer jobs |
| 40 | OnExit | `state.onExits` of the abandoned state |
| 50 | ChangeState | Persist current/effective state |
| 60 | OnEntry | `state.onEntries` of the target state |
| 70 | SubFlow | `stateType: 4` → create correlation, start child (sync since 0.0.91) |
| 75 | LongPollTermination | `interaction.longPoll.terminate: true` → pause here, instance stays Busy (see `long-poll-interaction.md`) |
| 79 | ClearBusyOnResume | SubFlow resume / long-poll ack re-entry clears Busy |
| **80** | **Auto** | Evaluate `triggerType: 1` transitions; a winner requests the next hop |
| **90** | **Schedule** | Arm `triggerType: 2` timers — **skipped when Auto picked a winner** |
| 100 | Finish | Final state → Completed / Cancelled |
| 110 | Finalize | Close the transition record |
| 111 | AfterEpilogueRefresh | Reload projections |
| 112 | ResolveAvailable | Busy → Active when the target has only manual/event transitions |

**Auto before Schedule (PR #943, 0.0.90).** Consequences:

- If an auto rule is satisfied on entry, the state's timers are **never armed** (log 10156) — the
  chained hop would have cancelled them at 39 anyway.
- If the Auto step throws, no timer is armed either; the instance faults with an incident.
- A state that is passed through by an auto winner never shows a `kind: "scheduled"` entry.
- vnext-meta `selfTargetPipelineProfile` still says "Schedule (80)" — stale; trust the table above.
- Fixture: `vnext-example/core/Workflows/schedule-after-auto/` (`gate` state: auto `auto-advance`
  + timer `gate-timeout`; `mode: "auto"` in data suppresses the timer).

Profiles remove irrelevant steps per trigger type (AutoChain drops 5/10/19/38, Scheduled/Event drop
5/10, ErrorBoundary drops 5/10/25 and never pauses at 75). The profile is chosen from the
**inbound** trigger type, not the transition definition.

## 2. Admission kinds (`ITransitionAdmissionService.cs`)

Busy is the mutex. The first hop does an Active→Busy compare-and-set under a ~5 s status lock; the
pipeline and its auto-chain then run lock-free.

| Kind | Who | Busy check | Status flip | Client sees when instance is Busy |
|------|-----|-----------|-------------|-----------------------------------|
| `Normal` | state / shared transitions | yes | Active→Busy reserve | **409** `Instance:100031` "Instance is busy…" |
| `BypassBusyCheck` | `cancel`, `exit`, workflow `timeout` | exempt | unconditional flip at accept time | accepted |
| `Unconditional` | `updateData` | none | none — status-neutral | accepted; N parallel requests all accepted (no lock, no duplicate guard — PR #917, 0.0.86) |
| `OwnerReentry` | background job, SubFlow resume, long-poll ack | none | none (already owns Busy) | n/a |

Error-boundary transitions re-enter a Busy instance as the owner (#892). Same async transition
queued twice → 409 `Transition:100009`. See `runtime-operations.md` for the full 409/503 catalogue.

## 3. `updateData` semantics

Declared once at workflow level; request alias `update-parent-data` is still accepted, but the
state function lists the **configured key**.

### Plain instance (no open SubFlow) — `+Self` profile

Runs: data write → OnExecute (30) → ChangeState (50, no-op to `$self`) → Auto (80) → Finish/Finalize.
**Skips** 39 CancelScheduledJobs, 40 OnExit, 60 OnEntry, 90 Schedule — no state is left or entered,
so timers stay armed and entry hooks do not re-fire.

Only `updateData` gets this skip (PR #884, 0.0.80). Any other transition with `target: "$self"`
(typically a shared transition) keeps its base profile and runs the **full** lifecycle: OnExit/OnEntry
fire, timers are torn down and re-armed. A literal self-loop (`target` = the current state key) is
not `$self` and also runs the full lifecycle.

### Parent with an open SubFlow correlation — data-only

Step 21 writes the data and jumps to Finalize. No tasks, no auto evaluation, **no forward to the
child**, child never restarted. Use it to enrich parent data while a child runs; it cannot advance
either instance.

### Discovery and gates

- Listed in `transitions[]` with `kind: "updateData"` (also `cancel` / `exit`), filtered by
  `roles` and `availableIn` (PR #859, 0.0.79).
- Execution enforces the `availableIn` **state** gate (`Transition:100024` outside it) but **not**
  roles — roles scope what the client is offered, everywhere.
- Every accepted `updateData` writes **two data rows** (request payload + task output).
- `entityEtag` / `X-Entity-ETag` may stay **stale** after `updateData` — data is not part of the
  state fingerprint. Read the data function without `If-None-Match` after a write.

### Schema (`#/definitions/updateDataTransition`, `additionalProperties: false`)

| Field | Required | Constraint |
|-------|----------|------------|
| `key`, `labels`, `versionStrategy` | yes | `key` matches `^[a-z0-9-]+$` |
| `target` | yes | `const "$self"` |
| `triggerType` | yes | `const 0` (manual) |
| `availableIn` | no | bare state keys or `{state, roles}`; roles AND with `roles` |
| `roles`, `annotations`, `view`, `schema`, `mapping`, `onExecutionTasks`, `from` | no | same as any transition |

```json
"updateData": {
  "key": "update-timeout-lab-root",
  "target": "$self",
  "triggerType": 0,
  "versionStrategy": "Major",
  "labels": [{ "language": "en-US", "label": "Update Timeout Lab Root Data" }],
  "annotations": { "ui/source": "updateData" }
}
```

### Design patterns

- **Parallel branches / fan-in / loops:** route all concurrent writes through `updateData`; normal
  transitions 409 against each other. Auto rules on the state evaluate after every accepted write,
  so "accumulate, advance at threshold" works under a write storm.
- **Mappings return delta only.** Each write persists immediately; echoing the full instance data
  overwrites fresher concurrent values with stale ones.
- **Distinct task definitions per parallel branch at the same `order`.** The task journal key is
  `transition+task+order`; two branches sharing a task at one order collide.
- `cancel`/`exit` always get through; do not build "abort" states on a normal transition.

## 4. Annotations

`#/definitions/annotations`: string-valued object, namespaced keys, pure passthrough — the runtime
never interprets values. Surfaces on `transitions[].annotations` and `timeout.annotations` in the
state function (0.0.95, shape v12); `kind: "scheduled"` entries carry the arming transition's
annotations.

| Declared on | Allowed |
|-------------|---------|
| state `transitions[]`, `sharedTransitions[]`, `cancel`, `exit`, `updateData` | yes |
| workflow `timeout.annotations` | yes — a `subFlow.overrides.timeout` replaces the child's timeout **including** annotations |
| `startTransition` | **no** (schema rejects) |

Defined keys (vnext-docs): `ui/visibility-channel` (pipe-separated: `IbWeb`, `backoffice`,
`IbIvnApp`), `ui/priority` (integer as string, lower = higher), `ui/intent` (`cancel`, `destructive`,
`close`, `confirm`). Anything else is free-form.

```json
"timeout": {
  "key": "root-abandoned",
  "target": "root-timedout",
  "versionStrategy": "Minor",
  "timer": { "reset": "never", "duration": "PT20S" },
  "annotations": { "ui/countdown": "root-deadline" }
}
```

## 5. Extensions are READ-only surfaces (PR #984, 0.0.93)

`sync=true` start/transition responses always carry `"extensions": {}`; `?extensions=` on those two
endpoints is ignored. Extensions run on instance GET, list, `functions/data?extensions=` and the
extensions endpoint. Need an extension value after a write? Call the data function.
Meta: migration `sync-response-no-longer-carries-extensions`, deprecation
`start-transition-extensions-query-parameter-removed`.

## Pitfalls

- Auto rule true on entry → timer never armed. Do not rely on a timer as a "backstop" for a state
  whose auto rule can be satisfied immediately.
- `updateData` on a parent with an open child cannot advance anything — put threshold logic on the
  child or use a shared `$self` transition (full lifecycle).
- A `$self` shared transition re-arms timers and re-runs OnEntry; move idempotent-only logic to
  `onExecutionTasks`.
- Reading `extensions` from a transition response is always `{}` since 0.0.93.

## Sources

- Runtime `vnext` @ `eca5b466` (0.0.97): `src/BBT.Workflow.Execution/Pipeline/LifecycleOrder.cs`,
  `src/BBT.Workflow.Execution/Pipeline/ITransitionAdmissionService.cs`,
  `Pipeline/Steps/{HandleUpdateDataDataOnlyStep,ForwardToActiveSubflowStep}.cs`,
  `docs/domain/well-known-transitions.md`, `docs/domain/extensions.md`
- Schema `vnext-schema` @ `ac42026` (0.0.54): `#/definitions/{updateDataTransition,annotations,availableInEntry,workflowTimeout}`
- vnext-docs @ `adf9bf4`: `concepts/transition-pipeline.md`, `components/workflow.md` §Annotations, §Transition Yürütme Modeli
- Fixtures `vnext-example` @ `3b5ebab`: `core/Workflows/timeout-lab/timeout-lab-root.json`, `core/Workflows/schedule-after-auto/`
- PRs: #877 (Busy-as-mutex), #884 (`+Self` only for updateData), #859 (well-known discovery), #917 (updateData no lock/guard), #943 (Auto 80 before Schedule 90), #984 (extensions read-only)
- vnext-meta: `wellKnownTransitionDiscovery` 0.0.79, `selfTargetPipelineProfile` (stale order note), `stateAnnotations` 0.0.95
