# Roles & Authorization

vNext authorizes actions against **role tokens** resolved from the caller's JWT and the instance's
lineage. This applies to transition `roles`, state/flow `queryRoles`, master-schema field
visibility (`roles[]` on a schema property), and state-alias role grants (see
`workflow-types.md` § State alias).

## Token claims

Two subjects are resolved from the token:

| Claim | Meaning |
|-------|---------|
| `sub` | The **subject** — the customer the action is performed *on behalf of*. |
| `act_sub` | The **actor** — the user actually performing the action. |

For a direct customer action these are the same; for a backoffice operator acting on a customer's
behalf they differ (`act_sub` = operator, `sub` = customer).

## Static system roles

Four built-in role tokens describe the instance's lineage. Use them anywhere a `role` is expected:

| Role | Compares against | Meaning |
|------|------------------|---------|
| `$InstanceStarter` | actor (`act_sub`) | The actor who **started** the instance |
| `$PreviousUser` | actor (`act_sub`) | The actor who triggered the **previous** transition |
| `$InstanceBehalfOfStarter` | subject (`sub`) | The subject the instance was **started** for |
| `$PreviousBehalfOfUser` | subject (`sub`) | The subject of the **previous** transition |

```json
{
  "roles": [
    { "role": "$InstanceStarter", "grant": "allow" },
    { "role": "$PreviousUser", "grant": "allow" }
  ]
}
```

> There is no `$CurrentUser` token. The current actor is implicit in the request; lineage is
> expressed with the four roles above.

## JSONPath role grants (instance-data authorization)

`role` values may also be **JSONPath-style** expressions. At runtime the engine compares a token
value against a value read from the `ScriptContext` (including `Instance.Data`):

| Prefix | Token compared | Context value compared |
|--------|----------------|------------------------|
| `$user.<jsonpath>` | **actor** | the `<jsonpath>` value in context |
| `$role.<jsonpath>` | **role** | the `<jsonpath>` value in context |
| `$userBehalfOf.<jsonpath>` | **subject** (on-behalf) | the `<jsonpath>` value in context |

Example paths (must match your workflow's data schema):

```text
$user.$.context.Instance.Data.customer.ownerUserId
$user.$.context.Instance.Data.assignedUsers[*].userId
$userBehalfOf.$.context.Instance.Data.customer.behalfOfUserId
$role.$.context.Instance.Data.permissions.requiredRole
$role.$.context.Transition.Key
```

**How to read these expressions.** The prefix (`$user` / `$userBehalfOf` / `$role`) declares **what
the role definition addresses** — which token side the runtime should resolve and compare. The
`$.context...` part is a JSONPath into the **`ScriptContext`** mapping, so you can address any value
the runtime exposes there (`Instance.Data`, `Transition.Key`, etc.) — not just instance data fields.
So `$user.$.context.Instance.Data.customer.ownerUserId` means: *compare the **actor** token against
the value at `context.Instance.Data.customer.ownerUserId`*.

This lets you scope an action to, say, "only the user listed as `ownerUserId` in the instance data"
without hardcoding identities into the workflow definition.

## Where roles are used

- **Transition `roles`** — who may fire a transition.
- **State / flow `queryRoles`** — who may read the state / query instances (multi-actor flows).
- **Schema field `roles[]`** — field-level read/write visibility on the master schema.
- **State alias `roles[]`** — which role sees which localized state label (`workflow-types.md`).

## Sources

- Canonical schemas: `workflow.json`, `schema.json` at `vnext-schema/v{schemaVersion}/schemas/`
- Related: `schema-vocabularies.md` (schema field `roles`), `view-roles.md`,
  `workflow-types.md` (state alias)
