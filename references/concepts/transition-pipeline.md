# Transition Pipeline — Order, Admission, `updateData`, Annotations

> Author-facing view of what happens between `PATCH …/transitions/{key}` and the next state
> function response. Runtime 0.0.105 (rule-based payload schemas §1.1). For the state-function body itself see
> `state-function-response.md`; for locking error codes see `runtime-operations.md`.

## 1. Lifecycle order (`LifecycleOrder.cs`)

| Order | Step | What an author sees |
|------:|------|---------------------|
| 5 | Preflight | `cancel`/`exit` detection; already-terminal instance short-circuits |
| 10 | ForwardToActiveSubflow | Fallback only since 0.0.100: a forwardable parent transition is normally **proxied to the leaf before the pipeline starts** (no parent lock/Busy/job — `runtime-operations.md` §1). **Never** forwards `updateData`, `cancel`, `exit`, timeout or a parent shared transition available in the parent's state |
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
| **80** | **Auto** | Evaluate `triggerType: 1` transitions one by one — `priority` ascending (absent = 100), then declaration order, `triggerKind: 10` last (0.0.102); the first satisfied rule wins and requests the next hop |
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

### Sync or async — `executionType` (0.0.99, #1037)

Which mode a request runs in is decided **before** admission:

```
effective = transition.executionType ?? flow.executionType ?? caller ?sync (default false = async)
```

| Where | Field |
|-------|-------|
| flow | `attributes.executionType` |
| state transition, `sharedTransitions[]`, `startTransition` | `executionType` |
| `cancel`, `exit`, `updateData` | not available |

`S` → `200` + full instance; `A` → `202` + `{ id, status }`. A definition value **overrides** `?sync`,
so clients must branch on the HTTP status. Not applied to auto transitions (always inline in the
chain), scheduled transitions, workflow timeouts, retry, SubFlow start/forward/resume/cancel/fault and
the long-poll ack. A SubFlow proxy resolves the mode once at the parent and calls the leaf in it.
Spans tag `vnext.execution.requested` / `vnext.execution.effective` and `vnext.execution.overridden=true`
when the definition changed the caller's mode. Use it when a step must never depend on the caller
(e.g. an always-sync validation, an always-async long call). Async bodies are capped at **10 MB**
(Kestrel `MaxRequestBodySize`, `413`) since 0.0.99.

### 1.1 Payload schema — `schema` or rule-based `schemas` (0.0.105, #1225; schema 0.0.60)

Every transition kind (state, shared, `startTransition`, `cancel`, `updateData`, `exit`) validates its
request body against **`schema`** (one `sys-schemas` reference, unchanged) or **`schemas`** — a
rule-based list mirroring `view` / rule-based views and the function `inputSchema`:

```jsonc
"schemas": [
  { "rule": { "location": "./src/IsCorporateRule.csx", "code": "<base64>", "encoding": "B64" },
    "schema": { "key": "corporate-payload", "domain": "core", "flow": "sys-schemas", "version": "1.0.0" } },
  { "schema": { "key": "retail-payload", "domain": "core", "flow": "sys-schemas", "version": "1.0.0" } }
]
```

