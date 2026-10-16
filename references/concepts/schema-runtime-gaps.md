# Schema ↔ Runtime Gaps — Where `npm run validate` and the Runtime Disagree

> **Scope.** `@burgan-tech/vnext-schema` **0.0.56** (the package `npm run validate` uses) against runtime **v0.0.100**. The schema is the authoring contract and the runtime is the execution contract; they are released separately and are *not* identical. Two consequences:
>
> 1. **Validate passes ≠ runtime accepts.** A shape the schema allows can still be rejected at `publish` (D5 and the publish-time rules below) or silently ignored at execution (D7, D8).
> 2. **Runtime accepts ≠ validate passes.** The runtime tolerates shapes the schema rejects (D1, D2, D6, D11) — a domain package that only ever ran through `publish` can fail `npm run validate` later.
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
| validate: `attributes.type must be equal to one of the allowed values` on a task with `"23"` | D1 |
| validate: `attributes.type must be equal to one of the allowed values` on a **schema** component (`workflow`, `schema`, `view`, `task-input` …) — runtime publish only warns | D11 | <!-- lint:allow -->
| validate: `must be equal to one of the allowed values` / `propertyNames` on an `x-*` keyword inside a schema component | D12 |
| validate prints `⚠ Warning: Could not compile validator for schema` and still passes | D13 |
| validate: `errorBoundary…action must be integer` / `must be equal to one of the allowed values` with `"retry"`, `"rollback"` … | D2 |
| validate: `interaction.longPoll must match exactly one schema in oneOf` | D3 |
| validate: `grant must be equal to one of the allowed values` with `ALLOW` / `DENY` | D4 |
| publish 400: `State '…' declares subFlow.type 'P'. A state can only start a SubFlow ('S')` | D5 / publish-time rules |
| validate passes, but a rule inside `views: […]` on a state never fires | D6 |
| validate: `timer must have required property 'reset'` | D7 |
| runtime: task timeout ignores `onTimeout` | D8 |
| publish 400: `x-filterOperators value 'ge' is not a declaration name; declare 'gte'` | publish-time rules (D9 resolved) | <!-- lint:allow -->
| runtime `CS0246` for a namespace the script imports | D10 |
| publish 400: `onExecutionTasks[i] task key '…' collides with '…'` / `variableKey '…'` slot collision | publish-time rules |
| publish 400: `x-indexed … attributes.type must be master` | publish-time rules |
| publish 400: `x-computed …`, `x-masking …`, `x-encryption …`, `x-storage …`, `x-roles entry is invalid` | publish-time rules; shapes in `field-protection.md` / `file-fields.md` |
| publish 400: `Workflow may contain at most one initial state`, start target, `$start`, `history: none` rules | publish-time rules |

### Not a gap (looks like one, isn't)

- `"subFlow": null` on a `stateType: 4` state — the schema allows `null` by design ("developer does not have a subflow definition" yet); a placeholder, not an error.
- `verbs` absent on a function — "no restriction" in both schema and runtime, not "no verbs".
- `viewOverrides` still present in the schema — it is *deprecated*, not removed; validate accepts it, but new definitions must use `overrides.states.*.views` (see drift table). <!-- lint:allow -->
- `subType` values `0–8` in the schema — `6` (Human) marks an approval state; `1` Success, `2` Error, `3` Terminated, `7` Cancelled, `8` Timeout label final-state outcomes; `4` Suspended / `5` Busy exist in the enum but are not something an author picks.

## Known gaps (D1–D13)

