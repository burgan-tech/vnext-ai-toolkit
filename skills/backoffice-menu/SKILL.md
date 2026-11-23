---
name: backoffice-menu
description: Use when a domain's flows should appear in the back-office client's left menu, or its menu should change — triggers "sol menüye ekle", "menüye ekle", "menüde görünmüyor", "add to the sidebar", "yeni kayıt butonu çıkmıyor", "menü etiketini değiştir". Adds the navigations flow and schema the client discovers, starts the backoffice-side record with one entry per flow (list, Flow analysis, optional New button), and proves it in the client.
---

# backoffice-menu — give the domain its group in the left menu

A domain with flows published shows nothing in the back-office client's menu until it answers the client's
discovery. The contract — the two questions, the three pieces, the shape of an item — is
`references/concepts/backoffice-navigation.md`. Read it first; this skill is the order of work.

Adding the flow and its schema is authoring components: where a plan gate is in force, it applies here.
Changing an existing menu is only data and needs none.

## 1. See what the domain already has

Through a port-forward (the `cluster-publish` skill, steps 2–3):

```
GET <origin>/api/v1/<domain>/workflows/sys-flows/instances?filter={"key":{"eq":"navigations"}}&pageSize=1
GET <origin>/api/v1/<domain>/workflows/navigations/instances?filter={"key":{"eq":"backoffice-side"},"status":{"in":["A","B"]}}&pageSize=1
```

Ask the second only when the first returned a row — a read of a flow the domain does not carry is a server
error, not an empty page. Both rows present → go to step 4.

## 2. Add the two components

Copy from the plugin's `templates/navigations/`, replacing `{{domain}}`:

- `navigations-master.schema.json` → the workspace's Schemas folder as `navigations-master.json`
- `navigations.workflow.json` → the Workflows folder as `navigations.json`

Resolve both folders from `vnext.config.json`. Run `npm run validate`, then publish with `cluster-publish`.

## 3. Start the record

Fill `templates/navigations/backoffice-side.record.json` — one item per flow the menu should open — and
keep the filled file in the workspace so the menu is reviewable. Then, on the forwarded origin:

```
POST  <origin>/api/v1/<domain>/workflows/navigations/instances/start?sync=true     <the filled record>
PATCH <origin>/api/v1/<domain>/workflows/navigations/instances/backoffice-side/transitions/activate?sync=true   {}
```

Per item, settle with the person: which flow, the title in each language, and whether people may create
records from the list. **No `payload.create`, no New button.**

## 4. Change an existing menu

Edit the workspace's record file and send the whole `attributes`:

```
PATCH <origin>/api/v1/<domain>/workflows/navigations/instances/backoffice-side/transitions/update?sync=true   { "attributes": { "items": [ … ] } }
```

A label, an added flow, a removed entry — all are this one move. Nothing is published.

## 5. Prove it in the client

Reload the client. The group is named after the domain; the item opens the list; **Flow analysis** is on
it; **New** is there when the entry carries `create`; a row opens the record with the flow's moves in its
Transitions menu. Report what the screen showed, not what the calls answered.

A flow without views opens as "This stage has no view" with its fields listed and a generated form per
move. That is usable but bare; its screens are the `view-design` skill.

## When it does not appear

- The domain is not listed by discovery yet — a new domain can take a few minutes to be re-read.
- The record is closed — only a live one (status `A` or `B`) is drawn.
- An item repeats a key another group holds, or carries an absolute URL — see the reference.
- The client was not reloaded: the menu is composed once, at boot.

## Example requests

```text
ornek domainine sol menü ekle: "Talepler" başlığıyla ornek-talep akışının listesini açsın, "Yeni talep" düğmesi olsun.
```

```text
ornek domaininin menüsünde yeni kayıt düğmesinin etiketini "Yeni talep" yap.
```
