# Schema Vocabularies — Roles and `x-*` Keywords

> Schema package **0.0.56** / runtime **0.0.100**. vNext extends JSON Schema with `x-*` keywords that
> drive forms, record exposure, queries, files and client context. Since 0.0.56 **a schema plays one
> role** (`attributes.type`), and the role decides which `x-*` keywords it may carry.
>
> Where the vocabulary files live and how to load them for the workspace's `schemaVersion`:
> `component-schemas.md`. Field protection (`x-roles`, `x-masking`, `x-encryption`, `x-computed`) in
> depth: `field-protection.md`. File fields (`x-storage`): `file-fields.md`. Query contract:
> `instance-query.md`.

## 1. Role × keyword matrix (read this first)

✅ accepted · ❌ refused by the package validator (`npm run validate`, CLI, Forge) · ⚠️ accepted, see note

| Keyword | Group | `master` | `transition` | `function` | `component` | no type / `""` |
|---|---|:-:|:-:|:-:|:-:|:-:|
| `x-labels`, `x-enum`, `x-order`, `x-displayFormat`, `x-lov`, `x-lookup`, `x-errorMessages`, `x-validation`, `x-conditional` | base | ✅ | ✅ | ✅ | ✅ | ✅ |
| `x-helpText`, `x-placeholder`, `x-uiHint`, `x-uiNote`, `x-group` | view hints | ✅ | ✅ | ✅ | ✅ | ✅ |
| `x-roles` | record | ✅ | ❌ | ❌ | ❌ | ✅ |
| `x-masking` | record | ✅ | ❌ | ❌ | ❌ | ✅ |
| `x-encryption` `source: runtime` (default) | record | ✅ | ❌ | ❌ | ❌ | ✅ |
| `x-encryption` `source: client` | record + input | ⚠️ accepted, runtime ignores it | ✅ | ✅ | ❌ | ✅ |
| `x-storage` | record | ✅ | ❌ | ❌ | ❌ | ✅ |
| `x-indexed` | record | ✅ | ❌ | ❌ | ❌ | ❌ |
| `x-filterOperators`, `x-sortable` | record | ✅ | ❌ | ❌ | ❌ | ✅ |
| `x-computed` (`runtime` or `client`) | record | ✅ | ❌ | ❌ | ❌ | ✅ |
| `x-context-target` | record | ✅ | ❌ | ❌ | ❌ | ✅ |
| `x-context-source` | input | ❌ | ✅ | ✅ | ❌ | ✅ |
| `x-binding` | component | ❌ | ❌ | ❌ | ✅ | ✅ |
| any other `x-*` (incl. `x-encrypt`, `x-persistance`) | — | ❌ | ❌ | ❌ | ❌ | no gate | <!-- lint:allow -->

- The check is **recursive** (`properties`, `items`, combinators, `$defs`/`definitions`): a keyword outside
  the role is refused wherever it sits.
- The "no type" column is the package view only. The **runtime** applies its own publish rules whatever
  the type, and it enforces the record keywords only on the schema a workflow references as its
  `attributes.schema` (the master). Writing `x-roles` on a transition schema protects nothing.
- Exception enforced by the runtime too: `x-computed` with `evaluatedBy: "runtime"` is refused on a
  `transition` / `function` / `component` schema.

## 2. Schema roles — `attributes.type`

| `attributes.type` | Role vocabulary | Use it for |
|---|---|---|
| `master` | `record-vocab.json` | a flow's master (data) schema — the one `workflow.attributes.schema` points to |
| `transition` | `input-vocab.json` | a transition's request body schema |
| `function` | `input-vocab.json` | a function's `inputSchema` |
| `component` | `component-vocab.json` | the `dataSchema` of an embedded view (`Component` node) that sends nothing itself |
| absent / `""` | none (no role gate) | last resort for a schema that serves several roles; `x-indexed` is not allowed |

This enum is **only** for schema components (`flow: sys-schemas`). Workflow, task, view and extension
`attributes.type` keep their own enums.

