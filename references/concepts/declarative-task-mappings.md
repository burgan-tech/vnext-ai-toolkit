# Declarative Task Mappings — `input` / `output` blocks

A task binding (`state.onEntries[]` / `onExits[]`, `transition.onExecutionTasks[]`, `function.task` /
`function.onExecutionTasks[]`, `extension.task`) can shape the task request and write the task result
**without a `.csx` file**: two optional JSON blocks, `input` and `output`, each with `select`, `into` and
`set`. Values in `set` are Dynamic Expresso expressions — no Roslyn compile, checked at publish.

> **Availability.** Runtime: the first release after **0.0.106**. Schema: the vnext-schema release that
> adds `inputMappingBlock` / `outputMappingBlock`. On 0.0.106 / schema 0.0.61 a binding still needs
> `mapping`; check the project's pinned versions before scaffolding blocks. Runtime contract:
> vnext `docs/runtime/declarative-task-mappings.md`.

## Default: blocks first, `.csx` as the escape hatch

Scaffold blocks for a new binding when every step is "copy this value there" or "compute this value from
one expression". Keep (or write) an `IMapping` `.csx` when the binding needs any of:

| Need | Why blocks cannot do it |
|---|---|
| Secrets (`GetSecretAsync`), `GetFileAsync`, `context.Related`, `DecryptAsync` | Expressions see variables only, no I/O |
| Loops, branching over several statements, helpers (`scripts.helpers`) | One expression per target |
| Throwing to stop the call from the input side | Blocks never stop the call |
| FanOut (21), Notification (10), Human tasks | The runtime **rejects** blocks on these at run time (`IFanOutMapping` / `INotificationMapping`) |

`mapping` and the blocks are **mutually exclusive** on one binding — schema and publish both reject a
binding with both, and one with neither.

## Shape

```json
{
  "order": 1,
  "task": { "key": "score-task", "domain": "core", "version": "1.0.0", "flow": "sys-tasks" },
  "input": {
    "select": "$.data.customer",
    "into": "$.body.customer",
    "set": { "$.body.customerId": "data.customer.id", "$.headers.x-channel": "\"web\"" }
  },
  "output": {
    "select": "$.body.score",
    "into": "$.kyc.score",
    "set": { "$.kyc.checkedAt": "now", "$.kyc.state": "instance.currentState" }
  }
}
```

A string literal is a quoted expression: `"\"web\""`. Each `set` value is at most 8000 characters.

### Paths

`$`, `.name` (hyphens allowed: `$.headers.x-channel`), `['name']`, `[n]` and `[*]`. `[n]` / `[*]` are
**read-only** (`select`); a write target (`into`, a `set` key) has neither, and an array is written whole.
No filters, no recursive descent.

### `input` — shape the request

- **Targets are fields of the task's own `config`**, named as in the task JSON: `$.url`, `$.method`,
  `$.body.customer`, `$.headers.x-channel`, `$.timeoutSeconds`, a DaprService's `$.queryString`, a
  DaprBinding's `$.data`. Anything a C# `InputHandler` could set is reachable; the root `$` is rejected.
- The block edits a **copy** of the configured `config` (untouched fields keep their configured value)
  and hands it back through the task type's own parser, as if the definition had carried it. A value the
  parser rejects (`"$.url": "42"`) fails the task.
- A path into a field that is not an object (`$.body.x` over an array body) fails; target the field
  whole to replace it. An absent or `null` field becomes an object. Header values are written as strings.
- **A field the task type does not read is ignored**, as in the task definition — publish cannot see the
  task type, so check field names against the task's schema.
- `select` + `into` copy one value and must appear together; `select` starts with a JSON variable
  (`$.data.customer`, `$.input.items`, `$.task.body`); `config` is not selectable.

#### Several headers

One `set` key per header; configured headers the block does not touch are kept, a written one is overridden:

```json
"input": {
  "set": {
    "$.headers.x-channel": "\"web\"",
    "$.headers.x-customer-id": "data.customer.id",
    "$.headers.x-amount": "data.amount",
    "$.headers['x-correlation.id']": "instance.key",
    "$.headers.Accept-Language": "data.lang ?? \"tr-TR\""
  }
}
```

- Values are sent as strings (`data.amount` → `"1250.5"`). A name with a dot or space needs `['...']`; hyphens
  don't.
- `null` / a missing value writes nothing (the configured value stays); a header cannot be removed.
- **Never `into: "$.headers"` to add headers** — `into` replaces the whole object and drops the configured ones.

#### Environment-driven URL

The `API_BASEURL` placeholder a `.csx` resolves with `GetConfigValue` is one expression:

