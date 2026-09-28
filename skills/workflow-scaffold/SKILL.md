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

**Roles gate (mandatory question).** Before designing any state or transition, **ask the user whether this flow should configure roles (`queryRoles`/`roles`) at all** — via `AskUserQuestion`, with "no roles" as the Recommended default. Roles add real complexity, especially for vNext newcomers; never add role configuration without explicit user confirmation. If confirmed, follow `references/concepts/roles-and-authorization.md` — and remember the 0.0.95 model: the runtime only *filters visibility* by roles; the **`authorize` function** (called by the gateway) is the single enforcement point, so a local runtime without a gateway will not 403 on reads.

### 3. Map the states

Walk through the flow with the user. For each state capture:

- **Key** (kebab-case)
- **stateType** (Initial / Intermediate / Final / SubFlow / Wizard — values from the fetched schema)
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

**Initial state input pattern** — if the Initial state needs user input before anything happens, **propose placing the form on `state.view`** (not on the outgoing transition) and confirm with the user via `AskUserQuestion`. Reason: the runtime serves the state view immediately on instance start; the user fills it and submits via a `view: null` transition. The reverse (form on transition) forces an extra discovery step with no UX benefit. Make state-view the Recommended option; only switch if the user wants an intentional "intro screen → tap → form" two-step. See `references/concepts/workflow-types.md` for the pattern note.

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
90, since 0.0.90) — a state passed through by an auto never schedules its timers. Details:
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
- **`onExecutionTasks`**: which tasks run during the transition, and which `.csx` mapping shapes each task's input/output. Parallel tasks at the same `order` must be **distinct task definitions** (the journal key is transition+task+order). "Do X for each item in a list" → a **FanOut task** (type 21), not an auto loop — `references/concepts/fan-out.md`.
- **`annotations`** (optional, see above)

### 5. Identify the start transition

Exactly one initial transition; its `target` is the first state. Encode as `attributes.startTransition`.

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

If transitions call HTTP tasks pointing at `localhost:3001`, append a `mocks[]` entry to the domain's existing seed file at `etc/docker/config/seed/{collection}.json` — one collection per domain; do not split. Endpoint pattern stays `api/{domain}/{resource}/{action}`. Capture 2xx and 4xx/5xx scenarios via `rules[]` (`conditionField: "query.X" | "body.X"`, operators `equals | regex | exists | greaterThan | ...`) and use `sequenceItems[]` for retry/rate-limit demos (`isSequential: true`). Add 200–500 ms `delayMs` for realistic latency.

**Re-import gotcha** — MockLab skips collections whose name already exists in its DB on restart. After editing a seed, run `docker compose down -v && docker compose up -d mocklab` to force a clean import, or push the new mocks via MockLab's admin API.

Full reference: [`.claude/references/mocklab-seed-format.md`](../../references/mocklab-seed-format.md).

## Notes

- Exactly **one** initial state per workflow (enforced by validator).
- Auto transitions must come in complementary pairs (or be unconditional) — the validator catches this; the skill should catch it earlier in step 4.
- Never hardcode `core/Workflows/...` — always resolve from `vnext.config.json`.
- For component references, the shape is `{ "key", "domain", "flow", "version" }` — strict mode is on, so a wrong `flow` value will fail validation.
