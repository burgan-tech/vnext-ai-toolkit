---
name: vnext-init
description: Bootstrap a vNext workspace. Detects what's missing (vnext.config.json, package.json, docker-compose, .claude/references, CLAUDE.md, component folders, tests/, api-tests/) and offers to copy template files with the workspace's domain name substituted. Asks before each copy — nothing happens silently.
---

# /vnext-init

One-shot workspace setup for vNext. Run this in the repo root once when starting a new domain workspace.

## Behavior

The command walks a checklist. For each item:
1. Check if the file/folder exists.
2. If missing, summarize what it is and what the template provides.
3. Use `AskUserQuestion` to confirm. Default: install.
4. If the user confirms, copy from `templates/` with `{{domain}}` placeholder substitution.
5. Report what was created.

The user can answer "Skip" to any item. Nothing is overwritten — existing files are left untouched (the command warns and skips, doesn't merge).

## Checklist

### Step 1 — `vnext.config.json`

If missing, ask:
- Domain name (kebab-case, e.g. `banking`, `payments`, `core`)
- `runtimeVersion` (e.g. `0.0.32` — verify against `https://www.nuget.org/packages/BBT.Workflow.Scripting/`)
- `schemaVersion` (e.g. `0.0.42` — verify against `https://github.com/burgan-tech/vnext-schema/releases`)

Substitute these into `templates/vnext.config.json.tmpl` and write to repo root.

### Step 2 — `package.json`

If missing, copy `templates/package.json.tmpl` with `{{domain}}` substituted into the package name (`@burgan-tech/vnext-{{domain}}`). Note to the user: run `npm install` afterwards.

### Step 3 — `docker-compose.yml` + MockLab seed folder

If missing, copy `templates/docker-compose.yml.tmpl` (MockLab + `mocklab-dapr` sidecar) and create `etc/docker/config/seed/{{domain}}-collection.json` from `templates/etc/docker/config/seed/example-collection.json` with `{{domain}}` substituted.

Warn about port conflicts (3001 for MockLab, 3500 for Dapr, 4201 for runtime).

Remind: after editing seed files later, run `docker compose down -v && docker compose up -d mocklab` to force re-import (MockLab skips collections that already exist by name).

### Step 4 — `etc/dapr/config.yaml`

If missing, copy `templates/etc/dapr/config.yaml.tmpl`. (Skip if the workspace won't use Dapr.)

### Step 5 — `.claude/references/` pattern guides

If `.claude/references/` is missing or empty, copy the three pattern guides:

- `view-author-guide.md`
- `function-mapping-pattern.md`
- `mocklab-seed-format.md`

These give the AI in-repo pattern context independent of the plugin (so the workspace works even if the plugin is uninstalled).

### Step 6 — `CLAUDE.md` and `AGENTS.md`

If `CLAUDE.md` is missing, copy `templates/CLAUDE.md.tmpl` with `{{domain}}` substituted. Mirror to `AGENTS.md` (same content, header changed to Codex-friendly wording).

If only one of the two exists, ask whether to mirror to the other.

### Step 7 — Component folders

Read `vnext.config.json` `paths.*`. For each path that doesn't exist as a folder, create it with a `.gitkeep`:

- `{paths.componentsRoot}/{paths.workflows}/`
- `{paths.componentsRoot}/{paths.views}/`
- `{paths.componentsRoot}/{paths.tasks}/`
- `{paths.componentsRoot}/{paths.schemas}/`
- `{paths.componentsRoot}/{paths.functions}/`
- `{paths.componentsRoot}/{paths.extensions}/`

### Step 8 — Integration test scaffold (recommended)

If `tests/` is missing, ask:

> "Set up an integration test project? vNext best practice is to verify each workflow's lifecycle (start → transitions → final state) with the `VNext.Testing.Sdk`. **(Recommended)**"

If yes:
- Check `dotnet --version` is on PATH; warn if not.
- Determine `{Domain}` (PascalCase version of `{{domain}}`).
- Copy `templates/tests/` into `tests/{Domain}/` with substitutions:
  - `{{Domain}}.IntegrationTests.csproj`
  - `Infrastructure/VNextTestEnvironment.cs`
  - `Infrastructure/IntegrationTestBase.cs`
  - `SmokeTests.cs`
  - `test.runsettings`
  - `test.runsettings.local.example`
- Remind: `dotnet restore` to pull `VNext.Testing.Sdk`. If the package is private, the user may need a `nuget.config`.

### Step 9 — `api-tests/` folder

If missing, create `api-tests/` with a `.gitkeep` and a brief README inside pointing at `templates/.http.tmpl` for the per-workflow REST Client file pattern.

## Final report

After all steps:

- List created files (path + brief description).
- List skipped files (and why — existed already, user declined, missing dependency).
- Show next-step commands:
  ```bash
  npm install
  dotnet restore               # if tests scaffolded
  docker compose up -d mocklab # if you'll develop with mocked endpoints
  ```
- Suggest: `/vnext-design-process "<your first workflow name>"` to start designing.

## What this command does NOT do

- It does not run `npm install`, `dotnet restore`, or `docker compose up`. It only creates files.
- It does not overwrite existing files. If you want to refresh a file, delete it first.
- It does not configure git or set up CI. Those are workspace-specific decisions.
