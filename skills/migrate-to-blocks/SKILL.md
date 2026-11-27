---
name: migrate-to-blocks
description: Use when the user wants existing `.csx` mappings of a vNext domain on runtime 0.0.107+ turned into declarative `select` / `into` / `set` blocks — triggers "migrate to blocks", "csx'i bloğa çevir", "bloğa geçir", "csx migrate", "declarative'e geçir". Checks the runtime/schema pin, takes the candidates from the domain-check scanner (check 23), proposes each block side by side with its `.csx`, and on approval replaces the mapping, bumps the component version and validates. Never converts unasked.
---

# Migrate `.csx` mappings to declarative blocks

Turns `.csx` mappings that a declarative block can express into `input` / `output` blocks
(`select`, `into`, `set`; Dynamic Expresso values). The rules — sites, variables, paths, missing
values, what stays `.csx` — live in
[`references/concepts/declarative-task-mappings.md`](../../references/concepts/declarative-task-mappings.md);
read it first, this skill does not repeat it.

**Why migrate, honestly.** Readability, publish-time checking of every path and expression, a 15x
cheaper compile on the first call after a publish or pod start, about 10x less allocated then, and
less memory per compiled mapping. A compiled `.csx` is still 2–2.6x faster per call (1–2 µs, small
against a hop). Never tell the user blocks are "faster" without that split
([§ Version gate](../../references/concepts/declarative-task-mappings.md#version-gate--which-form-to-scaffold)).

## 1. Gate on the versions

Read `vnext.config.json` (or the named variant the user works in):

- `runtimeVersion` < 0.0.107 → stop. Blocks fail publish there. Offer the version bump exactly as
  `/vnext-ai-toolkit:vnext-init` Step 2 does (known version as the recommendation, `runtimeVersion`
  and `schemaVersion` as a matching pair, edit the config only on confirmation), then come back.
- The pinned vnext-schema must carry the blocks: `node_modules/@burgan-tech/vnext-schema/schemas/`
  defines `inputMappingBlock` / `outputMappingBlock` (grep for them). If it does not, the same bump
  applies — `npm run validate` would reject every converted binding.

## 2. Take the candidates

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/domain-check/scan.py" [root] [--config FILE] --json
```

Read `blockMigration`: `sites[]` with `site` (`binding`, `transition`, `subflow`, `event`,
`workflowOutput`, `functionOutput`), `where`, `file` (the component), `script` (the `.csx` path or
`inline`), `bucket` and its `hard` / `soft` reasons (lists: domain-check CHECKS.md § 23):

1. **`aday`** — no reason found. Propose these first.
2. **`incele`** — only soft reasons: a block usually can, the author decides. Go one at a time and
   show the reasons: a `Log*` call means the block drops that log line; `GetPropertyValue` /
   `HasProperty` guards are usually unnecessary (a block reads a missing value as null and writes
   nothing); `if` becomes a ternary; a local helper or LINQ must fit one expression per target;
   `GetConfigValue` outside a task binding has no `config.get` there.
3. **`kalir`** — a hard reason. List them with the reasons; never convert one.

The scanner is a text heuristic: read every script before proposing, whatever its bucket.

## 3. Read and propose

For each candidate, read the `.csx` and the component binding. Decide the block by the semantics,
not the text:

- Everything the script writes must be reachable from the site's variables (`data`, `input`,
  `instance`, `now`, `user`, `headers`, plus `task` / `config` / `result` where the site has them).
  If it is not, it stays `.csx` — say why.
- A script that returns `null` / writes nothing on some branch maps to a missing value or a ternary
  yielding `null` ("write nothing"); a script that clears a field with `""` needs the same `""`.
- A task `InputHandler` that returns an empty response and an `OutputHandler` that only shapes the
  result → an `output` block alone; no `input` block.

Show the proposal side by side — the `.csx` lines and the block JSON — one mapping at a time, or,
for many, a table (site · where · block summary · notes) the user approves as a batch. Do not write
anything before the approval.

## 4. Apply on approval

Per approved site:

1. Replace `mapping` with the block(s) on that site — **never both on one site** (publish error).
   For a workflow or function `output`, replace the `{location, code}` object with the block object.
2. Delete the `.csx` only when nothing else references it: grep the whole package for its file name
   and its class name (another binding, a `scripts.helpers` consumer, a `REF`).
3. Bump the component's patch `version` (publish is version-immutable: the same version is not
   republished).
4. Run `npm run validate`; fix or roll back any failure before the next site.

End with the list of what stayed `.csx` and why (the `kalir` items with their reasons, the `incele`
items the author declined, anything you kept after reading), and suggest running the domain's integration tests (`/vnext-ai-toolkit:e2e`) —
a block that validates can still map differently at run time.

## Worked conversions

**Task output — `select` / `into` / `set`.**

```csharp
public Task<ScriptResponse> OutputHandler(ScriptContext context) =>
    Task.FromResult(new ScriptResponse { Data = new {
        kyc = new { score = context.Body.data.score, checkedAt = DateTime.UtcNow,
                    state = context.Instance.CurrentState } } });
```

```json
"output": {
  "select": "$.body.score",
  "into": "$.kyc.score",
  "set": { "$.kyc.checkedAt": "now", "$.kyc.state": "instance.currentState" }
}
```

**Task input — URL from configuration.**

```csharp
var baseUrl = GetConfigValue("Example:ApiBaseUrl", "http://localhost:3001");
var id = GetPropertyValue<string>(context.Instance.Data.customer, "id", "");
if (task is HttpTask http)
    http.SetUrl(http.Url.Replace("API_BASEURL", baseUrl) + "/" + Uri.EscapeDataString(id) + "?lang=tr");
```

```json
"input": {
  "set": {
    "$.url": "task.url.ToString().Replace(\"API_BASEURL\", config.get(\"Example:ApiBaseUrl\", \"http://localhost:3001\")) + \"/\" + urlEncode(data.customer.id) + \"?lang=tr\""
  }
}
```

`config` and `urlEncode` exist in task mappings only.

**Transition output.** An `ITransitionMapping` that keeps the request's `customer` and stamps the
submit:

```json
{
  "key": "submit",
  "target": "review",
  "output": {
    "select": "$.input.customer",
    "into": "$.customer",
    "set": { "$.submittedAt": "now" }
  }
}
```

Not on automatic (`triggerType` 1) or scheduled (2) transitions. An empty block is a publish error.

**SubFlow input (`type: S`).** An `ISubFlowMapping.InputHandler` that builds the child's start:

```json
"subFlow": {
  "type": "S",
  "process": { "key": "kyc-check", "domain": "core", "version": "1.0.0", "flow": "sys-flows" },
  "input": {
    "set": {
      "$.attributes.customerId": "data.customer.id",
      "$.attributes.amount": "input.amount",
      "$.key": "\"kyc-\" + data.customer.id.ToString()"
    }
  }
}
```

The SubFlow `output` block runs on completion **and** fault (`result.status`); script `Mutations`
have no block form.

## Traps

- **JSON values are views.** Convert before an operator or a method: `data.amount.AsDouble() > 1000`,
  `AsInt32()`, `AsBoolean()`, `AsArrayLength()`; `.ToString()` before a string method or a string
  comparison, and for a SubFlow `$.key` built from a number. Writing a value as it is needs no
  conversion.
- **Missing value vs error.** A missing path or member writes nothing, silently; a conversion of a
  missing value (`data.nope.AsDouble()`), a bad cast or an unwritable path fails the mapping (the
  error boundary applies). Guard optional fields with a ternary or `?.`.
- **`user` is guarded.** On System hops (timers, SubFlow resume, continuations) reading
  `user.roles` / `user.hasRole` fails; write `user.available && user.hasRole("x")`. A function or
  extension never has a caller, and a function `output` block that reads `user` is a publish error.
- **Camel case.** `instance.currentState`, not `CurrentState`; only the legacy `context.*` keeps
  PascalCase.
- **Headers.** `headers["x-channel"]` (indexer for hyphenated names); `headers` is never a `select`
  root. `task.headers` is the task's outgoing headers, not the incoming ones.
- **Arrays replace whole, `null` never clears.** Use a sentinel (`""`, `false`) where a clear must be
  expressible.
- **No `$"..."` interpolation**, no assignment (`data.x = 1` does not compile): build strings with
  `+`.

Stays `.csx` regardless of the scan: FanOut (21), Notification (10) and Human tasks, SubProcess
(`P`) mappings, an event mapping that builds a `Selector`, binary function responses, and any
mapping using secrets, `GetFileAsync`, `context.Related`, `DecryptAsync`, `InstanceQuery`, loops,
helpers or a throw on the input side.
