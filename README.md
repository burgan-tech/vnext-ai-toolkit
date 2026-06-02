# vNext AI Toolkit

> Claude Code plugin for building [vNext](https://burgan-tech.github.io/vnext-docs/) workflow-domain components with AI assistance — analyze a request, design it, author the JSON, validate, security-review, and document it. Built for projects scaffolded from [`@burgan-tech/vnext-template`](https://github.com/burgan-tech). **Schema-first**: every component is authored against the JSON Schemas shipped in `@burgan-tech/vnext-schema` (pinned in the project's `package.json`), never from hardcoded assumptions.

## What it is

The vNext platform defines a workflow domain as a set of JSON component files — `schema`, `workflow`, `task`, `view`, `function`, `extension` — each validated against a JSON Schema. Building a domain by hand means juggling cross-references, getting enum values right, writing `.csx` mapping files against the right C# interfaces, and keeping everything passing `npm run validate`. This plugin turns that work into a guided, agent-driven workflow inside your domain project.

It ships three kinds of capability:

1. **Seven specialized agents** that form a build pipeline — `analyst` → `architect` → `component-author` → `validator` → (`security-reviewer` + `doc-writer`), with `reviewer` for PR-style checks.
2. **Nine skills** — one umbrella reference skill (`authoring-vnext-components`) plus eight focused authoring skills (`workflow-scaffold`, `view-design`, `schema-design`, `component-task`, `component-function`, `component-extension`, `integration-test`, `validate-and-fix`).
3. **Four slash commands** — `/new-domain`, `/new-component`, `/validate`, `/build` — as entry points.

## Install

```bash
claude plugin marketplace add burgan-tech/vnext-ai-toolkit
claude plugin install vnext-ai-toolkit@burgan-tech
```

To update later:

```bash
claude plugin marketplace update burgan-tech
```

Or, for development:

```bash
git clone https://github.com/burgan-tech/vnext-ai-toolkit.git ~/.claude/plugins/vnext-ai-toolkit
```

The plugin is meant to run **inside a vNext domain project** (a checkout of `@burgan-tech/vnext-template`, with a `vnext.config.json` at the root and `@burgan-tech/vnext-schema` in `node_modules`).

## Quickstart

```bash
# 1. Turn the template into a concrete domain (replaces the {{DOMAIN_NAME}} placeholder)
claude /new-domain payments

# 2. Scaffold a component — runs analyst → architect → component-author → validator,
#    then security-reviewer + doc-writer
claude /new-component workflow account-opening "Open a new current account"

# 3. Validate everything (and offer to fix failures)
claude /validate

# 4. Build the domain package
claude /build
```

## The agent pipeline

`/new-component` orchestrates the agents in order; you can also invoke any of them directly.

| Agent | Role | Writes JSON? |
|-------|------|:---:|
| `analyst` | Docs-first. Checks `docs/<Type>/<key>.md`, clarifies scope, produces acceptance criteria and an ordered task list. | No |
| `architect` | Turns the analysis into a technical design — folder placement, state/transition model, task/function wiring, references, exports. | No |
| `component-author` | Implements the design as schema-valid component JSON and `.csx` mappings. | Yes |
| `validator` | Independent QA — runs `npm run validate` and `npm test`, sanity-checks builds. | No |
| `security-reviewer` | Hunts leaked secrets, untrusted reference hosts, over-broad exports, unsafe task/function/extension config. | No |
| `doc-writer` | Writes/updates `docs/<Type>/<key>.md` (one file per component) and the `CHANGELOG.md` entry. | Docs only |
| `reviewer` | PR-check role — schema compliance, naming/version conventions, reference integrity, config/exports correctness. | No |

After the `validator` passes, `security-reviewer` and `doc-writer` run in parallel (they don't conflict — doc-writer writes under `docs/`, security-reviewer only reads).

## Skills

- **`authoring-vnext-components`** — the core reference: the common component envelope, type-specific `attributes`, the `.csx` `scriptCode` shape, transition trigger types, and the validate-fix loop. The agents and commands lean on it for field rules.
- **`workflow-scaffold`** — plan a state/transition graph, scaffold the workflow JSON + `.csx` mappings + `.http` test file.
- **`view-design`** — renderer choice (pseudo-ui recommended), vocabulary loading, view-tree generation.
- **`schema-design`** — interactive field gathering with localization (`x-labels`) and role-based access, producing JSON Schema draft 2020-12.
- **`component-task`** — task `type` + per-type `config` driven from the schema enum, `.csx` mapping, MockLab seed suggestion.
- **`component-function`** — scope `D`/`I`, single- vs multi-task composition, `IMapping`/`IOutputHandler` `.csx`.
- **`component-extension`** — type × scope matrix with performance warnings.
- **`integration-test`** — xUnit class against `VNext.Testing.Sdk` asserting a workflow's lifecycle.
- **`validate-and-fix`** — runs `npm run validate`, categorizes failures, proposes schema-cited fixes before applying.

## Commands

| Command | What it does |
|---------|--------------|
| `/new-domain <name>` | Initializes the template into a concrete domain (`npm run setup`), then `sync-schema` + `validate`. |
| `/new-component <type> <key> [desc]` | Scaffolds a component end-to-end through the agent pipeline. `<type>` ∈ `schema\|workflow\|task\|view\|function\|extension`. |
| `/validate` | Runs `npm run validate`, summarizes failures by file with the violated schema rule, and offers to fix. |
| `/build [runtime\|reference] [flags]` | Builds the domain package via `npm run build` / `build:reference`. |

## Design philosophy

### Schema-first

The single most important rule: **no hardcoded enums, no assumed required fields, no guessed JSON shapes**. Before authoring or editing a component, agents and skills read the authoritative schema from the version pinned in your project:

```
node_modules/@burgan-tech/vnext-schema/schemas/<component>-definition.schema.json
```

When the schema or platform behavior isn't clear from the local schema and existing components, the knowledge access order is: pinned local schema → Context7 MCP (`/burgan-tech/vnext-docs`, `/burgan-tech/vnext-example`) → `WebFetch` of the vnext-docs site. A docs claim that contradicts the pinned schema does not win — the schema does.

### Domain-agnostic

The plugin doesn't assume a domain name. It reads `domain` and `paths.*` from `vnext.config.json` and resolves every component folder from there. It works the same in `payments`, `lending`, `core`, or any other domain.

### Schema-driven, schema-validated

Components are authored to pass `npm run validate` on the first try — because the author and the validator share one source of truth, the pinned `@burgan-tech/vnext-schema`.

## What you'll have after `/new-component workflow <key>`

For a typical workflow (paths resolved from `vnext.config.json`):

- `Workflows/<key>.json` — the state machine (with the required master payload schema reference)
- `Workflows/.../src/*.csx` — C# mappings (`IMapping`), auto-transition rules (`IConditionMapping`), timers (`ITimerMapping`)
- `Workflows/<key>.http` — REST Client probe file
- `Views/<key>-view.json`, `Schemas/<key>.json`, `Tasks/<key>.json`, `Functions/<key>.json`, `Extensions/<key>.json` — supporting components the design calls for
- `docs/Workflows/<key>.md` — component documentation
- a `CHANGELOG.md` entry

All passing `npm run validate`.

## Repo layout

```
vnext-ai-toolkit/
├── .claude-plugin/plugin.json        # Manifest (agents / skills / commands)
├── agents/                           # 7 pipeline agents
│   ├── analyst.md  architect.md  component-author.md
│   ├── validator.md  reviewer.md  security-reviewer.md
│   └── doc-writer.md
├── skills/                           # 9 skills
│   ├── authoring-vnext-components/SKILL.md   # core reference skill
│   ├── workflow-scaffold/  view-design/  schema-design/
│   ├── component-task/  component-function/  component-extension/
│   └── integration-test/  validate-and-fix/
├── commands/                         # 4 slash commands
│   └── new-domain.md  new-component.md  validate.md  build.md
├── references/                       # Concept docs the architect/agents may consult
│   ├── concepts/                     # workflow-types, view-roles, csx-contracts, ...
│   ├── decision-tree.md  external-sources.md
│   ├── view-author-guide.md  function-mapping-pattern.md  mocklab-seed-format.md
├── templates/                        # Workspace bootstrap files ({{Domain}} placeholders)
│   ├── vnext.config.json.tmpl  package.json.tmpl  docker-compose.yml.tmpl
│   ├── CLAUDE.md.tmpl / AGENTS.md.tmpl  .http.tmpl
│   ├── etc/{docker,dapr}/...
│   └── tests/                        # Integration-test scaffold
└── scripts/check-prerequisites.sh
```

## Compatibility

| AI agent | Status |
|----------|--------|
| Claude Code | Primary target |
| Codex (via `AGENTS.md`) | Supported — every `CLAUDE.md` is mirrored to `AGENTS.md` |
| Cursor (`.cursor/rules/*.mdc`) | Planned |

The plugin tracks whatever `@burgan-tech/vnext-schema` version your project pins in `package.json` — when vNext adds a new state type or task type, the plugin sees it on the next read, no change required here.

## Related repos

- [`burgan-tech/vnext-example`](https://github.com/burgan-tech/vnext-example) — Reference domain with working examples of every component type.
- [`burgan-tech/vnext-docs`](https://github.com/burgan-tech/vnext-docs) — Official documentation portal ([browse online](https://burgan-tech.github.io/vnext-docs/)).
- [`burgan-tech/vnext-schema`](https://github.com/burgan-tech/vnext-schema) — Canonical JSON Schemas + vocabularies (this plugin's contract source).
- [`burgan-tech/mocklab`](https://github.com/burgan-tech/mocklab) — Mock API used for HTTP task development.
- [`burgan-tech/vnext-integration-test`](https://github.com/burgan-tech/vnext-integration-test) — Integration testing SDK.

## License

MIT — see [LICENSE](./LICENSE).

## Contributing

Issues and PRs welcome. When proposing a new skill or agent, or extending an existing one:

1. Confirm the change respects the schema-first rule (read the pinned schema, never hardcode enums).
2. Add or update the relevant `references/concepts/*.md` if a new concept is introduced.
3. Update `CHANGELOG.md`.
