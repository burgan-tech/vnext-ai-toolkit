# Roles & Authorization

> **Design rule: roles are opt-in and require explicit user confirmation.** When designing or
> scaffolding a flow, always ask the user first whether roles should be configured at all — they
> add real complexity, especially for vNext newcomers. Default to *no roles* unless the user
> explicitly confirms.

vNext evaluates **role grants** against the caller's resolved role set, the caller's identity
(`act_sub` / `sub`) and the instance's lineage. A grant is `{ "role": "...", "grant": "allow" | "deny" }`
or, since 0.0.99, a combinator `{ "allOf" | "anyOf": [ { "role": "..." }, … ], "grant": … }`. Grants
live on transitions (`roles`), `availableIn` entries, states and the workflow root (`queryRoles`),
custom functions (`roles`), `interaction.longPoll` (`roles`), state aliases, SubFlow overrides and
master-schema properties (`x-roles`). One evaluator (`RoleGrantEvaluator` / `RoleGrantMatcher`)
serves every surface, so the rules below hold everywhere. `grant` values are **lowercase**.
Runtime 0.0.100, schema 0.0.56.

## The decision model since 0.0.95

**`authorize` is the single decision point.** Since runtime 0.0.95 (PR #1027) the runtime itself does
not refuse reads on role grounds: the built-in read functions and the long-poll acknowledge endpoint
carry **no in-process `queryRoles` gate**. Roles still shape *what the caller sees* (visibility
filtering); *whether a request is admitted* is decided by the **Internal Gateway** ("middle tier") in
front of the runtime, which identifies the caller, calls
`GET …/instances/{id}/functions/authorize` and forwards or refuses on the answer.

- A **local runtime without a gateway does not 403** on `state`, `data`, `view`, `schema`, `master`,
  `tasks`, `actions`, `incidents`, `incidents/active`, `data/history` or `POST …/longpoll/ack`. A 200
  there proves nothing about `queryRoles` — ask `authorize` instead (checklist below).
- `PATCH …/transitions/{key}` **never enforced roles** and still does not (by design: `roles` decides
  what to *offer*). It **does** enforce the `availableIn` state gate (`Transition:100021`).
- A direct **custom function call** has had no role gate since 0.0.88 (PR #927): `FunctionAccessPolicy`
  checks scope (D/F/I) only. `function.roles` is evaluated by `authorize?functionKey=` and by the
  discovery surfaces (`/info`, `catalog`).

| Surface | What the runtime still does | Who decides admission |
|---|---|---|
| `state`, `data`, `view`, `schema`, `master` | filters `transitions[]`, state aliases, `x-roles` fields; `CallerScopeHash` in ETag/cache key; no 403 | Gateway → `authorize?queryRoles=true` |
| `tasks`, `actions`, `incidents`, `incidents/active`, `data/history` (0.0.100) | serves the payload (`data/history` with the same field pass as `data`); no 403 | Gateway → `authorize?queryRoles=true` |
| `POST …/longpoll/ack` | resumes the pause; no 403 | Gateway → `authorize?ack=true` |
| `PATCH …/transitions/{key}` | `availableIn` state gate (`Transition:100021`); never a role check | Gateway → `authorize?transitionKey=` |
| custom function call | scope check only (`FunctionScopeNotSatisfied`) | Gateway → `authorize?functionKey=` |
| `functions/file` (0.0.100) | **enforces in process**: `queryRoles` → `403`, then `x-roles` of the field path → `404` (`file-fields.md`) | runtime |
| `human-task` list | **fail-closed** filter on the leaf state's `queryRoles` (`human-task.md`) | runtime (visibility) |
| `permissions` (authorization matrix) | returns the full grant matrix, ungated | — |

## Credential headers

The runtime **validates no token**. Every identity and role value below is **self-asserted** by the
request; the **gateway is the trust boundary** — it must authenticate the caller and own (set or strip)
these headers on every inbound request. The framework (Aether `HeaderCurrentUserResolver`) maps them
onto `ICurrentUser`:

| Header | Runtime meaning | Audit column it fills | Sent to morph-idm | Outbound forwarding (0.0.99+) |
|---|---|---|---|---|
| `act_sub` | **actor** — who performs the action (`ActorUserName`) | `CreatedBy` / `ModifiedBy` (instance, transition) | yes | filled when the task mapping left it absent/empty |
| `sub` | **subject** — the user acted *for* (`UserName`) | `CreatedByBehalfOf` / `ModifiedByBehalfOf` | yes | same |
| `role` | caller role set (comma- or space-separated) | — | **never**; a non-blank `role` header means morph-idm is not called (0.0.97) | only as the caller **sent** it; roles morph-idm resolved are never forwarded |
| `position` | `ICurrentUser.Position` | — | yes | same as `sub` |
| `client_id` | read only by the morph-idm provider | — | yes | same as `sub` |

Same values for a direct customer action; for a backoffice operator acting for a customer they differ
(`act_sub` = operator, `sub` = customer).

> **Always send `act_sub` when starting an instance.** `$InstanceStarter` compares `act_sub` with
> `Instance.CreatedBy`. A start request that carries only `sub` leaves `CreatedBy` empty, and
> `$InstanceStarter` / `$user.$.context.Instance.CreatedBy` can then **never** match for that instance.
> Under morph-idm a caller with neither `act_sub` nor `client_id` also gets an empty role set.

- **Not credential headers.** `x-roles`, `user_reference`, `x-device-id`, `x-token-id` are **not read**
  by the runtime's authorization. They reach only scripts (`context.Headers`) and `$.context.Headers.*`
  grants. Never document them as "role headers".
- **Outbound credential forwarding (0.0.99, #1054).** HTTP, SOAP, Dapr service, Dapr HTTP endpoint,
  Start/DirectTrigger, SubProcess and `GetInstance` / `GetInstances` / `GetInstanceData` tasks send the
  caller's `sub`, `act_sub`, `position`, `client_id` and `role` for every one the mapping left absent
  or empty; a non-empty mapping value always wins. Set `role` (or the whole credential) in the mapping
  to call as a service identity. Nothing else of the caller travels.
- **Audit:** instance GET/list `metadata` carries `createdBy`, `createdByBehalfOf`, `modifiedBy`,
  `modifiedByBehalfOf` (`state-function-response.md` §4).

## Reserved `$` roles (complete catalog)

No other `$` role exists — there is no `$CurrentUser` token; the current actor is implicit. <!-- lint:allow -->
Use these anywhere a `role` is expected, including combinator children.

| Role | Compares | Against | Bound to |
|---|---|---|---|
| `$InstanceStarter` | `act_sub` | `Instance.CreatedBy` | identity |
| `$PreviousUser` | `act_sub` | `CreatedBy` of the last **manual** transition (auto/scheduled/event ignored) | identity |
| `$InstanceBehalfOfStarter` | `sub` | `Instance.CreatedByBehalfOf` | identity |
| `$PreviousBehalfOfUser` | `sub` | `CreatedByBehalfOf` of the last manual transition | identity |
| `$user.$.context.<path>` | `act_sub` | value(s) at the path (`[*]` allowed) | identity |
| `$userBehalfOf.$.context.<path>` | `sub` | value(s) at the path | identity |
| `$role.$.context.<path>` | caller's role set | value(s) at the path | **role** |

- **Context namespaces** (`$.context.…`): `Instance` (`Id`, `Key`, `Flow`, `Status`, `CurrentState`,
  `CreatedBy`, `CreatedByBehalfOf`, `ModifiedBy`, `ModifiedByBehalfOf`, `Data.…`), `Transition`
  (`Key`, `From`, `Target`, `TriggerType`), `Workflow`, `Headers`, `QueryParameters`, `RouteValues`.
- **Comparison:** identity values are **ordinal, case-sensitive**; role names (static and `$role.`)
  are case-insensitive.
- **Path spelling:** the literal `$.context.` is **case-sensitive** and must be followed by a
  non-empty path — `$.Context.x`, `$user.$CreatedBy`, `$role.$.context.` are **publish errors**
  (PR #859; since 0.0.99 also for schema `x-roles` and function `roles`).
- **`CreatedBy` is an instance property, not data:** `$user.$.context.Instance.CreatedBy` is right;
  `$user.$.context.Instance.Data.CreatedBy` resolves to nothing and never matches.
- **Predefined roles resolve against the grant's own instance.** In a parent-stamped SubFlow override,
  `$InstanceStarter` is the **child's** starter.
- `authorize` forwards headers, query string and route values, so `$.context.Headers.*` grants work
  there; a caller that omits them leaves the namespace empty and the grant cannot match.

```text
$user.$.context.Instance.Data.customer.ownerUserId
$userBehalfOf.$.context.Instance.CreatedByBehalfOf
$role.$.context.Instance.Data.permissions.requiredRole
```

## Grant evaluation rule

The whole caller role set is evaluated **once** against the whole grant set (never role by role):

```text
authorized   = DenyGroupOk AND AllowGroupOk
DenyGroupOk  = no deny grant fires                               (AND over denies)
AllowGroupOk = no allow grant exists (blacklist)
               OR at least one allow grant is Yes                (OR over allows)
empty grant set → allowed
```

1. **Deny group first, AND** — one firing deny refuses whatever else the caller carries (PR #860).
2. **Allow group, OR** — any allow that evaluates *Yes* admits.
3. **No allow grant = blacklist** — allowed unless denied. "Block everyone" needs an `allow`.
4. **Empty set = allowed** (except the human-task list, which is fail-closed).
5. **Rule 5 (0.0.96): a role-less caller cannot clear a role-bound deny.** Since 0.0.99 this is the
   three-valued rule below: a role-bound leaf is *Unknown* for a caller without roles, and a deny fires
   on *Yes or Unknown*. Identity leaves stay *Yes/No*. This is what makes a fail-open provider safe:
   an empty role set can only narrow.

### Three-valued evaluation (0.0.99, PR #1071)

| Leaf | Caller has roles | Caller has no roles |
|---|---|---|
| static role / `$role.…` | Yes if matched, else No | **Unknown** |
| the four predefined roles, `$user.…`, `$userBehalfOf.…` | Yes / No | Yes / No (No when there is no instance) |

| `allOf` children | Result | `anyOf` children | Result |
|---|---|---|---|
| any **No** | No | any **Yes** | Yes |
| else any **Unknown** | Unknown | else any **Unknown** | Unknown |
| all **Yes** | Yes | all **No** | No |

A **deny** fires on Yes **or** Unknown; an **allow** admits only on **Yes**.

| Grant set | Caller | Result |
|---|---|---|
| `[allow maker, allow approver, deny viewer]` | roles `[maker, viewer]` | **deny** — maker cannot rescue a hit deny |
| `[deny blocked]` | roles `[teller]` | allow (blacklist) |
| `[deny blocked]` | no roles | **deny** (Unknown fires) |
| `[deny $InstanceStarter]` | no roles, not the starter | allow (identity No) |
| `[allow $InstanceStarter, deny blocked]` | no roles, is the starter | **deny** (Unknown fires first) |
| `[allow $role.$.context.Instance.Data.role]` | no roles | **refused since 0.0.99** (was admitted when the path resolved to `""`) |

Static role names match **case-insensitively** (`Teller` = `teller`); grant *values* stay lowercase.

## Combinators — `allOf` / `anyOf` (0.0.99)

```json
{ "allOf": [ { "role": "$InstanceStarter" }, { "role": "branch-manager" } ], "grant": "allow" }
{ "anyOf": [ { "role": "$InstanceStarter" }, { "role": "$InstanceBehalfOfStarter" } ], "grant": "allow" }
```

- A grant carries **exactly one** of `role` / `allOf` / `anyOf`; `grant` stays on the outer object.
- Children are `{ "role": "..." }` only — no `grant`, no nesting (**depth 1**), at least one child, no
  extra members. A child may be static, predefined or dynamic.
- **Accepted on:** transition `roles`, `availableIn[].roles`, state/root `queryRoles`, function `roles`,
  `interaction.longPoll.roles`, SubFlow overrides, schema `x-roles`.
- **Rejected on:** `x-masking.roles` and `x-encryption.roles` — those are **allow-only exemption
  lists** of plain `{ "role", "grant": "allow" }` entries (`field-protection.md`).
- **"(A OR B) AND C"** needs two grants because depth is 1: `allow allOf[A, C]`, `allow allOf[B, C]`.

| Intent | Grant set |
|---|---|
| The starter who also holds `customer` | `allow allOf[$InstanceStarter, customer]` |
| Role **and** acting for the starter (human approval) | `allow allOf[approver, $InstanceBehalfOfStarter]`, `allow allOf[super-user, $InstanceBehalfOfStarter]` (`human-task.md`) |
| Starter or the person they act for | `allow anyOf[$InstanceStarter, $InstanceBehalfOfStarter]` |
| Four eyes: a maker acts, but not twice in a row | `allow maker`, `deny allOf[maker, $PreviousUser]` |
| Block a role only for its own starter | `deny allOf[blocked, $InstanceStarter]` |

The four-eyes deny does not fire for a caller without `maker` (`Unknown ∧ No = No` for a role-less
caller, `No ∧ …` for others); they are refused by the allow side only.

- **`permissions` matrix:** a combinator grant is listed with `allOf`/`anyOf` and **no `role`** —
  clients reading the matrix must tolerate a grant without `role`.
- **Rollout:** author the first combinator only after **every pod** (and every domain that stamps
  overrides onto this one) runs ≥ 0.0.99; an older runtime cannot load it. Do not binary-downgrade
  after publishing one (known issue `role-grant-combinators-rollback-floor`).
- **Publish now rejects** malformed `x-roles` entries and malformed function `roles` dynamic paths it
  used to skip silently (0.0.99).

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

`queryRoles` describes who may **read** an instance while it sits in a state. Resolution at the
deciding instance, highest precedence first, always on its own `CurrentState` (never `EffectiveState`):

1. the parent-stamped SubFlow override `overrides.states.<currentState>.queryRoles` — **replaces**,
   never merges (`subflow-overrides.md`);
2. the state's own `queryRoles`;
3. the workflow root `attributes.queryRoles`.

An **empty** set at the resolved level allows — except the **human-task list, which is fail-closed**
(a leaf with no `queryRoles` at state or root is dropped, log 20459; `human-task.md`).

**Leaf-only since 0.0.99 (PR #1071) — this LOOSENED access.** While an instance is inside an active
SubFlow, `authorize?queryRoles=true` is decided by the **deepest active leaf alone**; the levels above
are no longer AND-ed (the 0.0.95 every-hop AND is gone). A root that declares `queryRoles` while
the leaf declares none **no longer restricts anyone** during the SubFlow. To keep a restriction, put
`queryRoles` on the leaf state/workflow or stamp `subFlow.overrides.states.<state>.queryRoles` from the
parent (migration `query-roles-decided-at-subflow-leaf`). Fixture: `authorization-chain-lab/`.

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
| `queryRoles=true` | stamped override → state → root at the deciding instance | yes — **deepest leaf only** (0.0.99); an empty leaf allows |
| `ack=true` | the paused state's `interaction.longPoll` arm: `rule` (C# script) → else `roles` → else allow; nothing awaiting an ack ⇒ **allowed** (the endpoint is idempotent there) | the instance that `IsAwaitingLongPollAck` answers |

Optional: `role=<single role>` (composition depends on the provider — table below) and
`version=<flowVersion>` (defaults to the instance's own). Headers, query string and route values are
forwarded into `$.context.Headers` / `$.context.QueryParameters` / `$.context.RouteValues`.

Response: `200 {"allowed": true}` / `403 {"allowed": false}` — **read the body on both statuses**; a
4xx/5xx error envelope means the question could not be answered, not a denial. Every decision logs
`WorkflowLogs.AuthorizeRequest` (EventId **50030**: domain, workflow, instance, target, resolved
roles, verdict) and is spanned as `Auth.Decide` (source `BBT.Workflow.Authorization`).

```bash
B=http://localhost:4201/api/v1/core/workflows/role-matrix-lab/instances/$ID/functions/authorize
H='-H act_sub:u-ali -H sub:u-ali'
curl -s $H -H 'role: morph-idm.approver' "$B?transitionKey=approve"        # offered in current state + roles
curl -s $H -H 'role: chain.reader'       "$B?queryRoles=true"              # may this caller read the instance?
curl -s $H -H 'role: morph-idm.maker'    "$B?functionKey=customer-lookup"  # custom function roles (none ⇒ 200)
curl -s $H -H 'role: morph-idm.maker'    "$B?ack=true"                     # may POST …/longpoll/ack be called?
curl -s $H "$B?transitionKey=approve&role=morph-idm.approver"             # probe one role (provider table)
```

## Caller-role providers — `default` vs `morph-idm`

The role set every surface evaluates comes from `ICallerRoleResolver`, selected once at startup,
process-wide, by `CallerRoleProvider:Provider` (0.0.88, PR #927). **An unrecognised value silently
falls back to `default`** (header-trusting).

| Provider | Role source |
|---|---|
| `default` | `ICurrentUser.Roles` (parsed from the `role` header), else the forwarded `role` header dictionary in background scopes — fallback, not merge |
| `morph-idm` | the request's non-blank `role` header if present (0.0.97, morph-idm **not** called); otherwise the identity service's operation set |

**morph-idm flow** (one resolution per DI scope, memoized; no distributed cache):

1. Non-blank `role` header → that set, no call (`vnext.auth.outcome=header`).
2. Neither `act_sub` nor `client_id` → **no call**, empty set (`skipped`, log 20464).
3. Otherwise one `GET {BaseUrl}{GetRolesPath}` with headers `act_sub`, `sub`, `position`, `client_id`
   (`role` is never sent — with it the endpoint degrades to a yes/no check for one role).
4. The body is read as `{ "roles": [...] }`, `{ "data": { "roles": [...] } }` or
   `{ "getRoles": { "data": { "roles": [...] } } }`.
5. **It never fails** (0.0.96): `204`, blank body, `roles: []` (log 20441), non-success status,
   timeout, transport error (20442), unrecognisable body (20463) → **empty role set**, the request is
   evaluated on it (allow-lists refuse, role-bound denies fire). `Authorization:110004` is no longer
   produced. Retries are exponential (`RetryDelayMilliseconds × 2^n`); the circuit breaker is
   **process-wide** — after `CircuitBreakerFailureThreshold` transient failures *every* caller
   resolves to an empty set for `CircuitBreakerTimeoutSeconds`.

```text
CallerRoleProvider:Provider                         default | morph-idm
CallerRoleProvider:MorphIdm:BaseUrl                 ""
CallerRoleProvider:MorphIdm:GetRolesPath            /api/1/morph-idm/functions/get-roles   (code default)
CallerRoleProvider:MorphIdm:TimeoutSeconds          5
CallerRoleProvider:MorphIdm:MaxRetryAttempts        1
CallerRoleProvider:MorphIdm:RetryDelayMilliseconds  200
CallerRoleProvider:MorphIdm:CircuitBreakerFailureThreshold 20
CallerRoleProvider:MorphIdm:CircuitBreakerTimeoutSeconds   30
CallerRoleProvider:MorphIdm:ValidateSsl             true
```

> **`GetRolesPath` caveat.** The code default and the execution host's appsettings use
> `/api/1/morph-idm/functions/get-roles`; the orchestration host's appsettings ships
> `/api/v1/morph-idm/functions/get-roles`. **Always set `GetRolesPath` explicitly** on every host. If the
> mismatch bites you, file it with `/vnext-ai-toolkit:report-issue`.

**Role names** are free-form strings matched case-insensitively. A grant must spell the role exactly as
`get-roles` returns it (`morph-idm.officer` is only a naming convention; the vnext-example seed returns
`chain.admin`, `idmFirstApprover`).

How `?role=` on `authorize` composes with the provider (`ICallerRoleResolver.RoleParameterMode`):

| Provider | `transitionKey` / `functionKey` / `queryRoles` | `ack` |
|---|---|---|
| `default` | **fallback** — used only when the request resolved no roles; a `role` header wins | **additive** (0.0.96) |
| `morph-idm` (0.0.97+) | **`AsRoleHeader`** — no header ⇒ `?role=X` *is* the role set `[X]`, morph-idm not asked; a real header wins | same |

Under `morph-idm` the gateway is therefore the authority for the `role` header — it must strip or own
it on every inbound request, or a client asserts its own roles.

## `x-roles`, the data function and read surfaces

- `x-roles` is a **master-schema** (`attributes.type: "master"`) property keyword. It **prunes on read
  only** — writes are never gated by it. Order on every guarded read: `x-roles` prune → `x-masking` →
  `x-encryption` (`field-protection.md`). Properties without `x-roles` are visible to everyone; a caller
  whose role set resolves empty (no header, morph-idm failure) loses every field guarded by a role-bound
  allow or deny — only identity-bound grants can still admit it.
- **Applied on:** instance GET and list, the `data` function, `data/history`, sync start/transition
  responses, and `GetInstance` / `GetInstances` / `GetInstanceData` tasks — evaluated **as the task's
  caller credential** since 0.0.99 (`SystemRead` removed).
- **Not applied:** scripts (`context.Instance.Data`), transition history, custom functions, the
  human-task text, `context.Related` (still system identity), outbox events. Copying a guarded field
  into another field removes its protection.
- **Filters are not pruned:** list `filter` / `sort` / `groupBy` run on raw JSON, so a hidden field can
  be probed (known issue `list-filter-probes-guarded-fields`) — never declare `x-filterOperators` /
  `x-sortable` on an `x-roles` field.
- **Caching:** state, data, schema/master and human-task caches key on `CallerScopeHash` (roles, actor
  `act_sub`, subject `sub` since 0.0.99, headers, version), so callers never share a filtered body.
- **`queryRoles` is not enforced** by any of these reads (gateway). The two in-process exceptions are
  the `file` function (`403` on `queryRoles`, `404` when `x-roles` hides the path —
  `file-fields.md`) and the human-task list (fail-closed, leaf-decided).

## Where roles are used

| Place | Field | Effect |
|---|---|---|
| Transition | `roles` | filters `transitions[]` in the state body; `authorize?transitionKey=`; never enforced at execution |
| Transition `availableIn[]` entry | `roles` | per-state narrowing, AND-ed with transition `roles` |
| Workflow root / state | `queryRoles` | read visibility; `authorize?queryRoles=true` (leaf-only); human-task list (fail-closed); `file` function (403) |
| Custom function | `roles` | `authorize?functionKey=`; discovery (`/info`, `catalog`); not a call gate since 0.0.88 |
| State `interaction.longPoll` | `roles` / `rule` | who is signalled and may ack; `authorize?ack=true` (`long-poll-interaction.md`) |
| State `alias[]` | `roles` | which role sees which localized state label (`workflow-types.md`) |
| SubFlow `overrides` | `transitions.<t>.roles`, `states.<s>.queryRoles`, `…longPoll.roles` | replace the child's grants for one hop (`subflow-overrides.md`) |
| Master schema property | `x-roles` | field-level **read** pruning (`schema-vocabularies.md`, `field-protection.md`) |
| `x-masking.roles`, `x-encryption.roles` | allow-only exemption list | who sees the clear value; no combinators, no deny |
| View | — | views carry no roles; select per role through state/transition view rules (`view-roles.md`) |

## Authorization integration tests

Assert on **`authorize` verdicts** and on **`transitions[]`** in the state body. Do not rely on read
`200`s or `PATCH` status codes: locally there is no gateway, and transitions are never role-gated at
execution. Send `sub` **and** `act_sub` on every request.

| Scenario | Headers | Expectation |
|---|---|---|
| Role-header caller (`default`) | `role: maker`, `act_sub: u-ali`, `sub: u-ali` | grants on `maker` evaluate normally |
| morph-idm caller | `sub: idm-admin`, `act_sub: idm-admin`, **no `role`** | roles come from MockLab `get-roles` keyed on `sub`; without `act_sub` / `client_id` → empty set |
| Behalf-of | start with `act_sub: u-agent`, `sub: c-acme` (→ `CreatedBy=u-agent`, `CreatedByBehalfOf=c-acme`); approver sends `sub: c-acme` + role | `$InstanceBehalfOfStarter` matches |
| Role-less | `act_sub: u-x`, `sub: u-x`, no role | allow-lists refuse; role-bound denies refuse (deny-only `x-roles` fields disappear); identity grants match |
| Four-eyes | `[allow maker, deny allOf[maker, $PreviousUser]]` | AYŞE (`maker`, `act_sub: u-ayse`) submits → `authorize?transitionKey=approve` 403 for AYŞE, 200 for BOB (`maker`, `act_sub: u-bob`) |

- The data function needs no cache bypass between callers (its cache keys on roles, actor and `sub`).
  `X-VNext-Cache-Override: true` exists for the **human-task list** only (while
  `HumanTaskFunctionCache:AllowClientOverride`).
- Lab fixtures to read: vnext-example `AuthorizationChainLab/MorphIdmProviderTests`,
  `HumanTaskChain/IdmBehalfOfGrantTests`, `CombinatorGrantTests`.

### Local morph-idm recipe

1. **MockLab seed** for `GET api/1/morph-idm/functions/get-roles`, rules on `header.sub`: one user per
   role set (`{"roles":["chain.admin"]}`), plus `204` (empty set) and `500` (failure → empty set)
   users. Format: `mocklab-spec.md`.
2. **Runtime env** on both orchestration and execution containers (Testcontainers or compose override —
   never by editing vnext-runtime):

   ```text
   CallerRoleProvider__Provider=morph-idm
   CallerRoleProvider__MorphIdm__BaseUrl=http://mocklab:<port>
   CallerRoleProvider__MorphIdm__GetRolesPath=/api/1/morph-idm/functions/get-roles
   ```

3. **Tests** send `sub` + `act_sub`, **no `role` header** (a role header would bypass the provider), and
   skip unless the suite knows the runtime was started that way (e.g. `VNEXT_CALLER_ROLE_PROVIDER=morph-idm`).

## Designing roles — checklist for authors

1. **Confirm first.** Ask whether roles are wanted at all; default to none.
2. **`roles` on transitions, `queryRoles` on human/waiting states.** Root `queryRoles` is the fallback
   audience; narrow per state where the audience changes. Inside a SubFlow only the **leaf** decides —
   repeat the restriction on the child or stamp an override.
3. **Prefer allow-lists.** A deny-only set is a blacklist, and it also refuses role-less callers — a
   deny-only `x-roles` field disappears for anonymous tokens.
4. **Combinators only when needed, and only after every pod runs ≥ 0.0.99.** Depth 1; use two
   `allOf` allows for "(A or B) and C".
5. **Use `availableIn: {state, roles}`** rather than one shared transition per state; never list a
   state twice. Human states need `queryRoles` (state or root) or they vanish from the human-task list.
6. **Clients and gateways must send `act_sub` on start** or the starter roles never match.
7. **Test with `authorize`, not with 200s** (table above; `integration-test-patterns.md`).
8. **Remember the gateway.** Production admission is only as good as the gateway's `authorize`
   pre-flight on the `/workflows` routes; it must own every credential header.
9. **SubFlow overrides replace.** `overrides.states.<s>.queryRoles` / `overrides.transitions.<t>.roles`
   swap the child's grant set for one hop only (`subflow-overrides.md`).

## Sources

- Runtime `vnext` @ `f06961ec` (0.0.100): `src/BBT.Workflow.Application/Authorization/{AuthorizeAppService,TransitionAuthorizationManager,RoleGrantEvaluator,ICallerRoleResolver,DefaultCallerRoleResolver}.cs`, `src/BBT.Workflow.Domain/Definitions/Authorization/{PredefinedInstanceRoles,RoleGrantDefinitionRules}.cs`, `src/BBT.Workflow.Infrastructure/Authorization/{MorphIdmCallerRoleResolver,Configuration/CallerRoleProviderOptions,Extensions/CallerRoleResolverServiceExtensions}.cs`, `src/BBT.Workflow.Execution.Abstractions/HttpTaskInvocation.cs` (`BuildOutgoingHeaders`), `Instances/Caching/CallerScopeHash.cs`, orchestration/execution `appsettings.json` (`CallerRoleProvider`)
- Runtime docs: `docs/domain/role-grant-authorization.md` (surface table row "behind the in-process enforcement switch" is stale), `docs/domain/authorize-function.md`, `docs/domain/field-masking.md`, `docs/runtime/correlation-and-tracing.md`, `docs/runtime/file-storage.md`
- Aether: `BBT.Aether.Core/.../Users/AetherClaimTypes.cs`, `HeaderCurrentUserResolver`
- vnext-docs: `blog/2026-10-05-v0-0-99.md`, `blog-breaking-changes/2026-10-05-v0-0-99.md`, `blog/2026-10-15-v0-0-100.md`, `docs/concepts/authorization.md`
- PRs: #859, #860, #870, #927, #1016, #1027, #1032, #1034, #1054 (credential forwarding, `SystemRead` removed), #1071 (combinators, leaf-only `queryRoles`)
- vnext-meta: migration `query-roles-decided-at-subflow-leaf`; known issues `role-grant-combinators-rollback-floor`, `list-filter-probes-guarded-fields`
- Fixtures `vnext-example`: `core/Workflows/authorization-chain-lab/`, `core/Workflows/role-matrix-lab/`, `core/Workflows/human-task-chain/ht-idm-approval.json`, `etc/docker/config/seed/morph-idm-roles-collection.json`, `tests/Core.IntegrationTests/Tests/{AuthorizationChainLab,HumanTaskChain}/`
- Related: `human-task.md`, `long-poll-interaction.md`, `subflow-overrides.md`, `state-function-response.md`, `schema-vocabularies.md`, `field-protection.md`, `file-fields.md`, `view-roles.md`, `workflow-types.md`, `integration-test-patterns.md`, `security-review-checklist.md`
