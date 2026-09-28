# Instance Query — list endpoint, filters, sort, `x-filterOperators`, `x-indexed`

> Runtime 0.0.97. The list endpoint fails **closed** since 0.0.84: anything the runtime cannot
> execute exactly as written is a 400, never a silently widened result set. `GetInstancesTask`
> (type `15`) validates the same way and returns `Result.Fail` — under an `Abort` boundary rule
> the calling instance can end up **Faulted** (see Pitfalls).

## 1. Endpoint and query parameters

```
GET /api/v1/{domain}/workflows/{workflow}/instances
```

| Param | Type / range | Notes |
|---|---|---|
| `filter` | string, ≤ 5000 chars | GraphQL-style JSON (recommended) or legacy `field=op:value`. **One expression** — combine with `and`/`or`/`not`. `{}` = no restriction. |
| `sort` | JSON | `{"field":"createdAt","direction":"desc"}` or `{"fields":[…]}`. Overrides envelope `orderBy`. |
| `orderBy` | JSON | Same shape as `sort`; may also live inside the filter envelope. |
| `groupBy` | JSON | `{"fields":["attributes.status"],"aggregations":{"count":true,"sum":"attributes.amount"}}` — aggregations nest here. |
| `aggregations` | JSON | Standalone `{"count":true,"sum":…,"avg":…,"min":…,"max":…}`; only honoured with `groupBy`. |
| `page` | int, **1–1000**, default 1 | Offset paging, DB-side since 0.0.94 (`instanceQueryPaging`). |
| `pageSize` | int, **1–100**, default 10 | `hasNext` computed from `pageSize + 1` identities. |
| `version` | string | Pin a workflow version; bypasses the function cache. |
| `extensions` | string[] | Extension keys to attach to each item. |

Response: `{ data: { items: [GetInstanceOutput…], page, pageSize, hasNext } }`; every item carries
`metadata.incident` (see `incidents-and-retry.md`). Grouped requests return `GroupSummary` items.
Same `filter` semantics on `GET …/instances/{instance}/functions/data?filter=…`.

## 2. Wire operators

Operator names on the wire (case-insensitive):

| Wire op | Meaning | Value |
|---|---|---|
| `eq`, `ne` | equal / not equal | scalar |
| `gt`, `ge`, `lt`, `le` | comparison (numeric or timestamptz by schema type) | scalar |
| `between` | inclusive range | `[lo, hi]` |
| `like`, `match` | contains, case-insensitive (`ILIKE %v%`) | string |
| `startswith`, `endswith` | prefix / suffix, `ILIKE` | string |
| `in`, `nin` | membership | array |
| `isNull` | null test | `true` / `false` |
| `includes` | JSON array containment (`Data @> …`, GIN) | partial object, list queries only |
| `and`, `or`, `not` | logical | array / object |

```jsonc
{"and":[
  {"status":{"eq":"Active"}},
  {"attributes":{"amount":{"ge":500}}},
  {"or":[{"currentState":{"eq":"review"}},{"currentState":{"eq":"approve"}}]}
]}
```

**Instance columns** are bare names; **instance data** is `attributes.<path>` (dot-nested or
`{"attributes":{"address":{"city":{"eq":"Ankara"}}}}`).

## 3. Schema-side vs wire operator names — the mapping table

**This is the trap.** The master schema's `x-filterOperators` uses *different* spellings from the
wire. `SchemaFilterContext.ToSchemaOperator` translates the wire op before checking the schema:

| Wire (client sends) | Schema-side (`x-filterOperators` must contain) |
|---|---|
| `eq` | `eq` |
| `ne` | **`neq`** |
| `gt` / `lt` | `gt` / `lt` |
| `ge` / `le` | **`gte`** / **`lte`** |
| `between` | `between` |
| `like`, `match` | **`contains`** (both map to it) |
| `startswith` / `endswith` | **`startsWith`** / **`endsWith`** |
| `in` / `nin` | `in` / `nin` |
| `isNull` | `isNull` |
| `includes` | `includes` |

Comparison is case-insensitive on both sides. Rules:

- **Declare schema-side names in `x-filterOperators`.** A schema listing `ge`/`le` lets **no**
  client use `ge`/`le` — the check looks for `gte`/`lte` and answers `Validation:900010`.
- The wire does **not** accept schema-side names: `{"amount":{"gte":5}}` is `900011
  filter.unknownOperator` with hint `gte→ge`. `contains` is not a wire alias (ambiguous).
