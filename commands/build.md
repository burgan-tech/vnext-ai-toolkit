---
description: Build the vNext domain package (runtime or reference) and report output
argument-hint: "[runtime|reference] [extra build.js flags]"
allowed-tools: Bash(npm run build:*), Bash(node build.js:*), Read
---

> **Freshness check (non-blocking, first).** If `vnext.config.json` exists, compare the workspace toolkit stamp — `.claude/vnext-toolkit.json` `toolkitVersion`, falling back to the `<!-- vnext-ai-toolkit vX.Y.Z -->` comment in `CLAUDE.md` — against `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` `.version`. If the stamp is missing or older, tell the user once: "Workspace toolkit files are from vX (plugin is vY) — run `/vnext-update` to refresh", then continue with the command below. Never block on this.

Build the domain package using the repo's build script.

- `$ARGUMENTS` may name a build type (`runtime` or `reference`) and/or extra flags
  for `build.js` (e.g. `-o my-build`, `--skip-validation`).
- Default to `npm run build` (runtime) when no type is given.
- Map `reference` → `npm run build:reference`, `runtime` → `npm run build:runtime`.
- Pass through extra flags after `--` (e.g. `npm run build -- -o my-build`).

After building, report the build type, output directory, and a short summary of
what was produced. If the build runs validation and it fails, surface those errors
the same way `/validate` does.
