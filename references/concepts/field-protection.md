# Field Protection — `x-roles`, `x-masking`, `x-encryption`, `x-computed`

> Runtime **0.0.99+** (`x-masking`, `x-encryption` runtime) and **0.0.100** (`x-encryption`
> `source: client`, `x-computed`); schema package **0.0.56**. All four keywords live on the **master**
> schema (`attributes.type: "master"`, the schema `workflow.attributes.schema` points to) — except client
> `x-encryption`, which is also the only protection keyword an input schema accepts
> (`schema-vocabularies.md` §1).
>
> **Sensitive data is a first-class design topic in this toolkit.** `schema-design` asks, for every PII or
> sensitive field, which of `x-roles` / `x-masking` / `x-encryption` applies — there is no silent
> "unprotected" default — and the reviewer reports an unprotected PII field as a warning.

## 1. Which control for which data

| Need | Keyword | Acts on | Stored value |
|---|---|---|---|
| Some callers must not see the field at all | `x-roles` | read | unchanged |
| Callers may see that a value exists, but only partially (`TR12 **** 4567`) | `x-masking` | read | unchanged |
| Nobody ever needs the raw value back; only equality within one instance | `x-encryption` `type: "hash"` | **write** | `HASHED:SHA256:<hex>` |
| Value must be unreadable at rest (API exposure, table dumps); a few roles read plaintext | `x-encryption` `type: "encrypt"` | write + read | `ENCRYPTED:AES256:i1:…` token |
| Value must never travel in clear from client to backend (password, PIN) | `x-encryption` `source: "client"` | client only | whatever the client sent (ciphertext) |
| Show a derived value (full name, total) without storing it | `x-computed` `evaluatedBy: "runtime"` | read | never stored |

A field carries **at most one transform**: `x-masking` next to an active `x-encryption` (`hash`/`encrypt`)
is a publish error. `x-roles` combines with either.

Ask per field, in this order: *Who may see it?* (`x-roles`) → *Do others see a hint of it?* (`x-masking`)
→ *Must it be unreadable in the database?* (`encrypt`, or `hash` if nobody needs it back) → *Must it be
sealed on the way in?* (client `x-encryption` on the transition schema).

## 2. `x-roles` — hide a field on read

```jsonc
"monthlyIncome": {
  "type": "number",
  "x-roles": [
    { "role": "morph-idm.credit-officer", "grant": "allow" },
    { "role": "$InstanceStarter", "grant": "allow" },
    { "grant": "deny", "allOf": [ { "role": "morph-idm.intern" }, { "role": "$PreviousUser" } ] }
  ]
}
```

- Each grant is exactly one of `role` / `allOf` / `anyOf`, plus `grant: allow|deny` (lower case). Combinator
  children are `{ "role" }` only; **depth 1** (no nesting). Deny wins. Full grant model, reserved `$` roles
  and three-valued logic: `roles-and-authorization.md`.
- **Read-only.** `x-roles` prunes the field from what a caller reads; it does **not** stop a caller from
  writing the field in a transition body. Gate writes with transition `roles` and the transition schema.
- A property without `x-roles` is visible to every caller allowed to read the instance. A pruned property is
  removed before masking/encryption look at it. If role resolution fails, **every** `x-roles` field is pruned.
- Publish rejects a malformed entry (missing `grant`, both `role` and `allOf`, malformed `$user.` /
  `$userBehalfOf.` / `$role.` path — paths start with `$.context.`). Before 0.0.99 such entries were silently
  skipped, so a deny written that way never fired.
- Combinators are understood only by runtimes ≥ 0.0.99 (`role-grant-combinators-rollback-floor`): author
  the first `allOf`/`anyOf` only when every pod (and every domain stamping overrides onto this one) runs
  ≥ 0.0.99, and never binary-downgrade after publishing one.

## 3. `x-masking` — mask a visible value on read

```jsonc
"iban": {
  "type": "string",
  "x-masking": {
    "operator": "mask",
    "params": { "keepFirst": 4, "keepLast": 4, "maskingChar": "*" },
    "roles": [ { "role": "morph-idm.auditor", "grant": "allow" } ]
  }
},
"motherMaidenName": {
  "type": "string",
  "x-masking": { "operator": "replace", "params": { "value": "***" } }
}
```

| Member | Meaning |
|---|---|
| `operator` | `mask` (keep first/last, mask the middle, **length-preserving**) or `replace` (write `params.value`) |
| `params` for `mask` | `keepFirst`, `keepLast` (integers ≥ 0, default 0), `maskingChar` (exactly one character, default `*`); no `value` |
| `params` for `replace` | `value` (required, non-empty); no mask parameters |
| `roles` | **allow-only exemption list**: an `allow` match sees the raw value; everyone else the masked one |