```json
"input": {
  "set": {
    "$.url": "task.url.ToString().Replace(\"API_BASEURL\", config.get(\"Example:ApiBaseUrl\", \"http://localhost:3001\")) + \"/\" + urlEncode(data.customer.id)"
  }
}
```

- `task.url` is a JSON view: call `.ToString()` before string methods.
- Splice every data value into a path or query through `urlEncode(...)`. No `$"..."` interpolation — use
  `+` or `string.Format`.
- Numbers: `data.amount.AsDouble().ToString("0.00")` follows the server culture (`1250,50` under tr-TR);
  `urlEncode(data.amount)` / `"" + data.amount` use the JSON text (`1250.5`).

### `output` — write the result into instance data

- `select` reads `result` = `{ body, headers, statusCode }`; default `$.body`.
- `into` writes the selected value at a data path. **Without `into`** the selected **object** merges at
  the data root (like an `OutputHandler` returning `Data`). **Without `select`**, `into` takes
  `result.body`.
- **In a function or extension** the output block's result is what an `IMapping.OutputHandler` would
  return — that task's output in the function/extension response, not an instance-data write. A
  multi-task function still aggregates in its `function.output` `IOutputHandler` (`.csx`).
- Order: `into` first, then `set` in declaration order (a later key wins). In a workflow everything lands in **one**
  instance-data append — x-encryption, versioning and ETag behave as for any other write; an empty result
  writes no version.
- The block builds a **delta**, merged at the end. `data` in a `set` value is the data **before** this task —
  what `into` wrote is not visible through it; read the new value from `result`.

#### Worked example

Data `{ "kyc": { "level": "basic", "score": 10, "history": [1, 2] } }`, response
`body: { "score": 87, "band": "A", "checks": ["id", "address"] }`, block
`select: "$.body.score", into: "$.kyc.score", set: { "$.kyc.checkedAt": "now" }`:

1. `select` + `into` → delta `{ "kyc": { "score": 87 } }`
2. `set` → delta `{ "kyc": { "score": 87, "checkedAt": "2026-11-24T10:15:03Z" } }`
3. Merge → `{ "kyc": { "level": "basic", "score": 87, "history": [1, 2], "checkedAt": "…" } }` — `band` / `checks`
   not written.

| Authored | Delta (same response) |
|---|---|
| `into: "$.kyc.response"` only | `{ "kyc": { "response": { "score": 87, "band": "A", "checks": [...] } } }` |
| `select: "$.body"` only | `{ "score": 87, "band": "A", "checks": [...] }` at the data root |
| `select: "$.body.score"` only | **fails** — a non-object cannot merge at the root |

Merge rules: objects merge deeply (absent fields survive); **arrays are replaced whole**
(`"$.kyc.history": "result.body.checks"` → `["id", "address"]`); `null` never clears a field — use a sentinel
(`""`, `false`); a path inside a non-object (`$.kyc.score.detail` after `score` = 87) fails.
Response headers/status: `result.headers["x-request-id"]`, `result.statusCode`.

## Expression variables

| Variable | What it is | Example |
|---|---|---|
| `data` | latest instance data | `data.customer.id` |
| `input` | the request body of the hop (not the task payload); `null` on timers, continuations, SubFlow resume and read paths | `input.amount` |
| `instance` | read-only view, **camelCase**: `id`, `key`, `flow`, `version`, `currentState`, `effectiveState`, `effectiveStateType`, `effectiveStateSubType`, `effectiveStatus`, `type` (`R`/`S`/`P`), `data` | `instance.currentState` |
| `now` | one timestamp per mapping | `now` |
| `user` | the caller: `available`, `roles`, `hasRole("x")` | `user.available && user.hasRole("approver")` |
| `context` | the legacy rule context, **PascalCase**, unchanged | `context.Instance.CurrentState` |
| `task` | the task's `config` (a JSON view); in the output phase as the input phase left it | `task.url` |
| `config` | host configuration, same reach as `GetConfigValue` (connection strings included) | `config.get("Example:ApiBaseUrl", "http://localhost:3001")` |
| `result` | output only: `body`, `headers`, `statusCode` | `result.body.score` |
| `headers` | the **incoming** request's headers, read-only, case-insensitive names | `headers["x-channel"]`, `headers.has("x-channel")` |

- Function `urlEncode(value)` percent-encodes one URL component. `task`, `config` and `urlEncode` exist
  in task mappings only, not in condition rules.
- Names are **case-sensitive**: `instance.CurrentState` is a publish error.
- JSON values (`data`, `input`, `result`) need a conversion for comparison and arithmetic:
  `data.amount.AsDouble() > 1000`, `.AsInt32()`, `.AsBoolean()`, `.AsArrayLength()`. Writing a value as it
  is needs none: `"data.customer"`.
