---
name: workflow-scaffold
description: Use when the user wants to create a new vNext Workflow end-to-end. Plans the state/transition graph, scaffolds the workflow JSON + .csx mapping files + .http test file, and chains to view-design / schema-design as needed.
---

# Workflow Scaffold

End-to-end scaffolding for a new vNext workflow. A workflow is a state machine — getting the states, transitions, and trigger types right up front saves rewriting later.

## Prerequisites

- Working directory is a vNext domain project (has `vnext.config.json`).
- The user can describe the business flow at a conceptual level (the "what happens when" story).

## Canonical schema-first (mandatory pre-step)

> **Before asking about workflow type, states, or transitions, fetch `workflow.json` for the workspace's `schemaVersion`.** Enum options for `attributes.type`, `stateType`, and `triggerType` come from this schema — never hardcode them.

```
1. Read vnext.config.json → schemaVersion + domain + paths.workflows + runtimeVersion
2. Load the workflow schema from the pinned package:
   node_modules/@burgan-tech/vnext-schema/schemas/workflow-definition.schema.json
   (missing → `npm install`; version/fallback rules → references/concepts/component-schemas.md;
   never guess field names from memory)
3. Parse:
   - properties.attributes.properties.type.enum → workflow type options
   - properties.attributes.properties.states.items.properties.stateType.enum → state kinds
   - properties.attributes.properties.transitions.items.properties.triggerType.enum → trigger kinds
   - required[] at every level → what the skeleton must include
4. Drive AskUserQuestion lists + skeleton from this schema.
```

See `references/concepts/component-schemas.md` for the full rule and `references/concepts/workflow-types.md` for the mental model.

## Steps

### 1. Resolve paths from `vnext.config.json`

Capture:
- `paths.componentsRoot`
- `paths.workflows`
- `domain`
- `runtimeVersion` (for `.http` test file header)

Target folder: `{componentsRoot}/{paths.workflows}/{workflow-key}/`. Inside it: `{workflow-key}-workflow.json`, `src/` (for `.csx` mappings), and a `.http` test file.

### 2. Ask the workflow type

`attributes.type` values (rendered from `workflow.json` schema enum — typical set):
- **`F`** — Flow (standard top-level user-facing flow)
- **`S`** — SubFlow (started from a parent's state via `stateType: 4` + `subFlow`; result merges into the parent)
- **`P`** — SubProcess (independent child; started **only** through a `SubProcessTask` (type 14) — a state-level `subFlow.type: "P"` is rejected at publish since 0.0.95)
- **`C`** — Core (system-level)

Verify the current set against Context7 (`"workflow attributes type values"`) if the user's case doesn't fit cleanly.

**History mode (ask for `F`/`S` flows, runtime ≥ 0.0.100).** *"Is this a one-shot, fully automatic
flow that runs often and nobody inspects afterwards (quote, lookup, validation)?"* If yes, offer
`attributes.history: "none"` — no transition/task history and a single data write, i.e. lower storage
and write cost. Only valid when **every** state transition is automatic, every state reaches a Final
state, and there is no human/Wizard/Suspended/Busy state, long poll, timeout, `cancel`/`exit`/
`updateData` or shared transition; retry is not available (409 `Instance:100045`) and a SubFlow child
must be `none` too. Default: omit (full history). Rules: `references/concepts/workflow-types.md` §8.

**Sync/async (`executionType`, runtime ≥ 0.0.99).** Ask whether the caller should keep choosing
`?sync` (default — omit the field) or the flow/transition must pin it: `"S"` (always 200 + instance)
or `"A"` (always 202). Set on `attributes.executionType` and/or individual state, shared or start
transitions (transition beats flow beats `?sync`; not on `cancel`/`exit`/`updateData`; ignored for
auto/timer transitions). Clients must then branch on the status code.

**Roles gate (mandatory question).** Before designing any state or transition, **ask the user whether this flow should configure roles (`queryRoles`/`roles`) at all** — via `AskUserQuestion`, with "no roles" as the Recommended default. Roles add real complexity, especially for vNext newcomers; never add role configuration without explicit user confirmation. If confirmed, follow `references/concepts/roles-and-authorization.md` — and remember the 0.0.95 model: the runtime only *filters visibility* by roles; the **`authorize` function** (called by the gateway) is the single enforcement point, so a local runtime without a gateway will not 403 on reads.

**Row visibility (only if roles are confirmed; runtime ≥ 0.0.102, schema ≥ 0.0.58).** Ask: *"Should every caller who may list this flow see every instance, or only some rows (own branch, own region, own applications)?"* If rows differ per role, design `attributes.rowSecurity` with `references/concepts/row-security.md` §5: one rule per role group, an explicit unfiltered rule for admins/auditors (it is deny by default — there is no `default`), scope values from gateway-written headers or `CurrentUser` (never `QueryParameters`), filtered fields `x-indexed` and not masked/encrypted, `$InstanceStarter` for "own instances". State the limits plainly: it filters the list, the single GET and `GetInstance(s)` tasks only — `functions/data`, transitions and SubFlow children are not covered (experimental).

### 3. Map the states

Walk through the flow with the user. For each state capture:

- **Key** (kebab-case)
- **stateType** (Initial / Intermediate / Final / SubFlow / Wizard — values from the fetched schema). An Initial state is **optional, at most one** (0.0.99): without one the instance starts in the implicit `$start` and enters `startTransition.target`. Never use `$start` as a key.
- **Is it final?** (`isFinal: true` ends the instance)
- **Has a view?** (if yes, note the view key — will resolve in step 6)
- **`onEntry` tasks?** (anything that must run when entering the state)
- **Is a person expected to act here (approval, review, manual step)?** If yes → **human task state**:
  `subType: 6`, a `queryRoles` list (mandatory — with no `queryRoles` anywhere the task is *hidden*
  from the `human-task` list, fail-closed), and the entering transition's mapping (or an `onEntry`
  task) must write `humanTask: { title, description }` at the instance-data root. Details and the
  `GET /{domain}/functions/human-task` contract: `references/concepts/human-task.md`.
