---
name: view-design
description: Use when the user wants to create or modify a vNext View component. Asks for the renderer first (pseudo-ui recommended), loads vocabulary if pseudo-ui, then generates the view JSON at the correct path resolved from vnext.config.json.
---

# View Design

Interactive, multi-step authoring of a vNext View component. The first decision — and the most consequential — is the **renderer**, because pseudo-ui requires loading vocabulary before any JSON is produced.

## Prerequisites

- Working directory is a vNext domain project (has `vnext.config.json` at the root).
- The state(s) this view will bind to are known (or can be created later).

## Canonical schema-first (mandatory pre-step — applies to every step below)

> **Before producing any view JSON or asking schema-driven questions, fetch the canonical `view.json` schema for the workspace's `schemaVersion`.** Never hardcode `display` values, `renderer` values, or `attributes` field lists — render them from the schema.

```
1. Read vnext.config.json → schemaVersion + domain + paths.*
2. Fetch https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/view.json
   ├─ HTTP 404 on tag → retry master branch, warn user
   ├─ Network down → fall back to references/concepts/component-schemas.md snapshot, warn user
   └─ No snapshot → halt; ask user to paste schema. Never guess.
3. Parse:
   - properties.attributes.properties.display.enum → display options
   - properties.attributes.properties.renderer.enum → renderer options
   - properties.attributes.properties.content.* → renderer-specific content shape
   - required[] → which fields the skeleton must include
4. Drive every AskUserQuestion option list + the skeleton from this schema.
```

See `references/concepts/component-schemas.md` for the full rule.

## Steps

### 1. Resolve paths from `vnext.config.json`

Read the repo-root `vnext.config.json` and capture:
- `paths.componentsRoot` (e.g. `core`)
- `paths.views` (e.g. `Views`)
- `domain` (e.g. `core`)

Target write path: `{componentsRoot}/{paths.views}/{domain-subfolder}/{key}-view.json`. The `{domain-subfolder}` mirrors the workflow folder name (e.g. `account-opening`); ask the user if unclear.

### 2. Ask for the renderer (always)

Use `AskUserQuestion` with these options:

- **`pseudo-ui`** (Recommended) — official UI SDK; rich vocabulary, data binding, role-aware
- `html` — raw HTML content
- `json` — generic JSON payload (machine consumers)
- `markdown` — rendered markdown
- `url` — redirect to a URL
- `http` — fetch and embed remote content
- `deeplink` — mobile/web deeplink

### 3. If `pseudo-ui` — load vocabulary

**Before producing any JSON**, fetch the vocabulary so component names, properties, and data-binding syntax are correct. Sources in priority order:

1. **In-repo author guide (always available)** — `.claude/references/view-author-guide.md`. Pattern guide (English): action model, expression namespace, ForEach, nested Component, common antipatterns. Read this first.
2. **Renderer repo (vocabulary source-of-truth)** — `https://github.com/burgan-tech/vnext-client-view-renderer`, file `vocabularies/view-vocabulary.md`. Currently **private** (request access from the vNext team); will be public at RC. When cloned, this is the most authoritative spec for component props and platform mapping. If you already have it locally, an agent may have remembered the absolute path in private memory.
3. **Context7 fallback**:
   - `mcp__context7__resolve-library-id` with `vnext-docs`
   - `mcp__context7__query-docs` with `"pseudo-ui view vocabulary components"` and `"pseudo-ui tasarimci rehberi data binding"`
4. **WebFetch last resort**:
   - `https://burgan-tech.github.io/vnext-docs/docs/how-to/view-consept/view-yapisi`
   - `https://burgan-tech.github.io/vnext-docs/docs/how-to/view-consept/tasarimci-rehberi`
   - `https://burgan-tech.github.io/vnext-docs/docs/how-to/view-consept/data-akisi`

Confirm with the user the available component types (`ScrollView`, `Column`, `Row`, `Card`, `ListTile`, `Button`, `TextField`, etc.) before drafting.

**Icons — Material Symbols / MD3 only.** pseudo-ui's `Icon` (and `Button.icon`) consumes the Material Symbols icon set. Use lowercase `snake_case` names exactly as listed at https://fonts.google.com/icons (e.g. `home`, `schedule`, `show_chart`, `check_circle`, `credit_card`, `location_on`, `arrow_forward`, `notifications`, `settings`, `badge`, `smartphone`, `bar_chart`, `check_box`). Never use kebab-case, Font Awesome names, or invented tokens. If unsure, verify the symbol exists in the Material Symbols catalog before placing it in the JSON.

### 4. Verify `rawResponse: true` on every function this view will bind

For each function referenced in the view's `dataSchema`, `x-lov.source`, `x-lookup.source`, or `$lov`/`$lookup` expressions:

1. Read the function JSON.
2. Confirm `attributes.rawResponse: true` is set.
3. If missing or `false` → fix it (or hand off to `component-function` skill). Without it, the runtime wraps the function output under the function key and JsonPath bindings like `$.data[*]` silently return nothing — empty dropdowns and null lookups with no error logged.

This is the most common cause of "the view looks right but no data shows up". Always check.

Full reference: `references/function-mapping-pattern.md` § 5.

### 5. Gather view requirements