- Exemption list rules: plain `{ "role", "grant": "allow" }` entries only — **no `deny`, no `allOf`/`anyOf`**
  (publish error). An unlisted, misspelled or missing role is masked (fail closed); a role-less caller can
  never satisfy a role-bound grant. No `roles` ⇒ masked for everyone.
- `mask` keeps the length: if length itself is sensitive use `replace`. If `keepFirst + keepLast` ≥ the
  value length the value is returned **unchanged**.
- Stored data never changes; masking runs only on the read surfaces (§5). `SchemaMasking:Enabled=false`
  switches `x-masking` off host-wide.

## 4. `x-encryption`

`source` selects **who** encrypts: `runtime` (default when absent — at rest) or `client` (in transit).

### 4.1 `source: runtime`, `type: "hash"` — irreversible, on write

```jsonc
"tckn": {
  "type": "string",
  "x-encryption": { "type": "hash", "params": { "algorithm": "sha256" }, "purpose": "PII-Identification" }
}
```

- The write funnel replaces the value with `HASHED:SHA256:<hex>` (`HASHED:SHA512:` for `sha512`) — an HMAC
  keyed by a **per-instance salt** the runtime generates. The plaintext is never stored; the engine, scripts
  and every reader see the digest.
- No `roles` (nobody can be shown a raw value). No `pattern`, `format`, `minLength`, `maxLength`, `enum`,
  `const` on the property (later writes re-validate the digest). `params` only on `hash`.
- Same value → same digest within one instance; **different across instances** (no joins/dedup across
  instances, `field-hash-no-cross-instance-matching`).
- Hash is pseudonymisation, not anonymisation: low-entropy values (national ids, phone numbers) can be
  brute-forced by whoever reads the salt from `InstanceSecrets` (`field-hash-low-entropy-values`).

### 4.2 `source: runtime`, `type: "encrypt"` — AES-256-GCM at rest

```jsonc
"email": {
  "type": "string",
  "x-encryption": {
    "type": "encrypt",
    "roles": [ { "role": "morph-idm.auditor", "grant": "allow" } ],
    "purpose": "PII",
    "redactInLogs": true,
    "retentionDays": 2555
  }
}
```

- Stored as `ENCRYPTED:AES256:i1:<base64url>` in `InstancesData`; the token is bound to scheme, instance and
  path (a token copied to another field or instance does not open).
- Read surfaces: an `allow`-listed caller sees the plaintext, everyone else the token. `roles` follows the
  same allow-only exemption rules as `x-masking`. No `params`.
- `purpose`, `redactInLogs`, `retentionDays` are governance metadata — **not enforced**.
- Per-instance key + salt: the runtime generates them on the first protected write and stores them in the
  flow schema's `InstanceSecrets` table (migration `AddInstanceSecrets`), never in config, Vault or the
  schema. They are kept **in plaintext by decision**: `encrypt` protects API exposure and single-table dumps,
  not a database reader (`field-encryption-script-key-access`). Deleting the secret row crypto-shreds the
  instance's values (effective per pod after the L1 cache expires, `field-encryption-shred-l1-delay`).
- A request may not introduce a string starting with `ENCRYPTED:AES256:` or `HASHED:` (400
  `Instance:100041`), except echoing the value already stored at the same path. Copying a token into
  another field is refused (`EncryptedValueReservedException`).
- List filter / sort / groupBy / aggregation on an `encrypt` path (or an ancestor) → 400
  `Validation:900010`, regardless of `EnforceMasterSchemaFiltering`.
- Do not `encrypt` a field used as a dynamic role (`$user.$.context.Instance.Data.x`) or in a human-task
  title: those see the token.

Rules for both runtime types: the property declares `type: "string"` (optionally with `"null"`), is reached
through nested `properties` (not root, `items`, `$defs`, combinators, `if/then`), and is not combined with
`x-filterOperators`, `x-sortable`, `x-indexed` or `x-masking`. `type: "none"` declares no encryption.
`persisted` / `transport` were removed in 0.0.99 (publish error — use `encrypt`). A host with
`SchemaEncryption:EncryptWrites=false` refuses to publish any `hash`/`encrypt` schema.

### 4.3 `source: client` — sealed by the client, in transit

