# View Roles & pseudo-UI Data Binding

> **Schema first.** View `attributes.type`, `display`, and `renderer` enum values come from the canonical `view.json` schema. Treat this file as a mental model; if it conflicts with the schema, the schema wins.

## 1. View `type` and `renderer`

A view's `attributes.type` selects the content model; `renderer` (for the JSON content model) selects the rendering SDK.

Approximate mapping (verify against the schema):

| `type` | Content | Notes |
|--------|---------|-------|
| `1` | Structured JSON (pseudo-UI tree, or other JSON-based renderer) | Most common. Uses `renderer` to pick the SDK. |
| `2` | HTML string | Raw HTML body |
| `3` | Markdown string | Rendered markdown |
| `4` | Deeplink string | `myapp://path?params` |
| `5` | HTTP URL | Redirect / embed |
| `6` | URN | URN-based content reference |

Renderer options (for `type: 1`): `pseudo-ui` (recommended — official SDK), `react`, `vue`, `angular`, `flutter`, `react-native`, `native-ios`, `native-android`.

**Content shapes for `http` / `deeplink` / `urn`** — each is a small object (not a bare string), so
the format can be extended later. All support `${param}` runtime binding:

```jsonc
// http     → { "href": "https://google.com?s=${param}" }
// deeplink → { "href": "on-burgan//onboarding/${param}" }   // full-path only for now
// urn      → { "urn": "urn:vnext:flow:transition:core:account-opening:${param}:approved" }
```

## 2. `display` modes

How the view is presented on screen:

- `full-page` — typical state view, full screen
- `popup` — modal dialog (good for confirmations)
- `bottom-sheet` / `top-sheet` — mobile panels
- `drawer` — side drawer
- `inline` — embedded inside another surface

## 3. State view vs Transition view (critical distinction)

| Context | Role | User input? | Recommended `display` | `dataSchema` |
|---------|------|-------------|------------------------|--------------|
| **State view** (`state.view`) | Shows the user where they are; read-only summary | No | `full-page` | Master / instance schema (covers full instance shape so `$instance.X` resolves everywhere) |
| **Transition view** (`transition.view`) | Form for input, or confirmation dialog | Yes | `popup` (confirmation) or `full-page` (complex form) | Transition payload schema (carries `enum`/`x-lov`/`x-validation`/`x-conditional` for the input set) |

**Pattern: don't point a transition view at the master schema** "just to keep things uniform." You lose the input-side semantics — required fields, LOV options, validation rules — because those live on the transition payload schema. (The master schema deliberately uses **no `required`** and **`additionalProperties: true`** so instance data can expand across states — see `workflow-types.md` § Master schema.)

**Pattern: input on the initial state goes on the STATE view (default).** When the workflow's Initial state (`stateType: 1`) needs the user to provide data before doing anything else, the convention is to put the input form on `state.view`, NOT on the outgoing transition. The runtime exposes the state view immediately when the instance starts; the user fills it, then a manual transition (with `view: null`) executes the submission. Putting the form on the transition forces an extra hop: instance starts → state has no view → user has to discover the transition → form appears. Bad UX, more clicks.

This is a **default with confirmation**: the skill should propose state-view placement when it detects input on the initial state, and ask the user to confirm (some flows legitimately want a "intro screen → tap to start → form" two-step). Use `AskUserQuestion` with state-view as Recommended.

**Pattern: Wizard fast-path.** When the parent state is `stateType: 5` (Wizard), the runtime's view function returns the transition's view directly on state entry. Keep `state.view = null` and put the form on the single outgoing transition's `view`.

**Pattern: auto/timer transitions never carry a view.** `triggerType` 1, 2, 3 → `transition.view = null`.

## 4. pseudo-UI vocabulary (high-level)

pseudo-UI views set `content.$schema: "https://amorphie.io/meta/view-vocabulary/1.0"` and reference a `content.dataSchema` URN. The `content.view` is a component tree.

Common component families (verify the full catalog against the renderer repo / docs):

- **Layout**: `ScrollView`, `Column`, `Row`, `Container`, `Spacer`
- **Input**: `TextField`, `PasswordField`, `Dropdown`, `Select`, `CheckBox`, `RadioButton`, `DatePicker`
- **Display**: `Text`, `Image`, `Icon`, `Badge`
- **Interactive**: `Button`, `Card` (with `onTap`), `Link`, `Expandable`
- **Composite**: `ListTile`, `Stepper` (true multi-step single-screen form), `ForEach`, `Component` (nested)

## 5. Data binding namespaces

pseudo-UI expressions reference data through namespaces:

| Namespace | Source | Example |
|-----------|--------|---------|
| `$instance` | Workflow instance data | `$instance.customer.name` |
| `$schema` | Schema metadata (`x-labels`, etc.) | `$schema.accountType.label` |
| `$form` | Client-side form state | `$form.errors`, `$form.isDirty` |
| `$ui` | UI runtime state | `$ui.isLoading` |
| `$lov` | List-of-values lookups (resolved via Function) | `$lov.branches[]` |
| `$lookup` | Per-key lookup (resolved via Function) | `$lookup.branchDetail.address` |

**`bind` is the schema property path**, NOT a `$form.X` expression: `"bind": "firstName"` or `"bind": "address.city"`.

## 6. JSON Schema extensions used by pseudo-UI

These `x-*` keywords live on schema properties and are consumed by the view layer:

- **`x-labels`** — `{ "tr": "…", "en": "…" }` localized field labels
- **`x-lov`** — LOV (dropdown) datasource: static list or function reference + JsonPath
- **`x-lookup`** — Read-only enrichment: function reference + key field + JsonPath
- **`x-validation`** — Runtime validation rules beyond standard JSON Schema (e.g. cross-field)
- **`x-conditional`** — Field visibility/requirement conditions (`if X then required Y`)
- **`x-enum`** — Enum values with display metadata
- **`roles`** — Field-level access (`{ "role": "$PreviousUser", "grant": "allow" }`). System role tokens (`$InstanceStarter`, `$PreviousUser`, `$InstanceBehalfOfStarter`, `$PreviousBehalfOfUser`) and JSONPath grants are documented in `roles-and-authorization.md`.

`$lookup.{propertyName}` access uses **property name** — to expose `$lookup.branchDetail.X`, the `x-lookup` must sit on a schema property literally named `branchDetail` (a dedicated read-only object property, separate from the input field).

## 7. Action model (Buttons and Cards)

- Reserved verbs: `submit` (validates by default), `select` (inline set, host NOT called),
  `reset` (clears formData, *does* go to host), `dispatch` (domain dispatch; optional `validate`).
- The actual target lives in `command` as a URN (current `urn:vnext` scheme):
  - Flow transition: `urn:vnext:flow:transition:{domain}:{flow}:{transition}`
  - Function: `urn:vnext:fn:{cmd}:{domain}:{fn}` (`cmd` defaults to `get`)
  - Client-local (navigation, etc.): `urn:client:nav:/path`
- `Card.onTap` (preferred over legacy `action`):
  - Dispatch: `{ "action": "dispatch", "command": "urn:vnext:..." }`
  - Select-in-form: `{ "action": "select", "bind": "...", "value": "..." }`
- **Pre/post hooks**: `preHooks` / `postHooks` arrays fire audit/telemetry commands around the
  main action. See `view-author-guide.md` §4 for the full behavior rules.
- **No invented verbs** like `"transition"`. The SDK has no built-in semantics for them.

## 8. Icons — Material Symbols only

`Icon.name` and `Button.icon` consume Material Symbols (MD3). Names are **lowercase `snake_case`**, exactly as listed at `https://fonts.google.com/icons`. Common mappings (NOT kebab-case, NOT Font Awesome):

- clock → `schedule`
- chart-line → `show_chart`
- chart-bar → `bar_chart`
- pencil → `edit`
- user → `person`
- id-card → `badge`
- map-marker → `location_on`
- mobile → `smartphone`
- check-circle → `check_circle`
- credit-card → `credit_card`
- arrow-right → `arrow_forward`
- cog → `settings`
- bell → `notifications`

## 9. Antipatterns

- **LOV used as navigation grid.** `x-lov` is for input-bound dropdowns. A grid of cards that each dispatch a workflow transition is a static layout with hardcoded `Card.onTap.command` URNs — don't synthesize it via LOV item data.
- **Stepper as a progress bar.** `Stepper.steps[]` requires `title` AND `content` (componentNode[]). It renders a true multi-step form on one screen. If you want a "Step 2 of 4" indicator across separate state views, use a small `Text` at the top of each view instead.

## Sources

- Canonical schema: `https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/view.json`
- Vocabulary: `https://burgan-tech.github.io/vnext-docs/docs/how-to/view-consept/view-yapisi`
- Designer guide: `https://burgan-tech.github.io/vnext-docs/docs/how-to/view-consept/tasarimci-rehberi`
- Data flow: `https://burgan-tech.github.io/vnext-docs/docs/how-to/view-consept/data-akisi`
- Renderer source-of-truth (private): `https://github.com/burgan-tech/vnext-client-view-renderer`