### Legacy values → role

| Where the schema is actually used | Typical legacy value | New `attributes.type` |
|---|---|---|
| A workflow's `attributes.schema` (flow data) | `workflow`, `schema`, `SchemaDefinition` | `master` | <!-- lint:allow -->
| A transition body | `workflow`, `schema`, `transition` | `transition` | <!-- lint:allow -->
| A function `inputSchema` | `function`, `schema` | `function` | <!-- lint:allow -->
| An embedded (component) view's `dataSchema` | `view` | `component` | <!-- lint:allow -->
| Task I/O, headers, anything else, or several roles at once | `task-input`, `task-output`, `view-data`, `headers`, `task`, `extension` | **split** the schema per role; omit the field only as a last resort | <!-- lint:allow -->

| Layer | Legacy value | Missing / `""` | Keyword outside its role |
|---|---|---|---|
| Package 0.0.56 (`npm run validate`, CLI, Forge) | **refused** | accepted (no gate) | **refused** |
| Runtime 0.0.100 (`publish`) | accepted **with a warning**; will be refused later (`schema-attributes-type-legacy-values`) | accepted (before 0.0.100: `Schema type is required.`) | not applied; only the keywords it enforces are validated |

Runtime warning text: *"attributes.type 'workflow' is not a schema role (master, transition, component,
function) and will be refused in a future release …"* <!-- lint:allow -->

### One schema, several roles → split it (toolkit rule)

If the same schema is both a transition body and a read-only view's `dataSchema`, or both the master and
a transition body, **split it**: one schema per role, shared fields copied into each, each with its own
`attributes.type`. The package then catches out-of-role keywords. Leaving `attributes.type` empty is the
last resort (no gate; and a master without `type: "master"` cannot use `x-indexed`). Splitting is
mandatory in practice for file fields: the master's `x-storage` node describes the persisted handle and
cannot declare `content`, the transition schema must (`file-fields.md`).

### Validator caveat — `addVocabularies`

`schema-definition.schema.json` `$ref`s the role vocabularies by `$id`; a validator must register them
before compiling:

```js
const Ajv = require('ajv');
const { addVocabularies, schemaDefinition } = require('@burgan-tech/vnext-schema');
const validate = addVocabularies(new Ajv({ strict: false })).compile(schemaDefinition);
```

A workspace `validate.js` (from an older `@burgan-tech/vnext-template`) that does not call
`addVocabularies` cannot compile the schema validator against 0.0.56: it prints
`⚠ Warning: Could not compile validator for schema …` and **skips every `sys-schemas` component** while
still exiting green. Read the validate output for that line; if present, schema components were not
validated (role, keywords, shapes). Updating the template is the fix; do not "fix" it by pinning the
package back.

## 3. Base keywords (every role)

### `x-labels` — localized label

`{ "<lang>": "<text>" }`, keys `^[a-z]{2}(-[A-Z]{2})?$`, at least one entry. Views read
`$schema.<field>.label`; the runtime also uses it to localize schema-validation errors.

```jsonc
"currency": { "type": "string", "x-labels": { "tr": "Para Birimi", "en": "Currency" } }
```

### `x-enum` — labels per enum value (an **object**, not an array)

Keys are the `enum` values; each value is a localized text map.

```jsonc
"accountType": {
  "type": "string",
  "enum": ["savings", "checking"],
  "x-enum": {
    "savings":  { "tr": "Vadesiz", "en": "Savings" },
    "checking": { "tr": "Vadeli",  "en": "Checking" }
  }
}
```

### `x-order` — field order in a generated form

A number; lower first, unordered fields after every ordered one. Needed because a stored schema does not
keep property order (PostgreSQL `jsonb`).

### `x-displayFormat` — display hint

Non-empty string, UI only (e.g. `"yyyy-MM-dd'T'HH:mm:ssXXX"`).

### `x-lov` — options for a selectable input

`valueField` and `displayField` are required, plus **exactly one** of `source` or `items`:

| Member | Meaning |
|---|---|
| `source` | URN of the data-source function, fetched. May interpolate `{{$form.x}}` / `{{$instance.x}}` / `{{$param.x}}` to choose **which** source; an unresolved placeholder skips the load. `valueField`/`displayField` are JSONPaths into the response. |
| `items` | Expression (`$instance.<path>` / `$form.<path>`) naming an array already in scope; **no request**. `valueField`/`displayField` are plain property names in one element, or `""` for the element itself (array of strings). |
| `imageField` | Optional image path per option (same shape as `valueField`). |
| `filter[]` | `{ param, value, required? }`. `param` may carry the list-query operator after a colon (`"status:in"`; default equality). `value` is a reference string (`$form.x`, `$instance.x`, `$param.x`) **or a literal**; a literal may be an **array** — the only way to reach `in` / `nin`. `required: true` skips the load while the value is unresolved (cascade cleared). |

```jsonc
"district": {
  "type": "string",
  "x-lov": {
    "source": "urn:vnext:fn:get:shared:get-districts",
    "valueField": "$.response.data[*].code",
    "displayField": "$.response.data[*].name",
    "filter": [
      { "param": "cityCode", "value": "$form.city", "required": true },
      { "param": "status:in", "value": ["active", "pending"] }
    ]
  }
},
"selectedAccount": {
  "type": "string",
  "x-lov": { "items": "$instance.accounts", "valueField": "iban", "displayField": "name", "imageField": "bankLogo" }
}
```

Cascade: a `filter` value referencing `$form.X` re-loads the list when X changes. Meaning by role: on an
input schema it offers choices; on a master it resolves the stored key to its label. Every function behind
a `source` needs `attributes.rawResponse: true` (`function-mapping-pattern.md` §5).

### `x-lookup` — read-time enrichment (object **or** array)

`{ source (URN, required), resultField (JSONPath, required), filter[]? }` — `filter` has the same shape as
in `x-lov`. Where `x-lov` feeds a dropdown, `x-lookup` loads data to **render**; `resultField` decides what
`$lookup.{propertyName}` holds.

```jsonc
"branchDetail": {
  "type": "object",
  "readOnly": true,
  "x-lookup": {
    "source": "urn:vnext:fn:get:core:get-branch-detail",
    "resultField": "$.response.data",
    "filter": [ { "param": "code", "value": "$form.branchCode" } ]
  }
},
"branchList": {
  "x-lookup": { "source": "urn:vnext:fn:get:core:list-branches", "resultField": "$.response.data.branches" }
}
```

- Object → `$lookup.branchDetail.address`. Array → `ForEach` with `source: "$lookup.branchList"`, each
  element via `$item.*` (not `$lookup.*`).
- **Property name = access key**: the `x-lookup` sits on a property literally named what the view reads,
  and that name is listed in the view root's `lookups` array (`"lookups": ["branchDetail", "branchList"]`).
- A `filter` value referencing a binding re-loads the lookup when that value changes; otherwise it loads
  once.

### `x-errorMessages` — localized message per validation keyword