- **Does the engine have to pause until a specific client has rendered this state?** (e.g. a
  result screen on mobile before an auto transition continues) → `interaction.longPoll`
  `{ terminate: true, fallbackTimeoutSeconds, roles | rule }` — exactly one of `roles`/`rule` is
  required by the schema (write `"roles": []` for "everyone"). Keep the fallback short (5–10 s) when
  other clients wait on the instance. Never put a `rule` on a long-lived human state (it disables the
  shared body cache). `references/concepts/long-poll-interaction.md`.
- **Must the instance wait for data pushed later (client upload, partner callback) and give up after a
  timeout?** (runtime ≥ 0.0.102) → **interaction wait**: `subType: 5` + an `interaction` block, automatic
  transitions whose rules read the pushed data, a timer transition as the fallback, and a workflow
  `updateData` the client calls (`long-poll-interaction.md` §3b). Client transitions in that state get
  409 by design.
- **SubFlow state (`stateType: 4`)?** Ask whether the parent must adjust the child's
  `timeout`, transition `roles`/`views`, or state `queryRoles`/`interaction.longPoll`/`views` →
  `subFlow.overrides` (`references/concepts/subflow-overrides.md`; the old `viewOverrides` /
  `views`-by-key forms are deprecated since 0.0.95).

**First-state input pattern** — if the first state (Initial, or the start target) needs user input before anything happens, **propose placing the form on `state.view`** (not on the outgoing transition) and confirm with the user via `AskUserQuestion`. Reason: the runtime serves the state view immediately on instance start; the user fills it and submits via a `view: null` transition. The reverse (form on transition) forces an extra discovery step with no UX benefit. Make state-view the Recommended option; only switch if the user wants an intentional "intro screen → tap → form" two-step. See `references/concepts/workflow-types.md` for the pattern note.

Visualize back to the user as a list before moving on.

### 4. Map the transitions

**Admission & `updateData` (v0.0.79+ Busy-as-mutex, refined through 0.0.86).** Normal shared/state
transitions **409 (`Instance:100031`) while the instance is Busy**; `cancel`/`exit`/timeout bypass
the busy check; **`updateData` is admitted unconditionally** (no lock, no duplicate guard — N parallel
calls are all accepted) and is the only way to write data + advance under parallel requests. On a
plain instance it runs a trimmed `+Self` pipeline (OnExit/OnEntry/timer scheduling are **skipped**);
with an active SubFlow the **parent** stores the data and does **not** forward or run tasks/autos.
Its `target` must be `"$self"`. Mappings must return **deltas only**. If the flow has parallel
branches, fan-in states, loops, or clients that push data concurrently, ask whether an `updateData`
definition is needed. Auto transitions (order 80) are evaluated **before** timers are armed (order
90, since 0.0.90) — a state passed through by an auto never schedules its timers. While a SubFlow
is active, other parent transitions are **proxied to the leaf** (0.0.100): leaf 400/403/409 come back
synchronously, and a just-completed child answers 409 — retry. Details:
`references/concepts/transition-pipeline.md`.

