---
name: component-extension
description: Use when the user wants to create a vNext Extension — automatic instance data enrichment on workflow reads. Fetches extension.json schema first, walks the type × scope matrix from the schema, warns on performance impact (especially Global × Everywhere).
---

# Component Extension

An Extension automatically enriches workflow instance data on read operations. Unlike a Function (client must call), an Extension fires implicitly when the runtime serves an instance read endpoint. Common uses:

- Attach user session details to every workflow instance
- Join customer profile, branch info, or other related data
- Cross-cutting metadata (audit, permissions, computed fields)

## Canonical schema-first (mandatory pre-step)

> **Before asking about type or scope, fetch `extension.json` for the workspace's `schemaVersion`.** The `type` × `scope` matrix and the task composition rules come from the schema.

```
1. Read vnext.config.json → schemaVersion + domain + paths.extensions
2. Fetch https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/extension.json
   ├─ Fail → master → references/concepts/component-schemas.md snapshot
   └─ No snapshot → halt; never guess.
3. Parse:
   - properties.attributes.properties.type.enum (typical: 1 Global, 2 GlobalAndRequested, 3 DefinedFlows, 4 DefinedFlowAndRequested)
   - properties.attributes.properties.scope.enum (typical: 1 GetInstance, 2 GetAllInstances, 3 Everywhere)
   - task or tasks[] composition + mapping shape
   - required[]
4. Drive AskUserQuestion + skeleton from this schema.
```

See `references/concepts/function-vs-extension-vs-task.md` for the mental model.

## Steps

### 1. Resolve paths

From `vnext.config.json`: `componentsRoot`, `paths.extensions`, `domain`.
Target path: `{componentsRoot}/{paths.extensions}/{extension-key}/{extension-key}.json`.

### 2. Determine purpose

Ask:
- **What does this extension add?** (One sentence — e.g. "Attach the customer profile to every instance read")
- **Does it apply to every workflow, or only specific ones?** (Drives `type` 1/2 vs 3/4.)
- **Should it fire on single-instance reads, list queries, or everywhere?** (Drives `scope` 1/2/3.)

### 3. Choose type (from schema)

Render the `type` enum:

| Value | Name | Effect |
|-------|------|--------|
| 1 | Global | Fires on every workflow's read endpoints |
| 2 | GlobalAndRequested | Type 1 + can also be explicitly requested |
| 3 | DefinedFlows | Fires only on workflows that reference it |
| 4 | DefinedFlowAndRequested | Type 3 + explicit request |

(Verify the enum from the fetched schema.)

### 4. Choose scope (from schema)

| Value | Name | Endpoints |
|-------|------|-----------|
| 1 | GetInstance | Single-instance read |
| 2 | GetAllInstances | List query |
| 3 | Everywhere | All endpoints |

### 5. **Performance warning**

Before scaffolding, warn the user about the performance cost of broad combinations:

- **Type 1 × Scope 3** (Global × Everywhere) fires on every endpoint hit across the runtime. Use sparingly — only for very cheap enrichment (e.g. attaching the auth user's ID).
- **Type 1 × Scope 2** (Global × GetAllInstances) fires per item in list responses. If the extension makes an HTTP call per item, list endpoints become very slow.
- **Type 3 × Scope 1** (DefinedFlows × GetInstance) is the lightweight default — recommend this for typical enrichment.

If the user picks a heavy combination, ask them to confirm and document why.

### 6. Define the task composition

Extensions execute one or more tasks (typically HTTP or Script) to fetch the supplementary data. Two shapes (the schema's `oneOf` will tell you which):

- **Single task** — `attributes.task` field with `order`, `task` reference, `mapping`.
- **Multiple tasks** — `attributes.tasks[]` array (or `onExecutionTasks[]` — verify from schema), aggregated via a single mapping.

### 7. Reference or create tasks

For each task this extension calls:
- If a matching task exists, reference it.
- Otherwise, hand off to `component-task`; come back when ready.

### 8. Scaffold the `.csx` mapping

The mapping shapes the upstream task's response into the enrichment object that gets attached to the instance read response. Typical signature:

```csharp
using System.Threading.Tasks;
using BBT.Workflow.Scripting;
using BBT.Workflow.Definitions;

public class {ClassName}Mapping : IMapping
{
    public Task<ScriptResponse> InputHandler(WorkflowTask task, ScriptContext context)
    {
        // context.Instance.Data is available — use it to build the upstream call
        // e.g. HTTP request for the user's customer details by customer ID
        return Task.FromResult(new ScriptResponse { /* … */ });
    }

    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        // Unwrap context.Body, return the enrichment payload
        // The runtime attaches it to the instance read response under `extensions[key]` (or similar)
        return Task.FromResult(new ScriptResponse {
            Key = "{extension-key}",
            Data = context.Body?.data ?? context.Body
        });
    }
}
```

Refer to `references/concepts/csx-contracts.md` for full contract details.

### 9. Generate the extension JSON

Envelope (single-task variant — multi-task shape comes from the schema):

```json
{
  "key": "{extension-key}",
  "version": "1.0.0",
  "domain": "{domain}",
  "flow": "sys-extensions",
  "flowVersion": "1.0.0",
  "tags": [],
  "attributes": {
    "type": 3,
    "scope": 1,
    "task": {
      "order": 1,
      "task": { "key": "{task-key}", "domain": "{domain}", "flow": "sys-tasks", "version": "1.0.0" },
      "mapping": { "location": "./src/{ClassName}Mapping.csx", "code": "" }
    }
  }
}
```

`mapping.code` is empty — the VS Code extension auto-encodes on save.

### 10. Write the file

Path: `{componentsRoot}/{paths.extensions}/{extension-key}/{extension-key}.json`. `.csx` mappings go in the adjacent `src/`.

### 11. Wire into workflows (for Type 3/4 DefinedFlows)

For Type 1/2 (Global), the extension fires automatically — no wiring needed. For Type 3/4 (DefinedFlows), each target workflow must reference this extension. Edit the workflow JSON's `attributes.extensions[]` (or equivalent — verify from `workflow.json` schema) and add:

```json
{ "key": "{extension-key}", "domain": "{domain}", "flow": "sys-extensions", "version": "1.0.0" }
```

### 12. Validate

Run `npm run validate`. Hand failures to `validate-and-fix`.

## Notes

- Type 1 extensions intentionally have no workflow references — they fire implicitly. Don't try to "register" them per-workflow.
- The enrichment shows up in the response under a runtime-defined key (typically `extensions[key]` or similar). Verify by hitting the runtime endpoint and inspecting the response.
- Extensions that make HTTP calls on `Scope: Everywhere` are a top cause of slow list endpoints. If the extension is expensive, consider Type 3/4 (DefinedFlows) so only workflows that need it pay the cost.
