# Human Task — "My Pending Approvals" (PR #1016, 0.0.94)

> A human task is **not** task type 5 (`Human` task is a stub that answers 202 "Pending"). It is a
> **state** with `subType: 6` plus a domain-level function that lists such states for the caller.
> Runtime 0.0.100 (identity-aware leaf decision and combinators since 0.0.99).

## 1. Model

| Piece | Where | Purpose |
|-------|-------|---------|
| `"subType": 6` on a state | workflow definition | marks the state as a human task candidate |
| `queryRoles` on that state (or workflow root) | workflow definition | **who** sees the task — fail-closed |
| `humanTask: { title, description }` | instance data **root** | text shown in the list |
| `GET /api/v1/{domain}/functions/human-task` | domain function (`FunctionTypeConst.HumanTask`) | the list; morph-idm-api calls it once per registered domain and merges |

The approval is a state of the **main flow**, not a separate workflow. Web and mobile poll the same
instance; channel-specific screens come from view rules, not from separate states.

## 2. Author checklist

1. State: `stateType: 2`, `subType: 6`. Not allowed in a flow with `attributes.history: "none"`
   (publish rejects Human, Suspended and Busy states there).
2. State `queryRoles` (or workflow-level `attributes.queryRoles`). Missing on both → the task is
   **dropped** (log 20459), no error. This is the only read surface where an empty grant set means
   "hide", not "allow". Give the approve/cancel transitions the **same** audience in `roles` (§3.1).
3. Write `humanTask.title` / `humanTask.description` at the **data root** in the mapping of the
   transition that enters the state (or in an `onEntries` task). If the human state is in a SubFlow
   child, write it into the **child's** data (the parent's `ISubFlowMapping.InputHandler` output).
4. Optional: channel-based `view.rules` on the state; `interaction.longPoll.terminate: false` on the
   approval state (nobody stops polling — since 0.0.98 the state function serves
   `interaction { terminateLongPoll: false, fallbackTimeoutSeconds }` with no `ack`, and the client
   uses that window); a rule-gated `terminate: true` on the **result** state
   (`long-poll-interaction.md`).
5. The starting client/gateway must send **`act_sub`** (and `sub` when acting for someone): starter
   grants compare with `Instance.CreatedBy` (= `act_sub`) and `Instance.CreatedByBehalfOf` (= `sub`).
6. Do **not** put a long-poll `rule` on the approval state — it is the most-polled state and a rule
   disables the shared body cache.

```json
{
  "key": "ht-a-human",
  "stateType": 2,
  "subType": 6,
  "queryRoles": [
    { "role": "ht-approver", "grant": "allow" },
    { "role": "ht-blocked",  "grant": "deny" }
  ],
  "transitions": [
    { "key": "approve", "target": "ht-a-completed", "triggerType": 0, "versionStrategy": "Minor",
      "labels": [{ "language": "en-US", "label": "Approve" }] }
  ]
}
```

```csharp
// In the ISubFlowMapping / IMapping that enters the state:
dynamic humanTask = new ExpandoObject();
humanTask.title = "50.000 TL EFT approval";
humanTask.description = "Ahmet Yılmaz — TR33 0006 …";
output.humanTask = humanTask;          // root-level key, nothing nested
```

Fixture: `vnext-example/core/Workflows/human-task-chain/ht-a.json` (+ `ht-b`, `ht-c`;
`src/HtcToNextSubFlowMapping.csx` writes a distinct `humanTask` per level).

## 3. Authorization = leaf `queryRoles`

Resolution order at the **leaf** (deepest active SubFlow child):

1. parent-stamped `subFlow.overrides.states.<leafState>.queryRoles`
2. leaf state's own `queryRoles`
3. leaf workflow's root `attributes.queryRoles`
4. none → **dropped**

Intermediate flows between root and leaf are **not** evaluated. Evaluation is the standard grant rule
(`roles-and-authorization.md`): any firing deny removes the task, allows are OR, combinators and the
three-valued logic apply. A caller with `ht-approver,ht-blocked` sees **0** tasks with the fixture
above. Transition `roles` play no part in the list (they did before 0.0.94 — migration
`human-task-list-matches-transition-execution`), but they decide what the opened instance offers.

