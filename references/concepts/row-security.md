# Row Security — `attributes.rowSecurity` (role-keyed row filters)

> Runtime **0.0.102+** (#1134, feature `rowSecurity`, status **experimental**), schema package
> **0.0.58+** (`workflow-definition.schema.json` `#/definitions/rowSecurity`). Column-level protection is
> `x-roles` / `x-masking` / `x-encryption` (`field-protection.md`); row security adds the **row**
> dimension: per role, a filter the runtime ANDs into the instance reads it covers. Driving case: a branch
> employee lists only the applications of their own branch.

The runtime provides the mechanism; which request values are trustworthy and how tight a rule is stays
with the domain team (§6 gateway precondition, §7 what it does **not** protect).

## 1. Contract

```json
"attributes": {
  "rowSecurity": {
    "rules": [
      { "roles": ["branch-staff", "branch-ops"],
        "filter": { "attributes": { "branchCode": { "eq": "$.context.Headers.x-branch-code" } } } },
      { "roles": ["region-manager"],
        "filter": { "attributes": { "branchCode": { "in": { "$param": "$.context.Headers.x-branches", "split": "," } } } } },
      { "roles": ["hq-auditor"] },
      { "roles": ["$InstanceStarter"], "filter": { "status": { "eq": "A" } } }
    ]
  }
}
```

- **Deny by default once declared.** There is **no `default` member**: a caller no rule opens sees
  nothing. "Role X sees all rows" is an explicit rule **without** `filter` (`hq-auditor` above). A flow
  without `rowSecurity` is not filtered at all.
- `rowSecurity` has only `rules` (`minItems: 1`); a rule has only `roles` and optional `filter`. Any other
  member → RS-E12 (schema: `additionalProperties: false`).
- `roles`: **static roles** (case-insensitive) **or** the identity roles `$InstanceStarter`
  (`createdBy = caller actor`) / `$InstanceBehalfOfStarter` (`createdByBehalfOf = caller user name`) —
  never both in one rule (RS-E04, split the rule). `$PreviousUser`, dynamic grants (`$user.`, `$role.` …)
  and other reserved roles — `$Everyone` included (0.0.105) — are publish errors (RS-E01/E02/E05); "every
  caller sees these rows" is a static-role rule without `filter`, there is no wildcard. `allOf` / `anyOf` objects fail schema
  validation (and JSON binding, `400 App:900006`).
- `filter`: the **list-engine filter JSON** (`instance-query.md` §2): `eq ne gt ge lt le between like
  match startswith endswith in nin isNull includes`, `and` / `or` / `not`, on `attributes.*` paths and
  instance columns (`createdBy`, `createdByBehalfOf`, `modifiedBy`, `key`, `status`, `createdAt` …).
  No `sort` / `orderBy` / `groupBy` / `aggregations` in a rule (RS-E13). On a reserved-role rule the
  filter is ANDed with the identity predicate.

### Parameters

A string leaf starting with `$.context.` (case-sensitive) is a parameter:

| Path | Source | Trust |
|---|---|---|
| `$.context.Headers.<name>` | request header (case-insensitive) | only as strong as the gateway (§6) |
| `$.context.QueryParameters.<name>` | query string | **client-controlled — never a boundary** (RS-W6q; RS-E18 on an `x-roles` path) |
| `$.context.CurrentUser.{ActorUserName\|ActorUserId\|UserName\|Position}` | authenticated caller | `sub`, `act_sub`, `client_id` are reachable as `Headers` |

- Shorthands, valid only on their own column (RS-E06 elsewhere): `$InstanceStarter` on `createdBy`,
  `$InstanceBehalfOfStarter` on `createdByBehalfOf`.
- Arrays (`in`, `nin`, `between`): element-wise `["$.context.QueryParameters.from", "…to"]`, or
  `{ "$param": "<path>", "split": "," }`. `between` needs exactly two operands (RS-E10); `split` on a
  non-array operator is RS-E11.
- **No parameters** on `like` / `match` / `startswith` / `endswith` or inside `includes` (RS-E17).
- `$.context.Route.*`, `$.context.Query.*`, an unknown `CurrentUser` field → RS-E07.
- Values are coerced to the master-schema field type; an uncoercible value drops its rule. On an
  instance column an `in`/`nin`/`between` value containing a comma drops its rule.
- Limits (`Workflow:RowSecurity`): `MaxElements` 100, `MaxElementLength` 1000 — exceeding either drops
  the rule.

## 2. Evaluation — never widens

1. Role resolution **failed** (provider error, e.g. morph-idm unreachable) → **no rows**. "No roles" is a
   role-less caller, not a failure.
2. **Base** = OR of the filters of every static rule whose `roles` the caller holds (a rule without
   filter = all rows). No static match → none.
3. **Identity add-on**: each `$InstanceStarter` / `$InstanceBehalfOfStarter` rule whose identity value
   resolves, ORed onto the base.
4. Effective query = caller's own filter AND (base OR add-ons). Nothing opened → empty page, no SQL.

A matched rule whose parameter is missing, empty, multi-valued for a scalar operator, over a limit, or
fails under `nin` / `ne` / `not` **contributes nothing** (warning log 20507, which can fire on every
request of a client that never sends the header). A rule touching an `x-encryption` / `x-masking` path is
rejected at publish (RS-E08/E14/E15) and dropped at read time if the check was skipped (RS-W0).

## 3. Which surfaces are filtered

| Surface | Filtered | Notes |
|---|---|---|
| `GET …/instances` list (incl. `groupBy`, aggregates) | **yes** | counts/totals cover visible rows only |
| `GET …/instances/{id}` | **yes** | excluded = same **404** as missing, checked before the ETag (no 304) |
| `GetInstances` (15) / `GetInstance` (19) tasks | **yes**, same- and cross-domain | filtered with the header set the task presents — see below |
| `functions/state|data|view|schema|master`, history, `internal/*` | **no** | known issue `row-security-instance-surfaces-unfiltered` |
| `GetInstanceData` (13) task, transitions, direct trigger by key, view resolution, `context.Related`, human-task list, event correlation | **no** | |

**Trigger tasks.** The header set a 15/19 task presents carries only `sub`, `act_sub`, `position`,
`client_id`, `role`. A rule's parameter header (`x-branch-code`) is **not forwarded automatically** — set
it in the task's input mapping, or the parametrised rule contributes nothing. A mapping can also set
`role` / `sub`: a cross-domain read is only as strong as the mapping's author.

**Which version's rules.** The flow's **default version** (`sys-version-registry`,
`runtime-operations.md` § Flow default version) when set, else the latest published version — for
instances of every version. A `set-default` therefore also switches the rules in force.

**Lookup failure (migration `instance-read-fails-on-flow-lookup-error`, 0.0.102, every flow).** The list,
GET and both tasks now load the flow: a broken default-version pointer (`Instance:100052` 409), an
unreadable registry (`100053` 503), only-pending versions (`100051`) or a cache outage **fail the read**
(warning 20509) — also for flows without `rowSecurity`. A flow with no published definition stays
unfiltered.

## 4. Publish codes

Errors block publish; warnings are **log-only** (`ComponentValidationWarning`), the flow goes live.

| Code | Meaning | Fix |
|---|---|---|
| RS-E01 / E02 / E05 | `$PreviousUser…`, dynamic grant, other reserved role (`$Everyone` too, 0.0.105) as a rule role | use static roles or `$InstanceStarter` / `$InstanceBehalfOfStarter` |
| RS-E04 | static + reserved role in one rule | split into two rules |
| RS-E06 | starter shorthand on the wrong column | `$InstanceStarter` only on `createdBy`, `$InstanceBehalfOfStarter` only on `createdByBehalfOf` |
| RS-E07 | malformed `$.context.` path / unknown source or `CurrentUser` field | `Headers`, `QueryParameters`, `CurrentUser.{ActorUserName,ActorUserId,UserName,Position}` |
| RS-E08 / E14 / E15 | filter on an `x-encryption` (encrypt / hash) or `x-masking` path | filter on a non-protected field |
| RS-E09 | invalid operator or filter JSON | list-engine operators only |
| RS-E10 / E11 | `between` arity / `split` on a non-array operator | |
| RS-E12 | `rules` missing/empty or an unknown member | no `default` member exists |
| RS-E13 | `sort` / `groupBy` / `aggregations` in a rule | remove |
| RS-E16 | `rowSecurity` on a `sys-*` flow | |
| RS-E17 | parameter on a pattern operator or inside `includes` | use `eq` / `in` |
| RS-E18 | `QueryParameters` value on an `x-roles` path | use a header or `CurrentUser` |
| RS-W1 | filtered field not in the master schema | declare it |
| RS-W2a / W2b | range/`in`/pattern on a field without `x-indexed`; identity rule on unindexed `createdBy*` | add `x-indexed` (`instance-query.md` §9) |
| RS-W2c | rule made only of `ne` / `nin` | add a positive predicate |
| RS-W4 | `$.Context.` in another case — treated as a literal | fix the case |
| RS-W5 | `not` / `nin` on a non-`required` field also matches rows missing it | mark it `required` or add `isNull` |
| RS-W6q / W6r | `QueryParameters` used / `Headers` on an `x-roles` path | not a boundary |
| RS-W7 | flow has a SubFlow state — children do **not** inherit the rules | declare `rowSecurity` on the child flow too |

## 5. Design checklist (ask these in workflow-scaffold / architect)

- Who may **list** which instances? Name the roles and the row predicate per role, plus the unfiltered
  role(s) (admins, auditors) — forgetting them hides everything from them.
- Which request value carries the scope (branch code, region list)? It must be a **header the gateway
  writes** or `CurrentUser`, never a query parameter.
- Filtered fields: declared in the master schema, `x-indexed`, not `x-masking` / `x-encryption`.
- Does the flow start SubFlows whose instances are listed too? Give the child flow its own rules.
- Do other flows read this one through `GetInstances` / `GetInstance`? Put the rule header in their
  input mappings.
- Integration tests: one test per role row (own branch / other branch / auditor / no role / header
  missing) on the list **and** the single GET (`integration-test-patterns.md`).

## 6. Gateway precondition

The gateway must **strip or overwrite, never append,** the `role` header and every header a rule reads,
on every public route to the list and the GET, writing values introspected from the token. Under the
default caller-role provider `role` **is** the role set. With `CallerRoleProvider:Provider = morph-idm`
an unreachable provider means no rows for every opted-in flow. Rule headers appear in Aether request logs
unless listed in `Telemetry:Logging:Body:AdditionalSensitiveHeaderNames`.

## 7. What it does not protect

- **Not an access boundary for a known instance id.** `functions/data` answers 200 where the GET answers
  404 (existence oracle); a transition on an excluded instance succeeds. Enforce those routes with
  `authorize` at the gateway (`roles-and-authorization.md`); `authorize?queryRoles=true` has no row term.
- **Rollback below 0.0.102 serves every row** — an older runtime never reads `rowSecurity`. Do not roll
  back while a flow relies on it, or block the list/GET at the gateway meanwhile.
- **Do not force re-publish the same version** during a rolling upgrade (immutable full-version cache
  bodies, `ComponentCache:FullVersionTtlSeconds` 1800 s) — publish a new version.
- Status is **experimental**: re-check `scripts/vnext-meta-live.sh known-issues` before relying on it.

## 8. Observability

Span tags on the read span (none for flows without `rowSecurity`): `vnext.rowsecurity.applied`,
`vnext.rowsecurity.outcome` (`unrestricted` · `filtered` · `excluded` · `denied-no-match` ·
`denied-no-contribution` · `denied-resolution-failed` · `denied-flow-load`), `vnext.rowsecurity.rules`,
`vnext.rowsecurity.missing_params`, `vnext.rowsecurity.flow_version`. Logs 20505 decision, 20506 GET
excluded, 20507 rule contributed nothing, 20508 role resolution failed, 20509 rule set not loadable. A
"user sees an empty list" ticket starts with the outcome tag (`observability.md`).

## Sources

- Runtime `vnext` @ `74587011` (v0.0.103): `docs/domain/row-security.md`, `docs/integration/vnext-docs/row-security.md`, `.claude/rules/vnext-workflow-developer.md` § Row Security; PR #1134
- vnext-schema 0.0.58: `schemas/workflow-definition.schema.json` `#/definitions/rowSecurity` (PR #160)
- vnext-meta 0.0.103: feature `rowSecurity`, migration `instance-read-fails-on-flow-lookup-error`, known issue `row-security-instance-surfaces-unfiltered`
- vnext-example: `core/Workflows/row-security-lab/`, `core/Tasks/row-security-lab/`, `api-tests/row-security/` (PR #45)
