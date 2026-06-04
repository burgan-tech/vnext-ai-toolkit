---
name: vnext-init
description: Set up or refresh a vNext workspace. If none exists, scaffolds the base project with the official @burgan-tech/vnext-template CLI (via npx); then checks & revises the toolkit's value-add layer (CLAUDE.md, AGENTS.md, docker-compose + mocklab, .claude/references, .http API tests, integration tests) and offers to bump runtimeVersion/schemaVersion. Diffs before overwriting — nothing happens silently.
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

`vnext.config.json` now exists. Look up the latest published versions:

- `schemaVersion` — latest release of `burgan-tech/vnext-schema`
  (`gh api repos/burgan-tech/vnext-schema/releases/latest`, or the releases page).
- `runtimeVersion` — latest `BBT.Workflow.Scripting` on NuGet (and/or the runtime image tag).

If either differs from the values in `vnext.config.json`, use `AskUserQuestion` to ask whether to
update each (mark "update to latest" as Recommended). **Only edit `vnext.config.json` on
confirmation.** This is the only place this command touches the CLI-owned config.

## Steps 3+ — Layer / revise the toolkit-owned files

These files are **not** produced by the CLI; they are the toolkit's value-add. For each one: resolve
its target path, render the matching `templates/*.tmpl` by substituting `{{domain}}`, `{{Domain}}`
(PascalCase), `{{runtimeVersion}}`, `{{schemaVersion}}`, `{{maintainer}}`, `{{workflowKey}}` from
`vnext.config.json`. Then:

- **Missing** → offer to create it (default: yes).
- **Already exists** → **diff** the existing file against the rendered template, show what differs,
  and ask per file whether to **overwrite**, **skip**, or merge. **Never overwrite silently.**

### 3 — `CLAUDE.md` and `AGENTS.md`
- `CLAUDE.md` ← `templates/CLAUDE.md.tmpl`; `AGENTS.md` ← `templates/AGENTS.md.tmpl` (same content,
  Codex-friendly header). Keep the two mirrored — if only one exists, offer to mirror to the other.

### 4 — `docker-compose.yml` + MockLab seed + Dapr config
- `docker-compose.yml` ← `templates/docker-compose.yml.tmpl` (MockLab + `mocklab-dapr` sidecar).
- `etc/docker/config/seed/{domain}-collection.json` ← `templates/etc/docker/config/seed/example-collection.json`.
- `etc/dapr/config.yaml` ← `templates/etc/dapr/config.yaml.tmpl` (Dapr is optional — offer to skip).
- Warn about port conflicts (3001 MockLab, 3500 Dapr, 4201 runtime).
- Remind: after editing seed files later, run `docker compose down -v && docker compose up -d mocklab`
  to force a re-import (MockLab skips collections that already exist by name).

### 5 — `.claude/references/` pattern guides
Copy these three guides (no substitution) so the AI has in-repo pattern context even if the plugin
is uninstalled:
- `view-author-guide.md`
- `function-mapping-pattern.md`
- `mocklab-seed-format.md`

### 6 — `api-tests/` + `.http`
If missing, create `api-tests/` with a `.gitkeep` and a short README pointing at `templates/.http.tmpl`
(the per-workflow REST Client file pattern; uses `{{domain}}` / `{{workflowKey}}`).

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
- Suggest: `/vnext-design-process "<your first workflow name>"` to start designing.

## What this command does NOT do

- It does not re-implement the base scaffold — `vnext.config.json`, `package.json`, and the component
  folders come from `@burgan-tech/vnext-template`.
- It does not run `npm install`, `dotnet test`, or `docker compose up` — it only scaffolds (via the
  official `npx` and `dotnet new` templates) and writes the toolkit's layer files.
- It does not overwrite toolkit-owned files silently — it diffs and asks per file first.
- It does not configure git or set up CI — those are workspace-specific decisions.
