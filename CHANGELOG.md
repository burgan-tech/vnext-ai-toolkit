# Changelog

All notable changes to the vNext AI Toolkit will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Plugin uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **`/vnext-init` now delegates base scaffolding to the official `@burgan-tech/vnext-template` CLI.**
  When no `vnext.config.json` exists, it runs `npx @burgan-tech/vnext-template <domain>` to create the
  base project (config, `package.json`, component folders) instead of re-implementing it. In an
  existing workspace it skips the CLI and only layers the toolkit's value-add files.
- **Revise-with-diff**: toolkit-owned files (CLAUDE.md, AGENTS.md, docker-compose + mocklab, dapr
  config, `.claude/references`, `.http`/api-tests, integration tests) are now diffed against the
  latest templates and confirmed per file before overwriting — no longer skip-only.
- **Version bump prompt**: `/vnext-init` checks `runtimeVersion`/`schemaVersion` against the latest
  published releases and offers to update `vnext.config.json` (the one CLI-owned file it may edit).
- **Integration tests now use the official `VNext.Testing.Template`.** `/vnext-init` and the
  `integration-test` skill scaffold the test project with `dotnet new vnext-integration-test`
  (`--DomainName`/`--AppDomain`) instead of copying hand-rolled templates. The generated test surface
  is corrected to the real SDK API (`RunTransitionAsync`, `VNextApiResponse.Body`, `GetCurrentState`,
  `[Collection("VNextIntegration")]`, env overrides `Domain`/`DatabaseName`/`VNextImage`, target
  `net10.0`) — the previously documented `ExecuteTransitionAsync`/`WaitForStateAsync`/`GetStateAsync`
  and per-domain collections were inaccurate and have been removed.
- **Removed `urn:amorphie` legacy framing** from the URN docs. vNext is pre-release, so there is no
  legacy scheme — the docs now present `urn:vnext` / `urn:client` directly.

### Removed

- `templates/vnext.config.json.tmpl` and `templates/package.json.tmpl` — produced by
  `@burgan-tech/vnext-template`. The config/package/component-folder scaffolding steps are dropped.
- `templates/tests/*` — the integration test project is now scaffolded by the official
  `VNext.Testing.Template` (`dotnet new vnext-integration-test`).

### Added

- **`.claude-plugin/marketplace.json`** — makes the repo installable as the `burgan-tech`
  marketplace (`claude plugin marketplace add burgan-tech/vnext-ai-toolkit` →
  `claude plugin install vnext-ai-toolkit@burgan-tech`).
- **`.github/workflows/publish-plugin.yml`** — on push to a `release-v*` branch, validates
  the plugin (`claude plugin validate`), auto-increments the patch version, commits the
  bump, tags, and cuts a GitHub Release. Manual `workflow_dispatch` supports an explicit
  version and a dry run.

### Changed

- **Restructured around a multi-agent pipeline.** Replaced the single `vnext-architect`
  orchestrator with seven specialized agents — `analyst`, `architect`, `component-author`,
  `validator`, `security-reviewer`, `doc-writer`, and `reviewer` — wired together by the
  commands (analyst → architect → component-author → validator → security-reviewer +
  doc-writer in parallel).
- **New command set.** Replaced `/vnext-design-process`, `/vnext-init`, `/vnext-validate`
  with `/new-domain`, `/new-component`, `/validate`, and `/build`, aligned to the
  `@burgan-tech/vnext-template` project lifecycle (`npm run setup` / `validate` / `build`).
- **Added the `authoring-vnext-components` skill** as the core reference (component
  envelope, type-specific `attributes`, `.csx` `scriptCode` shape, transition triggers,
  validate-fix loop), alongside the eight focused authoring skills.
- **Schema source is now the pinned npm package.** Components are authored against
  `node_modules/@burgan-tech/vnext-schema/schemas/*.json` (the version pinned in the
  project's `package.json`), with Context7 MCP / `WebFetch` for docs — replacing the
  raw-GitHub-tag fetch chain.
- Rewrote `README.md` to match the new structure.

## [0.1.0] — initial release

### Added

- **Plugin manifest** (`.claude-plugin/plugin.json`) — Claude Code Plugin format with manifest pointing at agents, skills, commands, and references.
- **`vnext-architect` subagent** — multi-turn orchestrator that walks users through Discovery → Flow Architecture → Component Design → Workflow Assembly → Test & Validate phases. Enforces the canonical schema-first rule.
- **Eight skills**:
  - `workflow-scaffold` — state machine + transitions + `.csx` mappings + `.http` test file
  - `view-design` — renderer choice + pseudo-UI vocabulary loading + view tree generation
  - `schema-design` — interactive field gathering with localization and role-based access
  - `component-task` — task type from schema + per-type config + MockLab seed matching
  - `component-function` — scope D/I + single/multi-task composition + `IMapping`/`IOutputHandler` `.csx`
  - `component-extension` — type × scope matrix from schema + performance warnings
  - `integration-test` — xUnit class generation against `VNext.Testing.Sdk`
  - `validate-and-fix` — `npm run validate` interpretation with canonical-schema-cited fix proposals
- **Three slash commands**: `/vnext-design-process` (dispatch architect), `/vnext-init` (9-step workspace bootstrap with integration tests), `/vnext-validate` (shortcut to validate-and-fix).
- **Reference knowledge base** (`references/`):
  - Eight concept docs: `workflow-types`, `view-roles`, `function-vs-extension-vs-task`, `mapping-types`, `csx-contracts`, `schema-vocabularies`, `component-schemas`, `mocklab-spec`, `integration-test-patterns`
  - `decision-tree.md` — full Mermaid diagram and per-phase question summaries
  - `external-sources.md` — every upstream URL the plugin may fetch + version-tag rule
  - Three ported pattern guides: `view-author-guide`, `function-mapping-pattern`, `mocklab-seed-format`
- **Bootstrap templates** (`templates/`): `vnext.config.json`, `package.json`, `docker-compose.yml`, `etc/dapr/config.yaml`, `etc/docker/config/seed/example-collection.json`, `.gitignore`, `CLAUDE.md`, `AGENTS.md`, `.http`, full integration test scaffold (`{{Domain}}.IntegrationTests.csproj`, `Infrastructure/`, `SmokeTests`, `test.runsettings` + `.local.example`).
- **Prerequisite check script** (`scripts/check-prerequisites.sh`).

### Design principle

**Canonical schema-first**: every scaffolding skill fetches the matching JSON Schema from [`burgan-tech/vnext-schema`](https://github.com/burgan-tech/vnext-schema/tree/master/schemas) at the workspace's `schemaVersion` tag before asking the user anything. Enum values, required fields, and JSON shapes come from the schema — never from hardcoded tables in the plugin. Fallback chain: `v{schemaVersion}` tag → `master` branch → in-repo snapshot → halt and ask user.

### Notes

- Plugin compatibility tags: `claude-code` (primary), `codex` (via mirrored `AGENTS.md`). Cursor support planned.
- `VNext.Testing.Sdk` is pinned to `0.0.3` in the template; adjust to match the workspace's `runtimeVersion`.
- The `bbt-development` Docker network must exist before `docker compose up` — `docker network create bbt-development`.
