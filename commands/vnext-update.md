---
name: vnext-update
description: Refresh the toolkit-owned files in this vNext workspace (CLAUDE.md, AGENTS.md, .claude/references guides, docker-compose, dapr config) after a plugin update. Compares the workspace's stamped toolkit version against the installed plugin version, diffs each file against the current templates, and confirms per file — nothing is overwritten silently.
argument-hint: "[--force]"
allowed-tools: Read, Write, Edit, Glob, Bash(cat *), Bash(diff *), Bash(ls *), Bash(date *)
---

# /vnext-update

Bring a workspace's **toolkit-owned files** up to date with the installed plugin version. The
workspace's own components, `vnext.config.json`, `package.json`, and component folders are never
touched — those belong to the user and the official `@burgan-tech/vnext-template` CLI.

## Step 0 — Locate versions

1. **Workspace check.** If there is no `vnext.config.json` in the working directory, stop: this is
   not a vNext workspace — point the user at `/vnext-init` instead.
2. **Plugin version** (the "new" version): read `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`
   → `.version`.
3. **Workspace version** (the "current" version), in fallback order:
   - `.claude/vnext-toolkit.json` → `.toolkitVersion`, or
   - the `<!-- vnext-ai-toolkit vX.Y.Z ... -->` comment near the top of `CLAUDE.md`, or
   - **neither exists → legacy workspace.** Treat every toolkit-owned file as potentially stale,
     run the full Step 2 flow, and write the manifest for the first time in Step 3.

## Step 1 — Compare

Compare the two versions as semver (`sort -V` ordering).

- **Equal** → report "workspace toolkit files are up to date (vX.Y.Z)" and stop — **unless**
  `$ARGUMENTS` contains `--force`, in which case continue to Step 2 anyway.
- **Workspace older (or unknown/legacy)** → tell the user what's happening
  ("workspace files are from vX, plugin is vY — reviewing each file") and continue.
- **Workspace NEWER than plugin** (plugin was downgraded or the stamp was hand-edited) → surface
  this explicitly and ask before doing anything.

## Step 2 — Diff & confirm, file by file

The toolkit-owned file set (also recorded in `.claude/vnext-toolkit.json` `files`; use the union of
that list and this canonical one):

| Workspace file | Source in plugin |
|---|---|
| `CLAUDE.md` | `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md.tmpl` (rendered) |
| `AGENTS.md` | `${CLAUDE_PLUGIN_ROOT}/templates/AGENTS.md.tmpl` (rendered) |
| `.claude/references/view-author-guide.md` | `${CLAUDE_PLUGIN_ROOT}/templates/view-author-guide.md` (verbatim) |
| `.claude/references/function-mapping-pattern.md` | `${CLAUDE_PLUGIN_ROOT}/templates/function-mapping-pattern.md` (verbatim) |
| `.claude/references/mocklab-seed-format.md` | `${CLAUDE_PLUGIN_ROOT}/templates/mocklab-seed-format.md` (verbatim) |
| `.claude/references/csx-contracts.md` | `${CLAUDE_PLUGIN_ROOT}/templates/csx-contracts.md` (verbatim) |
| `docker-compose.yml` | `${CLAUDE_PLUGIN_ROOT}/templates/docker-compose.yml.tmpl` (rendered) |
| `etc/dapr/config.yaml` | `${CLAUDE_PLUGIN_ROOT}/templates/etc/dapr/config.yaml.tmpl` (rendered) |

Skip junk files (`.DS_Store` and similar) if any appear under `templates/`.

**Rendering rule (allowlist).** Substitute ONLY these placeholders, with values from
`vnext.config.json` and the plugin manifest:
- `{{domain}}` → `domain`
- `{{workflowKey}}` → only in per-workflow `.http` scaffolds (not part of this file set)
- `{{toolkitVersion}}` → the plugin version from Step 0

Every other `{{...}}` token — `{{baseUrl}}`, `{{apiVersion}}`, `{{instanceId}}`,
`{{start.response.body.$.id}}`, … — is a **VS Code REST Client variable and must survive verbatim**.
Never blanket-replace `{{...}}`.

**Per file:**
- **Missing in workspace** → offer to create it (default: yes).
- **Exists** → render/copy the source, `diff` against the workspace file, show a short summary of
  what changed, and ask per file: **overwrite / skip / merge**. If the user has local additions
  (e.g. their own sections in CLAUDE.md), prefer **merge**: apply the template's changed sections
  while keeping the user's additions, and show the result. **Never overwrite silently.**
- **Identical** → mark up-to-date, no prompt.

**CLAUDE.md ↔ AGENTS.md mirroring.** The two differ only in their first heading/intro lines; their
bodies must stay identical. Apply the same decision (overwrite/skip/merge) to both unless the user
says otherwise, and verify the bodies still match afterwards.

## Step 3 — Update the stamp

After processing all files, write `.claude/vnext-toolkit.json` (create `.claude/` if needed):

```json
{
  "toolkitVersion": "<plugin version from Step 0>",
  "updatedAt": "<today, YYYY-MM-DD>",
  "files": [
    "CLAUDE.md",
    "AGENTS.md",
    ".claude/references/view-author-guide.md",
    ".claude/references/function-mapping-pattern.md",
    ".claude/references/mocklab-seed-format.md",
    ".claude/references/csx-contracts.md",
    "docker-compose.yml",
    "etc/dapr/config.yaml"
  ]
}
```

List only files that actually exist in the workspace after this run. The
`<!-- vnext-ai-toolkit vX.Y.Z -->` comment in CLAUDE.md/AGENTS.md is refreshed as part of their
overwrite/merge — if the user skipped those files, leave them untouched (the manifest still records
the new version; the comment will catch up on the next accepted update).

## Final report

- Table: file → **updated / merged / created / skipped (why) / already current**.
- The old → new toolkit version.
- Note: this command does **not** bump `runtimeVersion` / `schemaVersion` in `vnext.config.json` —
  run `/vnext-init` (Step 2) for that.

## What this command does NOT do

- Never touches CLI-owned files (`vnext.config.json`, `package.json`, component folders) or the
  user's domain components (`Workflows/`, `Tasks/`, `Schemas/`, …, `.csx` sources, MockLab seeds,
  `api-tests/`).
- Never updates the plugin itself — that's `claude plugin marketplace update burgan-tech`.
- Never overwrites a file without showing the diff and getting a per-file confirmation.

$ARGUMENTS