**Annotations.** Any transition (state, shared, `cancel`, `exit`, `updateData`) and the workflow
`timeout` may carry `annotations: { "<ns>/<key>": "<string>" }` (e.g. `ui/priority`, `ui/intent`,
`ui/visibility-channel`); they are passed through verbatim to the state function's `transitions[]`
and `timeout` blocks. Ask the UI team whether they need any — `startTransition` cannot carry them.

For each transition capture:

- **From state → to state**
- **`triggerType`**: `0` (manual / user action), `1` (auto / condition-evaluated), `2` (timer), `3` (event)
- **For auto transitions**: ask what happens when each condition is false. Prefer mutually exclusive `rule`s; if rules overlap on purpose ("VIP first, then amount"), set `priority` (runtime ≥ 0.0.102 / schema ≥ 0.0.58: integer ≥ 1, absent = 100, lower first) and add a `triggerKind: 10` default as the fallback — never leave a state whose rules can all be false (`references/concepts/workflow-types.md` §3).
- **For timer**: `duration` (ISO 8601, e.g. `PT15M`)
- **Role-dependent auto rule or timer window** ("approvers skip review", "VIP gets 48 h"): runtime ≥ 0.0.105
  scaffolds `context.Caller.IsAvailable && await context.Caller.HasRoleAsync("x")` — the `IsAvailable` guard is
  mandatory because a fired timer or a SubFlow resume has no caller (a read throws). Timers see the caller who
  **entered** the state (computed at arming). A provider outage fails the step with `Authorization:110006`
  instead of taking the default. Never put roles into `.csx` task mappings — `context.Caller` is unavailable there
  (`references/concepts/csx-contracts.md` § Caller roles); a declarative task binding has its own `user` variable
  (`user.available ? user.hasRole("x") : false` — unguarded role reads fail on System hops, `references/concepts/declarative-task-mappings.md`).
- **`onExecutionTasks`**: which tasks run during the transition, and how each task's input/output is shaped (declarative `input`/`output` blocks, or a `.csx` mapping — step 7). Entries at the same `order` run in parallel and merge by slot `variableKey ?? camelCase(task.key)`; if the **same task** is bound twice at one order (e.g. two SubProcess starts), give at least one a `"variableKey"` (0.0.99; publish rejects a slot collision — same rule for `onEntries` / `onExits`). "Do X for each item in a list" → a **FanOut task** (type 21), not an auto loop — `references/concepts/fan-out.md`.
- **`executionType`** (optional, `"S"` / `"A"`) if this transition must not depend on the caller's `?sync`.
- **Payload schema** (manual/event, `cancel`, `exit`, `updateData`, start): one `schema`, or — when the
  same transition takes differently shaped bodies (retail vs corporate, per channel) — a rule-based
  **`schemas`** list (runtime ≥ 0.0.105 / schema ≥ 0.0.60): `[{ "rule": <IConditionMapping .csx>, "schema": ref }, …, { "schema": fallbackRef }]`,
  first match wins, rule-less fallback **last**, never on auto/timer transitions. The rule sees the
  instance's latest data as `body`, the request headers and — for a role-specific contract — the caller's
  resolved roles via `await context.Caller.HasRoleAsync("x")` (0.0.105, never `Headers.role`), not the
  request payload. Role rules are positive tests and the fallback is the least privileged contract. No matching entry →
  `400 Transition:100025`; ask the user whether unmatched callers must be refused (then omit the
  fallback deliberately). Details: `references/concepts/transition-pipeline.md` §1.1. On an older
  workspace keep the single `schema`.
- **No input = closed empty schema, never `null`.** A manual move that takes no body (Approve, Edit, Cancel, Confirm)
  references a closed empty schema (`{"type":"object","properties":{},"additionalProperties":false,"maxProperties":0}`).
  `schema: null` merges any body into instance data unvalidated — a caller could change an amount between the
  confirm screen and the send (`references/concepts/transition-pipeline.md` §1.1). When a later step executes what an
  earlier step checked and showed, add a snapshot written by the checking step and compared by the executing step.
- **Where does each form live, and can the person come back to it?** Ask for every input step: *"Can a later step
  send the person back here to correct the data (Edit / Düzenle)?"* — then follow
  `references/concepts/client-forms-and-transitions.md` §2. With a way back, the submitting transition must be
  **schema-less and view-less, with a whitelisting `ITransitionMapping`** (the client refuses to re-submit an untouched
  prefilled form to a transition that has a schema); the format rules move to the next task's output mapping. Never
  design an extra "intro" state that tells the person to use the Transitions menu — a button in the state view fires the
  move.