```jsonc
// transition schema (attributes.type: "transition")
"newPassword": {
  "type": "string",
  "format": "password",
  "x-encryption": {
    "source": "client",
    "key": "urn:client:context:read:device:memory:device.hpke.publicKey",
    "algorithm": "HPKE-P256-SHA256-AES128GCM",
    "into": "newPasswordEnc",
    "encoding": "base64url",
    "envelope": "publicKey"
  }
}
```

| Member | Required | Meaning |
|---|---|---|
| `source` | yes | `"client"` |
| `key` | yes | recipient public key: a context read address `urn:client:context:read:<boundary>:<storage>:<key>` or `$instance.<path>` |
| `algorithm` | yes | `HPKE-P256-SHA256-AES128GCM` (RFC 9180, DHKEM P-256 / HKDF-SHA256 / AES-128-GCM) or `RSA-OAEP-256` |
| `into` | no | field the ciphertext is sent as; absent = replaced in place |
| `encoding` | no | `base64` or `base64url` |
| `nonce` | no | per-record value bound into the sealed text (`{value}:{nonce}`) as a replay guard |
| `envelope` | no | `publicKey` sends `{publicKeyB64}.{ciphertextB64}` |
| `purpose` | no | classification metadata |

- The at-rest members (`type`, `params`, `roles`, `redactInLogs`, `retentionDays`) are refused here; client
  members are refused on a runtime rule.
- A client that cannot seal **refuses the write** — it never sends plaintext.
- The runtime does **nothing** with a client rule: no at-rest encryption, no read masking, no filter refusal.
  The ciphertext is stored and served as sent; only the backend service holding the private key opens it.
  If the value must also be protected at rest, the receiving service (or the master schema's own
  `encrypt` on a separate field) has to do it.
- Allowed on `transition`, `function` and `master` schemas; refused on `component`.
- Replaces the never-shipped `x-encrypt` keyword. <!-- lint:allow -->

## 5. Order of application and where it applies

Read order is fixed: **`x-roles` (prune) → `x-masking` → `x-encryption` (runtime rules) → `x-computed`
(`runtime`)**, in one pass. Computed values are derived from the already-shaped view.

| Surface | Applied? |
|---|---|
| Instance GET, instance list, `data` function, data history, sync start / transition response | yes |
| `GetInstance` / `GetInstances` / `GetInstanceData` tasks (same- and cross-domain) | yes, **as the task's credential** (0.0.99: `SystemRead` removed). A task with no headers reads as its caller; set `role` (or the whole credential) in the input mapping to read as a service role on the allow list |
| `functions/file` for an `x-storage` field | `x-roles` of the file path and its ancestors → `404` (`file-fields.md`) |
| Scripts (`context.Instance.Data`, runtime-filled `context.Body`, `LatestData`) | **no** — they see stored values (tokens, digests) |
| Transition history, `context.Related`, custom functions, human-task `title`/`description`, outbox events, internal endpoints | **no** — the row as stored |
| Dynamic role grants, DynamicExpresso rules, function-cache `varyBy` | see the stored token |

When the schema cannot be read, a surface serves the row **as stored** (tokens stay tokens) — never
plaintext. Bump the schema **version** whenever you change `x-roles` / `x-masking` / `x-encryption`:
a same-version republish does not move the data-function ETag (`masked-field-same-version-republish-stale-etag`).

## 6. Scripts — `DecryptAsync`

A script sees an `encrypt` field as its token. Open it explicitly:

```csharp
var tckn = await context.Instance.DecryptAsync("customer.identityNumber", context.CancellationToken);
```

- Takes a **path** of the instance's own latest data, never a value; returns `string?` — `null` for a plain
  field, an unknown path, an undecryptable value or a token passed as a path. Nothing that reached the
  script from elsewhere (body, task response, `context.Related`, another instance) can be decrypted.
- Copying the plaintext into another field removes its protection — the author's decision. Writing a token
  into another field is refused.
- DynamicExpresso conditions cannot await: move conditions on `encrypt` fields into a C# condition script.
- A SubFlow output mapping receives the child's data in clear (the child opens its own tokens).
- Signatures: `csx-contracts.md` (Encrypted fields).

## 7. Known issues (read before promising "encrypted at rest")

