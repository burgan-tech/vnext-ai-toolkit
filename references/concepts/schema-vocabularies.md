# Schema Vocabularies — `x-*` Extensions

vNext extends JSON Schema with custom `x-*` keywords that drive the view layer (form generation, validation, lookups, localization, access control). The canonical source for these vocabulary definitions is:

```
https://github.com/burgan-tech/vnext-schema/tree/master/vocabularies
```

Like `schemas/`, this folder is **tagged per `schemaVersion`**. Skills fetch the vocabulary for the workspace's exact version:

```
GET https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/vocabularies/{vocab-file}.json
```

## Vocabularies (conceptual list — verify against the repo for the current set)

### `x-labels` — bilingual labels

Per-property labels:

```jsonc
"properties": {
  "currency": {
    "type": "string",
    "x-labels": { "tr": "Para Birimi", "en": "Currency" }
  }
}
```

Consumed by views: `$schema.currency.label` → renders the current-locale label.

### `x-enum` — enum values with display metadata

Extends the standard `enum` with display info:

```jsonc
"accountType": {
  "type": "string",
  "x-enum": [
    { "value": "savings", "x-labels": { "tr": "Vadesiz", "en": "Savings" } },
    { "value": "checking", "x-labels": { "tr": "Vadeli", "en": "Checking" } }
  ]
}
```

Renders to a `Dropdown` with both the underlying value and the displayed label.

### `x-lov` — list-of-values dropdown source

Either static or function-backed:

**Static list:**
```jsonc
"currency": {
  "type": "string",
  "x-lov": {
    "items": [
      { "value": "TRY", "x-labels": { "tr": "TL", "en": "Turkish Lira" } },
      { "value": "USD", "x-labels": { "tr": "Dolar", "en": "US Dollar" } }
    ]
  }
}
```

**Function-backed (the usual case):**
```jsonc
"branchCode": {
  "type": "string",
  "x-lov": {
    "source": {
      "function": { "domain": "core", "key": "get-branches-lov", "version": "1.0.0" },
      "method": "GET",
      "params": [
        { "name": "currency", "value": "$form.currency" }
      ],
      "responsePath": "$.data[*]",
      "valueField": "code",
      "labelField": "name"
    }
  }
}
```

The function returns an enveloped array; the view applies `responsePath` (JsonPath) to extract items, then `valueField`/`labelField` populate the dropdown.

**Cascade**: when `params` reference `$form.X`, changing X re-invokes the function with the new value.

### `x-lookup` — read-time enrichment (object **or** array)

Where `x-lov` feeds a *selectable dropdown* bound to an input, `x-lookup` fetches data at read time
to **render** it — and it can resolve to either a **single object** or an **array**. `resultField`
(JsonPath into the function response) decides what `$lookup.{propertyName}` holds.

**Single object** — read fields with `$lookup.{propertyName}.{field}`:

```jsonc
"branchDetail": {
  "type": "object",
  "readOnly": true,
  "x-lookup": {
    "source": "core/functions/get-branch-detail",
    "resultField": "$.response.data",                 // points at an object
    "filter": [ { "param": "code", "value": "$form.branchCode" } ]
  }
}
```
→ `$lookup.branchDetail.address`, `$lookup.branchDetail.phone`.

**Binding-driven reload (cascade).** When a `filter` value references a binding (e.g. `$form.branchCode`),
the lookup **tracks that binding and re-loads itself** whenever the value changes — so the rendered
data stays in sync as the user picks a different code. (Same reactivity as `x-lov` cascade.) With no
binding-referencing filter, it loads once on render.

**Array** — point `resultField` at an array and iterate it with `ForEach`. `$lookup.{propertyName}`
is the **array container**; read each element with `$item.*` (NOT `$lookup.*`):

```jsonc
"branchList": {
  "x-lookup": { "source": "core/functions/list-branches", "resultField": "$.response.data.branches" }
}
```
```jsonc
{ "type": "ForEach", "source": "$lookup.branchList",
  "template": { "type": "Card", "children": [
    { "type": "Text", "content": "$item.name" },
    { "type": "Text", "content": "$item.address" }
  ] } }
```

**Property name = access key.** The lookup must sit on a property literally named what the view
references, and that name must appear in the view's root `lookups` array. Multiple lookups are
disambiguated **by property name**:

```jsonc
// schema — each property owns its x-lookup
"branchDetail":   { "x-lookup": { "source": "...", "resultField": "$.response.data" } },
"customerDetail": { "x-lookup": { "source": "...", "resultField": "$.response.data" } }
```
```jsonc
// view root
{ "dataSchema": "...", "lookups": ["branchDetail", "customerDetail"], "view": { /* ... */ } }
```

Then read with `$lookup.branchDetail.name`, `$lookup.customerDetail.fullName`. (`$lookup` with no
path returns the whole map, but in practice always use `$lookup.{name}`.)

### `x-validation` — runtime validation rules

Beyond standard JSON Schema (type/format/pattern/min/max), `x-validation` carries cross-field or business rules:

```jsonc
"amount": {
  "type": "number",
  "x-validation": [
    { "rule": "amount > 0", "message": { "tr": "Tutar pozitif olmalı", "en": "Amount must be positive" } },
    { "rule": "amount <= $instance.dailyLimit", "message": { "tr": "Günlük limiti aşıyor", "en": "Exceeds daily limit" } }
  ]
}
```

