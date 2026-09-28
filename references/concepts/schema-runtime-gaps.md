# Schema ↔ Runtime Gaps — Where `npm run validate` and the Runtime Disagree

> **Scope.** `@burgan-tech/vnext-schema` **0.0.54** (the package `npm run validate` uses) against runtime **v0.0.97**. The schema is the authoring contract and the runtime is the execution contract; they are released separately and are *not* identical. Two consequences:
>
> 1. **Validate passes ≠ runtime accepts.** A shape the schema allows can still be rejected at `publish` (D5, D-dup) or silently ignored at execution (D7, D8).
> 2. **Runtime accepts ≠ validate passes.** The runtime tolerates shapes the schema rejects (D1, D2, D6) — a domain package that only ever ran through `publish` can fail `npm run validate` later.
>
> Everything below is verified against the files in `## Sources`. When the runtime and the schema disagree, **author the schema-valid form** unless a row says otherwise — the schema is what CI runs.

Note on paths: `workflow-definition.schema.json` and `function-definition.schema.json` keep their reusable pieces under **`definitions`** (draft-07 style), not `$defs`. `$ref`s look like `#/definitions/roleGrant`.

## How to use this file (validate-and-fix triage)

When `npm run validate` fails or a `publish` returns 400:

1. Match the error's **member path** (e.g. `attributes.states[2].subFlow.type`, `attributes.type`, `x-filterOperators`) to the **Where** column.
2. Read **Symptom** — decide whether the error is a real authoring mistake or one of the known gaps.
3. Apply **Author workaround** exactly; do not "fix" by deleting the field or relaxing the schema.
4. Quote the **vnext-meta id** (where one exists) in the fix summary so the reader can look it up in `references/runtime-feature-matrix.md` / `@burgan-tech/vnext-meta`.
5. If the error matches nothing here, it is a genuine validation error — fix the component.

### Quick lookup — error text → row

| You see | Go to |
|---|---|
| validate: `attributes.type must be equal to one of the allowed values` on a task with `"22"` / `"23"` | D1 |
| validate: `errorBoundary…action must be integer` / `must be equal to one of the allowed values` with `"retry"`, `"rollback"` … | D2 |
| validate: `interaction.longPoll must match exactly one schema in oneOf` | D3 |
| validate: `grant must be equal to one of the allowed values` with `ALLOW` / `DENY` | D4 |
| publish 400: `State '…' declares subFlow.type 'P'. A state can only start a SubFlow ('S')` | D5 / publish-time rules |
| validate passes, but a rule inside `views: […]` on a state never fires | D6 |
| validate: `timer must have required property 'reset'` | D7 |
| runtime: task timeout ignores `onTimeout` | D8 |
| runtime 400 on `GET …/instances?…` with `ge` / `le` / `ne` / `like` on a field that declares them | D9 <!-- lint:allow --> |
| runtime `CS0246` for a namespace the script imports | D10 |
| publish 400: `onExecutionTasks[i] task key '…' collides with '…'` | publish-time rules |
| publish 400: `x-indexed … attributes.type must be master` | publish-time rules |

### Not a gap (looks like one, isn't)

- `"subFlow": null` on a `stateType: 4` state — the schema allows `null` by design ("developer does not have a subflow definition" yet); a placeholder, not an error.
- `verbs` absent on a function — "no restriction" in both schema and runtime, not "no verbs".
- `viewOverrides` still present in the schema — it is *deprecated*, not removed; validate accepts it, but new definitions must use `overrides.states.*.views` (see drift table). <!-- lint:allow -->
- `subType` values `0–8` in the schema — `6` (Human) marks an approval state; `1` Success, `2` Error, `3` Terminated, `7` Cancelled, `8` Timeout label final-state outcomes; `4` Suspended / `5` Busy exist in the enum but are not something an author picks.

## Known gaps (D1–D10)

