---
name: component-task
description: Use when the user wants to create a new vNext Task component (HTTP, Script, SOAP, Dapr, Notification, GetInstances, etc.). Fetches task.json schema first, drives type and config selection from the schema enum, scaffolds a .csx mapping if needed, suggests a matching MockLab seed.
---

# Component Task

A Task is the unit of action inside a workflow — invoked from a transition's `onExecutionTasks[]`, a state's `onEntries[]`/`onExits[]`, or composed inside a Function. The `type` field selects the kind of action (HTTP, script, SOAP, Dapr, notification, etc.).

## Canonical schema-first (mandatory pre-step)

> **Before asking about task type or config, fetch `task.json` for the workspace's `schemaVersion`.** The task type enum, the per-type `config` shapes, and the required-field lists all live in this schema — never hardcode them.

```
1. Read vnext.config.json → schemaVersion + domain + paths.tasks
2. Load the task schema from the pinned package:
   node_modules/@burgan-tech/vnext-schema/schemas/task-definition.schema.json
   (missing → `npm install`; version/fallback rules → references/concepts/component-schemas.md;
   never guess field names from memory)
3. Parse:
   - properties.attributes.properties.type.enum (or oneOf branching on type)
   - per-type `config` shape (HTTP has url/method/headers/body; SOAP has wsdl/...; Dapr has app-id/...)
   - required[] per type
4. Drive AskUserQuestion options + skeleton from this schema.
```

See `references/concepts/component-schemas.md` and `references/concepts/function-vs-extension-vs-task.md` for the mental model.

## Steps

### 1. Resolve paths

From `vnext.config.json`: `componentsRoot`, `paths.tasks`, `domain`.
Target path: `{componentsRoot}/{paths.tasks}/{domain-subfolder}/{task-key}.json`.

The `{domain-subfolder}` mirrors the parent workflow's folder name when the task is workflow-specific (e.g. `account-opening`). For shared/cross-workflow tasks, use a meaningful grouping (e.g. `shared`, `notifications`).

### 2. Determine purpose

