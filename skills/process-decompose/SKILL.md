---
name: process-decompose
description: Use when the user hands over a whole business process — a markdown file, a folder of documents, or documents dropped under docs/process/ — and wants to know how it becomes vNext components, triggers "bu süreci vNext'e çevir", "süreci böl", "kaç akış olur", "alt akış mı alt süreç mi", "decompose this process", "turn this process into flows". Reads the description, decides one flow or several (top-level flows, SubFlows, SubProcesses, functions, FanOut), and writes a process map with every decision tied to the sentence it came from. Writes NO component — building is /vnext-ai-toolkit:process-build.
---

# process-decompose — from a process description to a process map

A process description says what happens; it does not say how many flows that is. This skill makes that
decision once, in writing, before anything is authored. The rules are the plugin's
`${CLAUDE_PLUGIN_ROOT}/references/concepts/process-decomposition.md` — read it first, and the pages it
names for any piece you are about to decide.

It writes one file and no component. It never invents what the description leaves out.

## 1. Find and read the source

- An argument names a file or a folder → that. No argument → the workspace's `docs/process/`.
- Read every markdown and text file there, in name order. Empty files and files that are plainly not a
  description (logs, outputs) are skipped and named as skipped. A file you cannot read (a binary document) is
  named in the report as NOT read — ask for it as markdown rather than working around it.
- `PROCESS-MAP.md` in that folder is a previous map, not source. Read it to see what was decided and what
  is already built (its Status column); do not treat it as a description.
- No source at all → say where one is expected and offer the template
  `${CLAUDE_PLUGIN_ROOT}/templates/process/PROCESS.md.tmpl`. Stop.

Read `vnext.config.json` for the domain and the component folders. Outside a vNext workspace, the map is
still written — beside the source — and the report says there is nowhere to build it yet.

## 2. Decide the flows

Start from ONE top-level flow holding every step. Then try the rules of `process-decomposition.md` in
order against the description, and split only where a sentence gives the reason. For each flow record its
key (kebab-case, from the description's own words), its type, who starts it, its parent, and the quoted
sentence the decision rests on.

Steps that looked separable and stayed where they were go under "Not split, and why" — one line each. That
list is how a reader checks the decision was considered rather than missed.

## 3. Lay out each flow

Per flow: its states and who acts in each, its transitions with their trigger (manual, auto, timer,
event), and what each transition takes as input. For a child flow: which state or transition of the parent
starts it, what goes in, what comes back.

Take enum values (state kinds, trigger types, task types) from the pinned schema, not from memory:
`node_modules/@burgan-tech/vnext-schema/schemas/` — the rules for reading it are in
`${CLAUDE_PLUGIN_ROOT}/references/concepts/component-schemas.md`. Outside a workspace there is no pinned
schema: use the version the plugin knows (`vnext.knownSchemaVersion` in
`${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`) through that page's fallback URL, and say in the map
which version the terms were read from. This skill writes no component, so that page's "halt" rule does
not stop a map — it stops the build.

## 4. List the components

Every schema, task, function, flow and view the layout needs, with the flow that uses it and its place in
the build order: schemas → tasks and functions → views → `S` and `P` flows → `F` flows (a flow names its views by reference, so they exist before it). A flow has a master
schema and every transition that takes input has its own.

For every external call: the real endpoint and where its credentials come from if the description gives
them, otherwise "MockLab" — written down, so nobody later reads a mocked integration as a working one.

## 5. Write down what is not answered

Sort what the description leaves out into two lists.

- **Open questions** — a different answer would change the DESIGN: a step with no stated actor, a branch
  with no stated outcome, data with no stated shape, a wait with no stated limit, an external call with no
  stated failure, who may see or do what. A human-task state needs the roles that may act on it and the
  title a person sees in their task list — ask for them when the description does not give them. Phrase each
  question so one sentence answers it.
- **Assumptions** — the description is silent and one ordinary reading exists: a calendar day for "a day",
  the starter as the only one who may cancel, a refusal reason shown to the requester. State the assumption
  and what it replaces; the person corrects it at the approval stop.

Do not turn every silence into a question: a description that says enough to be built must come out
buildable. **A map with open questions is not built**; a map with assumptions is, once they are approved.

Write the map first (step 6), then ask the open questions — choices as a selection when there are a few
fixed options, names and field lists as plain prose — and fold the answers in. Where nobody can be asked
(an unattended run), leave them in the map, say the map is NOT ready, and stop.

## 6. Write the map, then report

Write `PROCESS-MAP.md` beside the source (`docs/process/PROCESS-MAP.md` in a workspace), in the shape of
`${CLAUDE_PLUGIN_ROOT}/templates/process/PROCESS-MAP.md.tmpl`. If one exists, show what changes before
replacing it, and keep the Status of every component that did not change.

Report in this order: how many flows and of which types, in one line; each split with its quoted reason;
what was NOT split; the component count (that is the size of the build); the external calls and which are
mocked; the assumptions taken; the open questions still unanswered, or "none". Do not start authoring — that is the person's decision, and
`/vnext-ai-toolkit:process-build` is how it is carried out.

## Example requests

```text
docs/process/ altındaki süreci vNext'e nasıl bölerdin? Haritayı çıkar, bir şey yazma.
```

```text
Bu dokümandaki süreç tek akış mı olur, alt akış ve alt süreç gerekir mi?
```
