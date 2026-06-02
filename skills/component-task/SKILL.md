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
2. Fetch https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/task.json
   ├─ Fail → master branch → references/concepts/component-schemas.md snapshot
   └─ No snapshot → halt; never guess.
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

### 3. Choose the task type (from schema)

Render `AskUserQuestion` with the enum from `task.json`. Annotate by common use:
- HTTP / REST → `HttpTask` (type usually 6)
- C# script (no external call) → `ScriptTask` (usually 7)
- Notification (SMS/email/push) → `NotificationTask` (usually 10) — requires `INotificationMapping`
- Cross-workflow query → `GetInstancesTask` (usually 15)
- Legacy SOAP → `SoapTask` (usually 16)
- Internal service via Dapr → `DaprService` (usually 3)
- Async messaging → `DaprPubSub` (usually 4)
- Start another workflow → `StartFlowTask`
- Fire a transition on an existing instance → `TriggerTransitionTask`

(Verify the exact numbers and full list from the fetched schema — the table above is illustrative.)

### 4. Fill the `config` from the schema

Once the user picks a type, the schema tells you the per-type `config` shape. For example, an HTTP task's config needs `url`, `method`, optional `headers`, `body`, `timeoutSeconds`, `validateSsl`. Walk the user through each required field.

For URLs that hit external systems during development, default to MockLab: `http://localhost:3001/api/{domain}/{resource}/{action}`. Production URLs are hardcoded only when explicitly requested.

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

Use `references/concepts/csx-contracts.md` for the exact interface signature, standard `using` directives, and class structure.

### 8. (HTTP/SOAP/Dapr tasks) Add a MockLab seed

If the task calls `localhost:3001`, append a `mocks[]` entry to the domain's collection file at `etc/docker/config/seed/{domain}-collection.json`. **One collection per domain** — don't split.

Mock entry pattern (see `references/concepts/mocklab-spec.md` for the full reference):

```jsonc
{
  "httpMethod": "POST",
  "route": "api/{domain}/{resource}/{action}",
  "statusCode": 200,
  "responseBody": "{ \"id\": \"{{ helpers.guid() }}\" }",
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
