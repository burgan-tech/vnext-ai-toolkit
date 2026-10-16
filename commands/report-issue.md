---
description: Triage a suspected vNext runtime problem and, if it really is the runtime, draft a redacted, evidence-backed English issue for burgan-tech/vnext and create it only after your approval
argument-hint: "[short description]"
allowed-tools: Read, Grep, Glob, Write, WebFetch, Bash(npm run validate*), Bash(*/scripts/vnext-meta-live.sh *), Bash(gh auth status*), Bash(gh issue list *), Bash(gh issue view *), Bash(gh search issues *), Bash(gh issue create *), Bash(gh issue comment *), Bash(curl *), Bash(date *)
---

> **Freshness check (non-blocking, first).** If `vnext.config.json` exists, compare the workspace toolkit stamp — `.claude/vnext-toolkit.json` `toolkitVersion`, falling back to the `<!-- vnext-ai-toolkit vX.Y.Z -->` comment in `CLAUDE.md` — against `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` `.version`. If the stamp is missing or older, tell the user once: "Workspace toolkit files are from vX (plugin is vY) — run `/vnext-update` to refresh". Also compare `vnext.config.json` `runtimeVersion` with the plugin manifest's `.vnext.knownRuntimeVersion`: if the workspace is older, mention once that features newer than its runtime (see `.claude/references/runtime-feature-matrix.md` `since`) are unavailable here; if newer, that the toolkit's knowledge lags the runtime. Then continue with the command below. Never block on this.

# /report-issue

Run the `report-runtime-issue` skill for the problem described in `$ARGUMENTS` (or, if empty, ask
the user what they observed: the request, the response, the component involved).

Follow the skill's eight steps in order — triage, duplicate search, evidence, redaction, draft,
approval gate, create, inform. In short:

1. **Triage first.** `npm run validate`, `references/concepts/schema-runtime-gaps.md`, live vnext-meta
   (`${CLAUDE_PLUGIN_ROOT}/scripts/vnext-meta-live.sh known-issues|deprecations|migrations`, snapshot
   `references/runtime-feature-matrix.md` when offline), vnext-docs, and domain-side causes (role
   headers, `queryRoles`, mappings, schema role). Known issue → give the workaround; domain-side →
   explain the fix. In both cases **do not file**.
2. **Duplicates:** read-only `gh issue list --repo burgan-tech/vnext --search "<keywords>" --state all`.
3. **Evidence → redaction (mandatory) → English draft** per the skill's `TEMPLATE.md`, saved under
   `.vnext/issues/`. `Write` is used for that draft only — never edit domain components here.
4. **Approval gate** (yes / edit / cancel). No `gh issue create` / `gh issue comment` before **yes**.
5. Create on `burgan-tech/vnext` only (another repo only if the user names it), or fall back to the
   draft file + prefilled new-issue URL when `gh` is missing or unauthenticated. Report the link,
   the next steps and any interim workaround as a suggestion.
