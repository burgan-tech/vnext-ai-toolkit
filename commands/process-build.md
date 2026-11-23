---
description: Build a whole business process from its description — decompose it into flows (top-level, SubFlow, SubProcess), stop for approval of the process map, author every component in dependency order through the agent pipeline, validate, write the lifecycle tests, then ASK whether to run them in Testcontainers and whether to publish to the cluster
argument-hint: "[file-or-folder]   (default: docs/process/)"
---

> **Freshness check (non-blocking, first).** If `vnext.config.json` exists, compare the workspace toolkit stamp — `.claude/vnext-toolkit.json` `toolkitVersion`, falling back to the `<!-- vnext-ai-toolkit vX.Y.Z -->` comment in `CLAUDE.md` — against `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` `.version`. If the stamp is missing or older, tell the user once: "Workspace toolkit files are from vX (plugin is vY) — run `/vnext-update` to refresh". Then continue.

# /process-build

Turn a process description into a working domain. `$ARGUMENTS` is a markdown file or a folder; with none,
the workspace's `docs/process/`.

`/vnext-ai-toolkit:vnext-design-process` designs ONE flow by asking. This command builds a WHOLE process
from what is already written down, and asks only for what the description leaves out.

**Precondition — an initialized workspace WITH the toolkit's layer.** `vnext.config.json` exists, its
`domain` is not the template placeholder, and the workspace carries the toolkit stamp
(`.claude/vnext-toolkit.json`). A bare template project lacks what the build leans on — the pinned schema at
the version the toolkit knows, the compose and seed files the tests need — so without the stamp stop and
run `/vnext-ai-toolkit:vnext-init` first.

**One approval, not two.** Where another plan gate is in force in this workspace, it is not worked around
and the person is not asked twice: the process map IS the design that gate wants approved. Run that gate's
own planning step with the map as its input and take its approval as step 2's.

## 1. Decompose

Run the `process-decompose` skill on the source. It writes `docs/process/PROCESS-MAP.md` and reports the
flows, the reason for each split, the component count and the open questions.

Open questions are asked and answered now. Nothing below starts while the map has any.

## 2. Stop — the map is approved by the person

Show: the flows and their types, each split with its quoted reason, what was not split, the assumptions
taken, the number of components (the size of the build), and which external calls will be written against
MockLab.

**Wait for a yes.** This is the one stop before authoring: a process split the wrong way is expensive to
undo once versions are published. A change the person asks for goes into the map first, then is shown again.

## 3. One spec per component

For every row of the map's Components table write `docs/<Type>/<key>.md` (`docs/Workflows/`,
`docs/Schemas/`, `docs/Tasks/`, `docs/Functions/`, `docs/Views/`), detailed enough that nothing has to be
asked: a flow's states, transitions with trigger types and the components it references; a schema's fields,
types and constraints; a task's type, configuration and mapping; a view's renderer, what it shows and which
transition it submits. This is what lets the `analyst` agent derive each component docs-first.

A spec file that already exists is not overwritten silently: show the difference and ask.

## 4. Build in dependency order

Schemas → tasks and functions → views → `S` and `P` flows → `F` flows. A flow names its views by reference
and validation resolves references, so a view is written before the flow that shows it. For each component
run the existing
pipeline exactly as `/vnext-ai-toolkit:new-component` does — `analyst` (docs-first, so no questions) →
`architect` for a flow or anything non-trivial → `component-author` → `validator` — using the matching
authoring skill (`schema-design`, `component-task`, `component-function`, `workflow-scaffold`,
`view-design`).

- After each component set its Status in the map (`written`, then `validated`).
- After each FLOW run `npm run validate`; a red is fixed before the next flow is started.
- A child flow is finished and validated before the parent that starts it.
- The pipeline finds the description wrong or incomplete → stop, say what, put it in the map as an open
  question. Do not improvise a design the map does not hold.

An interrupted run resumes from the map: components whose Status is past `waiting` are not rebuilt.

**Skills that ask.** Several skills this command calls stop to ask (where a report goes, whether to keep a
generated file). Inside this command their questions are the person's to answer like any other. In an
unattended run nobody can: take the plainest reading, write each one down as an assumption in the report,
and never let an unanswered question pass as a decision the person made.

## 5. The whole domain

`npm run validate` for everything, then the `domain-check` skill (read-only) — report its findings; do not
"fix" a finding by changing the approved design without saying so.

## 6. Write the tests

For every flow, the `integration-test` skill: the lifecycle from start through each transition to every
final state. A parent with a SubFlow gets a scenario where the child's result comes back and decides the
next state; a flow that starts a SubProcess gets one where the parent finishes without it and the child
finishes on its own. Set Status to `test written`.

Writing the tests is not asked. RUNNING them is.

## 7. Ask, then go by the answers

Two questions, in this order, each on its own, after everything above — so the person has seen what was
built before deciding.

**"Run the tests in Testcontainers now?"** Say with the question what the preflight found
(`${CLAUDE_PLUGIN_ROOT}/scripts/e2e-preflight.sh --mode container`: Docker, the .NET SDK).

- Yes → the `e2e-local` skill. A red is triaged as that skill describes (environment, fixture, domain,
  runtime), fixed where it is the domain's, and run again. Green sets Status to `test green`.
- No → the tests stay written and NOT run. Say so in the report; go to the next question.

**"Publish to the cluster?"** Say with the question which environment and domain, and — when the tests
were not run or are red — that they were not run or are red. In that case the suggested answer is no.

- Yes → the `cluster-publish` skill, in full: target and rights proven, the DRY list shown, the publish,
  a record started. This yes is the publish approval; the DRY list is still shown first.
- No → nothing is sent. The report names the skill that does it later.

Never run either without its yes, and never take a yes to one as a yes to the other.

## 8. Report

The FIRST line says how far it got, in these words:

- **written and validated** — every component exists and `npm run validate` is green;
- **ran locally** — the tests are green in Testcontainers;
- **ran on the cluster** — published, and a started record finished.

A stage that was not reached is stated as not done and why (declined, no Docker, red tests) — never as
done. Then: the map's flows, the files written, each question with its answer and result, what is written
against MockLab, and what was not measured.
