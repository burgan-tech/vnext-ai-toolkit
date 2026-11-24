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
| An environment-driven URL (`API_BASEURL/...` placeholder resolved with `GetConfigValue`) | No URL surface and no config access — input targets are `$.body`, `$.headers`, `$.query` only |
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

- Targets start with a request surface: `$.body`, `$.headers`, `$.query` (`$.route` is rejected). Each
  starts from the task's configured value — the static `body` in the task definition survives unless a
  target overwrites it.
- `select` + `into` copy one value and must appear together; `select` starts with a variable
  (`$.data.customer`, `$.input.items`).
- Surfaces by task type — an unsupported one fails at run time (publish cannot see the task type):

| Task type | body | headers | query |
|---|---|---|---|
| Http (6), DirectTrigger, Start, SubProcess | yes | yes | no |
| DaprService (3) | yes | yes | yes |
| DaprHttpEndpoint, DaprBinding, DaprPubSub | yes | no | no |
| Soap (16), GetInstance, GetInstanceData, GetInstances | no | yes | no |
| Script, Python, MCP, CacheAside | no input surface — output blocks only | | |

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

## Expression variables

| Variable | What it is | Example |
|---|---|---|
| `data` | latest instance data | `data.customer.id` |
| `input` | the transition request body (not the task payload; null with no transition) | `input.amount` |
| `instance` | read-only view, **camelCase**: `id`, `key`, `flow`, `version`, `currentState`, `effectiveState`, `effectiveStateType`, `effectiveStateSubType`, `effectiveStatus`, `type` (`R`/`S`/`P`), `data` | `instance.currentState` |
| `now` | one timestamp per mapping | `now` |
| `user` | the caller: `available`, `roles`, `hasRole("x")` | `user.available && user.hasRole("approver")` |
| `context` | the legacy rule context, **PascalCase**, unchanged | `context.Instance.CurrentState` |
| `result` | output only: `body`, `headers`, `statusCode` | `result.body.score` |

- Names are **case-sensitive**: `instance.CurrentState` is a publish error.
- JSON values (`data`, `input`, `result`) need a conversion for comparison and arithmetic:
  `data.amount.AsDouble() > 1000`, `.AsInt32()`, `.AsBoolean()`, `.AsArrayLength()`. Writing a value as it
  is needs none: `"data.customer"`.
- Assignment is off: `data.x = 1` is a publish error. Only `into` / `set` keys write.
- Only the variables an expression uses are built (roles are resolved only when `user.roles` /
  `user.hasRole` appears).

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
- A **non-JSON response body** is a string: `result.body.x` reads as missing (skipped), and a `select`
  without `into` fails ("must select a JSON object"). Check the backend's content type.

## Authoring checklist

1. Pick blocks vs `.csx` with the table above (environment-driven URL → `.csx`).
2. Input targets match the task type's surfaces; `select` and `into` together.
3. Output: decide `into` vs root merge; keep `set` keys in the order you want them applied.
4. Every comparison / arithmetic on a JSON value goes through `As*()`; `instance` members camelCase.
5. Any `user.roles` / `user.hasRole` is guarded by `user.available`.
6. `npm run validate` against a vnext-schema that knows the blocks, then publish — publish errors carry the
   JSON location (`states[x].onEntries[0].output.set['$.a']: ...`).
