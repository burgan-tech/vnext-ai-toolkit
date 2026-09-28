# Long-Poll Interaction — `interaction.longPoll`

> A **state-level** declaration that tells the polling client "stop, render, then acknowledge".
> Runtime 0.0.97, state-function shape v12. Transitions cannot carry `interaction`.

## 1. When to use

| Situation | Setting |
|-----------|---------|
| A specific client **must render a screen before the engine continues** (mobile result page, receipt, "your part is done") | `terminate: true` |
| Handover to another actor; everyone keeps waiting for a state change (approval state polled by web + mobile) | `terminate: false` (or no block) |
| Only one channel should stop while others keep polling | `terminate: true` + `roles` or `rule` |

`terminate: false` produces **no** `interaction` block in the response — it is documentation for the
author, not a client directive. The pause is armed only for `terminate: true`.

## 2. Definition

```jsonc
{
  "key": "result-page",
  "stateType": 2,
  "interaction": {
    "longPoll": {
      "terminate": true,              // required
      "fallbackTimeoutSeconds": 30,   // optional, >= 1, default 60
      "roles": [                      // EXACTLY ONE of roles | rule
        { "role": "client.mobile", "grant": "allow" }
      ]
    }
  }
}
```

Schema `#/definitions/longPoll` (`additionalProperties: false`): `terminate` bool required;
`fallbackTimeoutSeconds` integer ≥ 1; `oneOf` **`roles`** (roleGrant[]) | **`rule`** (scriptCode,
`IConditionMapping`). A block with neither arm — `{ "terminate": false }` as vnext-docs shows —
**fails schema validation**. Workaround: `"roles": []` (runtime treats an empty arm as allow).
Use lowercase `allow`/`deny`.

## 3. Semantics (`terminate: true`)

1. **Pause.** After ChangeState (50) + OnEntry (60), `HandleLongPollTerminationStep` (75) arms
   `Instance.LongPollAckToken`, schedules a one-shot fallback job at `fallbackTimeoutSeconds`, and
   skips to Finalize. The instance stays **Busy**.
2. **Signal.** While `IsAwaitingLongPollAck`, the state function returns **200** with:

   ```json
   "interaction": {
     "terminateLongPoll": true,
     "fallbackTimeoutSeconds": 60,
     "ack": { "href": "/api/v1/core/workflows/account-opening/instances/{id}/longpoll/ack" }
   }
   ```

   Emitted **only** to callers admitted by the arm (rule → roles → allow) and **only while the token
   is armed** (0.0.95, shape v11) — a state declaring `longPoll` whose instance is not parked shows
   no block. The body still carries `state` + `view.href` so the client can render.
3. **Acknowledge.** Client stops polling, renders, `POST …/instances/{id}/longpoll/ack`. The endpoint
   cancels the fallback job and resumes at `ClearBusyOnResumeStep` (79) → Auto (80) → Schedule (90) →
   Finish → Finalize → ResolveAvailable.
4. **Fallback.** No ack in time → the job resumes the same way. Ack on a non-awaiting instance is a
   **200 no-op**. Ack and fallback are serialized (`:lpack` lock); the second one no-ops.

ErrorBoundary and AutoChain profiles never pause at 75.

### `fallbackTimeoutSeconds` guidance

- Default 60 s. The instance is Busy the whole time: **every other transition 409s** until ack or
  fallback.
- If other actors wait on the same instance (backoffice queue, parent flow), use **5–10 s** — the
  screen renders within one poll cycle anyway.
- Long windows (minutes) only when the acknowledging client is the sole actor and a duplicate
  continuation would be harmful.

## 4. Roles vs rule arm

