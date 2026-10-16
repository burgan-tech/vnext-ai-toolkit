---
name: vnext-init
description: Set up or refresh a vNext workspace. If none exists, scaffolds the base project with the official @burgan-tech/vnext-template CLI (via npx); then checks & revises the toolkit's value-add layer (CLAUDE.md, AGENTS.md, docker-compose + mocklab, .claude/references, .http API tests, integration tests) and offers to bump runtimeVersion/schemaVersion. Diffs before overwriting — nothing happens silently.
allowed-tools: Bash(npm install *), Bash(npm run *), Bash(npm run setup:*), Bash(node setup.js:*), Bash(npm run sync-schema), Bash(npm run validate), Bash(*/scripts/check-prerequisites.sh*), Bash(*/scripts/check-test-coverage.sh*), Bash(dotnet --list-sdks), Bash(dotnet new *), Bash(dotnet add *), Bash(dotnet build *), Bash(docker info*), Bash(mkdir *), Read, Write, WebFetch
---

# /vnext-init

Set up or refresh a vNext workspace. The base project (`vnext.config.json`, `package.json`, the six
component folders, `.github`, `.vscode`, `.gitignore`) is owned by the **official vNext scaffolder**,
`@burgan-tech/vnext-template`. This command delegates that scaffolding to the CLI and then layers on
the toolkit's value-add files (CLAUDE.md, docker-compose + mocklab, integration tests, …).

Run `${CLAUDE_PLUGIN_ROOT}/scripts/check-prerequisites.sh` first: node/npm/git missing → stop;
Docker / docker compose / .NET 10 missing → **warning** only (authoring works; the test project can be
scaffolded but `/vnext-ai-toolkit:e2e` cannot run yet).

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
After a `runtimeVersion` bump: the toolkit test environment reads the image tag from
`vnext.config.json`, so the next `/vnext-ai-toolkit:e2e` runs the new runtime; the e2e stamp (G4) turns
stale until it does.

## Steps 3+ — Layer / revise the toolkit-owned files