Keys (closed list): `required`, `minLength`, `maxLength`, `minItems`, `maxItems`, `uniqueItems`,
`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `pattern`, `format`, `enum`,
`const`. Values are localized text maps. The runtime uses them in schema-validation error messages.

### `x-validation` — custom rule metadata (an **object**)

`{ rule (required), parameters?, errorMessages? }`. A named rule the client delegate runs
(`onValidationRequest`); the runtime strips it before JSON-Schema validation and never executes `rule`.
Server-side business rules belong in the transition's validation script / tasks, not here.

```jsonc
"email": {
  "type": "string",
  "x-validation": {
    "rule": "validateEmailDomain",
    "parameters": { "blockedDomains": ["tempmail.com"] },
    "errorMessages": { "tr": "Geçici e-postalar kabul edilmez", "en": "Temporary e-mails are not accepted" }
  }
}
```

### `x-conditional` — visibility / enablement

`{ showIf?, hideIf?, enableIf?, disableIf? }` (at least one), each a **condition**:
`{ field, operator, value? }` or `{ allOf: [...] }` / `{ anyOf: [...] }` / `{ not: {...} }`.

Operators (closed list): `equals`, `notEquals`, `in`, `notIn`, `isEmpty`, `isNotEmpty`, `contains`,
`greaterThan`, `lessThan`, `greaterThanOrEquals`, `lessThanOrEquals`, `startsWith`, `endsWith`.

```jsonc
"spouseName": {
  "type": "string",
  "x-conditional": {
    "showIf":   { "field": "maritalStatus", "operator": "equals", "value": "married" },
    "enableIf": { "allOf": [
      { "field": "age", "operator": "greaterThanOrEquals", "value": 18 },
      { "field": "consent", "operator": "equals", "value": true }
    ] }
  }
}
```

`x-conditional` only shows/enables. For "required when …" use JSON Schema `allOf` + `if`/`then` (the
runtime validates it).

## 4. View hints (every role; the runtime reads none)

| Keyword | Shape | Meaning |
|---|---|---|
| `x-helpText` | localized text | help under/beside the field |
| `x-placeholder` | localized text | placeholder in an empty input |
| `x-uiHint` | non-empty string | rendering hint (`hidden`, `readonly`, …); unknown hints are ignored |
| `x-uiNote` | non-empty string | note for maintainers, never displayed |
| `x-group` | non-empty string | section a generated form puts the field in |

## 5. Record keywords (`master` only)

### `x-roles`, `x-masking`, `x-encryption`, `x-computed`

Field exposure on the read surfaces, in the fixed order `x-roles` → `x-masking` → `x-encryption` →
`x-computed`. Shapes, combination rules, where they apply and where they do not, and examples:
**`field-protection.md`**. Quick shapes:

```jsonc
"x-roles":      [ { "role": "morph-idm.auditor", "grant": "allow" } ]          // read-only pruning
"x-masking":    { "operator": "mask", "params": { "keepFirst": 2, "keepLast": 4 } }
"x-encryption": { "type": "encrypt", "roles": [ { "role": "morph-idm.auditor", "grant": "allow" } ] }
"x-computed":   { "evaluatedBy": "runtime", "fallback": { "join": { "fields": ["firstName", "lastName"] } } }
```

### `x-storage` — file field

`{ "binding": "<dapr binding name>" }` on a `type: object` property (or one array's `items`). Placement,
write/read shapes and settings: **`file-fields.md`**.

### `x-filterOperators` — which operators a list query may use on the field

An array of **declaration names** — exactly these 14, no duplicates:

`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `between`, `contains`, `startsWith`, `endsWith`, `in`, `nin`,
`isNull`, `includes`.

- **Publish rejects anything else (0.0.100, `publish-rejects-filter-operator-tokens`)**: a query token or
  case variant (`ne`, `ge`, `le`, `like`, `match`, `startswith`, `endswith`, `isnull`, `EQ` …) fails with
  *"x-filterOperators value 'ge' is not a declaration name; declare 'gte'"*; unknown values, duplicates and <!-- lint:allow -->
  non-strings fail too. The package enum (0.0.56) is the same 14 names, so `npm run validate` catches it.
- **The wire is unchanged**: clients still send query tokens (`ge`, `le`, `ne`, `like`…); the runtime maps
  them to declaration names before checking. Full mapping and wire syntax: `instance-query.md` §2–3.
- Empty or absent ⇒ the field is not filterable.
- Not allowed together with `x-masking`, an active `x-encryption`, or `x-computed`. Do not declare it on a
  field hidden by `x-roles` (list filters probe the raw value — `field-protection.md` §7).

| JSON `type` | Sensible declaration set | SQL behavior |
|---|---|---|
| `number` / `integer` | `eq, neq, gt, gte, lt, lte, between, in, nin, isNull` | `accessor::numeric {op}` |
| `string` + `format: date-time` | `eq, gt, gte, lt, lte, between, isNull` | `accessor::timestamptz {op}` |
| `string` (text) | `eq, neq, contains, startsWith, endsWith, in, nin, isNull` | `ILIKE` / equality |
| `boolean` | `eq, neq, isNull` | equality |
| `array` | `includes` (+ `in` for scalar arrays) | `Data @> @param` |