The rule expression uses the data binding namespaces (`$instance`, `$form`, `$lookup`).

### `x-conditional` — conditional visibility / requirement

```jsonc
"taxId": {
  "type": "string",
  "x-conditional": {
    "show": "$form.accountType == 'business'",
    "required": "$form.accountType == 'business'"
  }
}
```

Shows or requires the field based on another form value.

### `x-filterOperators` — allowed filter operators

Declares which filter operators a field accepts in instance queries. **Empty or absent ⇒ the field
is not filterable.** Most relevant on the **master schema**, where the built-in `data` function reads
it to build the query.

```jsonc
"startDateTime": {
  "type": "string",
  "format": "date-time",
  "x-filterOperators": ["eq", "gt", "ge", "lt", "le", "between"],
  "x-sortable": true,
  "x-displayFormat": "yyyy-MM-dd'T'HH:mm:ssXXX"
}
```

Operator semantics depend on the field's JSON `type` (canonical operator tokens are `ge`/`le`, not
`gte`/`lte`):

| Schema `type` | Operators | SQL behavior |
|---|---|---|
| `number` / `integer` | `gt`, `ge`, `lt`, `le`, `between` | `accessor::numeric {op} @param` |
| `string` + `gt`/`ge`/`lt`/`le`/`between` | date comparison | `accessor::timestamptz {op} @param` |
| `string` + `eq`/`like`/`startswith`/`endswith` | text comparison | `accessor ILIKE @param` |
| `boolean` | `eq`, `ne` | equality |
| `array` (JSON array in instance data) | `in` / `includes` | `Data @> @param` (leaf path: single-element array + partial-object pattern) |

JSON-Schema definition:

```jsonc
"x-filterOperators": {
  "type": "array",
  "description": "Allowed filter operators for this field. Empty or absent means the field is not filterable. Operator semantics depend on the field's JSON type (number/integer: numeric compare; string + gt/lt/ge/le/between: date compare; string + eq/like/startswith/endswith: text compare; boolean: equality; array: includes).",
  "items": {
    "type": "string",
    "enum": ["eq", "ne", "gt", "ge", "lt", "le", "between", "match", "like", "startswith", "endswith", "in", "nin"]
  },
  "uniqueItems": true
}
```

### `x-sortable` — sortable field

`true` ⇒ the field can be sorted on in instance queries; absent ⇒ not sortable.

```jsonc
"x-sortable": {
  "type": "boolean",
  "description": "When true, the field is sortable. Absent means not sortable."
}
```

### `x-displayFormat` — UI display format hint

A format hint for rendering the field (e.g. a date pattern). UI-facing only; it doesn't affect
validation or storage.

```jsonc
"x-displayFormat": {
  "type": "string",
  "minLength": 1,
  "description": "UI-facing format hint (e.g. yyyy-MM-dd'T'HH:mm:ssXXX)."
}
```

### `x-roles` — field-level access

> The keyword is **`x-roles`** (the `x-` JSON-Schema vocabulary prefix). It matters **especially in
> the master schema**, where it drives field visibility in the built-in `schema` / `data` functions.
> (Don't confuse it with workflow-definition `roles` on a transition, or `queryRoles` on a state —
> those are not `x-` prefixed.)

```jsonc
"branchCode": {
  "type": "string",
  "x-roles": [
    { "role": "$InstanceStarter", "grant": "allow" },
    { "role": "$PreviousUser", "grant": "allow" }
  ]
}
```

`role` also accepts a JSONPath grant compared against the `ScriptContext` (incl. `Instance.Data`):

```jsonc
"x-roles": [
  { "role": "morph-idm.initiator", "grant": "allow" },
  { "role": "$userBehalfOf.$.context.Instance.Data.initial.customer.ownerUserId", "grant": "deny" }
]
```

Built-in system role tokens:
- `$InstanceStarter` — the actor who started the instance
- `$PreviousUser` — the actor who triggered the previous transition
- `$InstanceBehalfOfStarter` — the subject (on-behalf) the instance was started for
- `$PreviousBehalfOfUser` — the subject of the previous transition
- (Custom roles defined in the workflow; JSONPath grants like `$user.<path>` / `$role.<path>` / `$userBehalfOf.<path>`)

There is **no `$CurrentUser`**. The full model — token claims (`sub` / `act_sub`) and JSONPath
grants — is documented in `roles-and-authorization.md`.

`grant: "allow"` / `"deny"` controls read/write visibility on this field for matched roles.

## Skill behavior

When `schema-design` runs, it:

1. Fetches `schema.json` for envelope shape (canonical schema-first rule).
2. Fetches `vocabularies/*.json` for the current set of `x-*` keywords and their inner shapes.
3. Asks the user about each field's needs (labels? LOV? validation? `x-roles` access? filterable/sortable/display-format?) and assembles `properties` accordingly.
4. Never invents an `x-` keyword that isn't in the fetched vocabularies.

## Sources

- Vocabularies repo: `https://github.com/burgan-tech/vnext-schema/tree/master/vocabularies`
- Canonical envelope: `vnext-schema/schemas/schema.json` at `v{schemaVersion}`
- Working examples: `vnext-example/core/Schemas/account-opening/*.json` (look for `x-labels`, `x-lov`, `x-lookup`)