| vnext-meta id | Effect | What to do |
|---|---|---|
| `field-encryption-plaintext-copies` | `encrypt` covers `InstancesData` only. `InstanceTransition.Body`/`Header`, `InstanceTask.Request`/`Response`, outbox sub-completed/faulted payloads, job payloads and the human-task cache keep **plaintext** | Treat `encrypt` as instance-data field encryption. Do not echo protected values into task requests/responses or event payloads; restrict DB/backup access |
| `field-encryption-lazy-history` | rows written before a field became `encrypt` stay plaintext | treat old history as plaintext |
| `list-filter-probes-guarded-fields` | list filter/sort/groupBy run on the raw JSONB: a caller can **probe an `x-roles`-hidden field** | never declare `x-filterOperators` / `x-sortable` on an `x-roles` field; ask the platform team to keep `Workflow:InstanceFiltering:EnforceMasterSchemaFiltering=true` |
| `field-hash-low-entropy-values` | hashes of low-entropy values are brute-forceable with the salt | prefer `x-roles` (+ `encrypt`) for values that must not be matchable |
| `field-encryption-selector-unguarded` | event selectors match ciphertext and silently find nothing | never select on an encrypted field in an event mapping/selector |
| `field-encryption-rollback-floor` | runtimes < 0.0.99 hand tokens to the engine as values | publish the first `hash`/`encrypt` schema only when all pods run ≥ 0.0.99 with the `InstanceSecrets` migration; roll back with `SchemaEncryption__EncryptWrites=false`, not a binary downgrade |
| `field-encryption-job-deferral` | a write carrying an unopenable token forward fails with `Instance:100040` at the writing step | cancel the instance or write a new value |
| `masked-field-same-version-republish-stale-etag` | same-version republish keeps the old ETag | bump the schema version |

`x-encryption` with `source: client` has none of these runtime effects — and none of the protections.

## 8. Settings (platform team owns them)

```json
"SchemaMasking":    { "Enabled": true },
"SchemaEncryption": { "EncryptWrites": true, "SecretCacheEntries": 100000, "SecretCacheSlidingMinutes": 30 }
```

- `SchemaMasking:Enabled=false` turns off `x-masking` only; no switch touches `x-roles`.
- `SchemaEncryption:EncryptWrites=false` is the rollback switch: new values are stored plain, existing
  tokens keep decrypting, and `hash`/`encrypt` schemas cannot be published.
- Secrets are cached in-process only (never Redis).

| Code | HTTP | When |
|---|---|---|
| `Instance:100041` | 400 | request introduces an `ENCRYPTED:` / `HASHED:` value |
| `Instance:100043` | 503 | schema unresolvable while the instance already holds protected values |
| `Instance:100040` | 503 | write would carry an undecryptable value forward |
| `Validation:900010` | 400 | list filter/sort/group on an `encrypt` path |

## 9. `x-computed` — derived, never stored

```jsonc
"customer": {
  "type": "object",
  "properties": {
    "kind":        { "type": "string", "enum": ["individual", "corporate"] },
    "firstName":   { "type": "string" },
    "lastName":    { "type": "string", "x-roles": [ { "role": "morph-idm.officer", "grant": "allow" } ] },
    "companyName": { "type": "string" },
    "displayName": {
      "type": "string",
      "readOnly": true,
      "x-computed": {
        "evaluatedBy": "runtime",
        "cases": [
          { "when": { "field": "kind", "operator": "equals", "value": "corporate" },
            "join": { "fields": ["companyName"] } }
        ],
        "fallback": { "join": { "fields": ["firstName", "lastName"], "separator": " " } },
        "whenAbsent": "empty"
      }
    },
    "principal": { "type": "number" },
    "interest":  { "type": "number" },
    "totalDue":  {
      "type": "number",
      "readOnly": true,
      "x-computed": { "evaluatedBy": "runtime",
                      "fallback": { "arithmetic": { "op": "add", "fields": ["principal", "interest"] } },
                      "whenAbsent": "null" }
    }
  }
}
```

| Member | Meaning |
|---|---|
| `evaluatedBy` | `runtime` — computed by the runtime on every read surface (§5); `client` — the client computes it from this declaration; the runtime does not inspect it. `server` is refused (renamed) |
| `cases[]` | optional; each `{ when?, join \| arithmetic }`; first matching `when` wins. `when` is an `x-conditional` condition |
| `fallback` | exactly one `join` or `arithmetic`; at least one of `cases` / `fallback` is required |
| `join` | `{ fields (≥1), separator? }` — default separator one space; empty/missing values skipped |
| `arithmetic` | `{ op: add\|subtract\|multiply\|divide, fields (≥2) }` — decimal, left to right; missing/non-numeric operand, division by zero or overflow ⇒ unresolved |
| `whenAbsent` | unresolved result: `empty` (`""`, default) or `null` |

