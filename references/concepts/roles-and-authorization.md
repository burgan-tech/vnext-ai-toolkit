# Roles & Authorization

> **Design rule: roles are opt-in and require explicit user confirmation.** When designing or
> scaffolding a flow, always ask the user first whether roles should be configured at all — they
> add real complexity, especially for vNext newcomers. Default to *no roles* unless the user
> explicitly confirms.

vNext evaluates **role grants** (`{ "role": "...", "grant": "allow" | "deny" }`) against the caller's
resolved role set and the instance's lineage. Grants live on transitions (`roles`), `availableIn`
entries, states and the workflow root (`queryRoles`), custom functions (`roles`),
`interaction.longPoll` (`roles`), state aliases, and master-schema properties (`x-roles`). One
evaluator (`RoleGrantEvaluator` / `TransitionAuthorizationManager`) serves every surface, so the
rules below hold everywhere. `grant` values are **lowercase** (`allow` / `deny`).

## The decision model since 0.0.95

**`authorize` is the single decision point.** Since runtime 0.0.95 (PR #1027) the runtime itself does
not refuse reads on role grounds: the built-in read functions and the long-poll acknowledge endpoint
carry **no in-process `queryRoles` gate**. Roles still shape *what the caller sees* (visibility
filtering); *whether a request is admitted* is decided by the **Internal Gateway** ("middle tier") in
front of the runtime, which identifies the caller, calls
`GET …/instances/{id}/functions/authorize` and forwards or refuses on the answer.

- A **local runtime without a gateway does not 403** on `state`, `data`, `view`, `schema`, `master`,
  `tasks`, `actions`, `incidents`, `incidents/active` or `POST …/longpoll/ack`. A 200 there proves
  nothing about `queryRoles` — ask `authorize` instead (checklist below).
- `PATCH …/transitions/{key}` **never enforced roles** and still does not (by design: `roles` decides
  what to *offer*). It **does** enforce the `availableIn` state gate (`Transition:100021`).
- A direct **custom function call** has had no role gate since 0.0.88 (PR #927): `FunctionAccessPolicy`
  checks scope (D/F/I) only. `function.roles` is evaluated by `authorize?functionKey=` and by the
  discovery surfaces (`/info`, `catalog`).

| Surface | What the runtime still does | Who decides admission |
|---|---|---|
| `state`, `data`, `view`, `schema`, `master` | filters `transitions[]`, state aliases, `x-roles` fields; `CallerScopeHash` in ETag/cache key; no 403 | Gateway → `authorize?queryRoles=true` |
| `tasks`, `actions`, `incidents`, `incidents/active` | serves the payload; no 403 | Gateway → `authorize?queryRoles=true` |
| `POST …/longpoll/ack` | resumes the pause; no 403 | Gateway → `authorize?ack=true` |
| `PATCH …/transitions/{key}` | `availableIn` state gate (`Transition:100021`); never a role check | Gateway → `authorize?transitionKey=` |
| custom function call | scope check only (`FunctionScopeNotSatisfied`) | Gateway → `authorize?functionKey=` |
| `human-task` list | **fail-closed** filter on the leaf state's `queryRoles` (`human-task.md`) | runtime (visibility) |
| `permissions` (authorization matrix) | returns the full grant matrix, ungated | — |

## Token claims

| Claim | Meaning |
|-------|---------|
| `sub` | The **subject** — the customer the action is performed *on behalf of*. |
| `act_sub` | The **actor** — the user actually performing the action. |

Same for a direct customer action; for a backoffice operator acting on a customer's behalf they
differ (`act_sub` = operator, `sub` = customer). Static roles arrive in the `role` header
(`ICurrentUser.Roles`) or from the caller-role provider (§ Caller-role provider).

## Static system roles

Four built-in role tokens describe the instance's lineage. Use them anywhere a `role` is expected:

| Role | Compares against | Meaning |
|------|------------------|---------|
| `$InstanceStarter` | actor (`act_sub`) | The actor who **started** the instance |
| `$PreviousUser` | actor (`act_sub`) | The actor who triggered the **previous** transition |
| `$InstanceBehalfOfStarter` | subject (`sub`) | The subject the instance was **started** for |
| `$PreviousBehalfOfUser` | subject (`sub`) | The subject of the **previous** transition |

```json
{ "roles": [ { "role": "$InstanceStarter", "grant": "allow" }, { "role": "$PreviousUser", "grant": "allow" } ] }
```

> There is no `$CurrentUser` token; the current actor is implicit in the request. <!-- lint:allow -->
> Lineage is expressed with the four roles above. These four are **identity-bound** (matched on who the caller
> is, not on which roles it carries) — that distinction matters for Rule 5 below.

## JSONPath role grants (instance-data authorization)

`role` values may also be **dynamic**: a qualifier prefix plus a JSONPath into the `ScriptContext`
(`Instance.Data`, `Transition.Key`, `Headers`, `QueryParameters`, `RouteValues`, …):

| Prefix | Token compared | Bound to |
|--------|----------------|----------|
| `$user.<jsonpath>` | **actor** (`act_sub`) | identity |
| `$userBehalfOf.<jsonpath>` | **subject** (`sub`) | identity |
| `$role.<jsonpath>` | one of the caller's **roles** | role |

```text
$user.$.context.Instance.Data.customer.ownerUserId
$userBehalfOf.$.context.Instance.Data.customer.behalfOfUserId
$role.$.context.Instance.Data.permissions.requiredRole
```

The path **must start with the literal `$.context.`, case-sensitive** (`$.Context.` is rejected) and
must not be empty after it — both are **publish-time validation errors**
(`WorkflowValidator.ValidateRoleGrants`, PR #859), so a malformed dynamic grant never reaches the
runtime. `authorize` forwards headers, query string and route values, so `$.context.Headers.*`
grants work there; a caller that omits them leaves the namespace empty and the grant cannot match.

## Grant evaluation rule

The whole caller role set is evaluated **once** against the whole grant set (never role by role):

```text
authorized   = DenyGroupOk AND AllowGroupOk
DenyGroupOk  = no deny grant matches ANY caller role            (AND over denies)
AllowGroupOk = no allow grant exists (blacklist)
               OR at least one allow grant matches some role    (OR over allows)
empty grant set → allowed
```

1. **Deny group first, AND** — one matching deny refuses whatever else the caller carries (unified
   evaluator, PR #860, 0.0.79: deny wins across the *whole* set, also inside `x-roles`).
2. **Allow group, OR** — any allow matching any role admits.
3. **No allow grant = blacklist** — allowed unless explicitly denied. "Block everyone" needs an `allow`.
4. **Empty set = allowed.**
5. **Rule 5 (0.0.96, PR #1032): a role-less caller cannot clear a role-bound deny.** A static role or
   a `$role.` reference is a statement about the caller's *roles*; with none to compare, the deny
   refuses. Identity-bound denies (`$InstanceStarter` & co., `$user.`, `$userBehalfOf.`) are
   evaluated normally. This is what makes a fail-open provider safe: an empty set can only narrow.

Static role names match **case-insensitively** (`Teller` = `teller`); grant *values* stay lowercase.

| Grant set | Caller roles | Result |
|---|---|---|
| `[allow: maker, allow: approver, deny: viewer]` | `[maker, viewer]` | **deny** — viewer hit a deny; maker cannot rescue it |
| `[deny: blocked]` | `[teller]` | allow (blacklist, no match) |
| `[deny: blocked]` | none | **deny** (Rule 5 — role-bound deny, no roles to disprove it) |
| `[deny: $InstanceStarter]` | none, caller is not the starter | allow (identity-bound, normal evaluation) |
| `[allow: $InstanceStarter, deny: blocked]` | none, caller *is* the starter | **deny** (Rule 5 fires before the allow) |

## `availableIn` with roles (PR #870, meta 0.0.80)

Shared and well-known transitions (`cancel`, `updateData`, `exit`) scope themselves with
`availableIn`. Entries may be a bare `"state"` or `{ "state", "roles" }`, **mixed in one array**:

```json
{
  "key": "record-note",
  "roles": [ { "role": "morph-idm.maker", "grant": "allow" }, { "role": "morph-idm.approver", "grant": "allow" } ],
  "availableIn": [
    "intake",
    { "state": "review", "roles": [ { "role": "morph-idm.approver", "grant": "allow" } ] }
  ]
}
```

Composition is **AND**: `transition.roles` is the global gate, the matching entry's `roles` narrows
it for that state (above: makers may `record-note` in `intake`, only approvers in `review`). A
role-less entry equals the legacy string form; an empty `availableIn` means *every state*. **Listing
a state twice is a publish error** (only the first entry would apply). State transitions carry no
`availableIn` — they are scoped to the declaring state. Fixture: `role-matrix-lab/role-matrix-lab.json`.

## `queryRoles` semantics

`queryRoles` describes who may **read** an instance while it sits in a state. Resolution per level,
highest precedence first, always on the instance's own `CurrentState` (never `EffectiveState`):

1. the parent-stamped SubFlow override `overrides.states.<currentState>.queryRoles` — **replaces**,
   never merges (`subflow-overrides.md`);
2. the state's own `queryRoles`;
3. the workflow root `attributes.queryRoles`.

An **empty** set at the resolved level allows — except the **human-task list, which is fail-closed**:
a human state (`subType: 6`) whose leaf resolves to no `queryRoles` is dropped (log 20459, PR #1016;
`human-task.md`). Across an active SubFlow chain the read answer is a **conjunction**: every hop from
the polled instance to the deepest active leaf must allow (0.0.95 `authorizeChainConjunction`).
Fixture: `authorization-chain-lab/` (root → mid → leaf, each with its own `queryRoles` plus a parent
override on the child's waiting state).

## `authorize` contract

```text
GET /api/v1/{domain}/workflows/{workflow}/instances/{instanceId}/functions/authorize
```

Instance-scoped only — the runtime serves no flow-level `…/workflows/{wf}/functions/authorize` (the
vnext-docs "Flow Authorize" section is stale). **Exactly one** of the four selectors must be present;
zero or two is a request error (`AuthorizeRequiresExactlyOneTarget`), not a default.

| Selector | Evaluates | Descends into the active SubFlow? |
|---|---|---|
| `transitionKey=` | offered in `CurrentState` (state transition: declared there; shared/well-known: `availableIn`) **AND** `transition.roles` **AND** `availableIn[state].roles` | only if the parent does **not** retain it — `cancel`, `exit`, `updateData` and a shared transition offered in the parent's current state are answered at the parent |
| `functionKey=` | the custom function's `roles`; **no `roles` ⇒ allowed** | yes |
| `queryRoles=true` | stamped override → state → root, per level | yes — **conjunction** of every hop |
| `ack=true` | the paused state's `interaction.longPoll` arm: `rule` (C# script) → else `roles` → else allow; nothing awaiting an ack ⇒ **allowed** (the endpoint is idempotent there) | the instance that `IsAwaitingLongPollAck` answers |

Optional: `role=<single role>` (composition depends on the provider — table below) and
`version=<flowVersion>` (defaults to the instance's own). Headers, query string and route values are
forwarded into `$.context.Headers` / `$.context.QueryParameters` / `$.context.RouteValues`.

Response: `200 {"allowed": true}` / `403 {"allowed": false}` — **read the body on both statuses**; a
4xx/5xx error envelope means the question could not be answered, not a denial. Every decision logs
`WorkflowLogs.AuthorizeRequest` (EventId **50030**: domain, workflow, instance, target
`transition:{key}` / `function:{key}` / `queryRoles` / `ack`, resolved roles, verdict) and is spanned
as `Auth.Decide` (source `BBT.Workflow.Authorization`); a SubFlow forward is spanned as `Subflow.Descend`.

```bash
B=http://localhost:4201/api/v1/core/workflows/role-matrix-lab/instances/$ID/functions/authorize
curl -s -H 'role: morph-idm.approver' "$B?transitionKey=approve"        # offered in current state + roles
curl -s -H 'role: chain.reader'       "$B?queryRoles=true"              # may this caller read the instance?
curl -s -H 'role: morph-idm.maker'    "$B?functionKey=customer-lookup"  # custom function roles (none ⇒ 200)
curl -s -H 'role: morph-idm.maker'    "$B?ack=true"                     # may POST …/longpoll/ack be called?
curl -s "$B?transitionKey=approve&role=morph-idm.approver"             # probe one role (provider table)
```

## Caller-role provider

The role set every surface evaluates comes from `ICallerRoleResolver`, selected once at startup by
`CallerRoleProvider:Provider` (0.0.88, PR #927). An unrecognised value silently falls back to `default`.

| Provider | Role source | On failure |
|---|---|---|
| `default` | `ICurrentUser.Roles` (parsed from the `role` header), else the forwarded `role` header dictionary — fallback, not merge | never fails (in-process) |
| `morph-idm` | non-blank `role` header **replaces** the service answer and morph-idm is not called (0.0.97); otherwise one `GET get-roles` per request scope with `act_sub`/`sub`/`position` | 0.0.96: error status, timeout, transport error, unparseable body, `204`, empty array → **empty role set** (no more `403 Authorization:110004`); a caller with neither `act_sub` nor `client_id` is never asked |

How `?role=` composes with the provider's answer (`ICallerRoleResolver.RoleParameterMode`):

| Version | `default` — `transitionKey`/`functionKey`/`queryRoles` | `default` — `ack` | `morph-idm` (all selectors) |
|---|---|---|---|
| 0.0.95 | fallback: used only when the provider resolved nothing; a `role` header wins | fallback on some paths | parameter **ignored** |
| 0.0.96 (#1032) | fallback | **additive** on every path (merged with provider roles) | ignored; failures → empty set |
| 0.0.97 (#1034) | fallback | additive | `AsRoleHeader`: no header ⇒ `?role=X` *is* the header (set `[X]`, morph-idm not asked); a real header wins |

Under `morph-idm` the gateway is therefore the authority for the `role` header — it must strip or own
it on every inbound request, or a client can assert its own roles. Config:
`CallerRoleProvider:MorphIdm:{BaseUrl, GetRolesPath, TimeoutSeconds 5, MaxRetryAttempts 1,
CircuitBreakerFailureThreshold 20, CircuitBreakerTimeoutSeconds 30, ValidateSsl}`.

## Where roles are used

| Place | Field | Effect |
|---|---|---|
| Transition | `roles` | filters `transitions[]` in the state body; `authorize?transitionKey=`; never enforced at execution |
| Transition `availableIn[]` entry | `roles` | per-state narrowing, AND-ed with transition `roles` |
| Workflow root / state | `queryRoles` | read visibility; `authorize?queryRoles=true`; human-task list (fail-closed) |
| Custom function | `roles` | `authorize?functionKey=`; discovery (`/info`, `catalog`); not a call gate since 0.0.88 |
| State `interaction.longPoll` | `roles` / `rule` | who is signalled and may ack; `authorize?ack=true` (`long-poll-interaction.md`) |
| State `alias[]` | `roles` | which role sees which localized state label (`workflow-types.md`) |
| Master schema property | `x-roles` | field-level read/write pruning in `data`/`state` bodies (`schema-vocabularies.md`) |
| View | — | views carry no roles; select per role through state/transition view rules (`view-roles.md`) |

## Designing roles — checklist for authors

1. **Confirm first.** Ask whether roles are wanted at all; default to none.
2. **`roles` on transitions, `queryRoles` on human/waiting states.** Root `queryRoles` is the fallback
   audience; narrow per state where the audience changes (backoffice review, approval).
3. **Prefer allow-lists.** A deny-only set is a blacklist, and since 0.0.96 it also refuses role-less
   callers — a deny-only `x-roles` field disappears for anonymous tokens.
4. **Use `availableIn: {state, roles}`** rather than one shared transition per state; never list a
   state twice. Human states need `queryRoles` (state or root) or they vanish from the human-task list.
5. **Test with `authorize`, not with 200s.** Locally the reads never 403; assert
   `authorize?transitionKey=` / `?queryRoles=true` verdicts per role in integration tests
   (`integration-test-patterns.md`) and compare with `transitions[]` in the state body
   (`state-function-response.md`).
6. **Remember the gateway.** Production admission is only as good as the gateway's `authorize`
   pre-flight on the `/workflows` routes; under `morph-idm` the gateway must own the `role` header.
7. **SubFlow overrides replace.** `overrides.states.<s>.queryRoles` / `overrides.transitions.<t>.roles`
   swap the child's grant set for one hop only (`subflow-overrides.md`).

## Sources

- Runtime `vnext` @ `eca5b466` (0.0.97): `src/BBT.Workflow.Application/Authorization/{AuthorizeAppService,TransitionAuthorizationManager,ICallerRoleResolver,DefaultCallerRoleResolver,RoleParameterMode}.cs`, `src/BBT.Workflow.Infrastructure/Authorization/MorphIdmCallerRoleResolver.cs`, `src/BBT.Workflow.Application/Functions/FunctionAccessPolicy.cs`, `src/BBT.Workflow.Domain/Definitions/Validators/WorkflowValidator.cs` (`ValidateAvailableIn`, `ValidateRoleGrants`), `WorkflowLogs.cs` (50030), `AuthorizationActivityHelper` (`Auth.Decide`)
- Runtime docs: `docs/domain/authorize-function.md`; `docs/domain/role-grant-authorization.md` (partly stale — still describes the removed in-process gate)
- vnext-docs @ `adf9bf4`: `docs/concepts/authorization.md`, `docs/configuration/caller-role-provider.md`, `docs/components/functions/built-in.md` § Instance Authorize, `blog-breaking-changes/2026-09-24-v0-0-95.md`, `blog/2026-09-25-v0-0-96-97.md`
- PRs: #859 (dynamic-grant validation, all transition types, 0.0.79), #860 (unified evaluator, deny wins across grant set, 0.0.79), #870 (`availableIn` roles), #927 (caller-role provider, function call gate removed, 0.0.88), #1016 (human-task authorized by leaf `queryRoles`, 0.0.94), #1027 (single decision point, chain conjunction, `ack`, 0.0.95), #1032 (fail-open + Rule 5, 0.0.96), #1034 (`role` header precedence, `RoleParameterMode`, 0.0.97)
- vnext-meta 0.0.53: features `roleGrantAuthorization` 0.0.79, `availableInRoleScoping` 0.0.80, `authorizeChainConjunction` 0.0.95, `queryRolesEnforcementMovedToGateway` 0.0.95, `callerRoleResolutionEmptyOnFailure` 0.0.96, `morphIdmRequestRoleHeaderPrecedence` 0.0.97; security-policy `roleless-caller-cannot-clear-role-bound-deny` (enforced 0.0.96); migrations `x-roles-deny-now-wins-across-grant-set`, `x-roles-deny-only-visible-to-roleless-caller` (0.0.79; reversed for role-bound denies in 0.0.96)
- Fixtures `vnext-example` @ `3b5ebab`: `core/Workflows/authorization-chain-lab/`, `core/Workflows/role-matrix-lab/role-matrix-lab.json`
- Related: `human-task.md`, `long-poll-interaction.md`, `subflow-overrides.md`, `state-function-response.md`, `schema-vocabularies.md`, `view-roles.md`, `workflow-types.md`, `integration-test-patterns.md`, `security-review-checklist.md`