**Identity at the leaf (0.0.99).** The leaf hop now carries the caller's `act_sub` and `sub` beside the
roles and evaluates them against the **leaf instance's own** starter and history, so
`$InstanceStarter`, `$PreviousUser`, `$InstanceBehalfOfStarter`, `$PreviousBehalfOfUser` and
`$user.` / `$userBehalfOf.` grants **work on the list** (before 0.0.99 they never matched there). Like
the roles, the identity is self-asserted — the gateway is the trust boundary. The list cache key
includes `sub`, so two callers differing only in the user they act for never share a list.

### 3.1 Pattern: role **and** acting for the starter

"An approver may act only for the customer the case was started for" — depth is 1, so
"(A OR B) AND starter" is **two `allOf` allows**. Put the same set on the human state's `queryRoles`
**and** on the approve/cancel transitions' `roles`, so the list, the offered buttons and `authorize`
agree:

```json
"queryRoles": [
  { "grant": "allow", "allOf": [ { "role": "idmFirstApprover" }, { "role": "$InstanceBehalfOfStarter" } ] },
  { "grant": "allow", "allOf": [ { "role": "idmSuperUser" },     { "role": "$InstanceBehalfOfStarter" } ] }
]
```

Fixture: vnext-example `core/Workflows/human-task-chain/ht-idm-approval.json` (verified under
`morph-idm` with no `role` header; started with `act_sub` = agent, `sub` = customer).

| Idiom | Grants |
|---|---|
| Four eyes — the maker who submitted may not approve | `allow maker`, `deny allOf[maker, $PreviousUser]` |
| Starter or the person they act for | `allow anyOf[$InstanceStarter, $InstanceBehalfOfStarter]` |
| Owner recorded in data | `allow $user.$.context.Instance.Data.ownerUserId` |

- `CreatedBy` = `act_sub`, `CreatedByBehalfOf` = `sub`. The path is
  `$.context.Instance.CreatedBy` — **not** `Instance.Data.CreatedBy` (never matches).
- A start request with only `sub` leaves `CreatedBy` empty → `$InstanceStarter` never matches.
- In a parent-stamped override, predefined roles mean the **child's** starter/history.
- Combinators need every pod on ≥ 0.0.99 (`roles-and-authorization.md` § Combinators).

## 4. How the scan works

1. One `UNION ALL` statement per 64 flow schemas: `Type IN ('R','P') AND Status IN ('A','B') AND
   EffectiveStatus = 'A' AND EffectiveStateSubType = 6`, `CreatedAt DESC`, `PerSchemaLimit` 200
   (index `IX_Instances_HumanTaskV2`).
2. For each candidate root, descend the SubFlow chain to the leaf (parallel; cross-domain hops via
   `POST {domain}/workflows/{wf}/internal/human-task-leaf/batch`).
3. Read leaf `queryRoles` + stamped overrides → authorize; read leaf `humanTask` text.
4. Merge, `CreatedAt DESC`, cut at `ResultCap` 500 → header `X-VNext-HumanTask-Truncated: true`.
5. Cache per `domain + caller scope (roles, act_sub, sub) + auth-header hash`, TTL 60 s.

## 5. Response

Bare JSON array (no envelope — morph-idm deserializes a list):

```json
[
  { "instanceId": "APP-2026-000123", "id": "0f3c…", "workflow": "ht-a",
    "title": "HT-A step", "description": "HT-A step description",
    "createdAt": "2026-09-28T09:12:00Z", "vNext": true }
]
```

| Field | Meaning |
|-------|---------|
| `instanceId` | root's business `Key` — **except** a SubProcess, where it is the SubProcess's own `Id` |
| `id` | the addressable instance `Id` — **always use this** to open the instance (`SubflowStarter` copies the parent key onto children, so `Key` can point at the wrong instance) |
| `workflow` | root flow key |
| `title`, `description` | from the leaf's `humanTask`; empty strings when the block is missing (task still listed) |
| `vNext` | always `true` (lets the consumer mix legacy sources) |

Headers: `X-VNext-HumanTask-Truncated` (response, list was capped), `X-VNext-Cache-Override: true`
(request, skip the cache read while `AllowClientOverride`).

