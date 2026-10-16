# Long-Poll Interaction — `interaction.longPoll`

> A **state-level** declaration that tells the polling client "stop, render, then acknowledge".
> Runtime 0.0.100, state-function shape v14. Transitions cannot carry `interaction`.

## 1. When to use

| Situation | Setting |
|-----------|---------|
| A specific client **must render a screen before the engine continues** (mobile result page, receipt, "your part is done") | `terminate: true` |
| Handover to another actor; everyone keeps waiting for a state change (approval state polled by web + mobile) | `terminate: false` (or no block) |
| Only one channel should stop while others keep polling | `terminate: true` + `roles` or `rule` |

The pause (Busy + ack token + fallback job) is armed **only** for `terminate: true`.
`terminate: false` arms nothing server-side, but since 0.0.98 (PR #1051, shape v13) the state function
serves its `interaction` block again — **without `ack`** — as a client directive: "keep long polling
for `fallbackTimeoutSeconds`" (§3a). It was missing on 0.0.95–0.0.97.

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

## 3a. Semantics (`terminate: false`, 0.0.98+)

Nothing is paused, the instance is not Busy, no fallback job exists. Whenever the instance is in the
declaring state and the caller passes the gate (`rule`, else `roles`, else allow), the state function
returns:

```json
"interaction": { "terminateLongPoll": false, "fallbackTimeoutSeconds": 120 }
```

- No `ack` — there is nothing to acknowledge; `POST …/longpoll/ack` and `authorize?ack=true` act only
  on an armed `terminate: true` token.
- **Client contract:** `fallbackTimeoutSeconds` (default 60; a parent override applies) **replaces the
  client's own long-poll window** — a client defaulting to 60 s polls for 120 s here. Keep polling;
  do not stop or render a terminal screen.
- Typical use: the human approval state everyone (web, mobile, backoffice) keeps polling.

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
  credential headers in `ScriptResponse.Headers`: `role`, `sub`, `act_sub` (plus `position`,
  `client_id` under morph-idm). Those are the only headers the runtime reads for roles and identity;
  `x-roles`, `user_reference`, `x-device-id` are **not** role sources (they only feed scripts and
  `$.context.Headers.*` grants). Fixture: `subflow-override-lab/src/OverrideLabSubFlowMapping.csx`.

## 7. Parent override (`subFlow.overrides.states.<s>.interaction.longPoll`)

Field-level: `fallbackTimeoutSeconds` and `roles` (whole list; `[]` admits everyone, validator
warns). `terminate` and `rule` are **not** overridable; an override cannot **add** a long poll to a
state without one (log 20305); a `roles` override on a rule-gated child is ignored (log 20306).
Details in `subflow-overrides.md`.

## 8. Author checklist

1. Which client must render before continuing? If none → no block, or `terminate: false` with
   `"roles": []` when clients should poll with a longer/shorter window than their default.
2. `terminate: true` states: keep them short-lived; set `fallbackTimeoutSeconds` for the slowest
   acceptable render.
3. Choose the arm: roles when the channel is a role; rule when it is a header. Never both.
4. In a SubFlow child, forward the credential headers (`role`, `sub`, `act_sub`) from the parent mapping.
5. Client contract: on `interaction.terminateLongPoll === true` → stop polling → render → POST
   `ack.href` → resume polling. On `terminateLongPoll === false` → keep polling, using
   `fallbackTimeoutSeconds` as the window.
6. `roles` accept `allOf` / `anyOf` combinators (0.0.99); a role-less caller is refused by an allow-list
   and by any role-bound deny (`roles-and-authorization.md`).

## Sources

- Runtime `vnext` @ `f06961ec` (0.0.100): `src/BBT.Workflow.Domain/Definitions/States/LongPollInteraction.cs`,
  `src/BBT.Workflow.Application/Instances/DTOs/InstanceInteractionOutput.cs`,
  `src/BBT.Workflow.Application/Execution/LongPoll/LongPollInteractionGate.cs`,
  `Pipeline/Steps/{HandleLongPollTerminationStep,ClearBusyOnResumeStep}.cs`,
  `InstanceQueryAppService.ResolveInteractionAsync`, `InstanceCommandAppService.AcknowledgeLongPollAsync`,
  `orchestration/.../InstanceController.cs` (`POST …/longpoll/ack`), `docs/domain/long-poll-termination.md`
- Schema `vnext-schema` 0.0.56: `#/definitions/{interaction,longPoll,subFlowLongPollOverride,roleGrant}`
- vnext-docs @ `adf9bf4`: `components/workflow.md` §State Interaction, `how-to/async-sync.md`, `how-to/human-task-approval.md`
- Fixture `vnext-example` @ `3b5ebab`: `core/Workflows/subflow-override-lab/subflow-override-lab-child.json` (`lp-wait`)
- vnext-docs `blog/2026-10-01-v0-0-98.md`
- PRs: #936/#990 (rule arm), #1028 (overrides), #1051/#1052 (`terminate: false` block restored, 0.0.98); vnext-meta `longPollTermination` 0.0.62, `longPollInteractionRule` 0.0.94, `queryRolesEnforcementMovedToGateway` 0.0.95