- Empty or absent `x-filterOperators` ⇒ field not filterable at all (`900010`).
- `vnext-docs how-to/instance-filtering.md` (its `eq/gt/ge/lt/le/between` example) and
  `vnext-schema/vocabularies/view-vocab.json` still list wire names — **the runtime is
  authoritative**; `npm run validate` passes the wrong names.

## 4. `x-filterOperators` per JSON type — correct examples

| Schema `type` | Sensible schema-side set | SQL |
|---|---|---|
| `number` / `integer` | `eq, neq, gt, gte, lt, lte, between, in, nin, isNull` | `accessor::numeric {op}` |
| `string` + `format: date-time` | `eq, gt, gte, lt, lte, between, isNull` | `accessor::timestamptz {op}` |
| `string` (text) | `eq, neq, contains, startsWith, endsWith, in, nin, isNull` | `ILIKE` / equality |
| `boolean` | `eq, neq, isNull` | equality |
| `array` | `includes` (+ `in` for scalar arrays) | `Data @> @param` |

```jsonc
"properties": {
  "amount":        { "type": "number",  "x-filterOperators": ["eq","gt","gte","lt","lte","between"], "x-sortable": true },
  "startDateTime": { "type": "string", "format": "date-time",
                     "x-filterOperators": ["gte","lte","between"], "x-sortable": true,
                     "x-displayFormat": "yyyy-MM-dd'T'HH:mm:ssXXX" },
  "customerName":  { "type": "string",  "x-filterOperators": ["eq","contains","startsWith"] },
  "isVip":         { "type": "boolean", "x-filterOperators": ["eq"] },
  "participants":  { "type": "array",   "x-filterOperators": ["includes"] }
}
```

`x-sortable: true` is required for `sort` on `attributes.*`; `x-displayFormat` is UI-only.

## 5. Filterable instance columns

Bare names, whitelisted, case-insensitive:

| Column | Ops | Notes |
|---|---|---|
| `id`, `key`, `flow`, `stage` | eq, ne, like, startswith, endswith, in, nin | |
| `status`, `effectiveStatus` | eq, ne, in, nin | name or code: `Active`/`A`, `Busy`/`B`, `Completed`/`C`, `Faulted`/`F`, `Passive`/`P` |
| `instanceType` | eq, ne, in, nin | `Root`/`R`, `SubFlow`/`S`, `SubProcess`/`P`. **Never `type`** — `type` always means your `attributes.type` |
| `state` / `currentState`, `effectiveState` | eq, ne, like, startswith, endswith, in, nin | |
| `effectiveStateType`, `effectiveStateSubType` | eq, ne, gt, ge, lt, le, in, nin | ints; subType 7 = cancel, 8 = timeout |
| `createdAt`, `modifiedAt`, `completedAt` | eq, ne, gt, ge, lt, le, between | ISO-8601 |

Sort-only extras: `isTransient`, `currentStateType`, `currentStateSubType`, `createdBy`,
`createdByBehalfOf`, `modifiedBy`, `modifiedByBehalfOf`.

### Instance `type` and `effectiveStatus`

- `instanceType` records **how the instance was started** (`R` root, `S` SubFlow child, `P`
  SubProcess child), stamped once from `parent.id` + `parent.flowtype`, never updated; served as
  `metadata.type`. A workflow declared `type: "S"` but started directly via the API is `R`.
- `GetEffectiveStatus` (`Instance.cs`): `Status.IsTerminal || EffectiveStatus.IsTerminal ? Status : EffectiveStatus`
  — terminal = Completed, Faulted, Passive. A parent parked on an active subflow serves the deepest
  child's status (typically `Busy`) until either side is terminal.

## 6. Sort JSON shape

```
sort={"field":"createdAt","direction":"desc"}
sort={"fields":[{"field":"status","direction":"asc"},{"field":"attributes.startDateTime","direction":"desc"}]}
```

- `direction`: `asc` | `desc`, case-insensitive; absent = `asc`. Property names case-insensitive;
  **unknown members rejected** (`{"order":"desc"}` → 400).
- `-createdAt`, `createdAt desc`, bare `createdAt` **never worked** — they were swallowed and the list
  fell back to `CreatedAt DESC`. Since 0.0.84: `400 Validation:900012 sort.invalidJson`; in
  `GetInstancesTask` `"sort": "-CreatedAt"` → `Result.Fail`.
- `attributes.*` sort needs `x-sortable: true`; numeric attributes sort numerically.