- **Shared resource?** If the transition touches something other instances also change (a limit, an
  account, a slot), offer a `resourceLock`: key = resource kind + business id (an `ITransitionMapping`
  `.csx` returning the string, never the instance id), `ttlSeconds` covering the whole protected section,
  a `Release` transition (or rely on terminal cleanup). Then ask **what losing the race means**:
  `Abort` (default — instance faults, `409 Execution:200010`), `Reject` (runtime ≥ 0.0.106 / schema
  ≥ 0.0.61 — instance untouched, `409 Execution:200014`, the client repeats the same call) or **wait in
  the process** (0.0.106 — keep `Abort` and add a state/global `errorBoundary` rule
  `{ "errorCodes": ["Execution:200010"], "action": 2, "transition": "<park>" }` to a parking state whose
  timer re-acquires; add a give-up exit). Never a Retry rule on the lock codes; the parking transition
  itself carries no `resourceLock`. Details and the provider caveat for `Extend`:
  `references/concepts/resource-lock.md`.
- **`annotations`** (optional, see above)

### 5. Identify the start transition

Exactly one `attributes.startTransition`. Its `target` is **required** and must name a declared
state — the Initial state if there is one, otherwise any state (the instance is born in the implicit
`$start` and enters it). `$self`, `$start` and an empty target are rejected at publish (0.0.99,
#1068). No `view`; an optional `schema` (or rule-based `schemas`, 0.0.105) validates the start payload;
optional `executionType`. If roles are confirmed, ask **who may start** an instance: since 0.0.105 the
gateway can gate `POST …/instances/start` through `GET …/workflows/{wf}/functions/authorize?type=instance`,
which evaluates `startTransition.roles` — static roles or `$Everyone` only (a `$InstanceStarter` /
behalf-of / `$user.` grant never matches before the instance exists, so `allow $InstanceStarter` alone
closes the flow). The runtime itself never checks these roles; say that the gateway rule must exist.
If the flow should also start **on a schedule**, note that runtime 0.0.100 exposes
`POST …/instances/schedule?scheduleId=…` for a Dapr `bindings.cron` component (seed values arrive as
query-string **strings**) — `references/concepts/workflow-types.md` §6.

### 6. Spin off dependencies (chain skills)

For each view referenced in step 3 that does not yet exist → invoke the `view-design` skill.
For each schema needed (workflow master schema, transition payloads) that does not yet exist → invoke the `schema-design` skill.

These can be deferred (scaffold the workflow first with placeholder refs, then fill in), but record what's pending.

### 7. Shape task bindings — declarative blocks first, then `.csx`

For each `onEntries` / `onExits` / `onExecutionTasks` entry, first try declarative `input` / `output` blocks (`select`, `into`, `set` with Dynamic Expresso expressions) — `references/concepts/declarative-task-mappings.md` has the shape, variables (`data`, `input`, camelCase `instance`, `now`, `user`, `task`, `config`, `result`), config-field input targets (`$.url`, `$.body.x`, `$.headers.x`), the `API_BASEURL` URL as one expression, and the cases that still need a `.csx` (secrets, loops/helpers, FanOut/Notification/Human). Transitions take an `output` block and `type: S` SubFlow states `input` / `output` blocks in place of `mapping` (same file, § Blocks on transitions and SubFlow states); JSON values take no method calls without a conversion. Requires runtime 0.0.107 or later and a vnext-schema with the blocks; on older pins use `.csx`.

For each entry that needs a `.csx` input/output mapping:

- Create `src/{PascalCaseClassName}.csx` with a skeleton class.
- The workflow JSON's `mapping.location` points to `./src/{file}.csx`; the VS Code extension auto-encodes the file into `mapping.code` (base64) on save. **Do not manually base64-encode.**
- Outside VS Code, `scripts/cluster-publish.mjs` inlines every `location` at publish time — leave `code` empty in the
  repository rather than committing a copy that can drift from the file.
- Before writing a task mapping, apply `references/concepts/csx-contracts.md` golden rules 1 and 8–10: read dynamic
  data only through `HasProperty` / `GetPropertyValue` (or `IDictionary` in a static helper); write **every** output
  field in both the ok and the error branch and clear with `""` (a `null` does not clear); route business-rule failures
  back to a user-facing state instead of throwing in a passive state; after a side-effecting call, a 2xx without the
  expected reference throws (incident) instead of routing to "failed".
- HTTP tasks: `acceptedStatusCodes` by side effect — read-only `["4xx","5xx"]`, side-effecting the definite rejections
  only (`references/concepts/task-types.md` §3 "6 Http").

### 8. Look at a sibling workflow

Read one existing workflow in this repo for envelope and reference style (e.g. `core/Workflows/account-opening/account-opening-workflow.json`). Especially confirm:
- Cross-component reference shape
- `timeout` structure (`{ key, target, versionStrategy, timer: { reset, duration }, annotations? }` — `timer.reset` is required by the schema but not read by the runtime)
- `onExecutionTasks` ordering

### 9. Generate the workflow JSON

Envelope:

```json
{
  "key": "{workflow-key}",
  "version": "1.0.0",
  "domain": "{domain}",
  "flow": "sys-flows",
  "flowVersion": "1.0.0",
  "tags": [],
  "attributes": {
    "type": "F",
    // optional: "history": "none" (one-shot), "executionType": "S" | "A"
    "timeout": {
      "key": "timeout", "target": "{final-or-expired-state}", "versionStrategy": "None",
      "timer": { "reset": "N", "duration": "PT15M" },
      "annotations": { "ui/countdown": "root-deadline" }
    },
    "startTransition": { /* from step 5 */ },
    "states": [ /* from step 3, with transitions from step 4 */ ]
  }
}
```

Write to `{componentsRoot}/{paths.workflows}/{workflow-key}/{workflow-key}-workflow.json`.

### 10. Generate the `.http` test file

Create `{workflow-key}.http` next to the workflow JSON:

```http
@baseUrl = http://localhost:4201
@apiVersion = 1
@domain = {domain}

### Start instance
POST {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{workflow-key}/instances/start

### Start instance — explicit mode (ignored if the flow/start transition sets executionType)
POST {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{workflow-key}/instances/start?sync=true

### Get state
GET {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{workflow-key}/instances/{instanceKey}/functions/state

### Execute each manual transition (one block per transition)
PATCH {{baseUrl}}/api/v{{apiVersion}}/{{domain}}/workflows/{workflow-key}/instances/{instanceKey}/transitions/{transitionKey}
Content-Type: application/json

{ /* transition payload */ }
```

### 11. Validate

Run `npm run validate`. Hand off failures to the `validate-and-fix` skill.

### 12. (Optional) MockLab seed update

If transitions call HTTP tasks pointing at MockLab (`API_BASEURL/…`, resolved via `GetConfigValue`), append a `mocks[]` entry to the domain's existing seed file at `etc/docker/config/seed/{collection}.json` — one collection per domain; do not split. Endpoint pattern stays `api/{domain}/{resource}/{action}`. Capture 2xx and 4xx/5xx scenarios via `rules[]` (`conditionField: "query.X" | "body.X"`, operators `equals | regex | exists | greaterThan | ...`) and use `sequenceItems[]` for retry/rate-limit demos (`isSequential: true`). Add 200–500 ms `delayMs` for realistic latency.

**Matching gotchas (MockLab 0.0.10)** — `{param}` routes never match; serve a family of paths from one base route
and branch on `path` rules. A route also matches any longer path that CONTAINS it. `curl` every rule before wiring a
task (`mocklab-seed-format.md` §3.1).

**Re-import gotcha** — MockLab skips collections whose name already exists in its DB on restart. After editing a seed, run `docker compose down -v && docker compose up -d mocklab` to force a clean import, or push the new mocks via MockLab's admin API.

Full reference: [`.claude/references/mocklab-seed-format.md`](../../references/mocklab-seed-format.md).

### 13. Integration test (default: yes)

Every workflow is expected to have an integration test class (warn-only gates G1–G4). Offer it now —
default **yes** — and hand off to the `integration-test` skill with the state/transition graph from
steps 3–5 (full scope: every Success/Error Final state, one unhappy path per conditional auto pair,
`authorize` verdicts when transitions carry roles). It scaffolds the test project if missing.

If the user skips: end the scaffold report with
"**Warning:** `<workflow-key>` has no integration test (G2) — run the `integration-test` skill later; validate
and review will keep reporting it." Running the tests is `/vnext-ai-toolkit:e2e <workflow-key>`.

## Notes

- **At most one** Initial state (0.0.99+; none → implicit `$start`). `startTransition.target` must be a declared state; `$start` is a reserved key.
- Auto transitions must cover every branch (exclusive rules, or `priority` + a `triggerKind: 10` default) — ask in step 4; `priority` never goes on manual/timer/event, default, shared or start transitions.
- `history: "none"` flows: automatic transitions only, no human states, no retry — reject the option as soon as the design needs any of them.
- Never hardcode `core/Workflows/...` — always resolve from `vnext.config.json`.
- For component references, the shape is `{ "key", "domain", "flow", "version" }` — strict mode is on, so a wrong `flow` value will fail validation.
