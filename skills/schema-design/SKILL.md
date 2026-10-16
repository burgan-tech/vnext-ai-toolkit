---
name: schema-design
description: Use when the user wants to create or modify a vNext Schema component. Asks the schema's role first (master / transition / function / component — split a multi-role schema), then gathers fields, labels and form hints, sensitive-data protection for every PII field (x-roles / x-masking / x-encryption), query metadata with x-indexed on every filtered or sorted field, x-computed, x-storage file fields and client context keywords, and produces JSON Schema draft 2020-12 at the path resolved from vnext.config.json.
---

# Schema Design

Schemas drive view rendering, transition validation, record exposure and queries. **Never** produce schema
JSON before gathering the field shape from the user — guessing leads to schemas that fail validation or
mismatch the workflow. Since schema package 0.0.56 **a schema plays exactly one role**, and the role
decides which `x-*` keywords it may carry — so the role is the first question.

## Prerequisites

- Working directory is a vNext domain project (has `vnext.config.json`).
- The user knows roughly what the schema describes (a flow's stored data, a transition body, a function
  input, an embedded view component's input).

## Canonical schema-first (mandatory pre-step)

> **Before producing schema JSON, load** (1) `schema-definition.schema.json` (the envelope and the
> `attributes.type` role enum) and (2) the role vocabularies, pinned to the workspace's `schemaVersion`.

```
1. Read vnext.config.json → schemaVersion + domain + paths.schemas
2. Load from the pinned package (missing → `npm install`; rules → references/concepts/component-schemas.md):
   a) node_modules/@burgan-tech/vnext-schema/schemas/schema-definition.schema.json
   b) node_modules/@burgan-tech/vnext-schema/vocabularies/*.json
      role vocabularies: record-vocab (master), input-vocab (transition, function), component-vocab (component);
      shared: data-base-vocab (base keywords), view-hints-vocab (view hints), view-vocab (keyword shapes),
      data-vocab (x-context-source / x-context-target), roles-vocab (role grants)
3. Parse:
   - schema-definition.schema.json `properties.attributes.properties.type.enum` → the role options
   - <role>-vocab.json `#/definitions/allowedKeywords` → the ONLY x-* keywords to offer for that role
   - view-vocab.json / record-vocab.json / data-vocab.json definitions → each keyword's inner shape
4. Drive AskUserQuestion lists + skeleton from these. Never invent an x-* keyword or a shape.
```

Role × keyword matrix, shapes and pitfalls: `references/concepts/schema-vocabularies.md`. Protection:
`references/concepts/field-protection.md`. Files: `references/concepts/file-fields.md`.

## Steps

### 1. Resolve paths from `vnext.config.json`

Capture `paths.componentsRoot`, `paths.schemas`, `domain`. Target write path:
`{componentsRoot}/{paths.schemas}/{domain-subfolder}/{key}.json`.

### 2. Ask the role FIRST

`AskUserQuestion` — "Where is this schema used?" Options from the enum (never `workflow`, `task-input`,
`view-data` or other legacy values — the 0.0.56 package refuses them):

| Answer | `attributes.type` | Vocabulary |
|---|---|---|
| The flow's stored data (`workflow.attributes.schema`) | `master` | record |
| A transition's request body | `transition` | input |
| A function's `inputSchema` | `function` | input |
| The `dataSchema` of an embedded view component that sends nothing itself | `component` | component |

- **Used in more than one place → split it (default recommendation).** One schema per role, shared fields
  copied into each, each with its own `attributes.type`. Typical splits: master + transition body (always
  for file fields), transition body + read-only display view. Leaving `attributes.type` empty is the last
  resort — explain that the package then checks nothing role-related and `x-indexed` becomes impossible.
- **Editing an existing schema with a legacy value** (`workflow`, `schema`, `view`, `headers`,
  `task-input` …): map it by actual usage (table in `schema-vocabularies.md` §2) and fix it in the same
  change. The runtime still publishes legacy values with a warning; `npm run validate` refuses them.
- Which view binds to which role: state view → `master`; transition/input view → `transition`; embedded
  `Component` → `component` (`references/concepts/view-roles.md`).

### 3. Gather the field list (interactive)

For every field: name (confirm the repo's casing convention), JSON `type`, required? (not on `master` —
see step 11), format / `pattern` / length / range, `enum`, default. Recurse into objects; ask the item
shape of arrays.

### 4. Labels and form hints (every role)

Offer per field, only if the role's `allowedKeywords` lists them:

- `x-labels` `{ "tr": "…", "en": "…" }`; `x-enum` — an **object** keyed by enum value
  (`{ "TRY": { "tr": "…", "en": "…" } }`), never an array.
- `x-order` (number), `x-helpText`, `x-placeholder` (localized), `x-uiHint`, `x-uiNote`, `x-group`.
- `x-errorMessages` — keys only from: `required`, `minLength`, `maxLength`, `minItems`, `maxItems`,
  `uniqueItems`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `pattern`,
  `format`, `enum`, `const`.
- `x-lov` — `valueField` + `displayField` + **exactly one** of `source` (function URN, may interpolate
  `{{$form.x}}`) or `items` (`$instance.<path>` / `$form.<path>` array, no request); optional
  `imageField`; `filter[]` `{ param, value, required? }` where `param` may carry an operator
  (`"status:in"`) and a literal `value` may be an array. Every function behind `source` needs
  `rawResponse: true`.
- `x-lookup` — `{ source (URN), resultField (JSONPath), filter[]? }` on its own well-named property.
- `x-conditional` — `{ showIf | hideIf | enableIf | disableIf }`, each `{ field, operator, value }` or
  `allOf`/`anyOf`/`not`; operators: `equals`, `notEquals`, `in`, `notIn`, `isEmpty`, `isNotEmpty`,
  `contains`, `greaterThan`, `lessThan`, `greaterThanOrEquals`, `lessThanOrEquals`, `startsWith`,
  `endsWith`. "Required when …" → JSON Schema `allOf` + `if`/`then`.
- `x-validation` — an **object** `{ rule, parameters?, errorMessages? }` run by the client delegate; the
  runtime never executes it.

### 5. Sensitive data — ASK for every PII / sensitive field (mandatory, no silent default)

Go through the field list and flag anything that is PII or sensitive (national id, name, birth date,
phone, e-mail, address, IBAN / account / card data, income, health, credentials, tokens, documents). For
**each** flagged field ask the user explicitly; never pick for them and never leave a flagged field
unprotected without an explicit "no protection, because …" from the user (write that reason in the
component `description` or the PR).

On a **master** schema, `AskUserQuestion` per field (multi-select where valid):

| Option | Writes |
|---|---|
| Hide from some callers | `x-roles` — ask which roles may read (`allow`) / must not (`deny`); grants are `role` / `allOf` / `anyOf`, depth 1. Read-only: it does not stop writes |
| Show masked to most callers | `x-masking` `mask` (`keepFirst`/`keepLast`/`maskingChar`) or `replace` (`value`); `roles` = allow-only exemption list (no `deny`, no combinators) |
| Store encrypted, a few roles read plaintext | `x-encryption` `{ "type": "encrypt", "roles": [allow…] }` |
| Store only a one-way hash (equality within one instance) | `x-encryption` `{ "type": "hash", "params": { "algorithm": "sha256" } }` — no `roles`, no `pattern`/`format`/`minLength`/`maxLength`/`enum`/`const`; warn that low-entropy values are brute-forceable |
| No protection | only with a stated reason |

Enforce while asking: `x-masking` / `hash` / `encrypt` only on `type: "string"` fields under nested
`properties`; one transform per field (never `x-masking` + `hash`/`encrypt`); none of them with
`x-filterOperators`, `x-sortable`, `x-indexed`; an `x-roles` field gets **no** `x-filterOperators` /
`x-sortable` (filter probes). Tell the user what `encrypt` does **not** cover (transition bodies, task
records, events keep plaintext — `field-protection.md` §7) and that scripts need
`context.Instance.DecryptAsync`.

On a **transition / function** schema: for secrets the client must never send in clear (password, PIN,
OTP seed) ask about `x-encryption` `{ "source": "client", "key", "algorithm": "HPKE-P256-SHA256-AES128GCM" | "RSA-OAEP-256", into?, encoding?, nonce?, envelope? }`.
The runtime does nothing with it — the receiving service decrypts. Record-side protection then belongs on
the master.

A **component** schema accepts none of these; protection lives on the host's schemas.

### 6. Query metadata (master only)

If instances will be listed, filtered or sorted (the `data` function, the instance list, `GetInstances`
tasks), capture per field:

- **`x-filterOperators`** — declaration names only: `eq, neq, gt, gte, lt, lte, between, contains,
  startsWith, endsWith, in, nin, isNull, includes`. Query tokens (`ge`, `le`, `ne`, `like`, `startswith`…)
  are refused by `npm run validate` and at publish; clients keep sending tokens on the wire. Empty/absent ⇒
  not filterable. Per-type sets: `references/concepts/instance-query.md` §4.
- **`x-sortable`** — `true` if the field can be sorted on.
- **`x-indexed`** — **proposed by default (`true`) on every field that is filtered or sorted** (it declares
  `x-filterOperators` / `x-sortable`, or a `GetInstances` task / list query uses it). Toolkit rule: a
  filtered or sorted field carries `x-indexed: true`. Shape: master only, explicit scalar
  `string`/`number`/`integer`/`boolean` (dates: `string` + `format: "date-time"`) under fixed
  `properties`; not on arrays, objects, `$ref`, combinators; not with `x-masking`, active `x-encryption`,
  `x-computed`. Tell the user it is not a permission and the runtime runs no DDL: `wf indexes generate`
  produces SQL, a DBA applies it, `AttributeIndexes:Enabled` routes queries. Without it the query works
  but slows with volume. If the user declines, note why.
- **`x-displayFormat`** — UI format hint, e.g. `"yyyy-MM-dd'T'HH:mm:ssXXX"`.

```json
"startDateTime": {
  "type": "string",
  "format": "date-time",
  "x-filterOperators": ["eq", "gt", "gte", "lt", "lte", "between"],
  "x-sortable": true,
  "x-indexed": true,
  "x-displayFormat": "yyyy-MM-dd'T'HH:mm:ssXXX"
}
```

### 7. Derived fields — `x-computed` (master only)

Ask whether any displayed value is derived from siblings (full name, total). Offer
`{ "evaluatedBy": "runtime", "cases"?: [{ "when"?, "join" | "arithmetic" }], "fallback"?, "whenAbsent"?: "empty" | "null" }`
(`join` `{ fields ≥1, separator? }`, `arithmetic` `{ op: add|subtract|multiply|divide, fields ≥2 }`).
Rules: nested `properties` only, `readOnly: true`, never in `required`, fields are siblings, no chains, no
encrypted inputs; **not** with `x-indexed`, `x-filterOperators`, `x-sortable`, `x-storage`, `x-roles`,
`x-masking`, at-rest `x-encryption`. Never `evaluatedBy: "server"`. Details: `field-protection.md` §9. <!-- lint:allow -->

### 8. File fields — `x-storage` (master only)

If a field holds a document/image upload: on the master,
`{ "type": "object", "x-storage": { "binding": "<dapr binding>" } }` on a property (or one array's
`items`), never root/`$defs`/combinators/nested arrays, no `content` declared. Then create (or update) the
**transition** schema with the upload shape (`name`, `mimeType`, `size`, `content` base64). Ask the
binding name (local dev: `vnext-blob-local`) and point to `references/concepts/file-fields.md` for the
local binding and `functions/file`.

### 9. Client context — per role

- **transition / function**: does any field come from the client rather than the user (channel, device id,
  logged-in subject)? → `x-context-source`: `{ "const": … }` | `{ "context": { "boundary": "device|user|subject", "key", "storage"? } }` | `{ "identity": "subject" | "user" }`.
  Client-only and self-asserted — never an authorization input.
- **master**: should values that appear on the record be copied into the client context for later flows?
  → root-level `x-context-target` map `{ "<data path>": { "context": { … } } }` (`{instance}` /
  `{subject}` templates). Client-only; the runtime ignores it.

### 10. Component role — `x-binding`

For a `component` schema, ask per field whether the host must bind it: `"x-binding": "required" | "optional"`.

### 11. Look at a sibling example

Read one schema of the same role in the domain (e.g. `vnext-example` `core/Schemas/schema-roles-lab/` or
`core/Schemas/forge-file-form-lab/` for a master/transition split). Confirm the `$id` URN pattern
(`urn:vnext:res:schema:{domain}:{key}`).

### 12. Generate the schema JSON

```json
{
  "key": "{key}",
  "version": "1.0.0",
  "domain": "{domain}",
  "flow": "sys-schemas",
  "flowVersion": "1.0.0",
  "tags": [],
  "attributes": {
    "type": "{master|transition|function|component}",
    "schema": {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "urn:vnext:res:schema:{domain}:{key}",
      "type": "object",
      "required": [ /* not on master */ ],
      "properties": { /* fields from steps 3-10 */ }
    }
  }
}
```

**Master:** no `required` and `additionalProperties: true` — the runtime validates it on every
instance-data merge and data grows across states (`workflow-types.md` § Master schema). **Input roles:**
`required` and strict shapes are fine.

### 13. Write the file

`{componentsRoot}/{paths.schemas}/{domain-subfolder}/{key}.json`.

### 14. Validate

Run `npm run validate`. If the output contains `Could not compile validator for schema`, the workspace
`validate.js` does not call `addVocabularies` and **schema components were not validated** — say so, and
check role and keywords against the matrix by hand (`schema-runtime-gaps.md` D13). Hand other failures to
`validate-and-fix`. A runtime behaviour that contradicts the docs → `/vnext-ai-toolkit:report-issue`.

### 15. Wire references (if requested)

Point the workflow's `attributes.schema` at the master, a transition's `schema` at the transition schema, a
function's `inputSchema` at the function schema, a view's `dataSchema` at the schema of its role. Re-validate.
When changing `x-roles` / `x-masking` / `x-encryption` on an existing master, **bump its version** (same-version
republish keeps the old ETag).

## Notes

- JSON Schema draft is **2020-12**; `$id` is a URN (`urn:vnext:res:schema:{domain}:{key}`), resolved
  against the registered schema set, never fetched. Keep it stable across versions.
- Never-shipped or removed forms: `x-encrypt` (use `x-encryption` + `source: "client"`), `x-persistance`, <!-- lint:allow -->
  `x-encryption.type` `persisted`/`transport`, `x-computed.evaluatedBy: "server"`. <!-- lint:allow -->
- Never hardcode `core/Schemas/...` — always resolve from `vnext.config.json`.
