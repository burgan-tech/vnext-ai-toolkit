# Client forms and transitions — where a form lives, and what the client will fire

> **Audience:** whoever places a form in a workflow (`workflow-scaffold`, `view-design`, `architect`).
> **Client covered:** the web/back-office client built on `vnext-client-sdk-core` (pseudo-ui renderer + `vue`
> host), the client the staff surfaces run on. Measured 24.11.2026 on the deployed staff client against
> runtime 0.0.106. Mobile (`neo_core`) was not measured — confirm there before relying on these rules.

A form is a contract between three parties: the **view** (what is drawn), the **transition** (what the
runtime accepts) and the **client** (what it decides to send). The runtime contract alone does not tell you
whether a person can actually get through the screen. The client has its own rules, and four of them decide
most designs.

## 1. The four client rules

### R1 — a state-view button fires the transition with the view's own data

A `Button` in a **state view** with `"action": "submit"` and the record-less command
`urn:vnext:flow:transition:<domain>:<flow>:<transition>` fires that transition **on the record the surface
shows**, with the view's form data as the body. No second form is opened.
Source: `sdk/ts/vue/src/components/navActions/flowsActions.ts` → `onTransitionOnSurface`.

### R2 — a transition with a schema and NO view gets a generated form in the Transitions menu

Every manual transition is listed in the record's **Transitions** menu. Picking one that declares a
`schema` but no `view` makes the client **generate a form from that schema**. When the state view already
shows the same inputs, the person sees the form twice ("New" shows it, "Continue" shows it again).
A transition that has a `view` shows that view instead (in its own tab/page, without the record toolbar).

### R3 — a prefilled form with nothing touched is "no input" (AB-23 `seededUntouched`)

A state view's form is **seeded from the record**. Keys nobody touched are not counted as input. When the
transition declares a **`schema` or a `view`** and no key was touched, the client **refuses to fire** and
logs: *"`<tx>` asks a person to fill something in and this command carried nothing — nothing was fired."*
When the transition declares **neither**, the client fires it and withholds the untouched keys from the
body (the record already holds them).
Source: `sdk/ts/vue/src/components/navActions/transitionActions.ts` (comment block "WHAT THE SURFACE WAS
HANDED IS NOT INPUT").
Typical victim: an **Edit → resubmit** loop. The person goes back to a prefilled form, changes nothing,
presses the button — and nothing happens.

### R4 — `actions` is drawn only on `Dialog` (and the app bar)

The pseudo-ui renderer draws a view's `actions` array only for a `Dialog` root
(`DynamicRenderer.vue`, `d-dialog-footer`) and the app-bar chrome (`ChromeNode.vue`). On a
`Column`-rooted state or transition view the `actions` are **silently dropped**: the form renders, the
button does not. Put the buttons in the body (see `view-author-guide.md` §3.5).

## 2. Choosing where the form lives

| Need | Form placement | Transition carrying the input | Why |
|---|---|---|---|
| Enter data once, then the flow moves on (no going back) | state view, button = R1 command | `schema` = the input schema, `view: null` | R1 fires once; R2's menu form is a duplicate only if someone uses the menu |
| Enter data, **and a later step can send the person back to edit it** (Edit / Düzenle / correction loop) | state view, button = R1 command, `loadData: true` | **`schema: null`, `view: null`**, plus an `ITransitionMapping` that whitelists the input fields (§3) | R3: with a schema, "Edit → resubmit unchanged" is refused |
| Optional input on a later step (a note on Approve) | transition view (`Dialog` root, `mdi: popup`) | `schema` = that small schema | the person opens it deliberately; R3 does not bite because they type |
| A step that takes no input (Approve, Edit, Cancel) | button in the state view | closed empty schema (§4) | R3 does not apply to an empty schema the client knows asks nothing; the runtime refuses any smuggled body |
| Multi-step wizard | `stateType: 5`, form on the single transition | as the wizard needs | `workflow-types.md` "wizard view placement" |

Do **not** design a read-only "intro" state that tells the person to *"pick X from the Transitions menu"*.
A button (R1) does the same thing in one click. The menu is a fallback, not the path.

## 3. The schema-less input transition (the Edit-loop pattern)

When R3 forces `schema: null`, the transition loses its runtime validation and would merge **any** body
into instance data. Replace the schema with three things:

1. **An `ITransitionMapping` whitelist** (`transition.mapping`): copy only the known input keys from
   `context.Body` into the returned object and drop everything else. An untouched field is simply absent,
   and the record keeps its value.
2. **Server-side format checks** in the next task's mapping (or a rule): the same rules the schema had. A
   bad value takes the person back to the form with a message (§5 of `csx-contracts.md` — business
   checks route, they do not throw).
3. **Client-side validation stays**: the view's `dataSchema` is still the input schema, so the client
   validates the inputs it draws.

## 4. A step with no input still needs a schema

`schema: null` means **"accept any body"**: the runtime merges it into instance data without validation
(`transition-pipeline.md` §1.1 "nothing declared → accepted"). On an Approve after a confirm screen, that lets
a caller change the amount or the target between "confirm" and "send". For a step that takes no input,
publish a closed empty schema and reference it:

```json
{ "type": "object", "properties": {}, "additionalProperties": false, "maxProperties": 0 }
```

When a step **executes what an earlier step showed** (simulate → confirm → execute), also keep a
**snapshot** of what was checked/shown, written by the earlier step's output mapping. The executing
mapping should compare live data with the snapshot and `throw` on any difference before it sends anything.

## 5. Testing a UI fix

- **A record runs on the `flowVersion` it started with.** A fixed view or transition is invisible on an
  old record. Test every UI fix on a **new** record and say so to the person ("close the old tab, open a
  new one").
- Test the **paths a person actually takes**, not only the happy path: New → submit; submit → confirm →
  Edit → **submit unchanged**; Edit → change one field → submit; the Transitions-menu route.
- When driving the client with Playwright/CDP, **never log request bodies of identity/token calls**
  (`morph-idm`, `token`, `login`). The client renews its session in the background, and a body logger will
  capture a refresh token.

## Sources

- `vnext-client-sdk-core`: `sdk/ts/vue/src/components/navActions/flowsActions.ts` (R1),
  `sdk/ts/vue/src/components/navActions/transitionActions.ts` (R3),
  `sdk/ts/pseudo-ui/src/adapters/vue/DynamicRenderer.vue` and `ChromeNode.vue` (R4).
- Measured on the deployed staff client, 24.11.2026 (runtime 0.0.106): a backoffice money-transfer flow
  went through every row of §2's first two lines and §4; the failures that produced R2–R4 were each seen
  in the browser console before the fix.
