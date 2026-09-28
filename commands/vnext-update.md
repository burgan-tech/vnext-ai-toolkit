---
name: vnext-update
description: Refresh the toolkit-owned files in this vNext workspace (CLAUDE.md, AGENTS.md, .claude/references guides, docker-compose, dapr config) after a plugin update. Compares the workspace's stamped toolkit version against the installed plugin version, reports how the workspace runtimeVersion relates to the runtime the toolkit knows, diffs each file against the current templates, and confirms — nothing is overwritten silently.
argument-hint: "[--force]"
allowed-tools: Read, Write, Edit, Glob, Bash(cat *), Bash(diff *), Bash(ls *), Bash(date *), Bash(cmp *)
---

# /vnext-update

Bring a workspace's **toolkit-owned files** up to date with the installed plugin version. The
workspace's own components, `vnext.config.json`, `package.json`, and component folders are never
touched — those belong to the user and the official `@burgan-tech/vnext-template` CLI.

## Step 0 — Locate versions

1. **Workspace check.** If there is no `vnext.config.json` in the working directory, stop: this is
   not a vNext workspace — point the user at `/vnext-init` instead.
2. **Plugin version** (the "new" version): read `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`
   → `.version`. Also read `.vnext.knownRuntimeVersion`, `.vnext.knownSchemaVersion` and
   `.vnext.workspaceReferences[]` from the same file.
3. **Workspace version** (the "current" version), in fallback order:
   - `.claude/vnext-toolkit.json` → `.toolkitVersion`, or
   - the `<!-- vnext-ai-toolkit vX.Y.Z ... -->` comment near the top of `CLAUDE.md`, or
   - **neither exists → legacy workspace.** Treat every toolkit-owned file as potentially stale,
     run the full Step 2 flow, and write the manifest for the first time in Step 3.
4. **Workspace runtime**: `vnext.config.json` → `runtimeVersion` and `schemaVersion`.

## Step 1 — Compare

Compare the toolkit versions as semver (`sort -V` ordering).

- **Equal** → report "workspace toolkit files are up to date (vX.Y.Z)" and go to Step 1b — **unless**
  `$ARGUMENTS` contains `--force`, in which case continue to Step 2 anyway.
- **Workspace older (or unknown/legacy)** → tell the user what's happening
  ("workspace files are from vX, plugin is vY — reviewing each file") and continue.
- **Workspace NEWER than plugin** (plugin was downgraded or the stamp was hand-edited) → surface
  this explicitly and ask before doing anything.

### Step 1b — Runtime awareness (report only)

Compare the workspace `runtimeVersion` with the plugin's `knownRuntimeVersion`:

- **Equal** → nothing to say.
- **Workspace older** → one line: "This workspace targets runtime vX; the toolkit's knowledge is
  vY. Features whose `since` is above vX in `.claude/references/runtime-feature-matrix.md` are not
  available here. Run `/vnext-init` (Step 2) if you want to bump `runtimeVersion`/`schemaVersion`."
- **Workspace newer** → one line: "This workspace targets runtime vX but the toolkit only knows vY —
  update the plugin (`claude plugin marketplace update burgan-tech`); until then treat toolkit
  guidance about newer behaviour as unverified."

This command never edits `vnext.config.json`.

## Step 2 — Diff & confirm

The toolkit-owned file set (also recorded in `.claude/vnext-toolkit.json` `files`; use the union of
that list and this canonical one):

| Workspace file | Source in plugin | Handling |
|---|---|---|
| `CLAUDE.md` | `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md.tmpl` rendered with the CLAUDE placeholder set | per file: diff → overwrite / skip / merge |
| `AGENTS.md` | same template, AGENTS placeholder set (see `/vnext-init` Step 3 table) | same decision as CLAUDE.md |
| `docker-compose.yml` | `${CLAUDE_PLUGIN_ROOT}/templates/docker-compose.yml.tmpl` (rendered) | per file |
| `etc/dapr/config.yaml` | `${CLAUDE_PLUGIN_ROOT}/templates/etc/dapr/config.yaml.tmpl` (rendered) | per file |
| `.claude/references/<basename>` for **every** entry in `plugin.json` `.vnext.workspaceReferences[]` | `${CLAUDE_PLUGIN_ROOT}/<entry>` (verbatim) | **batched** (below) |