### `x-sortable`

`true` ⇒ `sort` on `attributes.<field>` is allowed; absent ⇒ not sortable. Same exclusions as
`x-filterOperators`.

### `x-indexed` — attribute index candidate

Boolean, in `record-vocab.json` since 0.0.56 (runtime support since 0.0.94).

| Rule | Detail |
|---|---|
| Role | Component `attributes.type` exactly `"master"`; any `x-indexed` (even `false`) elsewhere is refused by the package and at publish |
| Value | `true` / `false` only; omitting it requests nothing |
| Shape (`true`) | explicit scalar `type`: `string`, `number`, `integer`, `boolean` (dates: `string` + `format: "date-time"`), under fixed `properties`; first path segment `[a-zA-Z][a-zA-Z0-9_]*`. Arrays, objects, `$ref`, combinators/conditionals (on the node or an ancestor), `$defs`, `patternProperties` are refused |
| Exclusive with | `x-masking`, an active `x-encryption` (`hash`/`encrypt`), `x-computed` |
| Not a permission | filterability stays `x-filterOperators`, sortability `x-sortable` |
| No DDL from the runtime | `wf indexes generate` writes SQL, a **DBA** runs it, then `AttributeIndexes:Enabled=true` (default `false`) routes queries to ready projections (`instance-query.md` §9) |

Without an index a filter/sort still works — the runtime evaluates a JSON expression per row — it is
just slow on large tables. No error, no warning.

**Toolkit rule (maintainer decision):** every field that is **filtered or sorted** — it declares
`x-filterOperators` or `x-sortable`, or a `GetInstances` task / list query filters or sorts on it — carries
`x-indexed: true`. `schema-design` proposes it by default; the reviewer reports a filtered/sorted field
without it as a **warning**. The runtime does not enforce this.

```jsonc
"amount": {
  "type": "number",
  "x-indexed": true,
  "x-filterOperators": ["eq", "gte", "lte", "between"],
  "x-sortable": true
}
```

### `x-context-target` — copy record values into the client context (client only)

A map on the master schema (normally at the root): instance-data path (dot notation) → context-store slot
`{ "context": { "boundary": "device|user|subject", "key": "<template>", "storage"?: "memory|local|secure" } }`.
`key` may interpolate `{instance}` and `{subject}`. The **client** applies it on every instance read (start
result, after each transition) so values that appear later (tokens, device registrations, certificates)
reach the context store for later flows' `x-context-source`. The runtime never reads it.

```jsonc
"x-context-target": {
  "deviceData.instanceId": { "context": { "boundary": "device", "key": "device.registration.{instance}" } },
  "certificate":           { "context": { "boundary": "device", "key": "device.cert.{instance}", "storage": "secure" } }
}
```

Use `{instance}` for per-instance values; leave it out for a cross-flow singleton so the next flow's
`x-context-source` finds it at a stable key. Targets are context slots only (`const` / `identity` are
source-only).

## 6. Input keywords (`transition`, `function`)

### `x-context-source` — client-resolved input (client only)

Marks a property the **client** fills; it renders no form field for it. Exactly one of:

| Form | Meaning |
|---|---|
| `{ "const": <any JSON> }` | literal baked into the schema |
| `{ "context": { "boundary": "device\|user\|subject", "key": "<template>", "storage"?: "memory\|local\|secure" } }` | context-store slot (`{instance}`, `{subject}` interpolate) |
| `{ "identity": "subject" \| "user" }` | active subject (JWT `sub`) or active user |

```jsonc
"properties": {
  "channel":  { "type": "string", "x-context-source": { "const": "web" } },
  "deviceId": { "type": "string", "x-context-source": { "context": { "boundary": "device", "key": "device.id" } } },
  "userId":   { "type": "string", "x-context-source": { "identity": "subject" } }
}
```