## 6. Config

| Key | Default | Bounds |
|-----|--------:|--------|
| `HumanTaskFunction:PerSchemaLimit` | 200 | candidate rows per flow, in SQL (bounds sort/response, not scan cost) |
| `HumanTaskFunction:ResultCap` | 500 | rows in the merged response |
| `HumanTaskFunction:MaxDescentDepth` | 10 | SubFlow levels before a candidate is unresolvable |
| `HumanTaskFunction:FlowsPerScanStatement` | 64 | arms per `UNION ALL` |
| `HumanTaskFunction:FanoutParallelism` | 10 | descent branches per request |
| `HumanTaskFunction:MaxConcurrentDescents` | 32 | descent branches across all in-flight requests |
| `HumanTaskFunctionCache:Enabled` / `TtlSeconds` / `AllowClientOverride` | true / 60 / true | plain TTL cache, no fingerprint check |

## Pitfalls

- **Forgot `queryRoles`** → list is silently shorter (20459). Check logs, not the response.
- **Cache TTL 60 s**: a task completed by B stays in A's list for up to 60 s; A opens it and gets an
  error/finished state. Clients must tolerate "already done" on open. `X-VNext-Cache-Override`
  forces a rebuild (expensive; do not do it on every poll).
- `humanTask` nested under another key is ignored — root only.
- Opening by `instanceId` (Key) can land on the wrong instance for SubProcess children; use `id`.
- Cancelled/faulted/completed instances drop automatically (`EffectiveStatus = 'A'` clamp).
- Type-5 `Human` task in `onExecutionTasks` does **not** create a human task; it just returns 202.
- No in-process `queryRoles` gate on the state/view/data functions since 0.0.95 — the list filters,
  but reading a task's instance directly is gated by the gateway (`roles-and-authorization.md`).
- Root-only `queryRoles` does not protect a human state inside a SubFlow: the list and
  `authorize?queryRoles=true` decide at the **leaf** (leaf-only since 0.0.99). Declare `queryRoles` on
  the leaf or stamp `subFlow.overrides.states.<s>.queryRoles`.
- Starter/behalf-of grants on the list before 0.0.99 never matched — upgrade instead of working around.
- `humanTask.title` / `description` are not field-protected (`x-roles` / `x-masking` do not apply):
  never put PII there that the schema hides elsewhere.

## Sources

- Runtime `vnext` @ `f06961ec` (0.0.100): `src/BBT.Workflow.Application/Instances/HumanTask/{HumanTaskLeafResolver,HumanTaskFunctionOptions,HumanTaskLeafContracts}.cs`, `Instances/Caching/CallerScopeHash.cs`,
  `WorkflowValidator` (history `none` forbids Human states),
  `src/BBT.Workflow.Infrastructure/Instances/HumanTaskQuerySql.cs`, `EfCoreInstanceRepository.ScanBatchAsync`,
  `src/BBT.Workflow.Application/Instances/Caching/{HumanTaskFunctionCache,HumanTaskFunctionCacheOptions}.cs`,
  `src/BBT.Workflow.Domain/Instances/DTOs/GetInstanceOutput.cs` (`HumanTaskItemOutput`),
  `orchestration/.../Controllers/Functions/Handlers/HumanTaskFunctionHandler.cs`, `docs/runtime/human-task-function.md`
- Schema `vnext-schema` 0.0.56: `#/definitions/stateSubType` (6 = Human), `#/definitions/roleGrant` (combinators)
- vnext-docs @ `adf9bf4`: `how-to/human-task-approval.md`, `components/functions/built-in.md` §Human Task Fonksiyonu
- Fixtures `vnext-example`: `core/Workflows/human-task-chain/{ht-a,ht-b,ht-c,ht-idm-approval}.json`, `tests/Core.IntegrationTests/Tests/HumanTaskChain/IdmBehalfOfGrantTests.cs`
- vnext-docs `blog/2026-10-05-v0-0-99.md`; PRs #1016 (0.0.94), #1051 (0.0.98), #1071 (0.0.99), #1082 (history none); vnext-meta `roleGrantAuthorization.apiEndpoints`, migration `human-task-list-matches-transition-execution` (0.0.79)
