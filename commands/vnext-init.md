---
name: vnext-init
description: Set up or refresh a vNext workspace. If none exists, scaffolds the base project with the official @burgan-tech/vnext-template CLI (via npx); then checks & revises the toolkit's value-add layer (CLAUDE.md, AGENTS.md, docker-compose + mocklab, .claude/references, .http API tests, integration tests) and offers to bump runtimeVersion/schemaVersion. Diffs before overwriting — nothing happens silently.
allowed-tools: Bash(npm install *), Bash(npm run *), Bash(npm run setup:*), Bash(node setup.js:*), Bash(npm run sync-schema), Bash(npm run validate), Read, Write, WebFetch
---

# /vnext-init

Set up or refresh a vNext workspace. The base project (`vnext.config.json`, `package.json`, the six
component folders, `.github`, `.vscode`, `.gitignore`) is owned by the **official vNext scaffolder**,
`@burgan-tech/vnext-template`. This command delegates that scaffolding to the CLI and then layers on
the toolkit's value-add files (CLAUDE.md, docker-compose + mocklab, integration tests, …).

## Step 0 — Detect mode

Inspect the working directory:

- **`vnext.config.json` present → Mode A (existing workspace).** Workspace root = cwd. Read
  `domain`, `paths.*`, `runtimeVersion`, `schemaVersion` from it. **Do not run the CLI.** Go to
  Step 2.
- **No `vnext.config.json`, no `package.json`, dir is clean → Mode B (new workspace).** Go to Step 1.
- **No `vnext.config.json` but a `package.json` exists → ambiguous.** The official CLI refuses to
  scaffold over an existing `package.json`. Warn the user and ask (AskUserQuestion) whether to:
  (a) treat this as an existing workspace and just layer the toolkit files (Step 2 onward), or
  (b) point at a different empty path for a fresh scaffold (Mode B in that path).

## Step 1 (Mode B only) — Scaffold the base project with the official CLI

1. Ask for the **target path** (default: current directory) and the **domain** name (kebab-case;
   must match `^[a-zA-Z0-9_-]+$`).
2. Run the official scaffolder in the target path:
   ```bash
   npx @burgan-tech/vnext-template <domain>
   ```
   This writes the root files (`vnext.config.json`, `package.json`, `build.js`/`validate.js`/…,
   `.gitignore`, `.gitattributes`) into the target path, and the component folders
   (`Tasks/ Views/ Workflows/ Schemas/ Functions/ Extensions/`) into a `<domain>/` subdir
   (`paths.componentsRoot`). It **aborts** if `<domain>/` or `package.json` already exists — so the
   target path must be clean.
3. The workspace root is now the target path. Read the generated `vnext.config.json` for `domain`,
   `paths.*`, `runtimeVersion`, `schemaVersion`. Continue to Step 2.

> Do **not** re-create `vnext.config.json`, `package.json`, or the component folders by hand — the
> CLI is the single source of truth for those.

## Step 2 — Version check (both modes)

`vnext.config.json` now exists. Compare its `runtimeVersion` / `schemaVersion` with what the toolkit
**knows** (offline, deterministic) and, optionally, with what is **published**:

1. **Known versions** — `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` → `.vnext.knownRuntimeVersion`
   and `.vnext.knownSchemaVersion`. These are the runtime/schema the toolkit's references, skills and
   `references/runtime-feature-matrix.md` describe. A workspace **below** them cannot use every
   feature the toolkit will suggest (check `since` in the matrix); a workspace **above** them means
   the toolkit itself is behind — say so and suggest `claude plugin marketplace update burgan-tech`.
2. **Published versions** (only if network is available and the user wants "latest"):
   - `schemaVersion` — latest release of `burgan-tech/vnext-schema`
     (`gh api repos/burgan-tech/vnext-schema/releases/latest`, or the releases page).
   - `runtimeVersion` — latest `@burgan-tech/vnext-meta` on npm (`npm view @burgan-tech/vnext-meta version`;
     the package version tracks the runtime release) or the runtime image tag.

