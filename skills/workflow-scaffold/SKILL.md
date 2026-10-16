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
- **For auto transitions**: confirm complementary pair (mutually exclusive `rule` conditions) — a lone conditional auto transition is invalid; if there's only one, it must be unconditional.
- **For timer**: `duration` (ISO 8601, e.g. `PT15M`)
- **`onExecutionTasks`**: which tasks run during the transition, and which `.csx` mapping shapes each task's input/output. Entries at the same `order` run in parallel and merge by slot `variableKey ?? camelCase(task.key)`; if the **same task** is bound twice at one order (e.g. two SubProcess starts), give at least one a `"variableKey"` (0.0.99; publish rejects a slot collision — same rule for `onEntries` / `onExits`). "Do X for each item in a list" → a **FanOut task** (type 21), not an auto loop — `references/concepts/fan-out.md`.
- **`executionType`** (optional, `"S"` / `"A"`) if this transition must not depend on the caller's `?sync`.
- **`annotations`** (optional, see above)

### 5. Identify the start transition

Exactly one `attributes.startTransition`. Its `target` is **required** and must name a declared
state — the Initial state if there is one, otherwise any state (the instance is born in the implicit
`$start` and enters it). `$self`, `$start` and an empty target are rejected at publish (0.0.99,
#1068). No `view`; an optional `schema` validates the start payload; optional `executionType`.
If the flow should also start **on a schedule**, note that runtime 0.0.100 exposes
`POST …/instances/schedule?scheduleId=…` for a Dapr `bindings.cron` component (seed values arrive as
query-string **strings**) — `references/concepts/workflow-types.md` §6.

### 6. Spin off dependencies (chain skills)

For each view referenced in step 3 that does not yet exist → invoke the `view-design` skill.
For each schema needed (workflow master schema, transition payloads) that does not yet exist → invoke the `schema-design` skill.

These can be deferred (scaffold the workflow first with placeholder refs, then fill in), but record what's pending.

### 7. Scaffold `.csx` mapping files

For each `onExecutionTasks` entry that needs input/output mapping:

- Create `src/{PascalCaseClassName}.csx` with a skeleton class.
- The workflow JSON's `mapping.location` points to `./src/{file}.csx`; the VS Code extension auto-encodes the file into `mapping.code` (base64) on save. **Do not manually base64-encode.**

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
- Auto transitions must come in complementary pairs (or be unconditional) — the validator catches this; the skill should catch it earlier in step 4.
- `history: "none"` flows: automatic transitions only, no human states, no retry — reject the option as soon as the design needs any of them.
- Never hardcode `core/Workflows/...` — always resolve from `vnext.config.json`.
- For component references, the shape is `{ "key", "domain", "flow", "version" }` — strict mode is on, so a wrong `flow` value will fail validation.