| | `roles` | `rule` (#990, 0.0.94) |
|---|---|---|
| Decides on | caller roles (header / caller-role provider) | `IConditionMapping` result |
| Empty / missing | allow | n/a — one rule, no fallback entry |
| Failure | deny wins, then allow | **fail-closed**: false / throw / compile error → no signal, ack 403; fallback timer still resumes |
| Body cache | cached per caller scope | **never cached** (rule inputs not in `CallerScopeHash`) |
| Overridable by parent | `roles` yes (whole list) | no |

Rule pitfalls:

- `context.Body` is **not populated** — read `context.Instance.Data`. A view rule pasted here throws
  → deny.
- The ack endpoint forwards **headers only**; the discriminator must be a header (`x-channel`), not
  a query parameter or body field.
- `context.Headers` is dynamic — index and cast; `TryGetValue(out var …)` does not compile (CS8197).
- **Do not put a rule on a long-lived, heavily polled state** (human approval state). Put
  `terminate: false` there and the rule on the *next* state where the verdict really differs per
  channel.

## 5. Ack authorization and the gateway

Since 0.0.95 the runtime does **not** enforce the arm on `POST …/longpoll/ack` in-process. The
Internal Gateway calls `GET …/functions/authorize?ack=true` before forwarding (gate: rule → roles →
allow; no pending ack → allowed). A local runtime without the gateway accepts any ack. Test the
gate through `authorize?ack=true`, not by expecting a 403 from the ack endpoint.

## 6. SubFlow chains

- The paused instance is the **deepest** SubFlow child. Its `interaction` block bubbles up; each
  level rewrites `ack.href` to **its own** endpoint. The client always polls and acks the **top**
  instance; the ack descends one hop per level to the leaf.
- SubProcess children are not followed.
- **Runtime-started children see only the headers the parent's `ISubFlowMapping.InputHandler`
  forwards.** A `roles`-gated pause in a child never arms unless the mapping returns the caller's
  role headers (`x-roles`, `role`, `user_reference`, …) in `ScriptResponse.Headers`. Fixture:
  `subflow-override-lab/src/OverrideLabSubFlowMapping.csx`.

## 7. Parent override (`subFlow.overrides.states.<s>.interaction.longPoll`)

Field-level: `fallbackTimeoutSeconds` and `roles` (whole list; `[]` admits everyone, validator
warns). `terminate` and `rule` are **not** overridable; an override cannot **add** a long poll to a
state without one (log 20305); a `roles` override on a rule-gated child is ignored (log 20306).
Details in `subflow-overrides.md`.

## 8. Author checklist

1. Which client must render before continuing? If none → no block (or `terminate: false` with
   `"roles": []` for the schema).
2. `terminate: true` states: keep them short-lived; set `fallbackTimeoutSeconds` for the slowest
   acceptable render.
3. Choose the arm: roles when the channel is a role; rule when it is a header. Never both.
4. In a SubFlow child, forward role headers from the parent mapping.
5. Client contract: on `interaction.terminateLongPoll === true` → stop polling → render → POST
   `ack.href` → resume polling.

## Sources

- Runtime `vnext` @ `eca5b466` (0.0.97): `src/BBT.Workflow.Domain/Definitions/States/LongPollInteraction.cs`,
  `src/BBT.Workflow.Application/Execution/LongPoll/LongPollInteractionGate.cs`,
  `Pipeline/Steps/{HandleLongPollTerminationStep,ClearBusyOnResumeStep}.cs`,
  `InstanceQueryAppService.ResolveInteractionAsync`, `InstanceCommandAppService.AcknowledgeLongPollAsync`,
  `orchestration/.../InstanceController.cs` (`POST …/longpoll/ack`), `docs/domain/long-poll-termination.md`
- Schema `vnext-schema` @ `ac42026` (0.0.54): `#/definitions/{interaction,longPoll,subFlowLongPollOverride}`
- vnext-docs @ `adf9bf4`: `components/workflow.md` §State Interaction, `how-to/async-sync.md`, `how-to/human-task-approval.md`
- Fixture `vnext-example` @ `3b5ebab`: `core/Workflows/subflow-override-lab/subflow-override-lab-child.json` (`lp-wait`)
- PRs: #936/#990 (rule arm), #1028 (overrides); vnext-meta `longPollTermination` 0.0.62, `longPollInteractionRule` 0.0.94, `queryRolesEnforcementMovedToGateway` 0.0.95