Ask:
- **What does this task do?** (One sentence — e.g. "Create a bank account by calling the core banking API")
- **Is it called from a workflow transition, a function, or both?** (Affects which mapping interface you'll need.)
- **Is it reusable across workflows?** (If yes, consider extracting to a Function later.)

### 3. Choose the task type (from schema + catalog)

Render `AskUserQuestion` with the enum from the task schema, annotated from
`references/concepts/task-types.md` (the full 1–23 catalog with config shapes, default execution
location and pitfalls). Most common picks:

| Need | Type | Notes |
|---|---|---|
| HTTP / REST call | `6` Http | runs **in-process on Orchestration** (routed Local since 0.0.94); MockLab URL in dev |
| C# logic, no external call | `7` Script | |
| SMS / email / push | `10` Notification | needs `INotificationMapping` |
| Start another workflow | `11` StartTrigger | same-domain → in-process; `sync` defaults to `false` |
| Fire a transition on an existing instance | `12` DirectTrigger | `version` is deprecated |
| Read another instance's data | `13` GetInstanceData / `19` GetInstance | system identity, unfiltered |
| Independent child process | `14` SubProcess | the **only** way to start a SubProcess (never state-level `subFlow.type "P"`) |
| Query instances | `15` GetInstances | invalid filter now **faults** the task — declare `x-filterOperators` correctly |
| Legacy SOAP | `16` Soap | Local |
| Dapr state store get/set/delete | `17` StateStore | Local; custom `storeName` needs an orchestrator-scoped Dapr component |
| Cache an expensive task's result | `18` CacheAside | Local; wraps a `sourceTask`, `ttlInSeconds`, `bypassOnCacheError` |
| LLM conversation via Dapr | `20` DaprConversation | Remote |
| **Same work over a data-driven collection** | `21` FanOut | see `references/concepts/fan-out.md`; ask this whenever the user says "for each …" |
| Internal service via Dapr | `3` DaprService | Local; `httpVerb` must be set |
| Async messaging | `4` DaprPubSub | Remote |

Do **not** offer `5` Human (a stub — human approval is a *state* with `subType: 6`, see
`references/concepts/human-task.md`), `8` Condition / `9` Timer (no executor), `22` ExternalHttp
(deprecated 0.0.94 → use 6) or `23` Python unless the user asks (experimental; `Python:Enabled` is
off by default). **Schema ceiling:** vnext-schema 0.0.54 validates `"1"`–`"21"` only — a `22`/`23`
task fails `npm run validate` even though the runtime runs it (`references/concepts/schema-runtime-gaps.md`).

Before continuing: if the workspace `runtimeVersion` is below a type's `since` in
`references/runtime-feature-matrix.md`, say so and pick an older alternative.

### 4. Fill the `config` from the schema

Once the user picks a type, the schema tells you the per-type `config` shape. For example, an HTTP task's config needs `url`, `method`, optional `headers`, `body`, `timeoutSeconds`, `validateSsl`. Walk the user through each required field.

For URLs that hit external systems during development, default to MockLab: `http://localhost:3001/api/{domain}/{resource}/{action}`. Production URLs are hardcoded only when explicitly requested.

**Error boundary reminders.** `errorBoundary.onError[].action` must be an **integer** (0–5) to pass the schema even though the runtime also accepts strings; `errorBoundary.onTimeout` is accepted by the schema but never read; a task timeout surfaces as `…:TaskCanceledException` with **no status code**, so only an `errorTypes` rule can catch it; `errorTypes` rules now match on the in-process path too (they silently never did on the remote path before 0.0.94) — dormant rules may fire for the first time after an upgrade.

**FanOut (21).** If chosen, walk `references/concepts/fan-out.md`: `itemsPath` XOR `ItemSelector`, inner `task` reference (distinct task definition), `execution.{maxDegreeOfParallelism,itemTimeoutSeconds ≤ batchTimeoutSeconds}`, `join.{policy,resultKey}` (default `allSettled`; branch on `{resultKey}Summary` with an order-80 auto transition), and scaffold an `IFanOutMapping` `.csx` with at least `ItemInputHandler`.

### 5. Look at a sibling task

Read one existing task of the same type in this workspace (or in `vnext-example`) for envelope reference. Examples:
- HTTP: `vnext-example/core/Tasks/account-opening/create-bank-account.json`
- Script: `vnext-example/core/Tasks/.../flow-types-script-task.json`
- Notification: `vnext-example/core/Tasks/.../notification-task.json`
- Dapr: `vnext-example/core/Tasks/.../dapr-service-task.json`

Use it to confirm field order; don't blindly copy.

### 6. Generate the task JSON

Standard envelope:

```json
{
  "key": "{task-key}",
  "version": "1.0.0",
  "domain": "{domain}",
  "flow": "sys-tasks",
  "flowVersion": "1.0.0",
  "tags": [],
  "attributes": {
    "type": "{type-from-schema}",
    "config": { /* per-type, populated from schema requirements */ }
  }
}
```

Write to the path from Step 1.

### 7. Scaffold a `.csx` mapping if the caller needs one

Most consumers (transitions, functions) attach a mapping to their reference of this task. The mapping lives in the **caller's** `src/` folder, not the task's:

- Workflow transition: `{paths.workflows}/{workflow-key}/src/{ClassName}Mapping.csx`
- Function task: `{paths.functions}/{function-key}/src/{ClassName}Mapping.csx`

For `NotificationTask`, the mapping implements `INotificationMapping` (per-channel). For all other tasks, the mapping usually implements `IMapping`.

Use `references/concepts/csx-contracts.md` for the exact interface signature, standard `using` directives, and class structure. Mapping classes inherit `ScriptBase` and read dynamic data only through its helpers (`HasProperty`, `GetPropertyValue`, `GetList`, …) — direct dynamic access like `context.Instance.Data.x?.y` throws at runtime when the member is absent. Note: `INotificationMapping`'s method is `ChannelHandler(string channel, ScriptContext context)`, not `Handler`.

### 8. (HTTP/SOAP/Dapr tasks) Add a MockLab seed

If the task calls `localhost:3001`, append a `mocks[]` entry to the domain's collection file at `etc/docker/config/seed/{domain}-collection.json`. **One collection per domain** — don't split.

Mock entry pattern (see `references/concepts/mocklab-spec.md` for the full reference):

```jsonc
{
  "httpMethod": "POST",
  "route": "api/{domain}/{resource}/{action}",
  "statusCode": 200,
  "responseBody": "{ \"id\": \"{{ guid }}\" }",
  "contentType": "application/json",
  "delayMs": 500,
  "rules": [
    /* per-input-condition responses, if needed */
  ]
}
```

Remind the user: after editing seeds, run `docker compose down -v && docker compose up -d mocklab` to force re-import.

### 9. Validate

Run `npm run validate`. Hand off failures to `validate-and-fix`.

### 10. Wire into the caller (optional)

If the user wants this task wired now, edit the caller (workflow transition's `onExecutionTasks[]` or function's `task` / `onExecutionTasks[]`) and add the reference:

```json
{ "key": "{task-key}", "domain": "{domain}", "flow": "sys-tasks", "version": "1.0.0" }
```

Re-validate.

## Notes

- Task `type` numeric values come from the schema — never hardcode them.
- Production URLs in task config are a code-review red flag during development; MockLab during dev, environment overrides at deploy time.
- A `NotificationTask` without an `INotificationMapping` is a runtime no-op — always pair them.
- If the same task config is duplicated across many transitions, consider extracting to a Function with a single shared task.