Ask the user:
- **`display`** — `full-page`, `popup`, `inline`, etc.
- **State binding** — which workflow + state will reference this view?
- **Placement (state vs transition)** — if this view collects user input AND the target state is the workflow's Initial state (`stateType: 1`), the **Recommended placement is `state.view`** (not on the outgoing transition). Reason: the runtime serves the state view immediately on instance start, so the user sees the form right away. Confirm with `AskUserQuestion` — let the user override if they want an intentional "intro → tap → form" two-step. Wizard states (`stateType: 5`) are the exception — their form belongs on the single transition. See `references/concepts/view-roles.md` and `references/concepts/workflow-types.md`.
- **`dataSchema`** — which schema drives the data shape? **Choose by role**:
  - *Transition / input view* (user fills a form) → bind to the **transition payload schema** (carries `enum`/`x-lov`/`x-validation`/`x-conditional` for the input set).
  - *Display / summary / status view* (read-only from `$instance`) → bind to the **master / instance schema** (covers the full instance shape so `$schema.X.label` and `$instance.X` paths resolve everywhere).
  - Never point a transition view at the master schema "just to keep things uniform" — you'll lose the input-side semantics (required/LOV/validation).
  - If none exists, suggest spinning off the `schema-design` skill first.
- **Localization** — Turkish + English labels?
- **Interactions** — which buttons / transitions does it trigger?

### 6. Look at a sibling example (cheap context)

Before writing, read one nearby view of the same renderer for shape reference (e.g. `core/Views/account-opening/account-confirmation-view.json` for pseudo-ui). Do not copy blindly — use it to confirm field order and reference style.

### 7. Generate the view JSON

Standard envelope:

```json
{
  "key": "{key}-view",
  "version": "1.0.0",
  "domain": "{domain}",
  "flow": "sys-views",
  "flowVersion": "1.0.0",
  "tags": [],
  "attributes": {
    "display": "{display}",
    "renderer": "{renderer}",
    "content": { /* renderer-specific */ }
  }
}
```

**`renderer` lives at `attributes.renderer`** — a sibling of `attributes.content`, never inside
`content`. For pseudo-ui the value is `"pseudo-ui"` at `attributes.renderer`; the component tree
goes in `attributes.content.view`.

For `pseudo-ui`, `content` (i.e. `attributes.content`) looks like:

```json
{
  "$schema": "https://amorphie.io/meta/view-vocabulary/1.0",
  "dataSchema": "urn:vnext:res:schema:{domain}:{schema-key}",
  "view": { "type": "ScrollView", "children": [ /* components */ ] }
}
```

Data binding uses `$instance.fieldName` and `$schema.fieldName.label`.

**`dataSchema` must be a URN, not an HTTP URL** — exact form `urn:vnext:res:schema:{domain}:{schema-key}` matching the target schema's `$id`. URLs (`https://schemas.vnext.com/...`) won't resolve at runtime.

For non-pseudo-ui renderers, `content` is a small object (extensible later), with `${param}` runtime binding:

```jsonc
// http     → { "href": "https://google.com?s=${param}" }
// deeplink → { "href": "on-burgan//onboarding/${param}" }   // full-path only for now
// urn      → { "urn": "urn:vnext:flow:transition:{domain}:{flow}:${param}:approved" }
```

### 8. Write the file

Write to `{componentsRoot}/{paths.views}/{domain-subfolder}/{key}-view.json` (path from step 1).

### 9. Validate

Run `npm run validate`. If errors surface, hand off to the `validate-and-fix` skill.

### 10. Wire into the workflow (if requested)

If the user wants the view bound now, edit the target workflow JSON's state to add the `view` reference:

```json
{ "key": "{key}-view", "domain": "{domain}", "flow": "sys-views", "version": "1.0.0" }
```

Then re-run `npm run validate`.

## Notes

- Never hardcode `core/Views/...` — always resolve from `vnext.config.json`.
- pseudo-ui vocabulary evolves; re-query Context7 if the user reports an unknown component type.
- For non-pseudo-ui renderers, `content` shape varies — verify against `/docs/components/view` before drafting.
- `Icon.name` and `Button.icon` values are Material Symbols (MD3) tokens — lowercase `snake_case`. Never kebab-case (`check-circle`), Font Awesome (`fa-check`), or invented names.
- When the parent state is a Wizard (`stateType: 5`), keep `state.view = null`; the view belongs on that state's (single) transition.
- **Action model.** Reserved verbs: `submit` (validates by default), `select` (inline set, host NOT called), `reset` (clears formData, runs hooks), `dispatch` (domain dispatch; optional `validate`). The target lives in `command` as a URN (`urn:vnext` scheme) — flow transitions: `urn:vnext:flow:transition:{domain}:{flow}:{transition}`; functions: `urn:vnext:fn:{cmd}:{domain}:{fn}`; client-local nav: `urn:client:nav:/path`. For `Card.onTap`, use `{ "action": "dispatch", "command": "urn:vnext:..." }` or the inline `{ "action": "select", "bind": "...", "value": "..." }`. Attach `preHooks`/`postHooks` for audit/telemetry side-effects (see `view-author-guide.md` §4). Don't invent verbs like `"transition"`.
- **Auto transitions never carry a view.** `triggerType: 1` (auto/rule) and `triggerType: 2` (timer) must have `transition.view = null`. Auto-state (`stateType: 2`) whose only outgoing transitions are auto/timer should also have `state.view = null` — these states aren't user-facing.
- **Stepper is for true multi-step forms on one screen** (`steps[].title` + `steps[].content` both required). Don't use it as a wizard progress indicator across separate state views; a simple `Text` "Adım X / N" at the top of each view is the right pattern.
- **Input `bind`** = schema property path (`"firstName"`, `"address.city"`). Never prefix with `$form.` — that's only for expression contexts (Text content, showIf rule values, LOV filters).