## 7. Limits (`Security/InputValidator.cs`)

| Limit | Value |
|---|---|
| `MaxFilterLength` (whole `filter` string) | 5000 |
| `MaxFiltersCount` | 50 |
| `MaxFieldNameLength` / segment | 100 / 50, `^[a-zA-Z][a-zA-Z0-9_]*$` |
| `MaxValueLength` (scalar operand, post-decode `string.Length`) | **1000** — `in`/`nin`/`between` per operand; enforced since 0.0.94 (`filter.valueTooLong`), not configurable |
| `MaxFieldDepth` | 10 dotted segments |
| `includes` payload | 4096 chars / depth 8 / 40 properties |
| Validation errors returned per request | up to 20 |

## 8. Error codes

| Code | Constant | When |
|---|---|---|
| `Validation:900010` | `SchemaFilterValidation` | Master-schema **policy**: field has no/empty `x-filterOperators`, operator not declared (schema-side name!), or `attributes.*` sort without `x-sortable`. 400, not logged as drift. |
| `Validation:900011` | `InstanceFilterInvalid` | Grammar/limits: `filter.unknownOperator` (with hint), `.unrecognizedFormat`, `.invalidJson`, `.unknownProperty`, `.noOperator`, `.emptyLogicalOperator`, `.legacyNotAggregatable`, `.valueTooLong`, `.tooLong`, `.ambiguousEnvelope` |
| `Validation:900012` | `InstanceSortInvalid` | `sort.invalidJson`, `.invalidDirection`, `.unknownField`, `.unsafePath`, `.emptyField` |
| `Validation:900013` | `InstanceGroupByInvalid` | `groupBy.invalidJson`, `.noFields`, `.invalidField` |
| `Validation:900014` | `InstanceAggregationInvalid` | `aggregations.invalidJson`, `.empty`, `.invalidField`, `.invalidCount` |

400 body: `{"error":{"code":"Validation:900011","message":"…","validationErrors":[{"members":["filter.attributes.reference.eq"],"message":"…"}]}}`.

## 9. `x-indexed` — attribute indexes (0.0.94, `masterAttributeIndexes`)

`x-indexed: true` asks for a **physical projection** (stored generated column `q_<hash>` + index)
so `attributes.*` filters/sorts stop extracting JSON per row. **Not a permission**: filterability
is still `x-filterOperators`, sortability `x-sortable`.

| Rule | Detail |
|---|---|
| Master schema only | Component `attributes.type` must be exactly `"master"`. Any `x-indexed` (even `false`) elsewhere ⇒ publish error `x-indexed is only allowed when attributes.type is 'master'`. |
| Scalar only | `string`, `number`, `integer`, `boolean`; date = `string` + `format: "date-time"`. Nested under fixed `object.properties` OK. Arrays, objects, `$ref`, `oneOf/anyOf/allOf/if`, `type` arrays ⇒ rejected. |
| Boolean value | `true`/`false` only. |
| Runtime runs **no DDL** | Publishing, host start and reads never create indexes or schedule jobs. |

```
master schema (x-indexed) → wf indexes generate [--flow k] [-o dir] [--retire-obsolete]   (offline, no API/DB)
  → <dir>/<timestamp>/<flow>.sql + manifest.json + README.txt
  → DBA: psql -X -v ON_ERROR_STOP=1 --dbname=… --file=<flow>.sql   (maintenance window, ACCESS EXCLUSIVE)
  → AttributeIndexCatalog rows ready → runtime AttributeIndexes:Enabled=true (default false) routes;
     DisabledFlows[] rolls back routing; CatalogCacheSeconds=30
```

- CLI `vnext-workflow-cli` ≥ 1.0.14 (`bin/workflow.js` `indexes generate`), run beside
  `vnext.config.json`; fails before writing on missing refs, duplicate identities, cross-domain refs.
- Catalog/cache/lock failures or unready projections ⇒ JSON-expression fallback, warning
  **`AttributeIndexCatalogFallback` event 70021**; the query still runs.