- Assignment is off: `data.x = 1` is a publish error. Only `into` / `set` keys write.
- Only the variables an expression uses are built (roles are resolved only when `user.roles` /
  `user.hasRole` appears).

### `input` and `headers`

- `input` is one value per hop (the triggering request body); `input == null` tells a continuation or timer from the triggering hop.
- `x-encryption` fields arrive in **plaintext**: copying one to an unprotected path stores plaintext (writing it back to its own path keeps the protection; `data.email` is the stored token and cannot go elsewhere). `x-storage` fields arrive as the stored handle, except the transition / start `schemas[]` rule, which sees the request as sent.
- `headers["x-channel"]` (indexer for hyphenated names; `null` when absent) and `headers.has("x-channel")`. The `Workflow:HeaderExposure:Deny` list applies. `headers` is **not** a `select` root — read it with `set`. `task.headers` is the task's own **outgoing** headers, not `headers`; forward one with `"$.headers.x-channel": "headers[\"x-channel\"]"`.

### `user` — guard it

`user` is filled on **caller-driven hops**. On System hops (fired timer, SubFlow resume, continuation)
`user.available` is `false`, and reading `user.roles` / `user.hasRole` there **fails the task**
(deterministic, not retried) — always guard: `user.available ? user.hasRole("x") : false`. Functions and
extensions always see `available == false`. Writing roles into data (`"$.approval.roles": "user.roles"`)
exposes them to every later reader — protect the field with `x-roles` / `x-masking`.

## Missing values vs errors

- A missing `select` path, a missing leaf, `?.`, or a member read through a missing intermediate
  (`data.customer.id` with no `customer`) → that entry **writes nothing**, no error.
- Any other failure — a bad conversion (`"gold".AsInt32()`), an unwritable path, a role read on a System
  hop — **fails the task**: the error boundary applies, and with no boundary the instance faults. Nothing
  of the delta is written.
- **No methods on JSON values — convert first**: `input.name.ToString().Substring(0, 3)`. An unknown method call on a present value (`input.name.ToUpper()`) fails the mapping; through a missing intermediate it is a missing source and writes nothing.
- A **non-JSON response body** is a string: `result.body.x` reads as missing (skipped), and a `select`
  without `into` fails ("must select a JSON object"). Check the backend's content type.

## Blocks on transitions and SubFlow states

Three more sites take a block instead of a C# `mapping` (a block and a `mapping` together is a publish error; `select` / `into` / `set` and the expression rules are the same):

| Site | Block | Target | Notes |
|---|---|---|---|
| Transition | `output` only (`input` is a publish error) | instance data | Not on automatic / scheduled transitions. `"select": "$.input"` keeps the whole request. Empty delta = no data version |
| SubFlow state (`type: S` only) | `input` | the child's start document `{ attributes, headers, key, tags }` | `key` must be a string, `tags` a string array; `input` is `null` on an automatic chain and a retry restart |
| SubFlow state | `output` | instance data | Runs on completion **and** fault; `result` is `{ data, status }`, `status` is `"completed"` or `"faulted"`; `input` is `null` |

```json
{ "key": "submit", "target": "review",
  "output": { "select": "$.input.customer", "into": "$.customer",
              "set": { "$.submittedAt": "now" } } }
```

```json
"subFlow": {
  "type": "S",
  "process": { "key": "kyc-check", "domain": "core", "version": "1.0.0", "flow": "sys-flows" },
  "input": { "set": { "$.attributes.customerId": "data.customer.id",
                      "$.headers.x-channel": "\"web\"",
                      "$.tags": "new string[] { \"kyc\" }" } },
  "output": { "select": "$.data.score", "into": "$.kyc.score",
              "set": { "$.kyc.outcome": "result.status" } }
}
```

## Authoring checklist

1. Pick blocks vs `.csx` with the table above.
2. Input targets are field names of the task's `config` (spelled as in its schema); `select` and `into`
   together; data spliced into a URL goes through `urlEncode`.
3. Output: decide `into` vs root merge; keep `set` keys in the order you want them applied.
4. Every comparison / arithmetic on a JSON value goes through `As*()`; `instance` members camelCase.
5. Any `user.roles` / `user.hasRole` is guarded by `user.available`.
6. `npm run validate` against a vnext-schema that knows the blocks, then publish — publish errors carry the
   JSON location (`states[x].onEntries[0].output.set['$.a']: ...`).
7. Transition and SubFlow sites: `output` on transitions, `input` / `output` on `type: S` SubFlow states; never alongside a `mapping`.