If either value in `vnext.config.json` differs, use `AskUserQuestion` to ask whether to update each
— offer the **known** version as "(Recommended)" and the published one as an alternative when it is
newer. **Only edit `vnext.config.json` on confirmation.** This is the only place this command touches
the CLI-owned config. `runtimeVersion` and `schemaVersion` must stay a pair that appears together in
the matrix's "Runtime → schema versions" table.

## Steps 3+ — Layer / revise the toolkit-owned files

These files are **not** produced by the CLI; they are the toolkit's value-add. For each one: resolve
its target path, render the matching `${CLAUDE_PLUGIN_ROOT}/templates/*.tmpl` (the templates live in
the **plugin's install directory**, never in the workspace) by substituting ONLY these placeholders:
`{{domain}}` and `{{workflowKey}}` from `vnext.config.json`; `{{toolkitVersion}}` from
`${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` → `.version` and `{{knownRuntimeVersion}}` from
`.vnext.knownRuntimeVersion`; and the agent-file pair `{{agentFile}}` / `{{agentAudience}}` /
`{{peerFile}}` / `{{peerAudience}}` (values in Step 3).

> **Placeholder allowlist — do not blanket-replace `{{...}}`.** Tokens like `{{baseUrl}}`,
> `{{apiVersion}}`, `{{instanceId}}`, `{{start.response.body.$.id}}` in `.http` content are VS Code
> REST Client variables and must survive verbatim.

Then:

- **Missing** → offer to create it (default: yes).
- **Already exists** → **diff** the existing file against the rendered template, show what differs,
  and ask per file whether to **overwrite**, **skip**, or merge. **Never overwrite silently.**

### 3 — `CLAUDE.md` and `AGENTS.md` (one template, rendered twice)
Both come from `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md.tmpl`; there is no separate AGENTS template.
Render it twice with these fixed placeholder sets (everything else identical):

| Target | `{{agentFile}}` | `{{agentAudience}}` | `{{peerFile}}` | `{{peerAudience}}` |
|---|---|---|---|---|
| `CLAUDE.md` | `CLAUDE.md` | `Claude Code (claude.ai/code)` | `AGENTS.md` | `Codex` |
| `AGENTS.md` | `AGENTS.md` | `Codex (and any AGENTS.md-compatible agent)` | `CLAUDE.md` | `Claude Code` |

If only one of the two exists, offer to create the other. The bodies are identical by construction;
`diff CLAUDE.md AGENTS.md` must show only lines 1, 4 and 6.

### 4 — `docker-compose.yml` + MockLab seed + Dapr config
- `docker-compose.yml` ← `${CLAUDE_PLUGIN_ROOT}/templates/docker-compose.yml.tmpl` (MockLab + `mocklab-dapr` sidecar).
- `etc/docker/config/seed/{domain}-collection.json` ← `${CLAUDE_PLUGIN_ROOT}/templates/etc/docker/config/seed/example-collection.json`.
- `etc/dapr/config.yaml` ← `${CLAUDE_PLUGIN_ROOT}/templates/etc/dapr/config.yaml.tmpl` (Dapr is optional — offer to skip).
- Warn about port conflicts (3001 MockLab, 3500 Dapr, 4201 runtime).
- Remind: after editing seed files later, run `docker compose down -v && docker compose up -d mocklab`
  to force a re-import (MockLab skips collections that already exist by name).

### 5 — `.claude/references/` — runtime knowledge copied into the workspace
Read the list `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` → `.vnext.workspaceReferences[]`
(plugin-relative paths such as `references/concepts/task-types.md`). Copy **each** file verbatim (no
substitution) to `.claude/references/<basename>` so the AI has in-repo runtime context even if the
plugin is uninstalled. Do not hard-code the list here — the manifest is the single source. The set
covers: `.csx` contracts, function mapping pattern, MockLab seed format, view author guide, workflow
types, transition pipeline / `updateData`, roles & `authorize`, component choice, schema vocabularies,
mapping types, task types 1–23, FanOut, state function response, long-poll `interaction`, human task,
subflow `overrides`, instance query / `x-indexed`, incidents & retry, observability, runtime operations,
schema↔runtime gaps, and the generated runtime feature matrix.

Since the set is large, ask **once** ("copy N reference guides into `.claude/references/`?") rather
than once per file. Existing files that differ are handled like any other toolkit-owned file (diff,
then overwrite/skip) — but batch the question: "M of N differ — update all / review one by one / skip".

### 6 — `api-tests/` + `.http`
If missing, create `api-tests/` with a `.gitkeep` and a short README pointing at
`${CLAUDE_PLUGIN_ROOT}/templates/.http.tmpl` (the per-workflow REST Client file pattern; uses
`{{domain}}` / `{{workflowKey}}` — all other `{{...}}` tokens are REST Client variables, keep them).

### 7 — Integration test scaffold (recommended)
If no `*.IntegrationTests.csproj` exists (typically under `tests/`), ask:

> "Set up an integration test project? vNext best practice is to verify each workflow's lifecycle
> (start → transitions → final state) with the official `VNext.Testing.Sdk`. **(Recommended)**"

If yes, scaffold with the **official dotnet template** (the toolkit no longer hand-rolls these files):
- Check `dotnet --version` (needs the **.NET 10 SDK**) and a running Docker Desktop; warn if missing.
- Determine `{Domain}` (PascalCase of `{domain}`).
- Install the template once, then scaffold inside `tests/`:
  ```bash
  dotnet new install VNext.Testing.Template
  cd tests
  dotnet new vnext-integration-test --DomainName {Domain} --AppDomain {domain}
  ```
  This generates `tests/{Domain}.IntegrationTests/` with `Config/`, `Infrastructure/`
  (fixtures + `DaprComponents/` + `MocklabSeed/`), `Helpers/TestDataBuilder.cs`, `Tests/SmokeTests.cs`,
  and `test.runsettings`.
- Remind: `dotnet test` runs the suite (Testcontainers manages the Docker stack). If `VNext.Testing.Sdk`
  / the template fails to resolve, see
  `https://github.com/burgan-tech/vnext-integration-test/blob/master/GETTING_STARTED.md`.

### 8 — Version stamp (always, last)

Write `.claude/vnext-toolkit.json` so `/vnext-update` and the plugin's session hook can detect
staleness later (create `.claude/` if needed):

```json
{
  "toolkitVersion": "<version from ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json>",
  "knownRuntimeVersion": "<.vnext.knownRuntimeVersion from the same manifest>",
  "updatedAt": "<today, YYYY-MM-DD>",
  "files": [
    "CLAUDE.md",
    "AGENTS.md",
    "docker-compose.yml",
    "etc/dapr/config.yaml",
    ".claude/references/<basename>   // one entry per workspaceReferences item actually written"
  ]
}
```

List only the files that actually exist after this run. The rendered CLAUDE.md/AGENTS.md already
carry the matching `<!-- vnext-ai-toolkit vX.Y.Z -->` comment via `{{toolkitVersion}}`.

## Final report

- **Mode B**: note the `npx @burgan-tech/vnext-template <domain>` command that ran and where the
  project landed.
- List **created / revised / skipped** files (with the reason for each skip — existed and declined,
  missing dependency, user skipped).
- Show next-step commands:
  ```bash
  npm install
  dotnet test tests/{Domain}.IntegrationTests   # if tests scaffolded (Testcontainers + .NET 10 SDK)
  docker compose up -d mocklab                   # if you'll develop with mocked endpoints
  ```
- If `runtimeVersion` in `vnext.config.json` is below the toolkit's `knownRuntimeVersion`, say which
  it is and point at `.claude/references/runtime-feature-matrix.md` for the features that are not
  available on that runtime.
- Suggest: `/vnext-design-process "<your first workflow name>"` to start designing.
- Remind: after updating the plugin later (`claude plugin marketplace update burgan-tech`), run
  **`/vnext-update`** to refresh these toolkit-owned files.

## What this command does NOT do

- It does not re-implement the base scaffold — `vnext.config.json`, `package.json`, and the component
  folders come from `@burgan-tech/vnext-template`.
- It does not run `npm install`, `dotnet test`, or `docker compose up` — it only scaffolds (via the
  official `npx` and `dotnet new` templates) and writes the toolkit's layer files.
- It does not overwrite toolkit-owned files silently — it diffs and asks per file first.
- It does not configure git or set up CI — those are workspace-specific decisions.