These files are **not** produced by the CLI; they are the toolkit's value-add. For each one: resolve
its target path, render the matching `${CLAUDE_PLUGIN_ROOT}/templates/*.tmpl` (the templates live in
the **plugin's install directory**, never in the workspace) by substituting ONLY these placeholders:
`{{domain}}` and `{{workflowKey}}` from `vnext.config.json`; `{{Domain}}` = PascalCase of `domain`
(`my-domain` → `MyDomain`; used by `docker-compose.yml`, `etc/runtime/**` and `templates/tests/**`); `{{toolkitVersion}}` from
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
- `docker-compose.yml` ← `${CLAUDE_PLUGIN_ROOT}/templates/docker-compose.yml.tmpl` — MockLab
  `0.0.10` + `mocklab-dapr` (daprd `1.18.0`), both pinned and overridable (`MOCKLAB_VERSION`,
  `DAPR_RUNTIME_VERSION`); joins the external network `${VNEXT_NETWORK:-vnext-development}` (the
  vnext-runtime network) with alias `mocklab`.
- `etc/docker/config/seed/{domain}-collection.json` ← `${CLAUDE_PLUGIN_ROOT}/templates/etc/docker/config/seed/example-collection.json`.
- `etc/dapr/config.yaml` ← `${CLAUDE_PLUGIN_ROOT}/templates/etc/dapr/config.yaml.tmpl` **and**
  `etc/dapr/components/.gitkeep` ← `${CLAUDE_PLUGIN_ROOT}/templates/etc/dapr/components/.gitkeep`
  (daprd fails when its `--resources-path` folder is missing). Dapr is optional — offer to skip both.
- **Optional** `etc/docker/config/seed/morph-idm-roles-collection.json` ←
  `${CLAUDE_PLUGIN_ROOT}/templates/etc/docker/config/seed/morph-idm-roles-collection.json` — only if the
  user will test the `morph-idm` caller-role provider (ask; default no).
- **Only if a master schema declares `x-storage`** (grep the schemas folder for `"x-storage"`): the
  local blob overlay for vnext-runtime — `etc/runtime/dapr/components/<binding>.yaml` (one per distinct
  `binding`, from `templates/etc/runtime/dapr/components/vnext-blob-local.yaml.tmpl` with `metadata.name`
  set to the binding), `etc/runtime/docker-compose.blob.override.yml`, `etc/runtime/README.md`, and
  `data/blobs/` in `.gitignore`. Explain in one line: it is applied with `-f` on top of vnext-runtime's
  compose and never edits vnext-runtime.
- Task URLs: tell the user HTTP tasks use the `API_BASEURL` placeholder + `GetConfigValue("{Domain}:ApiBaseUrl", …)`
  (`.claude/references/mocklab-seed-format.md` §8) — `localhost:3001` works only from the host.
- Warn about port conflicts (3001 MockLab, 3500 Dapr, 4201 runtime, 3005 vnext-runtime init).
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

### 7 — Integration test project (default: yes)
Integration tests are expected for every workflow (warn-only gates G1–G4). If no `*.csproj` references
`VNext.Testing.Sdk`, scaffold one **by default**; the user may skip — then say once:
"**Warning:** no integration test project — validate/review will report G1/G2 warnings".

1. `.NET 10 SDK` (`dotnet --list-sdks`) — missing → warn and skip the scaffold (offer again later via
   the `integration-test` skill). Docker is needed only to run, not to scaffold.
2. Official template, pinned (GETTING_STARTED's `1.0.0` is not published on nuget.org):
   ```bash
   dotnet new install VNext.Testing.Template::0.0.6
   cd tests && dotnet new vnext-integration-test --DomainName {Domain} --AppDomain {domain} --SdkVersion 0.0.6
   cd {Domain}.IntegrationTests && dotnet add package Xunit.SkippableFact
   ```
3. Toolkit layer — render `${CLAUDE_PLUGIN_ROOT}/templates/tests/*.tmpl` (`{{domain}}`, `{{Domain}}`),
   diffing any file the template already generated:
   `Infrastructure/VNextTestEnvironment.cs` (image tag = `runtimeVersion`, daprd 1.18.0 / MockLab 0.0.10,
   workspace seeds, system package `@burgan-tech/vnext-core-runtime`, `{Domain}__ApiBaseUrl`, optional
   morph-idm), `Infrastructure/WorkflowTestBase.cs`, `Infrastructure/OptionalDomainEndpoint.cs`,
   `test.runsettings` (`VNEXT_BASE_URL` commented → Testcontainers), `TEST-SCENARIOS.md` at the workspace
   root, missing `.gitignore` lines from `gitignore.tmpl`, and — if a master schema has `x-storage` —
   `Infrastructure/DaprComponents/orchestration/<binding>.yaml`. `test.runsettings.local` is **not**
   written here (only `/vnext-ai-toolkit:e2e` local mode writes it, after approval).
4. `dotnet build tests/{Domain}.IntegrationTests -v q` — report the result (a failure is a warning).
5. Existing workflows without a test class: list them
   (`${CLAUDE_PLUGIN_ROOT}/scripts/check-test-coverage.sh`, G2 lines) and offer the `integration-test`
   skill for each.

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
    "etc/dapr/components/.gitkeep",
    "etc/runtime/docker-compose.blob.override.yml   // only when written (x-storage)",
    "tests/{Domain}.IntegrationTests/Infrastructure/WorkflowTestBase.cs   // and the other templates/tests files written",
    "TEST-SCENARIOS.md",
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
  /vnext-ai-toolkit:e2e --all          # integration tests: Testcontainers pinned to runtimeVersion (default),
                                       # or your running vnext-runtime / Forge on :4201 if you say so
  docker compose up -d mocklab         # with a local runtime: MockLab on the vnext-development network
  ```
- Warnings: e2e prerequisites missing, test project skipped, workflows without tests (G1/G2).
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
  official `npx` and `dotnet new` templates), builds the test project once, and writes the toolkit's
  layer files. Running the tests is `/vnext-ai-toolkit:e2e`.
- It never edits or runs anything from the vnext, vnext-example or vnext-runtime repositories.
- It does not overwrite toolkit-owned files silently — it diffs and asks per file first.
- It does not configure git or set up CI — those are workspace-specific decisions.
