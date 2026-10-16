# Workflow Concepts — Types, States, Transitions

> **Caveat.** The enum values listed here (workflow `type`, `stateType`, `triggerType`) are also defined in the canonical `workflow.json` schema. Always treat the schema as authoritative — this file exists to give the AI a mental model, not to be the source of truth for enum membership. If a value here disagrees with the schema, the schema wins.

## 1. Workflow `attributes.type`

Selects the workflow's runtime behavior. Read the schema for the current value set; the table below is the conceptual baseline.

| Code | Name | When to use | Runtime behavior |
|------|------|-------------|------------------|
| `F` | Flow | Top-level user-facing business processes — the usual starting point | State machine; user interactions enrich the instance data |
| `S` | SubFlow | Reusable step sequences invoked from a parent workflow | Shares the parent's data context; result merges back into parent |
| `P` | SubProcess | Parallel, fire-and-forget child work | Independent lifecycle; parent does not block on it |
| `C` | Core | Platform/system-level workflows | Rare; reserved for the platform team |

**Decision rule.** First question: "Is this a top-level business flow, or is it called from another workflow?" → `F` vs `S`. If parallel and independent → `P` — but a `P` child is started **only** by a SubProcess task (type 14), never from a state's `subFlow` block (see §5).

## 2. State `stateType`

Each state in `attributes.states[]` carries a `stateType`. Conceptual mapping:

| Value | Name | Role | Constraints |
|-------|------|------|-------------|
| `1` | Initial | Starting point | **Optional — at most one** (0.0.99, #1068). With none declared the instance is born in the implicit **`$start`** state and `startTransition.target` decides where it enters (§6). Two Initial states are rejected at publish. |
| `2` | Intermediate | Awaits user action or system work | Can have a view (user-facing) or be purely passive (auto-only transitions) |
| `3` | Final | Workflow ends here | Instance status becomes Completed; `subType` 1 Success / 2 Error / 3 Terminated / 7 Cancelled / 8 Timeout |
| `4` | SubFlow | Invokes a SubFlow child | Carries `subFlow` reference with `type: "S"` only (`"P"` rejected at publish since 0.0.95 — §5) |
| `5` | Wizard | Step-by-step form | Exactly one outgoing manual transition; the transition's view is returned on state entry (fast-path), so `state.view` stays `null` |

**`subType`.** `#/definitions/stateSubType` enum 0–8 (0 none, 1 Success, 2 Error, 3 Terminated, 4 Suspended, 5 Busy, **6 Human**, 7 Cancelled, 8 Timeout). `subType: 6` on an Intermediate state makes it a **human task** candidate for `GET /{domain}/functions/human-task` — it needs `queryRoles` and a root-level `humanTask: {title, description}` in data. See `human-task.md`. This is unrelated to task type 5.

**Pattern: wizard view placement.** When `stateType: 5`, attach the form to the single transition's `view`, not the state's `view`. The runtime exposes that form on state entry; reproducing it as `state.view` causes double-render bugs.

**Pattern: passive intermediate.** When an Intermediate state's only outgoing transitions are auto (1) or timer (2), set `state.view = null` — the state is not user-facing.

**Pattern: Initial state input.** When the first state (an Initial `stateType: 1`, or whatever `startTransition.target` names) gathers input from the user before anything happens, the **default placement is `state.view`** (on the state itself), not on the outgoing transition. Reason: the runtime serves the state view immediately on instance start — the user sees the form right away and submits via a `view: null` transition. The reverse (form on the transition) requires the client to discover the transition and trigger it before any UI appears — an extra step with no UX benefit. The skill should propose this placement and confirm with the user (some flows want an intentional "intro → tap → form" two-step; `AskUserQuestion` with state-view marked Recommended). Wizard states (`stateType: 5`) are the exception — their form lives on the single outgoing transition by design.

## 2.1 State alias (role-aware state labels)

By default a state's **state function** returns `state.key`. A state can also carry an `alias`
definition so that different actors see different, role-appropriate labels instead of the raw key.

**Why.** A client starts a process that later proceeds in the backoffice. While Fraud / Limit / KPS
checks run, returning the literal state key to the client leaks internal process detail (a security
concern). An alias lets the client see "Değerlendirme Aşamasında" / "Under Operational Review"
while backoffice actors see their own role-appropriate label.

**Resolution order** (in the state function):
1. State has an `alias` **and** the actor's role matches an alias entry → return that entry's
   localized `label`.
2. State has an `alias` but no role matches → return `alias.name`.
3. No `alias` at all → return `state.key` (unchanged legacy behavior).

**Shape** — `alias[]`, each entry `{ name, roles[], labels[] }`:

```json
{
  "alias": [
    {
      "name": "Değerlendirme Aşamasında",
      "roles": [ { "role": "backoffice.operator", "grant": "allow" } ],
      "labels": [
        { "label": "Operasyon İncelemesinde",   "language": "tr" },
        { "label": "Under Operational Review",   "language": "en" }
      ]
    }
  ]
}
```

The `roles[]` use the same role model as everywhere else — see `roles-and-authorization.md`.

## 2.2 Built-in instance functions & `queryRoles`

The runtime exposes four **built-in functions** on every instance:

| Function | Returns |
|----------|---------|
| `state` | the instance's current state (role-aware — applies the state alias, see §2.1) |
| `view` | the view to render for the current state/transition |
| `schema` | the data schema for the current context (field visibility filtered by `x-roles`) |
| `data` | the instance data (supports advanced filtering/sorting — see §7 Master schema) |

Since 0.0.99 field protection — `x-roles` pruning, then `x-masking`, then `x-encryption` — applies on
**every** instance read surface (instance GET and list, `data`, data history, sync start/transition
responses, the Get* tasks), not only `schema` / `data`; see `references/concepts/field-protection.md`.

Read access is gated by the current state's **`queryRoles`**: the gateway asks
`authorize?queryRoles=true` before forwarding and returns **403** when the caller's resolved roles
(see `roles-and-authorization.md`) aren't `allow`-listed — the runtime itself does not 403 these reads
(since 0.0.95; inside a SubFlow the decision is taken at the leaf only since 0.0.99). So `queryRoles`
on a state is what gates who can read that state, its view, its schema, and its data.

**Precedence: state, then flow.** `queryRoles` can be defined at **two levels** — on the **flow**
(`attributes.queryRoles`) and on a **state**. The **current state's `queryRoles` takes priority**; if
the current state defines none, the runtime falls back to the **flow-level `queryRoles`**. Use the
flow level for a workflow-wide default and override it per state only where access differs.

## 2.3 State interaction (long poll)

A **state** (never a transition) may declare `interaction.longPoll`. With `terminate: true` the
pipeline pauses after OnEntry (order 75), the instance stays Busy, and the state function returns an
`interaction` block (`terminateLongPoll`, `fallbackTimeoutSeconds`, `ack.href`) to admitted callers —
the client stops polling, renders, then `POST`s the ack (or the fallback timer resumes). Gate is
exactly one of `roles` | `rule` (schema `oneOf`; write `"roles": []` for an open gate). `terminate: false`
(since 0.0.98, shape v13) serves the `interaction` block **without `ack`** whenever the caller passes the
gate; nothing pauses, and `fallbackTimeoutSeconds` sets the client's poll window. Full semantics, SubFlow bubbling, rule pitfalls and overrides: `long-poll-interaction.md`.

## 3. Transition `triggerType`

How the transition fires.

| Value | Type | Fired by | Required fields | Notes |
|-------|------|----------|-----------------|-------|
| `0` | Manual | User click | — | Carry a `view` for input form / confirmation |
| `1` | Auto | Engine evaluates a rule | `rule` (`.csx` `IConditionMapping`) unless `triggerKind: 10` (always-true) | Auto transitions must come in **complementary pairs** with mutually exclusive rules — OR be a single unconditional transition. A lone conditional auto transition is invalid. |
| `2` | Timer | Scheduler at a moment in time | `timer` (ISO 8601 duration like `PT15M` OR `ITimerMapping` for dynamic schedule) | View must be `null`. |
| `3` | Event | External event listener | (event source spec — confirm in the schema; this is the least-documented trigger) | View must be `null`. |

**Pattern: auto-pair rule.** A state with a conditional auto transition (e.g. `triggerType: 1` with `if x > 0`) MUST also have its complement (`if x <= 0`) targeting a different state. Otherwise the engine has no defined behavior when the rule is false. The validator catches this; the scaffolding skill should catch it earlier by asking the user "what happens when the condition is false?"

**Pattern: no view on auto/timer.** `triggerType` 1, 2, and 3 transitions have `view: null`. They fire without user interaction; attaching a view is a no-op at best, a runtime error at worst.

## 3.1 Transition admission & locking — Busy-as-mutex (v0.0.79+)

The instance's **Busy** status is the execution mutex: the first hop does an Active→Busy
compare-and-set under a short status lock, then the pipeline and its auto-chain run lock-free.

| Kind | Transitions | Busy instance → client sees |
|------|-------------|-----------------------------|
| Normal | state / shared | **409** `Instance:100031` |
| BypassBusyCheck | `cancel`, `exit`, workflow `timeout` | accepted (flips Busy at accept) |
| Unconditional | `updateData` | always accepted; no lock, no duplicate guard, status-neutral |
| OwnerReentry | jobs, SubFlow resume, long-poll ack | n/a |

`updateData` (`target: "$self"`) is the only transition that skips OnExit/OnEntry/Schedule; against
a parent with an open SubFlow it is data-only and never forwarded. Route parallel writes through it,
return **delta-only** mappings, and give the same task listed twice at one `order` a distinct
`variableKey` (0.0.99, #1072 — publish rejects a slot collision). Step order,
`+Self` profile, discovery and annotations: `transition-pipeline.md`.

## 3.2 `executionType` — sync/async pinned by the definition (0.0.99, #1037)

`"executionType": "S"` (sync → `200` + full instance) or `"A"` (async → `202` + `{ id, status }`) on the
flow (`attributes.executionType`) or on a state transition, shared transition or `startTransition`
(not on `cancel` / `exit` / `updateData`). **Precedence: transition → flow → the caller's `?sync`**; when
a definition sets it, `?sync` is ignored. Not applied to auto transitions, scheduled/timeout/retry
paths, SubFlow resume/start/forward or the long-poll ack. Clients must branch on the **status code**,
not on the `sync` they sent. Details: `transition-pipeline.md` §1.

## 4. State lifecycle hooks

```
Transition fires
  ↓
[transition.onExecutionTasks]   ← sequential by `order`, parallel when same order
  ↓
[current state.onExits]
  ↓
Move to target state
  ↓
[target state.onEntries]
  ↓
State type check:
  - Final     → instance Completed
  - SubFlow   → invoke child
  - Initial/Intermediate/Wizard → evaluate outgoing auto transitions
```

`order` semantics: same `order` = parallel; different `order` = sequential.

## 5. SubFlow vs SubProcess

| Attribute | SubFlow (`S`) | SubProcess (`P`) |
|-----------|---------------|------------------|
| Started by | state `stateType: 4` + `subFlow.type: "S"` (pipeline step 70) | **SubProcess task (type 14)** in `onExecutionTasks`/`onEntries`; state-level `"P"` is rejected at publish since 0.0.95 (#1026) |
| Start / forward | **synchronous** in the parent's pipeline (#968, 0.0.91); a failed start **faults the parent** with an incident, retry repeats the start (#1026) | task executor starts the child and creates the correlation; parent continues |
| Parent status | parent shows the child's status as `status` / `effectiveStatus` (#983); since 0.0.100 a forwardable parent transition is **proxied** to the leaf, which validates and answers synchronously (`runtime-operations.md` §1) | independent; not projected upward |
| Data | child input from `ISubFlowMapping.InputHandler`; output merged by `OutputHandler` | own data; results come back only via explicit tasks/events |
| Discovery | `correlations[]` in the state body lists active + completed children with `terminalOutcome` (#856) | listed in `correlations[]` with `subFlowType: "P"`; not followed by state/long-poll/human-task descent |
| Cancellation | parent cancel → child cancel (bypassed if the child has no `cancel`) | independent; explicit cancel |
| Instance `metadata.type` | `S` | `P` (addressed by its own `id`; its `key` copies the parent's) |

Decision: reusable nested sequence whose progress the parent must show → `S`. Independent parallel
work → `P` via task 14 (`task-types.md`).

Parent-side tuning of a child (roles, queryRoles, long-poll window, view swaps, timeout) lives in
`subFlow.overrides` — see `subflow-overrides.md`. Scripts reach related instances through
`context.Related` (`ParentAsync`, `SubAsync`, `SubsAsync`): **one hop** up or down, read with the
**system identity** — no `queryRoles`, no `x-roles` field filtering — so copy only fields you intend
to expose.

## 6. Start transition

Every workflow has exactly one `attributes.startTransition`. The runtime fires it automatically when
the instance is created. Rules since 0.0.99 (#1068), checked at publish:

- `target` is **required** and must name a **declared state** — any state, not necessarily an Initial
  one. An empty target, `$self` and `$start` are rejected.
- **`$start` is a reserved state key** — never declare a state with it.
- With **no Initial state**, the instance is born in the implicit `$start` (no tasks, view or
  transitions; never listed in `states`) and enters `target` through the start transition. With one
  Initial state, behaviour is unchanged (point `target` at it).
- During an async start or a SubFlow child creation, `currentState` may briefly read `$start` —
  clients that branch on `currentState` must tolerate it.

**No view, but a schema.** The start transition **cannot carry a `view`** (`view` must be `null`) —
it fires automatically on creation, so there's no UI surface for it. It **can carry a `schema`** to
validate the **initial payload** sent to instance-start. It may also carry `executionType` (§3.2).

**Service-to-service vs client pattern.** In **service-to-service** flows it's natural to collect the
initial data *at start* (the caller already has it) — set `startTransition.schema` to the payload it
sends. In **client-facing** flows the instance usually starts with only base info, and the user
provides input on the **first state's view** (not at start). Design for this explicitly: put the
input form on that state's `view`, not on the start transition (which has none). See
`view-roles.md` § State view vs Transition view.

### Ways to start an instance

| Path | When |
|------|------|
| `POST …/instances/start` | Client or service call (body = initial payload) |
| `POST …/instances/events?action=start` | A published message; needs the workflow's `event.mapping` to compute the key (`event-driven-workflows` docs) |
| `POST …/instances/schedule?scheduleId=&version=&sync=` (**0.0.100**, #1076) | A Dapr `bindings.cron` component whose `route` points here — one component YAML per schedule, owned by the domain's deployment. No body: every non-reserved query parameter becomes a **string** attribute; key = `{scheduleId}-{yyyyMMddTHHmmssZ}`; `sync` defaults to `false`. Assumes one delivery per tick (no lock) — verify before scaling the orchestrator beyond one replica |
| SubFlow state / SubProcess task (14) / StartTrigger task (11) | From another instance |

## 7. Master schema

A flow defines a **master schema** (its `attributes.schema` / workflow-type schema). It derives the
InstanceData template and powers vNext features — `x-lookup`, field protection (`x-roles`,
`x-masking`, `x-encryption` — see `references/concepts/field-protection.md`), and instance filtering.

**Merge validation.** On every instance-data merge, the runtime validates the merged data against
the master schema and **rejects** the request if it doesn't fit. Because data **expands across
states** (each state merges more in), the master schema must be permissive:

- **No `required`** — early states don't yet have later fields.
- **`additionalProperties: true`** — data grows at different levels over the instance's life.

What still matters: `pattern`, the backbone object shape, vocabulary definitions (`x-*`), and the
field types — these drive filtering and the `x-*` features. In particular, master-schema properties
carry **`x-roles`** (read-side field pruning on every instance read surface, not only the
`schema`/`data` functions — `field-protection.md`) and
**`x-filterOperators` / `x-sortable` / `x-displayFormat`** (which the `data` function uses for
advanced filtering, sorting, and display). See `schema-vocabularies.md`.

**Filtering.** The **data function** uses the master schema actively when responding: it resolves
the types of dynamic instance-data fields *from the schema*, which is what gives advanced instance
filtering its flexibility.

**Views.** A read-only view may use the master schema as its `dataSchema` (the full instance shape
so `$instance.X` resolves everywhere). Input/transition views need a transition-specific schema
that carries `required` / `enum` / `x-lov` / `x-validation` for the input set — see `view-roles.md`.

## 8. History mode — `attributes.history: "none"` (0.0.100, #1082)

`"history": "none"` (at the root of `attributes`, beside `type` / `executionType`; omitted or `"full"`
= full history) marks a **one-shot** flow: no `InstanceTransitions` / `InstanceTasks` rows, and
instance data is buffered and written **once** — at Finish, at a SubFlow handoff, or on a fault.

**When to use it.** High-volume automatic flows nobody inspects afterwards — a quote, lookup,
introspection or validation run end to end by the system. It cuts storage and write cost. Do **not**
use it for anything a human waits on, anything you may need to `retry`, or flows whose history is
an audit requirement.

**Publish rejects a `none` flow that is not one-shot** (errors, flow-local; the schema enforces all
but the last rule):

- at least one Final state, and every state must reach one (no cycle, no `$self`-only loop, no dead end);
- every state transition is **automatic** (`triggerType: 1`) — no manual, timer or event transitions; every non-Final state has at least one;
- no `sharedTransitions`, `cancel`, `exit`, `updateData`, workflow `timeout`, `subFlow.overrides.timeout`;
- no `interaction.longPoll`, no Wizard state, no **Suspended / Busy / Human** subtype — so **human states are forbidden**.

`startTransition` stays, and SubFlow states, SubProcess tasks and a workflow `event` start are allowed.

| Runtime code | When |
|---|---|
| `Instance:100044` (400) | A `none` parent's SubFlow (`S`) child is not `none` itself — the child refuses to start, the parent faults with an incident (SubProcess children exempt; a `none` child under a `full` parent is fine) |
| `Instance:100045` (409) | `POST …/retry` on a `none` instance — retry is not available |
| `Instance:100046` (incident) | A stage came to rest at a non-Final state (e.g. every auto rule false) — the instance is faulted |

Also: transitions history, `functions/tasks`, `functions/actions` and the metrics endpoints return
empty lists; while it runs the instance has no data row (GET returns null data, attribute filters miss
it); `$PreviousUser` / `$PreviousBehalfOfUser` never resolve; a crash or post-commit fault loses the
data since the last flush. Needs schema 0.0.56 and runtime 0.0.100 together — older ones silently
ignore the field.

## 9. Annotations

`annotations` (string-valued, namespaced keys such as `ui/visibility-channel`, `ui/priority`,
`ui/intent`) may be declared on state transitions, `sharedTransitions`, `cancel`, `exit`,
`updateData` and `timeout` — **not** on `startTransition`. The runtime passes them through untouched
to `transitions[].annotations` and `timeout.annotations` in the state function. Declaration rules:
`transition-pipeline.md` §4; wire shape: `state-function-response.md`.

## Sources

- Runtime 0.0.100: `docs/runtime/{history-mode,execution-type}.md`, `docs/domain/scheduled-workflow-start.md`; release notes v0.0.98–v0.0.100 (#1051, #1037, #1068, #1072, #1076, #1082, #1085)
- Canonical schema: `workflow-definition.schema.json` — resolve the URL per `component-schemas.md` (do not hard-code a raw GitHub path)
- Docs portal: `https://burgan-tech.github.io/vnext-docs/docs/components/workflow`
- Working examples: `vnext-example/core/Workflows/account-opening/`, `payment-process/`; one-shot flows `history-none-lab/` (`hn-oneshot.json`, `hn-stuck.json`, `hn-fault.json`) and `history-none-subflow-lab/`
