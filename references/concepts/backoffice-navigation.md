# The back-office menu — discovered, not registered

How a domain gets its own group in the back-office client's left menu. Used by the `backoffice-menu` skill.

**A built domain with flows published still shows nothing in the menu.** Nothing is registered in the
client: the client ASKS every domain service discovery lists, on every boot, two questions.

1. Does the domain publish a flow keyed `navigations`? (a filtered read of `sys-flows`)
2. Does that flow hold a live record keyed `backoffice-side`? (status `A` or `B` — a status, not a state name)

A domain that answers both gets a group named after itself, drawn alphabetically among the others, holding
the record's `attributes.items`. A domain that answers neither costs nothing and is not an error.

## What the domain carries

| Piece | Kind | Where it comes from |
|---|---|---|
| `navigations-master` | schema component | the plugin's `templates/navigations/navigations-master.schema.json` |
| `navigations` | workflow component (`create` → `draft` → `activate` → `active`; `update`, `deactivate`, `archive`) | `templates/navigations/navigations.workflow.json` |
| `backoffice-side` | a RECORD of that flow — data, not a component | `templates/navigations/backoffice-side.record.json` |

The two components are published like any other definition. The record is started and moved on the
runtime: a `start` with `key: "backoffice-side"`, then `activate`. A later change is the record's `update`
move carrying the whole `attributes` — no publish, no version bump.

## An item

```json
{
  "type": "dynamicView",
  "version": "v1",
  "key": "<domain>-<flow>",
  "title": [{ "language": "tr-TR", "label": "…" }, { "language": "en-US", "label": "…" }],
  "icon": "list_alt",
  "config": {
    "view": "urn:client:view:open:<shell domain>:instance-list",
    "inputs": [{ "name": "q", "inQuery": true }],
    "payload": {
      "domain": "<domain>", "workflow": "<flow>", "title": "…",
      "create": { "label": [{ "language": "tr-TR", "label": "…" }, { "language": "en-US", "label": "…" }] }
    }
  }
}
```

- `instance-list` is the shell's generic list: the flow's records, a **Flow analysis** button, and a row
  that opens the record with the flow's moves in its Transitions menu. The domain writes no view for it.
- **The New button exists only when the entry carries `payload.create`**, and its text is
  `create.label` — the client shows the entry for its current language.
- New starts the flow directly. A start whose schema asks for nothing required creates the record at once,
  with no form; what a person should type is then collected on the first move.
- `sys-record-list` is a different view: the envelope list for `sys-*` records, with no create, no analysis
  and a read-only row. It is the wrong one for a business flow.
- A keyed item is a ROUTE across the whole client. Prefix keys with the domain; a key another group already
  holds is not drawn.
- An absolute URL anywhere in an item refuses the whole group: a discovered item stays inside the application.
- The shell domain in the view URN is the back-office client's own (`staff` unless the person says otherwise).
