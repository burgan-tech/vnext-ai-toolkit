# Changelog

All notable changes to the vNext AI Toolkit will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Plugin uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
