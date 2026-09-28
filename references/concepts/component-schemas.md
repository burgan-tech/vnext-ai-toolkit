# Component Schemas — The Canonical Contract

> **This is the most important reference in the plugin.** Every scaffolding skill MUST load the canonical JSON Schema for the component it is generating, BEFORE asking the user any questions or producing any JSON. Skills never hardcode enum values, field lists, or required-field sets — they read them from the schema at runtime.
>
> **This file is the single place the schema location is spelled out.** Skills, agents and commands say "resolve the schema as described in `references/concepts/component-schemas.md`" and never repeat a URL or path of their own — when the package layout changes, only this file changes.

## Where the schemas live

The schemas are published as the npm package **`@burgan-tech/vnext-schema`**. The repo behind it is `https://github.com/burgan-tech/vnext-schema` (`schemas/` + `vocabularies/`), tagged per release (`v{schemaVersion}`).

Real file names (one per component type — note the `-definition.schema.json` suffix):

| Component (`flow`) | Schema file |
|---|---|
| `sys-flows` (workflow) | `schemas/workflow-definition.schema.json` |
| `sys-tasks` | `schemas/task-definition.schema.json` |
| `sys-views` | `schemas/view-definition.schema.json` |
| `sys-schemas` | `schemas/schema-definition.schema.json` |
| `sys-functions` | `schemas/function-definition.schema.json` |
| `sys-extensions` | `schemas/extension-definition.schema.json` |
| `sys-mappings` | `schemas/mapping-definition.schema.json` |
| shared header / root | `schemas/core-header.schema.json`, `schemas/core-schema.schema.json` |
| `x-*` vocabularies | `vocabularies/view-vocab.json`, `data-vocab.json`, `roles-vocab.json` |

The reusable pieces of the workflow and function schemas sit under **`definitions`** (draft-07 style `#/definitions/...`), not `$defs`.

## Resolution order

**1. Primary — the workspace's installed package.** A `@burgan-tech/vnext-template` workspace pins the schema in `package.json` (`"@burgan-tech/vnext-schema": "^0.0.NN"`), and `npm run validate` uses exactly that copy. Read:

```
node_modules/@burgan-tech/vnext-schema/schemas/{type}-definition.schema.json
node_modules/@burgan-tech/vnext-schema/vocabularies/{file}.json
```

This is what the validator sees, so a skeleton built from it passes `npm run validate` on the first try. Confirm the installed version with `node_modules/@burgan-tech/vnext-schema/package.json` → `version`, and compare it with `vnext.config.json` → `schemaVersion`; if they differ, tell the user (the config is the intent, the package is what validates).

**2. Fallback — raw GitHub at the pinned tag** (no `node_modules`, or the user is working outside a template workspace):

```
https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/{type}-definition.schema.json
https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/vocabularies/{file}.json
```

where `{schemaVersion}` comes from `vnext.config.json` (currently `0.0.54` for runtime 0.0.97) and `{type}` is one of `workflow`, `task`, `view`, `schema`, `function`, `extension`, `mapping`.

**3. If the tag 404s** → retry against `master` and warn "schemaVersion tag missing, using master; output may not match the validator".

**4. If everything fails** → halt and ask the user to paste the schema. **Never guess an enum or a required field.** There is no offline snapshot bundled with the plugin.

## Mandatory flow (every scaffolding skill)

```
1. Read repo-root vnext.config.json:
   - Capture schemaVersion (e.g. "0.0.54"), domain, paths.*

2. Load the schema by the resolution order above (node_modules first).

3. Parse it and use it to drive:
   - required[]                         → which fields to ask the user about
   - properties[].enum                  → AskUserQuestion option lists (workflow type, task type, stateType, triggerType, renderer…)
   - properties[].oneOf / anyOf         → branching paths
   - additionalProperties               → whether user-defined extra fields are allowed
   - pattern / format / min / max / len → input validation
   - definitions + $ref                 → nested object skeletons

4. Generate the component skeleton populated only with schema-defined fields.

5. Run `npm run validate` — same package, same result.
```

## What the schema does NOT tell you

The schema is the **authoring** contract; the runtime is the **execution** contract, released separately. Known differences are catalogued in **`schema-runtime-gaps.md`** — read it whenever validate and the runtime disagree. Headline items:

- Schema **0.0.54 validates task types `"1"`–`"21"` only**; the runtime (v0.0.97) also knows `22` (ExternalHttp, deprecated — use `6`) and `23` (Python). A definition using them fails `npm run validate` but publishes fine.
- Some shapes the schema accepts are rejected at `publish` (state-level `subFlow.type: "P"`, colliding multi-task keys), and some schema-required fields are ignored at runtime (`timeout.timer.reset`).
- `x-filterOperators` must be authored with the runtime's schema-side spellings (`gte`, `lte`, `neq`, `contains`…), not the wire names the vocabulary enum lists.

## Why this matters

- **No drift between plugin and validator.** The validator and the scaffolder share one file.
- **Version-resilient.** When vNext adds a state type, task type or renderer, the plugin sees it on the next read — no code change required.
- **Smaller skill code.** Skills don't carry tables of "task type 6 = HTTP, 7 = Script, …". They render whatever the schema declares; `task-types.md` exists for *semantics*, not for enum membership.
- **Catches gaps in human-written docs.** If the docs portal hasn't documented a new `subType` yet, the schema still has it.

## Rules for skills

1. **First action** of any component-generating skill is the schema load above. No exceptions.
2. **Never hardcode an enum** that exists in the schema. Render the user prompt from `properties[X].enum`.
3. **Never invent a required field** that isn't in `schema.required`.
4. **Never strip a required field** to silence a validation error — fix the data instead (or apply the workaround in `schema-runtime-gaps.md`).
5. If the schema and a static reference (e.g. `workflow-types.md`) disagree, **the schema wins for validation**; if the schema and the runtime disagree, `schema-runtime-gaps.md` says which form to author.
6. **Never spell out the fetch URL or path in a skill** — point here.

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
  },
  "definitions": { /* reusable pieces referenced by $ref */ }
}
```

The interesting part is `properties.attributes` — that's where the type-specific contract lives. Skills focus their parse there.

## Sources

- Package: `@burgan-tech/vnext-schema` (npm); repo `https://github.com/burgan-tech/vnext-schema` @ `ac42026` (v0.0.54) — `schemas/*.json`, `vocabularies/*.json`
- Workspace pin: `package.json` → `@burgan-tech/vnext-schema`, `vnext.config.json` → `schemaVersion` (e.g. `vnext-example` @ `3b5ebab`)
- Gaps: `references/concepts/schema-runtime-gaps.md`; version matrix: `references/runtime-feature-matrix.md`