Files that were in an older manifest but are no longer in `workspaceReferences` are left alone
(mention them once as "no longer maintained by the toolkit").

**Rendering rule (allowlist).** Substitute ONLY these placeholders, with values from
`vnext.config.json` and the plugin manifest:
- `{{domain}}` → `domain`
- `{{workflowKey}}` → only in per-workflow `.http` scaffolds (not part of this file set)
- `{{toolkitVersion}}` → the plugin version from Step 0
- `{{knownRuntimeVersion}}` → `.vnext.knownRuntimeVersion`
- `{{agentFile}}` / `{{agentAudience}}` / `{{peerFile}}` / `{{peerAudience}}` → the fixed pairs
  (`CLAUDE.md` / `Claude Code (claude.ai/code)` / `AGENTS.md` / `Codex` for CLAUDE.md, and
  `AGENTS.md` / `Codex (and any AGENTS.md-compatible agent)` / `CLAUDE.md` / `Claude Code` for AGENTS.md)

Every other `{{...}}` token — `{{baseUrl}}`, `{{apiVersion}}`, `{{instanceId}}`,
`{{start.response.body.$.id}}`, … — is a **VS Code REST Client variable and must survive verbatim**.
Never blanket-replace `{{...}}`.

**Per-file files (CLAUDE.md, AGENTS.md, docker-compose, dapr config):**
- **Missing in workspace** → offer to create it (default: yes).
- **Exists** → render the source, `diff` against the workspace file, show a short summary of
  what changed, and ask: **overwrite / skip / merge**. If the user has local additions
  (e.g. their own sections in CLAUDE.md), prefer **merge**: apply the template's changed sections
  while keeping the user's additions, and show the result. **Never overwrite silently.**
- **Identical** → mark up-to-date, no prompt.
- CLAUDE.md and AGENTS.md get the **same** decision unless the user says otherwise; afterwards
  `diff CLAUDE.md AGENTS.md` must show only lines 1, 4 and 6.

**Reference guides (`.claude/references/`) — batched:** compare every manifest entry with `cmp`
and sort them into *identical* / *new* / *differs, unmodified locally* / *differs, modified locally*
(a file counts as locally modified when its diff against the **previous** plugin copy — if still
available under the old plugin version — or against the new copy contains additions that are not in
the new copy). Then ask **one** question: "N reference guides: A new, B changed — update all / review
one by one / skip". "Update all" writes new + unmodified-changed files at once; locally modified
files always fall back to the per-file overwrite/skip/merge prompt.

## Step 3 — Update the stamp

After processing all files, write `.claude/vnext-toolkit.json` (create `.claude/` if needed):

```json
{
  "toolkitVersion": "<plugin version from Step 0>",
  "knownRuntimeVersion": "<.vnext.knownRuntimeVersion from Step 0>",
  "updatedAt": "<today, YYYY-MM-DD>",
  "files": [
    "CLAUDE.md",
    "AGENTS.md",
    "docker-compose.yml",
    "etc/dapr/config.yaml",
    ".claude/references/<basename>   // one entry per workspaceReferences item present in the workspace"
  ]
}
```

List only files that actually exist in the workspace after this run. The
`<!-- vnext-ai-toolkit vX.Y.Z -->` comment in CLAUDE.md/AGENTS.md is refreshed as part of their
overwrite/merge — if the user skipped those files, leave them untouched (the manifest still records
the new version; the comment will catch up on the next accepted update).

## Final report

- Table: file → **updated / merged / created / skipped (why) / already current** (reference guides
  may be summarised as one row when updated in bulk).
- The old → new toolkit version, and the Step 1b runtime line if it applied.
- Note: this command does **not** bump `runtimeVersion` / `schemaVersion` in `vnext.config.json` —
  run `/vnext-init` (Step 2) for that.

## What this command does NOT do

- Never touches CLI-owned files (`vnext.config.json`, `package.json`, component folders) or the
  user's domain components (`Workflows/`, `Tasks/`, `Schemas/`, …, `.csx` sources, MockLab seeds,
  `api-tests/`).
- Never updates the plugin itself — that's `claude plugin marketplace update burgan-tech`.
- Never overwrites a file without showing the diff and getting a confirmation (per file, or once for
  the batched reference set).

$ARGUMENTS
