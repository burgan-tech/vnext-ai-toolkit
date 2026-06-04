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

**Decision rule.** First question: "Is this a top-level business flow, or is it called from another workflow?" → `F` vs `S`. If parallel and independent → `P`.

## 2. State `stateType`

Each state in `attributes.states[]` carries a `stateType`. Conceptual mapping:

| Value | Name | Role | Constraints |
|-------|------|------|-------------|
| `1` | Initial | Starting point | Exactly **one** per workflow. `startTransition.target` points to it. |
| `2` | Intermediate | Awaits user action or system work | Can have a view (user-facing) or be purely passive (auto-only transitions) |
| `3` | Final | Workflow ends here | `isFinal: true`. Instance status becomes Completed; optional `subType` (Success/Error/Terminated) |
| `4` | SubFlow | Invokes a SubFlow / SubProcess child | Carries `subFlow` reference; type S/P chosen at the child level |
| `5` | Wizard | Step-by-step form | Exactly one outgoing manual transition; the transition's view is returned on state entry (fast-path), so `state.view` stays `null` |

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

| Attribute | SubFlow (S) | SubProcess (P) |
|-----------|-------------|----------------|
| Started by | Explicit transition from parent state | Fire-and-forget from parent (no wait) |
| Data context | Shared with parent | Independent instance, own data |
| Return | Result merges into parent's instance data | Optional callback; parent doesn't block |
| Lifecycle | Synchronous from parent's perspective | Parallel; runs to its own completion |
| Cancellation | Parent cancel → child cancel | Independent; explicit cancel needed |

Decision: reusable nested sequence with shared data → `S`. Independent parallel work → `P`.

## 6. Start transition

Every workflow has exactly one `attributes.startTransition`. Its `target` must be the Initial (`stateType: 1`) state. The runtime fires this transition automatically when the instance is created.

## 7. Master schema

A flow defines a **master schema** (its `attributes.schema` / workflow-type schema). It derives the
InstanceData template and powers vNext features — `x-lookup`, `x-encrypt`, and instance filtering.

**Merge validation.** On every instance-data merge, the runtime validates the merged data against
the master schema and **rejects** the request if it doesn't fit. Because data **expands across
states** (each state merges more in), the master schema must be permissive:

- **No `required`** — early states don't yet have later fields.
- **`additionalProperties: true`** — data grows at different levels over the instance's life.

What still matters: `pattern`, the backbone object shape, vocabulary definitions (`x-*`), and the
field types — these drive filtering and the `x-*` features.

**Filtering.** The **data function** uses the master schema actively when responding: it resolves
the types of dynamic instance-data fields *from the schema*, which is what gives advanced instance
filtering its flexibility.

**Views.** A read-only view may use the master schema as its `dataSchema` (the full instance shape
so `$instance.X` resolves everywhere). Input/transition views need a transition-specific schema
that carries `required` / `enum` / `x-lov` / `x-validation` for the input set — see `view-roles.md`.

## Sources

- Canonical schema: `https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/workflow.json`
- Docs portal: `https://burgan-tech.github.io/vnext-docs/docs/components/workflow`
- Working examples: `vnext-example/core/Workflows/account-opening/`, `payment-process/`
