# vNext AI Toolkit

> Claude Code plugin for building [vNext](https://burgan-tech.github.io/vnext-docs/) workflow-domain components with AI assistance — analyze a request, design it, author the JSON, validate, security-review, and document it. Built for projects scaffolded from [`@burgan-tech/vnext-template`](https://github.com/burgan-tech). **Schema-first**: every component is authored against the JSON Schemas shipped in `@burgan-tech/vnext-schema` (pinned in the project's `package.json`), never from hardcoded assumptions.

**Runtime coverage:** the toolkit describes vNext runtime **0.0.100** / schema **0.0.56**. `vnext-meta` is read live from vnext master (`scripts/vnext-meta-live.sh`); [`references/runtime-feature-matrix.md`](references/runtime-feature-matrix.md) is its offline snapshot (feature → since-version). See "Updating runtime knowledge" below.

**Who it is for:** product teams that build vNext domains. They work in their own domain repository and have no write access to the vNext runtime, vnext-schema, vnext-docs or vnext-example repositories — the toolkit only *reads* those, and routes runtime defects to `/vnext-ai-toolkit:report-issue`.

## What it is

The vNext platform defines a workflow domain as a set of JSON component files — `schema`, `workflow`, `task`, `view`, `function`, `extension`, `mapping` — each validated against a JSON Schema. Building a domain by hand means juggling cross-references, getting enum values right, writing `.csx` mapping files against the right C# interfaces, and keeping everything passing `npm run validate`. This plugin turns that work into a guided, agent-driven workflow inside your domain project.

It ships these capabilities:

1. **Seven specialized agents** that form a build pipeline — `analyst` → `architect` → `component-author` → `validator` → (`security-reviewer` + `doc-writer`), with `reviewer` for PR-style checks.
2. **A multi-turn design orchestrator** (`vnext-architect`) for designing a whole workflow end-to-end — discovery → state machine → components → tests — through a structured decision tree.
3. **Fourteen skills** — one umbrella reference skill (`authoring-vnext-components`) plus thirteen focused authoring, testing and review skills (`workflow-scaffold`, `view-design`, `schema-design`, `component-task`, `component-function`, `component-extension`, `component-mapping`, `integration-test`, `e2e-local`, `validate-and-fix`, `security-audit`, `domain-check`, `report-runtime-issue`).
4. **Eleven slash commands** — `/vnext-ai-toolkit:vnext-init`, `/vnext-ai-toolkit:vnext-update`, `/vnext-ai-toolkit:new-component`, `/vnext-ai-toolkit:vnext-design-process`, `/vnext-ai-toolkit:validate`, `/vnext-ai-toolkit:review-components`, `/vnext-ai-toolkit:build`, `/vnext-ai-toolkit:e2e`, `/vnext-ai-toolkit:security-audit`, `/vnext-ai-toolkit:domain-check` and `/vnext-ai-toolkit:report-issue` — as entry points.

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

The plugin runs **inside a vNext domain project** (a checkout of `@burgan-tech/vnext-template`, with a `vnext.config.json` at the root and `@burgan-tech/vnext-schema` in `node_modules`). If you don't have one yet, `/vnext-ai-toolkit:vnext-init` can bootstrap it.

## Quickstart

```bash
# 1. Set up (or refresh) the workspace. If there's no vnext.config.json yet, this scaffolds the
#    base project with @burgan-tech/vnext-template, then layers on the toolkit files (docker-compose
#    + MockLab, CLAUDE.md, integration tests, ...). Diffs before overwriting anything.
claude /vnext-ai-toolkit:vnext-init

# 2a. Scaffold a single component through the agent pipeline
#     (analyst → architect → component-author → validator, then security-reviewer + doc-writer)
claude /vnext-ai-toolkit:new-component workflow account-opening "Open a new current account"

# 2b. ...or design a whole workflow end-to-end with the architect orchestrator
claude /vnext-ai-toolkit:vnext-design-process "Account opening"

# 3. Validate everything (and offer to fix failures)
claude /vnext-ai-toolkit:validate

# 4. Build the domain package
claude /vnext-ai-toolkit:build
```

## The agent pipeline

`/vnext-ai-toolkit:new-component` orchestrates the agents in order; you can also invoke any of them directly.

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

Beyond the per-component pipeline, **`vnext-architect`** is a multi-turn orchestrator for designing a *whole workflow* end-to-end (invoked by `/vnext-ai-toolkit:vnext-design-process`). It walks discovery → state machine → components → tests and delegates to the skills below.

## Skills

- **`authoring-vnext-components`** — the core reference: the common component envelope, type-specific `attributes`, the `.csx` `scriptCode` shape, transition trigger types, and the validate-fix loop. The agents and commands lean on it for field rules.
- **`workflow-scaffold`** — plan a state/transition graph, scaffold the workflow JSON + `.csx` mappings + `.http` test file.
- **`view-design`** — renderer choice (pseudo-ui recommended), vocabulary loading, view-tree generation.
- **`schema-design`** — asks the schema's role (`master`/`transition`/`function`/`component`) first, then gathers fields, localization (`x-labels`), an explicit protection decision for every sensitive field (`x-roles`/`x-masking`/`x-encryption`), `x-context-*`, file fields (`x-storage`) and `x-indexed` on every filtered or sorted field; produces JSON Schema draft 2020-12.
- **`component-task`** — task `type` + per-type `config` driven from the schema enum, `.csx` mapping, MockLab seed suggestion.
- **`component-function`** — scope `D`/`F`/`I`, single- vs multi-task composition, `IMapping`/`IOutputHandler` `.csx`.
- **`component-extension`** — type × scope matrix with performance warnings.
- **`component-mapping`** — reusable `sys-mappings` C# helper components, wired into consumers via `scripts.helpers` / `allowedAssemblies` or `encoding: "REF"`.
- **`integration-test`** — xUnit class against `VNext.Testing.Sdk` (scaffolds the project via the official `VNext.Testing.Template`) asserting a workflow's lifecycle, including authorization scenarios (role header, morph-idm, behalf-of, role-less, four-eyes). Every workflow is expected to have one; a missing test is a warning, never a block.
- **`e2e-local`** — runs the domain's integration tests end to end: Testcontainers with the image pinned to `runtimeVersion` by default, or — after asking — against a local runtime you already run; preflight, triage of failures (environment / fixture / domain / runtime) and a result stamp.
- **`validate-and-fix`** — runs `npm run validate`, categorizes failures, proposes schema-cited fixes before applying.
- **`security-audit`** — runs a four-phase OWASP-style security review (recon → hunt → verify → report) for secrets, authz, injection, SSRF/path traversal, weak crypto, dependency issues, and misconfiguration. Candidates are verified for reachability and existing mitigations, scored for confidence (0–100), and written to `security-report/SECURITY-REPORT.md` with CWE/OWASP references.
- **`domain-check`** — read-only runtime-cost and unused-capability audit of the domain package (CacheAside, GetInstances, error-boundary Retry, `P` vs `S`, same-order parallelism, function scope, `history: none`, `x-indexed`, …). A stdlib scanner reads enum labels from the pinned `@burgan-tech/vnext-schema`; every finding is verified in the file and triaged with you before a Turkish `Yapılmalı` / `Yapılsa iyi olur` report is written. Port of the runtime repo's `domain-performance-audit` (#27).
- **`report-runtime-issue`** — when a problem is the runtime's, not the domain's: triages against known gaps, live `vnext-meta` known issues and the docs, searches for duplicates, collects evidence, redacts secrets/PII/internal hosts, drafts an English issue and files it on `burgan-tech/vnext` only after your approval.
- **Security checklist reference** — [references/concepts/security-review-checklist.md](references/concepts/security-review-checklist.md) gives the agents and skills concrete per-category hunt patterns for the vNext component model (`roles`/`queryRoles`/`x-roles`, `.csx` `ScriptContext` data flow, `allowedHosts`, `REF` sources), false-positive rules (MockLab seeds, fixtures, dev URLs), and a severity/confidence rubric with OWASP Top 10 / CWE mapping.

## Commands

| Command | What it does |
|---------|--------------|
| `/vnext-ai-toolkit:vnext-init` | Sets up or refreshes the workspace. Scaffolds the base project via `@burgan-tech/vnext-template` (npx) when missing, then layers the toolkit files (docker-compose + MockLab, `CLAUDE.md`/`AGENTS.md`, `.claude/references`, integration tests) — diffing before overwriting. Offers to bump `runtimeVersion`/`schemaVersion`. Stamps the workspace with the toolkit version (`.claude/vnext-toolkit.json`). |
| `/vnext-ai-toolkit:vnext-update [--force]` | Refreshes the toolkit-owned files after a plugin update: compares the workspace stamp against the installed plugin version, reports how the workspace `runtimeVersion` relates to the runtime the toolkit knows, diffs each file against the current templates, and confirms (per file for `CLAUDE.md`/`AGENTS.md`/compose/dapr, once for the batched `.claude/references/` set). A SessionStart hook and a preamble in every command suggest running it when the workspace is stale. |
| `/vnext-ai-toolkit:new-component <type> <key> [desc]` | Scaffolds a component end-to-end through the agent pipeline. `<type>` ∈ `schema\|workflow\|task\|view\|function\|extension`. |
| `/vnext-ai-toolkit:vnext-design-process [name]` | Multi-turn, end-to-end workflow design via the `vnext-architect` orchestrator (discovery → states → components → tests). |
| `/vnext-ai-toolkit:validate` | Runs `npm run validate`, summarizes failures by file with the violated schema rule, and offers to fix. |
| `/vnext-ai-toolkit:review-components [type\|key]` | Full audit with hierarchical sub-agents: dispatches main `reviewer` & `security-reviewer` per workflow/function, each spawning sub-agents for sub-components. Empty = all workflows & functions; `workflow`/`function` = that type only; `key` = that component + closure. |
| `/vnext-ai-toolkit:build [runtime\|reference] [flags]` | Builds the domain package via `npm run build` / `build:reference`. |
| `/vnext-ai-toolkit:e2e [workflow\|--all]` | Runs the integration tests end to end. Default: Testcontainers pinned to `runtimeVersion`; asks whether you already run a local runtime and, if so, its port. Preflight, `npm run validate`, `dotnet test`, failure triage, `TEST-SCENARIOS.md` row and `.claude/vnext-e2e.json` stamp. |
| `/vnext-ai-toolkit:domain-check [root] [--config f]` | Read-only runtime-cost audit; scanner + verified findings + triage, then a Turkish report. Never edits components, commits or pushes. |
| `/vnext-ai-toolkit:report-issue [short description]` | Triages a suspected runtime problem (known gaps, live vnext-meta, docs, domain-side causes), then drafts a redacted English issue for `burgan-tech/vnext` and files it only after approval. |
| `/vnext-ai-toolkit:security-audit [scope]` | Runs the four-phase OWASP-inspired security review (recon → hunt → verify → report) and writes `security-report/SECURITY-REPORT.md` with confidence-scored, CWE/OWASP-referenced findings. Empty = full audit; `changed`/`diff` = delta review; `key` = that component + closure. |

## Design philosophy

### Schema-first

The single most important rule: **no hardcoded enums, no assumed required fields, no guessed JSON shapes**. Before authoring or editing a component, agents and skills read the authoritative schema from the version pinned in your project:

```
node_modules/@burgan-tech/vnext-schema/schemas/<component>-definition.schema.json
```

When the schema or platform behavior isn't clear from the local schema and existing components, the knowledge access order is: pinned local schema → live `vnext-meta` from vnext master → Context7 MCP (`/burgan-tech/vnext-docs`, `/burgan-tech/vnext-example`) → `WebFetch` of the vnext-docs site. A docs claim that contradicts the pinned schema does not win — the schema does; a contradiction that is the runtime's goes to `/vnext-ai-toolkit:report-issue`.

### Domain-agnostic

The plugin doesn't assume a domain name. It reads `domain` and `paths.*` from `vnext.config.json` and resolves every component folder from there. It works the same in `payments`, `lending`, `core`, or any other domain.

### Schema-driven, schema-validated

Components are authored to pass `npm run validate` on the first try — because the author and the validator share one source of truth, the pinned `@burgan-tech/vnext-schema`.

## What you'll have after `/vnext-ai-toolkit:new-component workflow <key>`

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
├── .claude-plugin/
│   ├── plugin.json                   # Manifest (agents / skills / commands / references)
│   └── marketplace.json              # Marketplace entry (install via burgan-tech)
├── agents/                           # 8 agents
│   ├── analyst.md  architect.md  component-author.md
│   ├── validator.md  reviewer.md  security-reviewer.md  doc-writer.md
│   └── vnext-architect.md            # multi-turn end-to-end design orchestrator
├── skills/                           # 14 skills
│   ├── authoring-vnext-components/SKILL.md   # core reference skill
│   ├── workflow-scaffold/  view-design/  schema-design/
│   ├── component-task/  component-function/  component-extension/  component-mapping/
│   ├── integration-test/  e2e-local/  validate-and-fix/  security-audit/
│   └── domain-check/ (SKILL + CHECKS + scan.py)  report-runtime-issue/
├── commands/                         # 11 slash commands
│   ├── vnext-init.md  vnext-update.md  new-component.md  vnext-design-process.md
│   ├── validate.md  review-components.md  build.md  security-audit.md
│   └── e2e.md  domain-check.md  report-issue.md
├── hooks/                            # SessionStart staleness check (toolkit version + runtime version)
│   └── hooks.json  check-toolkit-version.sh
├── references/                       # Runtime knowledge — single source; a subset is copied into
│   │                                 #   workspaces per plugin.json → vnext.workspaceReferences[]
│   ├── concepts/                     # workflow-types, transition-pipeline, task-types, fan-out,
│   │                                 #   state-function-response, long-poll-interaction, human-task,
│   │                                 #   subflow-overrides, roles-and-authorization, instance-query,
│   │                                 #   incidents-and-retry, runtime-operations, observability,
│   │                                 #   schema-runtime-gaps, csx-contracts, field-protection,
│   │                                 #   file-fields, schema-vocabularies, ...
│   ├── runtime-feature-matrix.md     # GENERATED offline snapshot of vnext-meta (scripts/sync-vnext-meta.sh)
│   ├── decision-tree.md  external-sources.md
│   └── view-author-guide.md  function-mapping-pattern.md  mocklab-seed-format.md
├── templates/                        # Rendered files only ({{domain}} etc. placeholders)
│   │                                 #   base project comes from @burgan-tech/vnext-template;
│   │                                 #   integration tests from VNext.Testing.Template
│   ├── CLAUDE.md.tmpl                # rendered twice → CLAUDE.md and AGENTS.md
│   ├── docker-compose.yml.tmpl  .gitignore.tmpl  .http.tmpl
│   ├── etc/{docker,dapr,runtime}/... # incl. the local blob-storage binding overlay
│   └── tests/...                     # WorkflowTestBase, runsettings, TEST-SCENARIOS checklist
├── scripts/
│   ├── sync-vnext-meta.sh            # regenerate the feature matrix + known versions (from vnext master)
│   ├── vnext-meta-live.sh            # print one vnext-meta file live from vnext master (cached, offline fallback)
│   ├── e2e-preflight.sh  check-test-coverage.sh  test-domain-check.sh
│   ├── lint-references.sh            # stale-fact + manifest/link lint (CI)
│   └── check-prerequisites.sh
└── .github/workflows/                # ci.yml (lint + validate on PRs), publish-plugin.yml (release-v*)
```

## Updating runtime knowledge

When a new vNext runtime ships:

1. Run `scripts/sync-vnext-meta.sh` — it reads `vnext-meta` from vnext master (`--from <dir>` or
   `--npm` also work; the npm package can lag behind master). Review the diff of
   `references/runtime-feature-matrix.md` — new `since` rows, deprecations, migrations and known
   issues are the to-do list. The release posts under vnext-docs `blog/` map PRs to versions.
2. Update the hand-written references under `references/concepts/` for anything that changed
   behaviour; mirror author-facing rules into the skills/agents and, briefly, `templates/CLAUDE.md.tmpl`.
3. Add or adjust `<!-- lint:allow -->`-free wording and run `scripts/lint-references.sh`; fix every
   FAIL. Then `claude plugin validate .`.
4. Record the change in `CHANGELOG.md` (state the runtime/schema versions covered) and release by
   merging into `release-v0.0` — the publish workflow bumps the patch version and tags it.

Manual smoke test after structural changes: run `/vnext-init` into a scratch directory and check
that `.claude/references/` contains one file per `workspaceReferences` entry, `diff CLAUDE.md AGENTS.md`
shows only lines 1/4/6, `.claude/vnext-toolkit.json` lists every written file, and no `{{` placeholder
survived in `CLAUDE.md`. Point `CLAUDE_PLUGIN_ROOT` at the checkout and run
`hooks/check-toolkit-version.sh` there with an older `runtimeVersion` to see the runtime warning.

## Compatibility

| AI agent | Status |
|----------|--------|
| Claude Code | Primary target |
| Codex (via `AGENTS.md`) | Supported — every `CLAUDE.md` is mirrored to `AGENTS.md` |
| Cursor (`.cursor/rules/*.mdc`) | Planned |

Skills read enum values from whatever `@burgan-tech/vnext-schema` version your project pins in `package.json`. Behavioural knowledge (what a task type does, how `updateData` or `authorize` behave) lives in `references/` and is tied to the runtime version in `plugin.json` → `vnext.knownRuntimeVersion`; the SessionStart hook warns when a workspace targets a different runtime, and `references/runtime-feature-matrix.md` says since which version each feature exists.

## Related repos

- [`burgan-tech/vnext-example`](https://github.com/burgan-tech/vnext-example) — Reference domain with working examples of every component type.
- [`burgan-tech/vnext-docs`](https://github.com/burgan-tech/vnext-docs) — Official documentation portal ([browse online](https://burgan-tech.github.io/vnext-docs/)).
- [`burgan-tech/vnext-schema`](https://github.com/burgan-tech/vnext-schema) — Canonical JSON Schemas + vocabularies (this plugin's contract source).
- [`burgan-tech/mocklab`](https://github.com/burgan-tech/mocklab) — Mock API used for HTTP task development.
- [`burgan-tech/vnext-integration-test`](https://github.com/burgan-tech/vnext-integration-test) — Integration testing SDK + `dotnet new vnext-integration-test` project template ([Getting Started](https://github.com/burgan-tech/vnext-integration-test/blob/master/GETTING_STARTED.md)).

## License

MIT — see [LICENSE](./LICENSE).

## Contributing

Issues and PRs welcome. When proposing a new skill or agent, or extending an existing one:

1. Confirm the change respects the schema-first rule (read the pinned schema, never hardcode enums).
2. Add or update the relevant `references/concepts/*.md` if a new concept is introduced.
3. Update `CHANGELOG.md`.
