# Human Task — "My Pending Approvals" (PR #1016, 0.0.94)

> A human task is **not** task type 5 (`Human` task is a stub that answers 202 "Pending"). It is a
> **state** with `subType: 6` plus a domain-level function that lists such states for the caller.
> Runtime 0.0.97.

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

1. State: `stateType: 2`, `subType: 6`.
2. State `queryRoles` (or workflow-level `attributes.queryRoles`). Missing on both → the task is
   **dropped** (log 20459), no error. This is the only read surface where an empty grant set means
   "hide", not "allow".
3. Write `humanTask.title` / `humanTask.description` at the **data root** in the mapping of the
   transition that enters the state (or in an `onEntries` task). If the human state is in a SubFlow
   child, write it into the **child's** data (the parent's `ISubFlowMapping.InputHandler` output).
4. Optional: channel-based `view.rules` on the state; `interaction.longPoll.terminate: false` on the
   approval state (nobody stops polling); a rule-gated `terminate: true` on the **result** state
   (`long-poll-interaction.md`).
5. Do **not** put a long-poll `rule` on the approval state — it is the most-polled state and a rule
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

Evaluation over the caller's whole role set: `DenyGroupOk AND AllowGroupOk` — any role hitting a
deny removes the task; allows are OR. A caller with `ht-approver,ht-blocked` sees **0** tasks with
the fixture above. Transition `roles` play no part (they did before 0.0.94 — migration
`human-task-list-matches-transition-execution`).

## 4. How the scan works

1. One `UNION ALL` statement per 64 flow schemas: `Type IN ('R','P') AND Status IN ('A','B') AND
   EffectiveStatus = 'A' AND EffectiveStateSubType = 6`, `CreatedAt DESC`, `PerSchemaLimit` 200
   (index `IX_Instances_HumanTaskV2`).
2. For each candidate root, descend the SubFlow chain to the leaf (parallel; cross-domain hops via
   `POST {domain}/workflows/{wf}/internal/human-task-leaf/batch`).
3. Read leaf `queryRoles` + stamped overrides → authorize; read leaf `humanTask` text.
4. Merge, `CreatedAt DESC`, cut at `ResultCap` 500 → header `X-VNext-HumanTask-Truncated: true`.
5. Cache per `domain + caller scope + auth-header hash`, TTL 60 s.

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

## Sources

- Runtime `vnext` @ `eca5b466` (0.0.97): `src/BBT.Workflow.Application/Instances/HumanTask/{HumanTaskLeafResolver,HumanTaskFunctionOptions}.cs`,
  `src/BBT.Workflow.Infrastructure/Instances/HumanTaskQuerySql.cs`, `EfCoreInstanceRepository.ScanBatchAsync`,
  `src/BBT.Workflow.Application/Instances/Caching/{HumanTaskFunctionCache,HumanTaskFunctionCacheOptions}.cs`,
  `src/BBT.Workflow.Domain/Instances/DTOs/GetInstanceOutput.cs` (`HumanTaskItemOutput`),
  `orchestration/.../Controllers/Functions/Handlers/HumanTaskFunctionHandler.cs`, `docs/runtime/human-task-function.md`
- Schema `vnext-schema` @ `ac42026` (0.0.54): `#/definitions/stateSubType` (6 = Human)
- vnext-docs @ `adf9bf4`: `how-to/human-task-approval.md`, `components/functions/built-in.md` §Human Task Fonksiyonu
- Fixture `vnext-example` @ `3b5ebab`: `core/Workflows/human-task-chain/{ht-a,ht-b,ht-c}.json`
- PR #1016 (0.0.94); vnext-meta `roleGrantAuthorization.apiEndpoints`, migration `human-task-list-matches-transition-execution` (0.0.79)