- Text fields with `contains`/`startsWith`/`endsWith` also get a trigram GIN (`pg_trgm`, `tr-TR-x-icu`).
- Separate from `x-indexed`: built-in **`IX_InstancesData_Data_Gin`** (`jsonb_path_ops`,
  `IsLatest = true`) serves `@>` equality and `includes` on the `Data` column (#911, 0.0.86).

## 10. Pitfalls

1. **`GetInstancesTask` faults instances.** Invalid `filter`/`sort` (or an operand > 1000 chars
   built by a mapping/`InstanceQuery`) → `Result.Fail` → error boundary → under `Abort` the
   caller is `Faulted` with an incident. Cover query strings in integration tests.
2. **`effectiveStatus` filter = stored column.** The served `metadata.effectiveStatus` is clamped at
   read time; the SQL filter is not, so `effectiveStatus eq Completed` can match a parent that
   serves `Busy`. For "is this flow finished?" filter on **`status`**.
3. **`type` ≠ `instanceType`.** Filtering `type` targets `attributes.type`.
4. **Schema-side names.** Wire spellings in `x-filterOperators` validate fine and make the field
   unfilterable with those operators at runtime (`900010`).
5. Envelope `orderBy` **plus** separate `groupBy`/`aggregations` params ⇒ `filter.ambiguousEnvelope`;
   legacy `field=op:value` cannot combine with groupBy (`filter.legacyNotAggregatable`).

## 11. Worked example

Master schema fragment (`attributes.type: "master"`):

```jsonc
"attributes": {
  "type": "master",
  "schema": {
    "type": "object", "additionalProperties": true,
    "properties": {
      "amount":     { "type": "number", "x-indexed": true,
                      "x-filterOperators": ["eq","gte","lte","between"], "x-sortable": true },
      "customerNo": { "type": "string", "x-filterOperators": ["eq","in"] },
      "appliedAt":  { "type": "string", "format": "date-time", "x-indexed": true,
                      "x-filterOperators": ["gte","lte"], "x-sortable": true }
    }
  }
}
```

Filtered list (wire names; URL-encode in practice):

```http
GET /api/v1/credit/workflows/loan/instances
    ?filter={"and":[{"status":{"eq":"A"}},{"attributes":{"amount":{"ge":10000}}},{"attributes":{"appliedAt":{"ge":"2026-09-01T00:00:00Z"}}}]}
    &sort={"fields":[{"field":"attributes.amount","direction":"desc"}]}
    &page=1&pageSize=50
```

→ 200: `ge` maps to `gte`, declared on both fields.

| Request | Result |
|---|---|
| `filter={"attributes":{"amount":{"gt":10000}}}` | **400 `Validation:900010`** — `gt` not in `amount.x-filterOperators`. Fix: add `"gt"` to the schema or send `ge`. |
| `filter={"attributes":{"customerNo":{"like":"12"}}}` | **400 `900010`** until the schema lists `"contains"`. |
| `filter={"attributes":{"amount":{"gte":10000}}}` | **400 `Validation:900011`** `filter.unknownOperator`, hint `gte → ge`. |
| `sort=-createdAt` | **400 `Validation:900012`** `sort.invalidJson`. |

## Sources

- Runtime: `src/BBT.Workflow.Domain/Definitions/Schemas/{SchemaFilterContext,SchemaFilterMetadataResolver,AttributeIndexDefinition}.cs`,
  `src/BBT.Workflow.Domain/QueryExtensions/GraphQL/{GraphQLFilterModels,Validation/InstanceQueryValidator}.cs`,
  `src/BBT.Workflow.Domain/Security/InputValidator.cs`, `src/BBT.Workflow.Domain/WorkflowErrorCodes.cs`,
  `src/BBT.Workflow.Domain/Instances/{Instance,InstanceType,InstanceStatus}.cs`,
  `src/BBT.Workflow.Application/Instances/DTOs/GetInstanceInput.cs`, `InstanceQueryAppService.cs`
- Runtime docs: `docs/runtime/instance-filtering-and-queries.md`, `docs/runtime/manual-attribute-index-maintenance.md`,
  `docs/contracts/instance-query-validation-breaking-changes.md`
- vnext-docs: `how-to/instance-filtering.md` (operator example uses wire names — wrong), `how-to/attribute-indexes.md`, `components/schema.md`
- CLI: `vnext-workflow-cli/bin/workflow.js` (`indexes generate`), `src/commands/indexes.js`
- PRs: #881 (fail-closed validation, 0.0.81–84), #911 (GIN `@>`/includes, 0.0.86), #987 (value limit, identity paging, `x-indexed`, `instanceType`, 0.0.94)
- vnext-meta: features `instanceQueryPaging`, `masterAttributeIndexes`; migrations `instance-filter-value-length-enforced`, `x-indexed-requires-master-schema`
- Related: `schema-vocabularies.md`, `incidents-and-retry.md`, `task-types.md` (GetInstancesTask)
