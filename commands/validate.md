---
description: Run vNext domain validation, summarize failures, and offer to fix them
allowed-tools: Bash(npm run validate), Bash(node validate.js), Read, Edit
---

Run `npm run validate` and report the result.

- If validation passes, say so concisely with the summary counts.
- If it fails, for each failure give: the component file (as a clickable
  `file://...:line` link from the output), the JSON pointer/path, and the schema
  rule that was violated — grouped by file.
- Then briefly explain the likely fix for each, referencing the relevant schema in
  `node_modules/@burgan-tech/vnext-schema/schemas/`. Do not edit files unless I ask
  you to fix them.

$ARGUMENTS