| # | Where (schema path / runtime file) | Symptom | Author workaround | vnext-meta id |
|---|---|---|---|---|
| **D1** | `task-definition.schema.json` → `properties.attributes.properties.type.enum` = `"1"`…`"22"` (0.0.55+) / `TaskEnums.cs` (`Python = 23`) | A task with `type: "23"` **fails validate**; the runtime parses, publishes and runs it. `"22"` validates since schema 0.0.55. | Never author `22` — it is deprecated since 0.0.94 and `type: "6"` (HttpTask) already runs orchestrator-local under the default `Workflow:TaskInvocation` routing. For `23` (Python, experimental) keep the file outside `validateSchemas` coverage or wait for a schema release that adds it. | `external-http-task` (deprecation) |
| **D2** | `workflow-definition.schema.json` → `definitions.errorAction` (`type: integer`, enum `0–5`) / `src/BBT.Workflow.Domain/Shared/JsonSerializerConstants.cs` (`JsonStringEnumConverter(CamelCase)`) | The schema accepts only integers for `errorBoundary.onError[].action`; reference fixtures (e.g. `vnext-example/core/Workflows/fan-out-config-matrix/fan-out-config-matrix.json`) write strings such as `"rollback"`; the runtime accepts **both**. | Write the integer: `0` Abort, `1` Retry, `2` Rollback, `3` Ignore, `4` Notify, `5` Log. Same for `onTimeout.action`. | — |
| **D3** | `definitions.longPoll` → `oneOf: [{required:[roles]}, {required:[rule]}]`, `additionalProperties: false` | `"interaction": { "longPoll": { "terminate": false } }` alone **fails validate** (neither arm satisfied). The runtime's `WorkflowValidator` only rejects declaring **both** arms; an arm-less long poll publishes. | Add an explicit arm: `"roles": []` for "any caller", or a real `roleGrant[]` / one `rule`. Never both arms. | — |
| **D4** | `definitions.roleGrant.grant` enum `["allow","deny"]` (lower-case) | Docs pages (e.g. `how-to/subflow-overrides`) show `"grant": "ALLOW"`; the schema **rejects** upper-case. The runtime compares case-insensitively. | Author `allow` / `deny`. `deny` always wins. | — |
| **D5** | `definitions.subFlow.type` enum `["S","P"]` / `WorkflowValidator.ValidateStateSubFlowType` | A state with `subFlow.type: "P"` **passes validate** but `publish` returns 400: *"A state can only start a SubFlow ('S'). Start a SubProcess with a SubProcess task instead."* Since 0.0.95 (PR #1026). Before that it "worked" only on the async path and stranded the parent `Busy` on the sync path (`Instance:100031`). | State-level `subFlow` is always `type: "S"`. Fire-and-forget children are a **SubProcessTask** (`task.type: "14"`) on a transition's `onExecutionTasks`. See `workflow-types.md` §5. | `state-level-subprocess-rejected-at-publish` |
| **D6** | `definitions.state.properties.view` → `definitions.viewDefinition` (`{view}` **or** `{rules:[…], default}`); `definitions.state` has **no** `additionalProperties: false` | Docs (`how-to/view-selection`) show `"views": [{ "rule", "view" }]` on a state. The schema does not know `views`, so it passes **uncontrolled** (any content), and the runtime accepts both spellings. A typo inside `views` is never caught. | Use the schema form: `"view": { "rules": [ { "rule": {…}, "view": {…} } ], "default": { "view": {…} } }`. Same shape on transitions. | — |
| **D7** | `definitions.timerConfig.required = ["reset","duration"]` / runtime reads only `duration` | `timeout.timer.reset` is **mandatory** in the schema and **read nowhere** in the runtime. The workflow timeout is always "not finished within `duration`, counted from instance start"; it never re-arms on activity. | Write `"reset": "N"` to satisfy the schema and do not design around an idle timeout. Model idle timeouts with a per-state timer transition (`triggerType: 2`). | `workflow-timeout-reset-not-implemented` |
| **D8** | `definitions.errorBoundary.properties.onTimeout` → `definitions.timeoutPolicy` | `onTimeout` validates fine but the runtime has no timeout-specific dispatch; a task timeout surfaces as an ordinary exception. | Catch it with an `onError` rule whose `errorTypes` includes `TaskCanceledException` (and `TimeoutException` for HTTP tasks) and act there. | — |
| **D10** | script `using` lines / `src/BBT.Workflow.Application/Scripting/ScriptEngine.cs` `DefaultUsings`, `CSharpEvaluator.CompileAndLoad` | **Runtimes < 0.0.87** dropped a script's own `using` lines (the compiler replaced them with the platform list), so `using System.Text;` + `StringBuilder` failed at runtime with `CS0246`. **Since 0.0.87 (PR #920)** author usings are merged with the defaults — never replaced. Non-default assemblies still need `scripts.allowedAssemblies` on every version. | Rely on the default usings (`System`, `System.Linq`, `System.Collections.Generic`, `System.Threading(.Tasks)`, `System.Dynamic`, `System.Text.Json(.Serialization)`, `System.Xml(.Linq)`, `BBT.Workflow.*`), add `allowedAssemblies` for anything else, and pin ≥ 0.0.87 if you need custom usings. | — |
| **D11** | `schema-definition.schema.json` → `attributes.type` enum `""`, `master`, `transition`, `component`, `function` / `SchemaComponentValidator` (`SchemaRoleTypes.IsValid`) | A legacy schema `attributes.type` (`workflow`, `schema`, `view`, `headers`, `task-input` …) **fails validate** on 0.0.56; the runtime 0.0.100 **publishes it with a warning** and will refuse it in a later release. | Set the role: `master` (flow data schema), `transition` (transition body), `function` (function `inputSchema`), `component` (embedded view's `dataSchema`); split a multi-role schema. Mapping table: `schema-vocabularies.md` §2. | `schema-attributes-type-legacy-values` (deprecation) | <!-- lint:allow -->
| **D12** | role vocabularies `record-vocab.json` / `input-vocab.json` / `component-vocab.json` (`#/definitions/property` `propertyNames`) / runtime: no role check | An `x-*` keyword outside its role (e.g. `x-roles` on a `transition` schema, `x-context-source` on `master`, `x-binding` anywhere but `component`) **fails validate**; the runtime publishes it and simply does not apply it (exceptions: `x-indexed` outside `master`, runtime `x-computed` on `transition`/`function`/`component` are publish errors). | Move the keyword to the schema whose role owns it (matrix: `schema-vocabularies.md` §1). Do not "fix" by dropping `attributes.type`. | — |
| **D13** | `index.js` `addVocabularies(ajv)` / workspace `validate.js` | `schema-definition.schema.json` 0.0.56 `$ref`s the role vocabularies by `$id`. A `validate.js` that does not register them cannot compile the schema validator, prints `⚠ Warning: Could not compile validator for schema …`, and **skips all `sys-schemas` components** while exiting 0. | Update the workspace template so `validate.js` calls `addVocabularies`; until then treat schema components as unvalidated and check roles/keywords by hand against `schema-vocabularies.md`. | — |

### Resolved gaps

| # | Was | Resolved by |
|---|---|---|
| **D9** | `view-vocab.json` `x-filterOperators` enum listed query tokens (`ne`, `ge`, `le`, `like` …) and omitted `isNull` / `includes`; a schema declaring `ge` validated and then failed every `ge` filter at runtime. | Schema 0.0.56: the enum is the 14 declaration names (`eq, neq, gt, gte, lt, lte, between, contains, startsWith, endsWith, in, nin, isNull, includes`). Runtime 0.0.100: publish rejects query tokens, case variants, unknown values and duplicates (`publish-rejects-filter-operator-tokens`). Clients keep sending query tokens on the wire. | <!-- lint:allow -->
| `x-indexed` absent from the vocabularies | 0.0.54 had no `x-indexed` entry; only the runtime knew it. | Schema 0.0.56: `record-vocab.json` (shape) + `schema-definition.schema.json` `masterIndexSchema` (placement). |

### Publish-time rules the schema does not know

These pass `npm run validate` but are rejected by the runtime's component validators at `publish`:

| Rule | Runtime file | Since | vnext-meta id |
|---|---|---|---|
| State-level `subFlow.type: "P"` (D5) | `WorkflowValidator.ValidateStateSubFlowType` | 0.0.95 | `state-level-subprocess-rejected-at-publish` |
| Function `onExecutionTasks[]` keys that normalise to the same variable (`user-info` / `user_info` → `userInfo`) | `FunctionComponentValidator.ValidateTaskKeysDistinct` | 0.0.95 | `function-multi-task-duplicate-keys-rejected-at-publish` |
| Function view slot entry carrying `extensions`; rule-less slot entry not last; `inputSchema` with body-less-only `verbs` (`["GET"]`); unknown verb | `FunctionComponentValidator` | 0.0.79+ | — |
| `x-indexed` anywhere in a schema whose `attributes.type` is not exactly `master` | schema publication | 0.0.94 | `x-indexed-requires-master-schema` |
| `x-indexed: true` on a non-scalar / `$ref` / combinator / conditional node, or with `x-masking`, an active `x-encryption` or `x-computed` | `AttributeIndexDefinition`, `FieldMaskingDefinition`, `ComputedFieldDefinition` | 0.0.94 / 0.0.99 / 0.0.100 | — |
| Function `onExecutionTasks[]` / transition same-`order` entries filing under one response slot (`variableKey ?? camelCase(task.key)`); invalid `variableKey` (`^[A-Za-z_][A-Za-z0-9_]*$`, ≤ 100) | `FunctionComponentValidator`, `WorkflowValidator` | 0.0.99 | — |
| More than one Initial state; a state keyed `$start`; `startTransition.target` not a declared state (`$self`, `$start`, empty) | `WorkflowValidator` | 0.0.99 | — |
| `scripts.allowedAssemblies` entry that cannot be resolved (even with the sandbox off) | script validation | 0.0.99 | `publish-rejects-unavailable-allowed-assemblies` |
| `x-roles` / function `roles` entry malformed (no `grant`, not exactly one of `role`/`allOf`/`anyOf`, nested combinator, malformed `$user.` / `$userBehalfOf.` / `$role.` path) | `SchemaComponentValidator`, `RoleGrantDefinitionRules` | 0.0.99 | `publish-rejects-malformed-role-grants` |
| `x-masking` / `x-encryption` (runtime): non-string property, not under nested `properties`, `deny` or `allOf`/`anyOf` in `roles`, `roles` on `hash`, `hash` with `pattern`/`format`/`minLength`/`maxLength`/`enum`/`const`, combined with `x-filterOperators`/`x-sortable`/`x-indexed`, `x-masking` + active `x-encryption`, `type: persisted`/`transport`, client members on a runtime rule (and vice versa), `hash`/`encrypt` on a host with `SchemaEncryption:EncryptWrites=false` | `FieldMaskingDefinition`, `SchemaComponentValidator` | 0.0.99 / 0.0.100 | `x-encryption-type-persisted`, `x-encryption-type-transport` |
| `x-filterOperators` value that is not one of the 14 declaration names (query token, case variant, unknown), duplicate or non-string — at every placement | `FilterOperatorDefinition` | 0.0.100 | `publish-rejects-filter-operator-tokens` |
| `x-computed`: `evaluatedBy: "server"`; `runtime` on a `transition`/`function`/`component` schema, at the root / under `items`/`$defs`/combinators, in `required`, combined with `x-indexed`/`x-filterOperators`/`x-sortable`/`x-storage`/`x-roles`/`x-masking`/at-rest `x-encryption`, chained, or reading a non-sibling / encrypted field | `ComputedFieldDefinition` | 0.0.100 | `computed-evaluated-by-server-renamed` | <!-- lint:allow -->
| `x-storage` misplaced (root, `$defs`, combinator, conditional, nested array, inside another file node), on a non-object node, with extra members, or declaring `content` | `FileStorageSchemaParser` | 0.0.100 | — |
| `attributes.history: "none"` on a flow that is not one-shot: a non-automatic state transition, shared transitions, `cancel`/`exit`/`updateData`, workflow or SubFlow-override `timeout`, `interaction.longPoll`, Wizard state, Suspended/Busy/Human subtype, a non-Finish state without transitions, or a state that cannot reach Finish (the last one is runtime-only; the rest the 0.0.56 schema also checks) | `WorkflowValidator.ValidateHistoryNone` | 0.0.100 | — |
| Legacy schema `attributes.type` — **warning only**, refused in a later release (D11) | `SchemaComponentValidator` | 0.0.100 | `schema-attributes-type-legacy-values` |
| Nested FanOut (inner task resolves to `type: "21"`) — rejected at **runtime**, not publish | `FanOutTaskExecutor` | 0.0.80 | — |

Related fixed issue: `function-multi-task-taskresponse-slot-collision` — on ≤ 0.0.94 every `ScriptContext.TaskResponse` slot carried the *last* task's payload; fixed in 0.0.95 (PR #1025) with isolated copies. Read `OutputResponse[variable]` if you must run on an older runtime.

## Documentation / metadata drift

Statements in vnext-meta, PR titles or vnext-docs that no longer match the runtime. Trust the runtime file cited in the fix.

| Stale statement | Where it appears | Reality (runtime v0.0.100) |
|---|---|---|
| `updateData` skips "…OnEntry (60) and **Schedule (80)**" | vnext-meta `features.selfTargetPipelineProfile.description` | `LifecycleOrder.cs`: `Auto = 80`, `Schedule = 90` since 0.0.90. Skipped steps are CancelScheduledJobs 39, OnExit 40, OnEntry 60, Schedule 90. |
| "PRs #883, #884" for the `$self` profile | blog `release-v0-0-80`, vnext-meta | **#883 was closed, not merged** (no merge commit in `vnext`). #884 is the merged change; cite #884 only. |
| PR #880 "type 21" for the orchestrator-local HTTP task | PR #880 title/body | `TaskEnums.cs`: `ExternalHttp = 22`; **21 is FanOut**. The v0.0.88 release note has it right. |
| PR #981 adds "`task-history` and `action-history` system functions" | PR #981 title | `FunctionTypeConst.cs`: the function keys are **`tasks`** and **`actions`** (`…/functions/tasks`, `…/functions/actions?taskId=`). |
| Feature `since` = 0.0.80 for `fanOutTask` / `pythonTask` | vnext-meta `features.json` | Release notes first describe them in **v0.0.85** (fan-out) and **v0.0.88** (python). `since` tracks the merge into `master`; the blog tracks the released image — use `version-manifest.json` when you need the image version. |
| `POST {domain}/workflows/{workflow}/instances/{instance}/transitions/{transitionKey}` | vnext-meta `apiEndpoints` of `selfTargetPipelineProfile`, `availableInRoleScoping`; generated `runtime-feature-matrix.md` | Transitions are **`PATCH`** (`docs/api-reference/rest-api.md`; the same meta file lists PATCH under `instanceEffectiveStatus`). `POST` is only `…/instances/start`. | <!-- lint:allow -->
| State `"views": [ { "rule", "view" } ]` | vnext-docs `how-to/view-selection` | Schema `definitions.viewDefinition`: `"view": { "rules": […], "default": {…} }` (D6). |
| `"grant": "ALLOW"` / `"DENY"` | vnext-docs `how-to/subflow-overrides` examples | Schema enum is lower-case `allow` / `deny` (D4). |
| `subFlow.viewOverrides` / `overrides.views.<viewKey>` | schema (still present, marked deprecated), older docs | Deprecated since 0.0.95; use `subFlow.overrides.states.<state>.views` / `overrides.transitions.<key>.views` (`subflow-view-overrides-legacy`, `subflow-overrides-views-by-view-key`). See `subflow-overrides.md`. <!-- lint:allow --> |
| "HumanTask is task type 5" | older toolkit references | `TaskEnums.cs` keeps `Human = 5`, but `HumanTaskExecutor` is a placeholder ("task execution waits for human interaction"); a human approval step is a **state** with `subType: 6` plus `queryRoles` and the built-in `human-task` function. See `human-task.md`. <!-- lint:allow --> |

## Sources

- Schema: `vnext-schema` @ tag `v0.0.56` — `schemas/task-definition.schema.json` (`attributes.type.enum`), `schemas/workflow-definition.schema.json` (`definitions.{errorAction,longPoll,roleGrant,subFlow,viewDefinition,viewRule,timerConfig,timeoutPolicy,errorBoundary,state,historyMode}`), `schemas/function-definition.schema.json` (`definitions.{viewSlot,schemaSlot}`), `schemas/schema-definition.schema.json` (`attributes.type`, `masterIndexSchema`), `vocabularies/{view,record,input,component}-vocab.json`, `index.js` (`addVocabularies`).
- Runtime: `vnext` @ `f06961ec` (v0.0.100) — `SchemaComponentValidator.cs`, `Definitions/Schemas/{SchemaRoleTypes,FilterOperatorDefinition,ComputedFieldDefinition,FieldMaskingDefinition,FileStorageSchemaParser,AttributeIndexDefinition}.cs`, `docs/runtime/history-mode.md`; `src/BBT.Workflow.Domain/Definitions/Tasks/TaskEnums.cs`; `src/BBT.Workflow.Application/Definitions/Validators/WorkflowValidator.cs` (`ValidateStateSubFlowType`); `src/BBT.Workflow.Application/Definitions/Validators/FunctionComponentValidator.cs` (`ValidateTaskKeysDistinct`); `src/BBT.Workflow.Domain/Definitions/Schemas/SchemaFilterContext.cs`; `src/BBT.Workflow.Domain/QueryExtensions/GraphQL/GraphQLFilterModels.cs` (wire operators + `Suggestions`); `src/BBT.Workflow.Domain/Shared/JsonSerializerConstants.cs`; `src/BBT.Workflow.Application/Scripting/ScriptEngine.cs` (`DefaultUsings`); `src/BBT.Workflow.Domain/Execution/Transitions/Pipeline/LifecycleOrder.cs`; `src/BBT.Workflow.Domain/Definitions/Functions/FunctionTypeConst.cs`; `src/BBT.Workflow.Domain/WorkflowErrorCodes.cs`.
- vnext-meta (vnext master): `deprecations.json` (`schema-attributes-type-legacy-values`, `x-encryption-type-*`), `migrations.json` (`publish-rejects-filter-operator-tokens`, `computed-evaluated-by-server-renamed`, `publish-rejects-malformed-role-grants`, `publish-rejects-unavailable-allowed-assemblies`); earlier entries from 0.0.53: `known-issues.json` (`state-level-subprocess-rejected-at-publish`, `workflow-timeout-reset-not-implemented`, `function-multi-task-taskresponse-slot-collision`), `deprecations.json` (`external-http-task`, `subflow-view-overrides-legacy`, `subflow-overrides-views-by-view-key`), `migrations.json` (`x-indexed-requires-master-schema`, `function-multi-task-duplicate-keys-rejected-at-publish`), `features.json` (`selfTargetPipelineProfile`, `fanOutTask`, `pythonTask`, `externalHttpTask`), `version-manifest.json`.
- PRs: #880, #884 (#883 closed unmerged), #981, #1025, #1026.
- vnext-docs @ `adf9bf4`: `docs/components/tasks/index.md` (22/23 warning), `docs/how-to/{view-selection,subflow-overrides,instance-filtering}.md`, `docs/api-reference/rest-api.md`; blog `release-v0-0-80`, `release-v0-0-85`, `release-v0-0-88`, `release-v0-0-95`.
- Fixtures: `vnext-example` @ `3b5ebab` — `core/Workflows/fan-out-config-matrix/`, `subflow-override-lab/`, `timeout-lab/`, `human-task-chain/`.
