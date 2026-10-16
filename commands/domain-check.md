---
description: Read-only runtime-cost and unused-capability audit of the current vNext domain package — scan, verify each candidate, let you triage must / nice-to-have, then write a short Turkish report
argument-hint: "[domain-root] [--config <file>]"
allowed-tools: Read, Grep, Glob, Write, WebFetch, Bash(python3 *), Bash(*/scripts/vnext-meta-live.sh *)
---

> **Freshness check (non-blocking, first).** If `vnext.config.json` exists, compare the workspace toolkit stamp — `.claude/vnext-toolkit.json` `toolkitVersion`, falling back to the `<!-- vnext-ai-toolkit vX.Y.Z -->` comment in `CLAUDE.md` — against `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` `.version`. If the stamp is missing or older, tell the user once: "Workspace toolkit files are from vX (plugin is vY) — run `/vnext-update` to refresh". Also compare `vnext.config.json` `runtimeVersion` with the plugin manifest's `.vnext.knownRuntimeVersion`: if the workspace is older, mention once that features newer than its runtime (see `.claude/references/runtime-feature-matrix.md` `since`) are unavailable here; if newer, that the toolkit's knowledge lags the runtime. Then continue with the command below. Never block on this.

# /domain-check

Run the `domain-check` skill on the domain package in the current directory (or the root given
in the arguments) and follow its procedure and report style exactly
(`${CLAUDE_PLUGIN_ROOT}/skills/domain-check/SKILL.md`, checks in `CHECKS.md` next to it).

This is about runtime cost and unused runtime capability. It is not `/validate` (schema),
`/vnext-ai-toolkit:review-components` (conventions, dead references) or
`/vnext-ai-toolkit:security-audit` (OWASP).

## Steps

1. **Scope.** The target needs a `vnext.config.json` (or the file named with `--config`). If the
   scanner exits with code 2, stop and say there is no domain package here.
2. **Scan** (read-only):
   `python3 "${CLAUDE_PLUGIN_ROOT}/skills/domain-check/scan.py" $ARGUMENTS`
   Report the header (domain, runtime / schema pin, schema source and installed version) and any
   `!! SCHEMA` / `!! ENUM` lines first. No finding may depend on an enum name that did not resolve.
3. **Interpret** against `CHECKS.md`; respect the version gates the scanner prints.
4. **Verify** — open every candidate file before keeping it. Confirm runtime claims against
   vnext-docs (`https://burgan-tech.github.io/vnext-docs/docs/...`), the pinned schemas in
   `node_modules/@burgan-tech/vnext-schema/schemas/`, and live vnext-meta via
   `"${CLAUDE_PLUGIN_ROOT}/scripts/vnext-meta-live.sh" features` / `known-issues`. Never from
   memory, never by citing runtime source paths.
5. **Triage before writing.** Show the verified findings, one line each with their numbers, and
   ask the user to split them into must / nice-to-have (or drop some). Ask where the report goes.
6. **Write the report** — Turkish, `## Yapılmalı` / `## Yapılsa iyi olur`, each item ending with a
   bold `**Çözüm:**` line, no effort table, no latency claims, closing with how to measure
   (OpenObserve spans `Instance.Activation`, `Step.*`, `Task.Execute`, `Script.Execute`, before
   and after).

If a finding is a runtime defect or a contradiction between docs, schema and vnext-meta, say so
and suggest `/vnext-ai-toolkit:report-issue`.

**Never** edit domain components, commit or push. The only file this command writes is the report.
