# Component Schemas — The Canonical Contract

> **This is the most important reference in the plugin.** Every scaffolding skill MUST fetch the canonical JSON Schema for the component it is generating, BEFORE asking the user any questions or producing any JSON. Skills never hardcode enum values, field lists, or required-field sets — they read them from the schema at runtime.

## Source

```
https://github.com/burgan-tech/vnext-schema/tree/master/schemas
```

Repo layout (one file per component type):
- `schemas/workflow.json`
- `schemas/view.json`
- `schemas/task.json`
- `schemas/schema.json`
- `schemas/function.json`
- `schemas/extension.json`
- `schemas/mapping-definition.schema.json` (the `sys-mappings` component)

The repo is **tagged per `schemaVersion`** — release `v0.0.42` matches `schemaVersion: "0.0.42"` in `vnext.config.json`. This pinning means every workspace gets the exact schema its runtime expects.

## Fetch URL pattern

```
https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/{componentType}.json
```

Where `{componentType}` is one of: `workflow`, `view`, `task`, `schema`, `function`, `extension`, `mapping`.

## Mandatory fetch flow (every scaffolding skill)

```
1. Read repo-root vnext.config.json:
   - Capture schemaVersion (e.g. "0.0.42")
   - Capture domain
   - Capture paths.* (folder resolution)

2. Fetch the canonical schema:
   GET https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/{componentType}.json

3. Fallback chain on failure:
   a) HTTP 404 on tag → retry against `master` branch + warn user "schemaVersion tag missing, using master; output may not match runtime"
   b) Network failure → fall back to the snapshot embedded in this file's appendix + warn "offline mode, snapshot may be stale"
   c) Snapshot also missing → halt; ask the user to paste the schema manually. NEVER guess.

4. Parse the schema and use it to drive:
   - `required[]` → which fields to ask the user about
   - `properties[].enum` → AskUserQuestion option lists (workflow type values, task type values, stateType, triggerType, renderer values, etc.)
   - `properties[].oneOf` / `anyOf` → branching paths
   - `additionalProperties` → whether to allow user-defined extra fields
   - `properties[].pattern`, `format`, `minimum`, `maximum`, `minLength`, `maxLength` → input validation
   - `$defs` and `$ref` → nested object skeletons

5. Generate the component skeleton populated only with schema-defined fields.

6. Run `npm run validate` — the validator uses the same `@burgan-tech/vnext-schema` package, so a schema-driven skeleton should pass on the first try.
```

## Why this matters

- **No drift between plugin and runtime.** The validator and the scaffolder share one source of truth.
- **Version-resilient.** When vNext adds a new state type, task type, or renderer, the plugin sees it on the next fetch — no code change required.
- **Smaller skill code.** Skills don't carry tables of "task type 6 = HTTP, 7 = Script, ...". They render whatever the schema declares.
- **Catches gaps in human-written docs.** If the docs portal hasn't documented a new `subType` yet, the schema still has it — the plugin asks about it.

## Rules for skills

1. **First action** of any component-generating skill is the fetch above. No exceptions.
2. **Never hardcode an enum** that exists in the schema. Render the user prompt from `properties[X].enum`.
3. **Never invent a required field** that isn't in `schema.required`.
4. **Never strip a required field** to silence a validation error — fix the data instead.
5. If the schema and a static reference (e.g. `workflow-types.md`) disagree, **the schema wins**. Update the reference if the schema's behavior is clearly intentional.

## Reading the schema in practice

Most vNext component schemas follow this top-level shape:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "...",
  "type": "object",
  "required": ["key", "version", "domain", "flow", "attributes"],
  "properties": {
    "key": { "type": "string", "pattern": "^[a-z0-9-]+$" },
    "version": { "type": "string", "pattern": "^\\d+\\.\\d+\\.\\d+$" },
    "domain": { "type": "string" },
    "flow": { "const": "sys-flows" },
    "attributes": {
      "type": "object",
      "required": [ /* component-specific */ ],
      "properties": { /* component-specific */ }
    }
  }
}
```

The interesting part is `properties.attributes` — that's where the type-specific contract lives. Skills focus their fetch + parse there.

## Appendix: Snapshot strategy

When network is unavailable, skills fall back to a snapshot stored next to this file (`schemas-snapshot/` — to be populated during plugin release). The snapshot is regenerated on each plugin release from the matching `vnext-schema` tag. It is **never edited by hand**.

Snapshot files (filled in at release time):
- `schemas-snapshot/{schemaVersion}/workflow.json`
- `schemas-snapshot/{schemaVersion}/view.json`
- `schemas-snapshot/{schemaVersion}/task.json`
- `schemas-snapshot/{schemaVersion}/schema.json`
- `schemas-snapshot/{schemaVersion}/function.json`
- `schemas-snapshot/{schemaVersion}/extension.json`

If a workspace's `schemaVersion` matches a snapshot, the plugin can serve it offline. Otherwise it warns and uses the closest available.
