# SubFlow Overrides — `state.subFlow.overrides` (PR #1028, 0.0.95)

> A parent that consumes a workflow as a SubFlow (`stateType: 4`, `subFlow.type: "S"`) tunes the
> child for its own context **without editing the child**: roles, query roles, long-poll window,
> view swaps, timeout. Runtime 0.0.97, schema 0.0.54 (`#/definitions/subFlowOverrides`, schema PR #139).

## 1. When to use

| Need | Override |
|------|----------|
| Same child, different approver roles per parent | `transitions.<key>.roles` |
| Parent's channel must (not) read a child state | `states.<state>.queryRoles` |
| Parent's client renders slower / faster than the child assumed | `states.<state>.interaction.longPoll.fallbackTimeoutSeconds` |
| Parent's channel should own the child's pause | `states.<state>.interaction.longPoll.roles` |
| Parent-branded screen instead of the child's | `states.<state>.views.<viewKey>` / `transitions.<key>.views.<viewKey>` |
| Different abandonment deadline per parent | `timeout` |

Not for: changing child logic (rules, tasks, transitions), adding states or long polls the child
lacks. Fork the child version instead.

## 2. Key catalog

All objects are `additionalProperties: false`. Keys match `^[a-z0-9-]+$`.

| Path | Effect on child | Mode |
|------|-----------------|------|
| `overrides.timeout` | workflow-level `timeout` (full `workflowTimeout`: key, target, versionStrategy, timer, mapping, annotations) | **replace whole block**, annotations included |
| `overrides.transitions.<childTransition>.roles` | transition role grants | replace whole list |
| `overrides.transitions.<childTransition>.views.<viewKey>` | the view the child's rules selected for that transition | replace reference |
| `overrides.states.<childState>.queryRoles` | state query grants | replace whole list |
| `overrides.states.<childState>.interaction.longPoll.fallbackTimeoutSeconds` | ack window (≥ 1) | field-level |
| `overrides.states.<childState>.interaction.longPoll.roles` | interaction grants; `[]` admits every caller (validator warns) | field-level; list replaces as a whole; **ignored when the child uses `rule`** (log 20306) |
| `overrides.states.<childState>.views.<viewKey>` | the view the child's rules selected in that state | replace reference |
| `overrides.views.<viewKey>`, `subFlow.viewOverrides` | swap by view key everywhere | **deprecated 0.0.95** — mixing with scoped views on one subFlow is a validation error | <!-- lint:allow -->

**Never overridable:** view `rule`, long-poll `rule`, long-poll `terminate`. An override cannot
**add** a long poll to a state that declares none (log 20305).

Grants use lowercase `"grant": "allow"` / `"deny"` (schema enum). vnext-docs
`how-to/subflow-overrides.md` shows `"ALLOW"` — that fails schema validation.

## 3. Example (fixture `subflow-override-lab-parent.json`)

```json
{
  "key": "waiting",
  "stateType": 4,
  "subFlow": {
    "type": "S",
    "process": { "key": "subflow-override-lab-child", "domain": "core", "version": "1.0.2", "flow": "sys-flows" },
    "mapping": { "location": "./src/OverrideLabSubFlowMapping.csx", "code": "<base64>" },
    "overrides": {
      "states": {
        "lp-wait": {
          "interaction": { "longPoll": { "fallbackTimeoutSeconds": 120 } },
          "views": {
            "subflow-override-lab-child-lp-view": {
              "key": "subflow-override-lab-parent-lp-view", "domain": "core", "version": "1.0.0", "flow": "sys-views"
            }
          }
        }
      },
      "transitions": {
        "confirm": {
          "views": {
            "subflow-override-lab-child-confirm-view": {
              "key": "subflow-override-lab-parent-confirm-view", "domain": "core", "version": "1.0.0", "flow": "sys-views"
            }
          }
        }
      }
    }
  }
}
```

The child's `lp-wait` declares `terminate: true, fallbackTimeoutSeconds: 600, roles: [ovr.child-ack]`;
the parent keeps `terminate` and `roles`, shortens the window to 120 s and swaps the view. Variant
`…-parent-roles.json` replaces the roles list with `[{ "role": "ovr.parent-ack", "grant": "allow" }]`;
`timeout-lab-parent.json` replaces the child's `timeout` with its own `PT20S` deadline and
`annotations`.

## 4. Resolution rules

| Rule | Consequence |
|------|-------------|
| **Stamped at start.** `SubflowStarter` copies `overrides.states` / `overrides.transitions` onto the child (`subflow.state_role_overrides`, `subflow.transition_role_overrides`) | start-time snapshot: children already running keep the overrides they started with; republishing the parent does not touch them |
| **Resolved child-side** on the child's `CurrentState` (`Instance.ResolveEffectiveLongPoll`, `ResolveViewOverride`) | overrides apply even when the child is addressed directly; state function, `authorize?ack=true`, the pipeline arm (75) and the fallback job all agree |
| **One hop.** In P → C → G, P's overrides apply to C only; G reads C's overrides | to reach G, override on C's `subFlow` definition |
| **Inert if the state/transition does not exist in the child** | validator cannot see the child; typos are silent — check the state function |
| Unresolvable replacement view → child's own view is served (log 20101) | keep parent views published with the parent |
| Malformed stamp on the child → falls back to child config (log 20307) | |

`transitions.<key>.roles` overrides key off the **child's** transitions; the parent's `availableIn`
narrowing does not apply to them. `states.<s>.queryRoles` is also what the human-task list reads
first (`human-task.md`).

## 5. Interplay

- **Timeout replace is total.** Overriding `timeout` drops the child's `mapping` and `annotations`
  unless you repeat them.
- **Long-poll roles on a runtime-started child only matter if the parent mapping forwards role
  headers** (`long-poll-interaction.md` §6). The fixture mapping forwards `x-roles`, `role`,
  `user_reference`, `x-device-id`, `x-token-id`.
- Child with `rule` arm: only `fallbackTimeoutSeconds` is effective; `roles` override is logged and
  dropped.
- `queryRoles` override participates in the `authorize?queryRoles=true` chain conjunction (each
  level: stamped override → state → root).

## Pitfalls

- Uppercase `ALLOW`/`DENY` → schema error.
- `viewOverrides` + scoped `views` on the same subFlow → publish rejected. <!-- lint:allow -->
- Expecting an override to add `interaction.longPoll` to a plain child state → nothing happens (20305).
- Overriding a grandchild from the top parent → no effect (one hop).
- Changing overrides and re-testing on an **existing** child instance → old stamp still applies;
  start a new instance.

## Sources

- Runtime `vnext` @ `eca5b466` (0.0.97): `src/BBT.Workflow.Domain/Definitions/{SubFlowOverrides,SubFlowStateOverride,SubFlowTransitionOverride,SubFlowLongPollOverride,SubFlowStateInteractionOverride}.cs`,
  `src/BBT.Workflow.Domain/Instances/SubFlowOverrideStamp.cs`, `Instance.ResolveEffectiveLongPoll`,
  `InstanceSubFlowOverrideExtensions.ResolveViewOverride`, `WorkflowValidator.ValidateSubFlowOverrides`,
  `docs/domain/subflow-overrides.md`, `docs/domain/long-poll-termination.md` §Parent override
- Schema `vnext-schema` @ `ac42026` (0.0.54): `#/definitions/{subFlowOverrides,subFlowStateOverride,subFlowTransitionOverride,subFlowLongPollOverride,subFlow}`
- vnext-docs @ `adf9bf4`: `how-to/subflow-overrides.md` (grant casing wrong), `components/workflow.md`
- Fixtures `vnext-example` @ `3b5ebab`: `core/Workflows/subflow-override-lab/{subflow-override-lab-parent,…-parent-roles,…-parent-short,…-child}.json`, `core/Workflows/timeout-lab/timeout-lab-parent.json`
- PR #1028 (0.0.95), schema PR #139; vnext-meta `subFlowOverrides` 0.0.95, deprecations `subflow-overrides-views-by-view-key`, `subflow-view-overrides-legacy`
