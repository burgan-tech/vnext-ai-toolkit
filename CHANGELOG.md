# Changelog

All notable changes to the vNext AI Toolkit will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Plugin uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Transition admission & locking documentation (v0.0.79, vnext PR #877 — Busy-as-mutex).** New
  `workflow-types.md` § 3.1: the Busy status is the execution mutex; normal shared/state transitions
  **409 while Busy**, `cancel`/`exit` hold the status lock but **bypass the busy check**, and
  **`updateData` bypasses all lock/busy checks** (status-neutral reserve transition) — the only way
  to write data and advance an instance under parallel requests. `updateData` semantics per
  situation: plain instance → data write + normal pipeline (advances the flow); active subflow →
  the **parent answers** (no forwarding, parent data updated, flow left in place, autos still
  evaluated). Design guidance for parallel branches, fan-in states, and loops (409 handling, when
  to add an `updateData` definition, distinct task definitions per parallel branch at the same
  order, two data rows per accepted updateData) baked into the `workflow-scaffold` skill, the
  `architect`/`vnext-architect` transition steps, and the CLAUDE/AGENTS templates.
- **Delta-only mapping rule** added to the csx-contracts golden rules (and templates copy): under
  the v0.0.79 immediate-persistence write model, `ScriptResponse.Data` must contain only changed
  fields — a full instance-data echo overwrites concurrent writers' fresher values.

- **Function mode decision — BFF API vs BFF View, confirm-first.** Functions now have an explicit
  two-mode model across the design surface: a **BFF API** (pure programmatic endpoint — verbs +
  schemas, no view fields) or a **BFF View** (stateless single input→output page — the function
  declares `inputView`/`outputView` itself). The `vnext-architect` Phase 1 discovery and the
  `architect` agent gained a "Function gate": when the user describes a stateless single page or
  pure API need, they propose a **Function instead of a workflow** and ask for confirmation. The
  `component-function` skill now settles the mode with the user in step 2 (no view need → design
  like an API; view fields only on confirmed view need) and drives the contract step from it.
  Also reflected in `references/decision-tree.md` (new early branch + split M2/M3 leaves),
  `function-vs-extension-vs-task.md`, `function-mapping-pattern.md` § 9, and the CLAUDE/AGENTS
  templates.

- **`/vnext-update` command** — refreshes the toolkit-owned workspace files (CLAUDE.md, AGENTS.md,
  the four `.claude/references/` guides, docker-compose, dapr config) after a plugin update:
  reads the installed plugin version from `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`,
  compares it with the workspace stamp, then diffs and confirms **per file** (overwrite/skip/merge —
  never silent). Supports `--force` and a legacy path for workspaces with no stamp yet.
- **Workspace version stamp** — `/vnext-init` and `/vnext-update` now write
  `.claude/vnext-toolkit.json` (`toolkitVersion`, `updatedAt`, tracked `files[]`), and the rendered
  CLAUDE.md/AGENTS.md carry an `<!-- vnext-ai-toolkit v{{toolkitVersion}} -->` comment via the new
  `{{toolkitVersion}}` template placeholder.
- **SessionStart staleness hook** (`hooks/hooks.json` + `hooks/check-toolkit-version.sh`) — on
  session start in a vNext workspace, compares the workspace stamp against the installed plugin
  version and injects a non-blocking reminder to run `/vnext-update` (or to update the plugin, when
  the stamp is newer). Silent no-op outside vNext workspaces; always exits 0; no jq dependency.
- **Freshness preamble in commands** — `/new-component`, `/vnext-design-process`, `/validate`,
  `/review-components`, `/build`, `/security-audit` now start with an identical non-blocking check
  that suggests `/vnext-update` when the workspace stamp is missing or older than the plugin.

### Changed

- **`/vnext-init` template paths are now plugin-rooted** (`${CLAUDE_PLUGIN_ROOT}/templates/...`
  instead of ambiguous bare `templates/...`), the placeholder substitution is an explicit allowlist
  (`{{domain}}`, `{{workflowKey}}`, `{{toolkitVersion}}` — REST Client variables like `{{baseUrl}}`
  / `{{apiVersion}}` / `{{instanceId}}` must survive verbatim), and a final step writes the
  `.claude/vnext-toolkit.json` stamp.

- **`csx-contracts.md` rewritten against the runtime source** (`Models.cs`, `ScriptBase.cs`,
  `Scripting/Contracts/*`): the verified `ScriptContext` surface (no `QueryString` — the query string
  is `QueryParameters`; adds `CurrentTransition`, `RawBody`, `EventPayload`, `Incident`,
  `OutputResponse`, `Related`), the dynamic runtime type model (every `dynamic` is an
  `ExpandoObject` / `List<object?>` with camelCase keys; a missing member access **throws**
  `RuntimeBinderException` — `?.` does not guard it), the full `ScriptBase` helper reference
  (`HasProperty`, `GetPropertyValue<T>`, list ops, `CreateObject`/`SetProperty`, XML, logging
  `args:` rule, config & Dapr secrets), and previously missing interfaces (`ISubProcessMapping`,
  `IEventMapping`, `IStateNotificationMapping`). Fixed two wrong method names: `IOutputHandler`'s
  method is `OutputHandler` (not `Handler`) and `INotificationMapping`'s is `ChannelHandler`.
- **All `.csx` skeletons and examples** (component-function / component-extension / component-task
  skills, mapping-types, function-mapping-pattern, CLAUDE/AGENTS templates) now inherit `ScriptBase`
  and read dynamic data via `HasProperty` / `GetPropertyValue` instead of direct dynamic access;
  the reflection-based `ResolveParam` (which probed a non-existent `QueryString` property) is gone.
- **`TaskResponse` vs `OutputResponse` vs `Body`** semantics unified across docs (previously
  contradictory): each task's `StandardTaskResponse` is merged into `Body` *and* stored in
  `TaskResponse[taskKey]`; a task's own output-mapping result goes to `OutputResponse[taskKey]`.
- **`sys-mappings` promoted to the primary reuse method** for repeated mapping structures
  (mappings-and-scripts, mapping-types, component-mapping skill, component-author agent, templates).
- **Roles are now confirm-first**: architect/vnext-architect agents, workflow-scaffold skill, and
  roles-and-authorization.md instruct asking the user whether a flow should configure roles at all
  before adding any (default: no roles — they add complexity for vNext newcomers).
- `templates/function-mapping-pattern.md` re-synced with `references/` (it was stale — missing the
  `rawResponse` section) and the duplicate "§ 5" heading fixed.

### Added

- **`context.Related` documentation (v0.0.79+, vnext PR #857)** in csx-contracts + templates:
  `HasParent` / `ParentAsync` / `SubAsync` / `SubsAsync` / `SubKeysAsync`, `RelatedInstanceView`
  fields, `IsCompleted` vs `CorrelationCompleted`, absence-vs-failure semantics, resolution cap,
  x-roles copy warning — and the rule that `Related` is for correlation data only (anything else
  goes through a task).
- **Function BFF contract documentation (vnext PRs #679/#858/#868)**: `verbs[]` (405 + `Allow`),
  `inputSchema` (400 validation), `outputSchema` (declarative), `inputView`/`outputView`
  (rule-based slots, first match wins), `cache`, `/info` + `view|schema?target=` discovery
  endpoints, the "BFF View" stateless-page pattern, and the missing `F` scope semantics —
  in function-mapping-pattern § 9, function-vs-extension-vs-task, component-function skill,
  and the CLAUDE/AGENTS templates.
- **State `interaction.longPoll` documentation** (`terminate`, `fallbackTimeoutSeconds`, `roles`)
  in workflow-types § 2.3 and the templates — the client stop/keep-polling handover signal.
- `csx-contracts.md` added to the `/vnext-init` `.claude/references/` copy list (and to
  `templates/`), so user workspaces carry the interface contracts even without the plugin.

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
- **Security audit workflow** — new `security-audit` skill and `/security-audit` command for
  OWASP-inspired reviews of secrets, authz, injection, SSRF/path traversal, weak crypto,
  dependency issues, and configuration risk, with output written to `security-report/SECURITY-REPORT.md`.
  The audit follows a four-phase pipeline (recon → hunt → verify → report): candidates are
  checked for reachability, existing mitigations, and test/mock context, confidence-scored
  (0–100) with severity capped by confidence, and reported with CWE / OWASP Top 10
  references. The `security-review-checklist.md` reference carries vNext-specific hunt
  patterns (`roles`/`queryRoles`/`x-roles`, `.csx` `ScriptContext` data flow, `allowedHosts`,
  `REF`/`allowedAssemblies` supply chain) and false-positive rules; the `security-reviewer`
  agent follows the same rubric. (Methodology informed by utkusen/sast-skills,
  mfkocalar/OWASP-Security-Skills, and ersinkoc/security-check.)

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
