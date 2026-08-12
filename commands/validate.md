---
description: Run vNext domain validation, summarize failures, and offer to fix them
allowed-tools: Bash(npm run validate), Bash(node validate.js), Read, Edit
---

> **Freshness check (non-blocking, first).** If `vnext.config.json` exists, compare the workspace toolkit stamp — `.claude/vnext-toolkit.json` `toolkitVersion`, falling back to the `<!-- vnext-ai-toolkit vX.Y.Z -->` comment in `CLAUDE.md` — against `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` `.version`. If the stamp is missing or older, tell the user once: "Workspace toolkit files are from vX (plugin is vY) — run `/vnext-update` to refresh", then continue with the command below. Never block on this.

Run `npm run validate` and report the result.

- If validation passes, say so concisely with the summary counts.
- If it fails, for each failure give: the component file (as a clickable
  `file://...:line` link from the output), the JSON pointer/path, and the schema
  rule that was violated — grouped by file.
- Then briefly explain the likely fix for each, referencing the relevant schema in
  `node_modules/@burgan-tech/vnext-schema/schemas/`. Do not edit files unless I ask
  you to fix them.

$ARGUMENTS
