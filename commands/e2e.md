---
description: Run the domain's integration tests end to end — preflight, Testcontainers pinned to runtimeVersion (or your local runtime if you have one), per-workflow dotnet test, red triage (environment / fixture / domain / runtime), TEST-SCENARIOS.md row and e2e stamp
argument-hint: "[workflow-key | --all] [--mode container|local]"
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(*/scripts/e2e-preflight.sh*), Bash(*/scripts/check-test-coverage.sh*), Bash(npm run validate*), Bash(dotnet build *), Bash(dotnet test *), Bash(dotnet --list-sdks), Bash(docker info*), Bash(docker ps*), Bash(docker inspect *), Bash(docker logs *), Bash(docker compose *), Bash(curl *), Bash(date *), Bash(git check-ignore *)
---

> **Freshness check (non-blocking, first).** If `vnext.config.json` exists, compare the workspace toolkit stamp — `.claude/vnext-toolkit.json` `toolkitVersion`, falling back to the `<!-- vnext-ai-toolkit vX.Y.Z -->` comment in `CLAUDE.md` — against `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` `.version`. If the stamp is missing or older, tell the user once: "Workspace toolkit files are from vX (plugin is vY) — run `/vnext-update` to refresh". Also compare `vnext.config.json` `runtimeVersion` with the plugin manifest's `.vnext.knownRuntimeVersion`: if the workspace is older, mention once that features newer than its runtime (see `.claude/references/runtime-feature-matrix.md` `since`) are unavailable here; if newer, that the toolkit's knowledge lags the runtime. Then continue with the command below. Never block on this.

# /e2e

Run the `e2e-local` skill (`${CLAUDE_PLUGIN_ROOT}/skills/e2e-local/SKILL.md`) for `$ARGUMENTS` and
follow its steps in order:

1. **Preflight** — `${CLAUDE_PLUGIN_ROOT}/scripts/e2e-preflight.sh --mode container` (read-only); show
   WARN/STOP lines; offer fixes from `${CLAUDE_PLUGIN_ROOT}/templates/tests/`.
2. **Mode** — Testcontainers by default (image `ghcr.io/burgan-tech/vnext/*:<runtimeVersion>`). Then ask:
   "Do you have a local vNext runtime running?" Yes → ask the port (default 4201), re-run the preflight
   with `--mode local --port <p>` (`/health` + `domain` must match), write
   `test.runsettings.local` **only after approval**.
3. **Gate** — `npm run validate`, `dotnet build`; offer a patch bump for changed components (publish is
   version-immutable, 409 `Instance:100002`).
4. **Run** — `dotnet test --filter "FullyQualifiedName~<WorkflowName>Tests"` per workflow (`--all` = all).
5. **Triage** each red as environment / fixture / domain / runtime with evidence (`incidents/active`,
   `functions/tasks`, transition metrics, MockLab `/_admin/logs`, OpenObserve, the `TEST-SCENARIOS.md`
   trap list). Runtime → offer `/vnext-ai-toolkit:report-issue`.
6. **Record** — a `TEST-SCENARIOS.md` run row and `.claude/vnext-e2e.json`
   (`runtimeVersion`, `mode`, `passed`, `failed`, `skipped`, `date`,
   `componentsHash` = `${CLAUDE_PLUGIN_ROOT}/scripts/check-test-coverage.sh --hash`), then the remaining
   G1–G4 warnings from `${CLAUDE_PLUGIN_ROOT}/scripts/check-test-coverage.sh`.

Warn-only: red tests or missing coverage never block other commands. Never edit the vnext, vnext-example
or vnext-runtime repositories and never build the runtime.
