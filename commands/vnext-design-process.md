---
name: vnext-design-process
description: Start a multi-turn design session for a new vNext workflow. Dispatches the vnext-architect subagent which walks you through Discovery → Flow Architecture → Component Design → Workflow Assembly → Test & Validate.
argument-hint: [optional process name, e.g. "Loan application"]
---

# /vnext-design-process

Use this when you want to design a complete vNext process end-to-end. The architect will:

1. Read `vnext.config.json` to pin `schemaVersion`, `runtimeVersion`, `domain`, and `paths.*`.
2. Fetch canonical JSON Schemas from `vnext-schema` at the workspace's `schemaVersion` tag — no hardcoded enums.
3. Walk you through a structured decision tree (see `references/decision-tree.md`).
4. Chain the right scaffolding skills (`workflow-scaffold`, `view-design`, `schema-design`, `component-task/function/extension`, `integration-test`).
5. End with `validate-and-fix` to ensure `npm run validate` is green.

## When to use it vs. a direct skill call

- Designing a new workflow from scratch → **this command**.
- Adding a single field to an existing schema → call `schema-design` directly.
- Fixing a validation error → call `validate-and-fix` directly.

## Argument

Pass an optional process name as an argument; the architect uses it as the initial working title.

```
/vnext-design-process Loan application
/vnext-design-process Account opening for retail
/vnext-design-process              # no name — architect asks
```

## Prerequisites

- `vnext.config.json` exists in the repo root. If not, run `/vnext-init` first.
- Network access to fetch canonical schemas from `https://github.com/burgan-tech/vnext-schema`.

## What you'll need to answer

The architect asks about:
- Process name and business goal
- Workflow type (from `workflow.json` schema enum)
- Actor model (single / multi)
- States and what each one shows
- Transitions and how they fire (manual / auto / timer / event)
- External integrations (HTTP, SOAP, Dapr, ...)
- Data enrichment needs (Extension or Function)
- Views per state/transition + renderer choice
- Schemas (master + transition payloads)
- Integration test scope (smoke / full lifecycle)

You can answer "Defer" to any question to revisit later.

## Dispatch

Dispatch the `vnext-architect` subagent with the user's process name (if any) as initial context. The subagent owns the conversation from that point until it returns a final summary.