The runtime does not resolve or check these values — they arrive as ordinary, **self-asserted** body
fields. Never base an authorization decision on them; identity comes from the credential headers
(`roles-and-authorization.md`).

### `x-encryption` with `source: "client"` — sealed in transit

The client seals the value to a recipient's public key before sending; only the service holding the private
key opens it. Input schemas accept **only** this source. Shape and HPKE/RSA members:
`field-protection.md` §4.

## 7. Component keyword (`component`)

### `x-binding`

`"required"` | `"optional"`: whether the embedding (host) view must bind this field into the component.
A component does **not** inherit its host's role; send/record behaviour (`x-context-source`, client
`x-encryption`, `x-roles`, `x-masking`, `x-context-target`) stays on the host's schema. A component that
submits uses a command the host passes in (`$param.submitCommand`). A view that submits its own move is not
a component — its `dataSchema` is in the `transition` role.

## 8. Removed / never shipped

| Form | Status | Use instead |
|---|---|---|
| `x-encrypt` | never shipped; refused by the package | `x-encryption` + `"source": "client"` | <!-- lint:allow -->
| `x-persistance` | never shipped; refused | — | <!-- lint:allow -->
| `x-encryption.type: "persisted"` / `"transport"` | removed 0.0.99; publish error | `"encrypt"` |
| `x-computed.evaluatedBy: "server"` | renamed 0.0.100; publish error | `"runtime"` | <!-- lint:allow -->
| `x-filterOperators` with query tokens (`ge`, `le`, `ne`, `like` …) | publish error since 0.0.100 | declaration names (`gte`, `lte`, `neq`, `contains` …) | <!-- lint:allow -->
| legacy `attributes.type` values | package refuses; runtime warns | a role (§2) |

## 9. Skill behavior

`schema-design`:

1. Loads `schema-definition.schema.json` and the role vocabularies from the pinned package
   (`component-schemas.md`); the per-role `#/definitions/allowedKeywords` lists are the source of truth for
   what a role accepts.
2. Asks the **role first** and proposes splitting a multi-role schema.
3. Offers only the keywords of that role; never invents an `x-` keyword.
4. For every PII / sensitive field asks which of `x-roles` / `x-masking` / `x-encryption` applies.
5. Proposes `x-indexed: true` on every filtered or sorted field.

## Sources

- `vnext-schema` v0.0.56: `vocabularies/{view-vocab,data-base-vocab,record-vocab,input-vocab,component-vocab,view-hints-vocab,data-vocab,roles-vocab}.json`, `schemas/schema-definition.schema.json` (`attributes.type`, `masterIndexSchema`), `README.md` (Role Vocabularies, Field Exposure), `index.js` (`addVocabularies`)
- Runtime v0.0.100: `SchemaComponentValidator`, `SchemaRoleTypes`, `FilterOperatorDefinition`, `ComputedFieldDefinition`, `FieldMaskingDefinition`, `FileStorageSchemaParser`, `AttributeIndexDefinition`, `JsonSchemaVocabularySanitizer`; `docs/domain/field-masking.md`, `docs/runtime/file-storage.md`, `docs/runtime/manual-attribute-index-maintenance.md`
- vnext-meta: deprecations `schema-attributes-type-legacy-values`, `x-encryption-type-persisted`, `x-encryption-type-transport`; migrations `publish-rejects-filter-operator-tokens`, `computed-evaluated-by-server-renamed`, `x-indexed-requires-master-schema`
- vnext-docs: `concepts/schema-roles.md`, `components/schema.md` (legacy migration, data-context vocabulary), `how-to/view-consept/schema-definition.md`, `how-to/file-fields.md`, `how-to/instance-filtering.md`, `how-to/attribute-indexes.md`
- Fixtures: `vnext-example` `core/Schemas/schema-roles-lab/`, `core/Schemas/forge-file-form-lab/` (`ffl-master` / `ffl-upload` split)