| Rule | Detail |
|---|---|
| Shape | plain array (`minItems: 1`) or the wrapped `{ "schemas": [ … ] }` the runtime writes back; an entry is `{ rule?, schema }`, `additionalProperties: false` |
| Order | declaration order, **first matching `rule` wins**; a rule-less entry always matches → it must be **last** (the fallback). A rule-less entry anywhere else is a **publish** error (`WorkflowValidator`); the schema does not catch it |
| Precedence | `schemas` wins over `schema` when both are present — declare one |
| Not allowed on | automatic (`triggerType: 1`) and scheduled (`2`) transitions — the schema forces `null` there |
| Rule | an `IConditionMapping` script; context = workflow, instance, runtime, transition, `body` (the instance's **latest data**, `{}` when none — *not* the request body), the request **headers** and the caller's resolved roles through **`context.Caller`** (`await context.Caller.HasRoleAsync("x")`, #1299 — never parse `Headers.role`); no query parameters. If a rule reads roles and the provider fails → `503 Authorization:110006`, never the fallback (`csx-contracts.md` § Caller roles) |
| Write path | nothing declared → accepted; declared, no entry matches → **`400 Transition:100025`**, instance stays in its state (not faulted, no transition row) |
| Order vs. other checks | the schema (and its rule) is resolved **before** the state-machine / actor policy, so a wrong-state request with no matching entry gets `Transition:100025` first |
| Read path | the instance `schema` function serves the matched entry, `404` on no match; `hasSchema` in `transitions[]` is **declared-only** (`schema` or a non-empty `schemas`), like `hasView` |
| Cache | the schema-function cache key and ETag hash the non-volatile request headers (`RequestHeaderHash`), so a header-driven rule never serves another caller's entry or a false `304` |

Design guidance: use `schemas` when **one transition** takes differently shaped bodies (retail vs
corporate, channel-specific forms, a role-specific contract via `context.Caller`). Selecting a schema by
role is not authorization: test positively and keep the fallback the **least privileged** contract. Keep a rule-less fallback last unless refusing every unmatched
caller is the point; then write that intent down in the design. Needs schema ≥ 0.0.60 **and** runtime ≥
0.0.105: on schema ≤ 0.0.59 `schemas` fails validate on `startTransition` / `cancel` / `exit` /
`updateData` (`additionalProperties: false`) but passes **unchecked** on state and shared transitions
(open objects — gap D15), and a runtime ≤ 0.0.104 ignores it, so the payload is not validated at all.

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
- **Parallel branches at the same `order` need distinct response slots.** Same-order entries run in
  parallel and merge by slot = `variableKey ?? camelCase(task.key)`. The same task twice at one order
  (e.g. two SubProcess starts) needs a `variableKey` on at least one entry (0.0.99, #1072; pattern
  `^[A-Za-z_][A-Za-z0-9_]*$`, ≤ 100 chars). Publish rejects a slot collision within one order; a later
  order may reuse a slot and overwrites it.
- `cancel`/`exit` always get through; do not build "abort" states on a normal transition.

## 4. Annotations

`#/definitions/annotations`: string-valued object, namespaced keys, pure passthrough — the runtime
never interprets values. Surfaces on `transitions[].annotations` and `timeout.annotations` in the
state function (since 0.0.95; current shape v14); `kind: "scheduled"` entries carry the arming transition's
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
- `?sync=true` does not guarantee a `200` when the transition or flow declares `executionType: "A"`
  (and `?sync=false` may get a `200` under `"S"`).
- `history: "none"` flows allow automatic transitions only — see `workflow-types.md` §8.
- A `schemas` list without a rule-less last entry refuses every caller no rule matches (`400 Transition:100025`)
  — and its rules see the instance's latest data as `body`, not the request payload.

## Sources

- Runtime `vnext` @ `f06961ec` (0.0.100): `src/BBT.Workflow.Domain/Execution/Transitions/Pipeline/LifecycleOrder.cs`,
  `ITransitionAdmissionService.cs`, `Pipeline/Steps/{HandleUpdateDataDataOnlyStep,ForwardToActiveSubflowStep}.cs`,
  `docs/runtime/execution-type.md`, `docs/architecture/subflow-transition-proxy.md`,
  `docs/domain/well-known-transitions.md`, `docs/domain/extensions.md`
- Schema `vnext-schema` 0.0.56: `#/definitions/{updateDataTransition,annotations,availableInEntry,workflowTimeout,executionType}`, task-entry `variableKey`
- vnext-docs: `concepts/transition-pipeline.md`, `how-to/async-sync.md`, `components/workflow.md` §Annotations, §Transition Yürütme Modeli
- Fixtures `vnext-example`: `core/Workflows/timeout-lab/timeout-lab-root.json`, `core/Workflows/schedule-after-auto/`, `core/Workflows/parallel-variable-key-lab/`
- PRs: #877 (Busy-as-mutex), #884 (`+Self` only for updateData), #859 (well-known discovery), #917 (updateData no lock/guard), #943 (Auto 80 before Schedule 90), #984 (extensions read-only), #1037 (`executionType`), #1067 (10 MB async body), #1072 (`variableKey`), #1085 (SubFlow transition proxy)
- vnext PR #1225 (0.0.105) / vnext-schema #169 (0.0.60): `transitions[].schemas`, `TransitionSchemaResolver`, `Transition:100025`; vnext `docs/runtime/function-contract-resolution.md` § Transitions
- vnext-meta: `wellKnownTransitionDiscovery` 0.0.79, `selfTargetPipelineProfile` (stale order note), `stateAnnotations` 0.0.95, `executionType` 0.0.99, `taskVariableKey` 0.0.99
