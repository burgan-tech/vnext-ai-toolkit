---
description: Initialize the template into a concrete domain by replacing {{DOMAIN_NAME}}
argument-hint: "<domain-name>"
allowed-tools: Bash(npm run setup:*), Bash(node setup.js:*), Bash(npm run sync-schema), Bash(npm run validate), Read
---

Turn this template into a concrete domain named from `$ARGUMENTS`.

- `<domain-name>` must match `^[a-z0-9-]+$` (e.g. `user-management`). If it's
  missing or invalid, ask me before doing anything.
- Run `npm run setup <domain-name>` (which runs `setup.js`) to replace every
  `{{DOMAIN_NAME}}` placeholder across the template files and folders.
- Then run `npm run sync-schema` followed by `npm run validate`.
- Report what was renamed (the domain directory and `vnext.config.json` `domain`)
  and the validation result.

Note: this rewrites files in place. Confirm with me before running if the working
tree already contains a concrete (non-`{{DOMAIN_NAME}}`) domain.