| # | Where (schema path / runtime file) | Symptom | Author workaround | vnext-meta id |
|---|---|---|---|---|
| **D1** | `task-definition.schema.json` → `properties.attributes.properties.type.enum` = `"1"`…`"21"` / `src/BBT.Workflow.Domain/Definitions/Tasks/TaskEnums.cs` (`ExternalHttp = 22`, `Python = 23`) | A task with `type: "22"` or `"23"` **fails validate**; the runtime parses, publishes and runs both. | Never author `22` — it is deprecated since 0.0.94 and `type: "6"` (HttpTask) already runs orchestrator-local under the default `Workflow:TaskInvocation` routing. For `23` (Python, experimental) keep the file outside `validateSchemas` coverage or wait for a schema release that adds it. | `external-http-task` (deprecation) |
| **D2** | `workflow-definition.schema.json` → `definitions.errorAction` (`type: integer`, enum `0–5`) / `src/BBT.Workflow.Domain/Shared/JsonSerializerConstants.cs` (`JsonStringEnumConverter(CamelCase)`) | The schema accepts only integers for `errorBoundary.onError[].action`; reference fixtures (e.g. `vnext-example/core/Workflows/fan-out-config-matrix/fan-out-config-matrix.json`) write strings such as `"rollback"`; the runtime accepts **both**. | Write the integer: `0` Abort, `1` Retry, `2` Rollback, `3` Ignore, `4` Notify, `5` Log. Same for `onTimeout.action`. | — |
| **D3** | `definitions.longPoll` → `oneOf: [{required:[roles]}, {required:[rule]}]`, `additionalProperties: false` | `"interaction": { "longPoll": { "terminate": false } }` alone **fails validate** (neither arm satisfied). The runtime's `WorkflowValidator` only rejects declaring **both** arms; an arm-less long poll publishes. | Add an explicit arm: `"roles": []` for "any caller", or a real `roleGrant[]` / one `rule`. Never both arms. | — |
| **D4** | `definitions.roleGrant.grant` enum `["allow","deny"]` (lower-case) | Docs pages (e.g. `how-to/subflow-overrides`) show `"grant": "ALLOW"`; the schema **rejects** upper-case. The runtime compares case-insensitively. | Author `allow` / `deny`. `deny` always wins. | — |
| **D5** | `definitions.subFlow.type` enum `["S","P"]` / `WorkflowValidator.ValidateStateSubFlowType` | A state with `subFlow.type: "P"` **passes validate** but `publish` returns 400: *"A state can only start a SubFlow ('S'). Start a SubProcess with a SubProcess task instead."* Since 0.0.95 (PR #1026). Before that it "worked" only on the async path and stranded the parent `Busy` on the sync path (`Instance:100031`). | State-level `subFlow` is always `type: "S"`. Fire-and-forget children are a **SubProcessTask** (`task.type: "14"`) on a transition's `onExecutionTasks`. See `workflow-types.md` §5. | `state-level-subprocess-rejected-at-publish` |
| **D6** | `definitions.state.properties.view` → `definitions.viewDefinition` (`{view}` **or** `{rules:[…], default}`); `definitions.state` has **no** `additionalProperties: false` | Docs (`how-to/view-selection`) show `"views": [{ "rule", "view" }]` on a state. The schema does not know `views`, so it passes **uncontrolled** (any content), and the runtime accepts both spellings. A typo inside `views` is never caught. | Use the schema form: `"view": { "rules": [ { "rule": {…}, "view": {…} } ], "default": { "view": {…} } }`. Same shape on transitions. | — |
| **D7** | `definitions.timerConfig.required = ["reset","duration"]` / runtime reads only `duration` | `timeout.timer.reset` is **mandatory** in the schema and **read nowhere** in the runtime. The workflow timeout is always "not finished within `duration`, counted from instance start"; it never re-arms on activity. | Write `"reset": "N"` to satisfy the schema and do not design around an idle timeout. Model idle timeouts with a per-state timer transition (`triggerType: 2`). | `workflow-timeout-reset-not-implemented` |
| **D8** | `definitions.errorBoundary.properties.onTimeout` → `definitions.timeoutPolicy` | `onTimeout` validates fine but the runtime has no timeout-specific dispatch; a task timeout surfaces as an ordinary exception. | Catch it with an `onError` rule whose `errorTypes` includes `TaskCanceledException` (and `TimeoutException` for HTTP tasks) and act there. | — |
| **D9** | `vocabularies/view-vocab.json` → `x-filterOperators.items.enum` = `eq, ne, gt, ge, lt, le, between, match, like, startswith, endswith, in, nin` / `src/BBT.Workflow.Domain/Definitions/Schemas/SchemaFilterContext.cs` `InternalToSchemaOperatorMap` | The vocabulary lists the **wire** operator names a client sends in a filter (`ge`, `le`, `ne`, `like`). `x-filterOperators` in a master schema must use the **schema-authoring** spellings the runtime checks against: `gte`, `lte`, `neq`, `contains` (`like` and `match` both map to `contains`), `startsWith`, `endsWith`, `isNull`, `includes`. Declaring `"ge"` in `x-filterOperators` means a `?ge=` filter is **rejected**. <!-- lint:allow --> | Author `x-filterOperators` with `eq, neq, gt, gte, lt, lte, between, contains, startsWith, endsWith, in, nin, isNull, includes`. Clients keep sending `ge`/`le`/`ne`/`like` on the wire. See `schema-vocabularies.md`. <!-- lint:allow --> | — |
| **D10** | script `using` lines / `src/BBT.Workflow.Application/Scripting/ScriptEngine.cs` `DefaultUsings`, `CSharpEvaluator.CompileAndLoad` | **Runtimes < 0.0.87** dropped a script's own `using` lines (the compiler replaced them with the platform list), so `using System.Text;` + `StringBuilder` failed at runtime with `CS0246`. **Since 0.0.87 (PR #920)** author usings are merged with the defaults — never replaced. Non-default assemblies still need `scripts.allowedAssemblies` on every version. | Rely on the default usings (`System`, `System.Linq`, `System.Collections.Generic`, `System.Threading(.Tasks)`, `System.Dynamic`, `System.Text.Json(.Serialization)`, `System.Xml(.Linq)`, `BBT.Workflow.*`), add `allowedAssemblies` for anything else, and pin ≥ 0.0.87 if you need custom usings. | — |

Vocabulary note (D9 neighbour): `vnext-schema` 0.0.54 has **no `x-indexed` entry** in any vocabulary file, and its `x-filterOperators` enum omits `isNull` / `includes` that the runtime accepts. See `schema-vocabularies.md` for the runtime-side list.

### Publish-time rules the schema does not know

These pass `npm run validate` but are rejected by the runtime's component validators at `publish`:

| Rule | Runtime file | Since | vnext-meta id |
|---|---|---|---|
| State-level `subFlow.type: "P"` (D5) | `WorkflowValidator.ValidateStateSubFlowType` | 0.0.95 | `state-level-subprocess-rejected-at-publish` |
| Function `onExecutionTasks[]` keys that normalise to the same variable (`user-info` / `user_info` → `userInfo`) | `FunctionComponentValidator.ValidateTaskKeysDistinct` | 0.0.95 | `function-multi-task-duplicate-keys-rejected-at-publish` |
| Function view slot entry carrying `extensions`; rule-less slot entry not last; `inputSchema` with body-less-only `verbs` (`["GET"]`); unknown verb | `FunctionComponentValidator` | 0.0.79+ | — |
| `x-indexed` anywhere in a schema whose `attributes.type` is not exactly `master` | schema publication | 0.0.94 | `x-indexed-requires-master-schema` |
| Nested FanOut (inner task resolves to `type: "21"`) — rejected at **runtime**, not publish | `FanOutTaskExecutor` | 0.0.80 | — |

Related fixed issue: `function-multi-task-taskresponse-slot-collision` — on ≤ 0.0.94 every `ScriptContext.TaskResponse` slot carried the *last* task's payload; fixed in 0.0.95 (PR #1025) with isolated copies. Read `OutputResponse[variable]` if you must run on an older runtime.

## Documentation / metadata drift

Statements in vnext-meta, PR titles or vnext-docs that no longer match the runtime. Trust the runtime file cited in the fix.

| Stale statement | Where it appears | Reality (runtime v0.0.97) |
|---|---|---|
| `updateData` skips "…OnEntry (60) and **Schedule (80)**" | vnext-meta `features.selfTargetPipelineProfile.description` | `LifecycleOrder.cs`: `Auto = 80`, `Schedule = 90` since 0.0.90. Skipped steps are CancelScheduledJobs 39, OnExit 40, OnEntry 60, Schedule 90. |
| "PRs #883, #884" for the `$self` profile | blog `release-v0-0-80`, vnext-meta | **#883 was closed, not merged** (no merge commit in `vnext`). #884 is the merged change; cite #884 only. |
| PR #880 "type 21" for the orchestrator-local HTTP task | PR #880 title/body | `TaskEnums.cs`: `ExternalHttp = 22`; **21 is FanOut**. The v0.0.88 release note has it right. |
| PR #981 adds "`task-history` and `action-history` system functions" | PR #981 title | `FunctionTypeConst.cs`: the function keys are **`tasks`** and **`actions`** (`…/functions/tasks`, `…/functions/actions?taskId=`). |
| Feature `since` = 0.0.80 for `fanOutTask` / `pythonTask` | vnext-meta `features.json` | Release notes first describe them in **v0.0.85** (fan-out) and **v0.0.88** (python). `since` tracks the merge into `master`; the blog tracks the released image — use `version-manifest.json` when you need the image version. |
| `POST {domain}/workflows/{workflow}/instances/{instance}/transitions/{transitionKey}` | vnext-meta `apiEndpoints` of `selfTargetPipelineProfile`, `availableInRoleScoping`; generated `runtime-feature-matrix.md` | Transitions are **`PATCH`** (`docs/api-reference/rest-api.md`; the same meta file lists PATCH under `instanceEffectiveStatus`). `POST` is only `…/instances/start`. | <!-- lint:allow -->
| State `"views": [ { "rule", "view" } ]` | vnext-docs `how-to/view-selection` | Schema `definitions.viewDefinition`: `"view": { "rules": […], "default": {…} }` (D6). |
| `"grant": "ALLOW"` / `"DENY"` | vnext-docs `how-to/subflow-overrides` examples | Schema enum is lower-case `allow` / `deny` (D4). |
| `x-filterOperators: ["eq","gt","ge","lt","le","between"]` | vnext-docs `how-to/instance-filtering` (schema example) | Those are wire names; the schema must declare `gte` / `lte` (D9). <!-- lint:allow --> |
| `subFlow.viewOverrides` / `overrides.views.<viewKey>` | schema (still present, marked deprecated), older docs | Deprecated since 0.0.95; use `subFlow.overrides.states.<state>.views` / `overrides.transitions.<key>.views` (`subflow-view-overrides-legacy`, `subflow-overrides-views-by-view-key`). See `subflow-overrides.md`. <!-- lint:allow --> |
| "HumanTask is task type 5" | older toolkit references | `TaskEnums.cs` keeps `Human = 5`, but `HumanTaskExecutor` is a placeholder ("task execution waits for human interaction"); a human approval step is a **state** with `subType: 6` plus `queryRoles` and the built-in `human-task` function. See `human-task.md`. <!-- lint:allow --> |

## Sources

- Schema: `vnext-schema` @ `ac42026` (v0.0.54) — `schemas/task-definition.schema.json` (`attributes.type.enum`), `schemas/workflow-definition.schema.json` (`definitions.{errorAction,longPoll,roleGrant,subFlow,viewDefinition,viewRule,timerConfig,timeoutPolicy,errorBoundary,state}`), `schemas/function-definition.schema.json` (`definitions.{viewSlot,schemaSlot}`), `vocabularies/view-vocab.json` (`x-filterOperators`, ~L95).
- Runtime: `vnext` @ `eca5b466` (v0.0.97) — `src/BBT.Workflow.Domain/Definitions/Tasks/TaskEnums.cs`; `src/BBT.Workflow.Application/Definitions/Validators/WorkflowValidator.cs` (`ValidateStateSubFlowType`); `src/BBT.Workflow.Application/Definitions/Validators/FunctionComponentValidator.cs` (`ValidateTaskKeysDistinct`); `src/BBT.Workflow.Domain/Definitions/Schemas/SchemaFilterContext.cs`; `src/BBT.Workflow.Domain/QueryExtensions/GraphQL/GraphQLFilterModels.cs` (wire operators + `Suggestions`); `src/BBT.Workflow.Domain/Shared/JsonSerializerConstants.cs`; `src/BBT.Workflow.Application/Scripting/ScriptEngine.cs` (`DefaultUsings`); `src/BBT.Workflow.Domain/Execution/Transitions/Pipeline/LifecycleOrder.cs`; `src/BBT.Workflow.Domain/Definitions/Functions/FunctionTypeConst.cs`; `src/BBT.Workflow.Domain/WorkflowErrorCodes.cs`.
- vnext-meta 0.0.53 (`vnext/vnext-meta/`): `known-issues.json` (`state-level-subprocess-rejected-at-publish`, `workflow-timeout-reset-not-implemented`, `function-multi-task-taskresponse-slot-collision`), `deprecations.json` (`external-http-task`, `subflow-view-overrides-legacy`, `subflow-overrides-views-by-view-key`), `migrations.json` (`x-indexed-requires-master-schema`, `function-multi-task-duplicate-keys-rejected-at-publish`), `features.json` (`selfTargetPipelineProfile`, `fanOutTask`, `pythonTask`, `externalHttpTask`), `version-manifest.json`.
- PRs: #880, #884 (#883 closed unmerged), #981, #1025, #1026.
- vnext-docs @ `adf9bf4`: `docs/components/tasks/index.md` (22/23 warning), `docs/how-to/{view-selection,subflow-overrides,instance-filtering}.md`, `docs/api-reference/rest-api.md`; blog `release-v0-0-80`, `release-v0-0-85`, `release-v0-0-88`, `release-v0-0-95`.
- Fixtures: `vnext-example` @ `3b5ebab` — `core/Workflows/fan-out-config-matrix/`, `subflow-override-lab/`, `timeout-lab/`, `human-task-chain/`.
