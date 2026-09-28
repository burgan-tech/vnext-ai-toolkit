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
| `1` | Initial | Starting point | Exactly **one** per workflow. `startTransition.target` points to it. |
| `2` | Intermediate | Awaits user action or system work | Can have a view (user-facing) or be purely passive (auto-only transitions) |
| `3` | Final | Workflow ends here | Instance status becomes Completed; `subType` 1 Success / 2 Error / 3 Terminated / 7 Cancelled / 8 Timeout |
| `4` | SubFlow | Invokes a SubFlow child | Carries `subFlow` reference with `type: "S"` only (`"P"` rejected at publish since 0.0.95 — §5) |
| `5` | Wizard | Step-by-step form | Exactly one outgoing manual transition; the transition's view is returned on state entry (fast-path), so `state.view` stays `null` |

**`subType`.** `#/definitions/stateSubType` enum 0–8 (0 none, 1 Success, 2 Error, 3 Terminated, 4 Suspended, 5 Busy, **6 Human**, 7 Cancelled, 8 Timeout). `subType: 6` on an Intermediate state makes it a **human task** candidate for `GET /{domain}/functions/human-task` — it needs `queryRoles` and a root-level `humanTask: {title, description}` in data. See `human-task.md`. This is unrelated to task type 5.

**Pattern: wizard view placement.** When `stateType: 5`, attach the form to the single transition's `view`, not the state's `view`. The runtime exposes that form on state entry; reproducing it as `state.view` causes double-render bugs.

**Pattern: passive intermediate.** When an Intermediate state's only outgoing transitions are auto (1) or timer (2), set `state.view = null` — the state is not user-facing.

**Pattern: Initial state input.** When the Initial state (`stateType: 1`) gathers input from the user before anything happens, the **default placement is `state.view`** (on the state itself), not on the outgoing transition. Reason: the runtime serves the state view immediately on instance start — the user sees the form right away and submits via a `view: null` transition. The reverse (form on the transition) requires the client to discover the transition and trigger it before any UI appears — an extra step with no UX benefit. The skill should propose this placement and confirm with the user (some flows want an intentional "intro → tap → form" two-step; `AskUserQuestion` with state-view marked Recommended). Wizard states (`stateType: 5`) are the exception — their form lives on the single outgoing transition by design.

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

Each call **authorizes against the current state's `queryRoles`**: if the caller's resolved roles
(see `roles-and-authorization.md`) aren't `allow`-listed, the function returns **403**. So
`queryRoles` on a state is what gates who can read that state, its view, its schema, and its data.

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
emits nothing. Full semantics, SubFlow bubbling, rule pitfalls and overrides: `long-poll-interaction.md`.

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
return **delta-only** mappings, and give parallel branches distinct task definitions. Step order,
`+Self` profile, discovery and annotations: `transition-pipeline.md`.

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
| Parent status | parent shows the child's status as `status` / `effectiveStatus` (#983); parent transitions are forwarded to the child (step 10) | independent; not projected upward |
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

Every workflow has exactly one `attributes.startTransition`. Its `target` must be the Initial (`stateType: 1`) state. The runtime fires this transition automatically when the instance is created.

**No view, but a schema.** The start transition **cannot carry a `view`** (`view` must be `null`) —
it fires automatically on creation, so there's no UI surface for it. It **can carry a `schema`** to
validate the **initial payload** sent to instance-start.

**Service-to-service vs client pattern.** In **service-to-service** flows it's natural to collect the
initial data *at start* (the caller already has it) — set `startTransition.schema` to the payload it
sends. In **client-facing** flows the instance usually starts with only base info, and the user
provides input on the **initial-state view** (not at start). Design for this explicitly: put the
input form on the Initial state's `view`, not on the start transition (which has none). See
`view-roles.md` § State view vs Transition view.

## 7. Master schema

A flow defines a **master schema** (its `attributes.schema` / workflow-type schema). It derives the
InstanceData template and powers vNext features — `x-lookup`, `x-encrypt`, and instance filtering.

**Merge validation.** On every instance-data merge, the runtime validates the merged data against
the master schema and **rejects** the request if it doesn't fit. Because data **expands across
states** (each state merges more in), the master schema must be permissive:

- **No `required`** — early states don't yet have later fields.
- **`additionalProperties: true`** — data grows at different levels over the instance's life.

What still matters: `pattern`, the backbone object shape, vocabulary definitions (`x-*`), and the
field types — these drive filtering and the `x-*` features. In particular, master-schema properties
carry **`x-roles`** (field visibility in the `schema`/`data` functions) and
**`x-filterOperators` / `x-sortable` / `x-displayFormat`** (which the `data` function uses for
advanced filtering, sorting, and display). See `schema-vocabularies.md`.

**Filtering.** The **data function** uses the master schema actively when responding: it resolves
the types of dynamic instance-data fields *from the schema*, which is what gives advanced instance
filtering its flexibility.

**Views.** A read-only view may use the master schema as its `dataSchema` (the full instance shape
so `$instance.X` resolves everywhere). Input/transition views need a transition-specific schema
that carries `required` / `enum` / `x-lov` / `x-validation` for the input set — see `view-roles.md`.

## 8. Annotations

`annotations` (string-valued, namespaced keys such as `ui/visibility-channel`, `ui/priority`,
`ui/intent`) may be declared on state transitions, `sharedTransitions`, `cancel`, `exit`,
`updateData` and `timeout` — **not** on `startTransition`. The runtime passes them through untouched
to `transitions[].annotations` and `timeout.annotations` in the state function. Declaration rules:
`transition-pipeline.md` §4; wire shape: `state-function-response.md`.

## Sources

- Canonical schema: `workflow-definition.schema.json` — resolve the URL per `component-schemas.md` (do not hard-code a raw GitHub path)
- Docs portal: `https://burgan-tech.github.io/vnext-docs/docs/components/workflow`
- Working examples: `vnext-example/core/Workflows/account-opening/`, `payment-process/`
