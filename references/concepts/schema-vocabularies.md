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

### `x-lookup` — per-key enrichment

Different from LOV: lookup fetches detail about ONE selected value, exposed to the view as `$lookup.{propertyName}.X`:

```jsonc
"branchDetail": {
  "type": "object",
  "readOnly": true,
  "x-lookup": {
    "source": {
      "function": { "domain": "core", "key": "get-branch-detail", "version": "1.0.0" },
      "method": "GET",
      "params": [
        { "name": "code", "value": "$form.branchCode" }
      ],
      "responsePath": "$.data"
    }
  }
}
```

The lookup must sit on a **property literally named** what the view will reference. To use `$lookup.branchDetail.address`, define a dedicated `branchDetail` property (NOT on the input field `branchCode`).

In the view, activate via `lookups: ["branchDetail"]`.

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

### `roles` — field-level access

```jsonc
"branchCode": {
  "type": "string",
  "roles": [
    { "role": "$InstanceStarter", "grant": "allow" },
    { "role": "$PreviousUser", "grant": "allow" }
  ]
}
```

Built-in system role tokens:
- `$InstanceStarter` — the actor who started the instance
- `$PreviousUser` — the actor who triggered the previous transition
- `$InstanceBehalfOfStarter` — the subject (on-behalf) the instance was started for
- `$PreviousBehalfOfUser` — the subject of the previous transition
- (Custom roles defined in the workflow; JSONPath grants like `$user.<path>`)

There is **no `$CurrentUser`**. The full model — token claims (`sub` / `act_sub`) and JSONPath
grants — is documented in `roles-and-authorization.md`.

`grant: "allow"` / `"deny"` controls read/write visibility on this field for matched roles.

## Skill behavior

When `schema-design` runs, it:

1. Fetches `schema.json` for envelope shape (canonical schema-first rule).
2. Fetches `vocabularies/*.json` for the current set of `x-*` keywords and their inner shapes.
3. Asks the user about each field's needs (labels? LOV? validation? roles?) and assembles `properties` accordingly.
4. Never invents an `x-` keyword that isn't in the fetched vocabularies.

## Sources

- Vocabularies repo: `https://github.com/burgan-tech/vnext-schema/tree/master/vocabularies`
- Canonical envelope: `vnext-schema/schemas/schema.json` at `v{schemaVersion}`
- Working examples: `vnext-example/core/Schemas/account-opening/*.json` (look for `x-labels`, `x-lov`, `x-lookup`)