Runtime behavior (`evaluatedBy: "runtime"`): no flag, always on; computed from the caller's
**already-shaped** view, so it never reveals a field the caller cannot see (`displayName` above omits
`lastName` for a non-officer). **Never stored**: a computed member in a request body is dropped on write
(the transition record still keeps the body as sent).

Publish rules (`runtime`; the package additionally allows `x-computed` only on `master`):

- master only: the runtime refuses `runtime` on a `transition` / `function` / `component` schema, and the
  package refuses `x-computed` outside `master` in both modes — put derived display logic for forms in the
  view instead;
- only on a property reached through nested `properties` (not root, `items`, `$defs`, combinators,
  conditionals); never listed in its parent's `required`; should be `readOnly`;
- **invalid combos**: not with `x-indexed`, `x-filterOperators`, `x-sortable`, `x-storage`, `x-roles`,
  `x-masking`, or an at-rest `x-encryption` (it takes its visibility from the fields it reads);
- `fields` / `when.field` name properties of the **same parent object** (dot paths for nested members) that
  are neither runtime-computed themselves (no chains) nor at-rest encrypted.

## 10. Worked examples

**Customer onboarding master** — national id never readable, phone masked for agents, income only for credit
officers, e-mail encrypted with an auditor exemption:

```jsonc
"properties": {
  "customer": {
    "type": "object",
    "properties": {
      "tckn":  { "type": "string", "x-encryption": { "type": "hash", "purpose": "PII-Identification" } },
      "phone": { "type": "string",
                 "x-masking": { "operator": "mask", "params": { "keepFirst": 3, "keepLast": 2 },
                                "roles": [ { "role": "morph-idm.call-center-lead", "grant": "allow" } ] } },
      "monthlyIncome": { "type": "number",
                         "x-roles": [ { "role": "morph-idm.credit-officer", "grant": "allow" } ] },
      "email": { "type": "string",
                 "x-encryption": { "type": "encrypt", "purpose": "PII",
                                   "roles": [ { "role": "morph-idm.auditor", "grant": "allow" } ] } },
      "segment": { "type": "string", "x-indexed": true, "x-filterOperators": ["eq", "in"] }
    }
  }
}
```

`tckn` is not filterable (hash), `monthlyIncome` carries no `x-filterOperators` (would leak through filter
probes), `segment` is the filter field and is indexed. A script that must call a KYC service with the e-mail
uses `DecryptAsync("customer.email", …)`; the service call's task record will hold the plaintext
(`field-encryption-plaintext-copies`) — decide that consciously.

**Password change** — transition schema seals the password, master never stores it:

```jsonc
// change-password-input, attributes.type "transition"
"newPassword": { "type": "string", "x-encryption": { "source": "client",
  "key": "urn:client:context:read:device:memory:device.hpke.publicKey",
  "algorithm": "HPKE-P256-SHA256-AES128GCM", "envelope": "publicKey" } }
```

Map the sealed value straight to the identity service in the transition task; do not merge it into instance
data.

## Sources

- Runtime v0.0.100: `docs/domain/field-masking.md`; `SchemaComponentValidator`, `FieldMaskingDefinition`, `ComputedFieldDefinition`, `ComputedFieldEvaluator`, `SchemaRoleTypes`, `InstanceDataRoleFilter`, `SchemaFieldFilterService`, `Instance.DecryptAsync`
- vnext-meta (master): known-issues `field-encryption-*`, `field-hash-*`, `list-filter-probes-guarded-fields`, `masked-field-same-version-republish-stale-etag`, `role-grant-combinators-rollback-floor`; deprecations `x-encryption-type-persisted`, `x-encryption-type-transport`; migrations `get-instance-task-reads-guarded`, `script-sees-encrypt-tokens`, `publish-rejects-malformed-role-grants`, `computed-evaluated-by-server-renamed`
- vnext-schema v0.0.56: `vocabularies/view-vocab.json` (`x-masking`, `x-encryption`, `x-encryption-client`, `roleGrant`), `vocabularies/record-vocab.json` (`x-computed`), `README.md` (Field Exposure Vocabulary)
- vnext-docs: `how-to/view-consept/schema-definition.md` (`x-masking`, `x-encryption`, `x-computed`), `concepts/schema-roles.md`
- Fixtures: `vnext-example` `core/Schemas/schema-roles-lab/schema-roles-lab-master.json`, `tests/Core.IntegrationTests/Tests/RoleMatrixLab/{SchemaFieldMaskingTests,SchemaFieldEncryptionTests}.cs`
- Related: `roles-and-authorization.md`, `schema-vocabularies.md`, `instance-query.md`, `csx-contracts.md`, `security-review-checklist.md`
