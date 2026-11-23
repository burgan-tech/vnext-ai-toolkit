# Decomposing a process into components

How one business process becomes one flow or several — used by the `process-decompose` skill and
`/vnext-ai-toolkit:process-build`. This page holds the DECISION; the mechanics of each piece are in the pages
it names.

## The default is one flow

A process is ONE top-level flow (`F`) unless a sentence in its description says otherwise. Every split costs
a component, a version to keep in step and a seam where data crosses; a split with no reason behind it is
removed. So each row of a process map carries the sentence it was decided from.

## The rules, in the order they are tried

| What the process says | Decision | Mechanics |
|---|---|---|
| one input, one answer, nothing to remember afterwards | **not a flow — a function** | `function-vs-extension-vs-task.md` |
| a piece of work with its own data that someone follows from start to end | a top-level flow, `F` | `workflow-types.md` §1 |
| a group of steps the main work WAITS for, whose result comes back into it | a SubFlow, `S` — a state of `stateType: 4` in the parent | `workflow-types.md` §5, `subflow-overrides.md` |
| work that runs beside the main work or outlives it, and that the main work does not wait for | a SubProcess, `P` — started by a SubProcess task (type 14) on a transition or state hook, never by a state | `workflow-types.md` §5, `task-types.md` |
| "for each item in a list, do X" where the count comes from data | a FanOut task (type 21) inside a transition — not a child flow per item and not a loop of auto transitions | `fan-out.md` |
| a fixed number of things at once | tasks sharing an `order` on one transition | `transition-pipeline.md` |
| the same group of steps appears in two places, or in two processes | ONE SubFlow, referenced from each | `workflow-types.md` §5 |
| a person approves, reviews or completes a manual step | a human-task STATE of the flow it belongs to — not a flow of its own | `human-task.md` |
| two parties each own a lifecycle (one can finish while the other goes on) | two top-level flows, joined by a SubProcess start or an event | `workflow-types.md` §3 |
| the caller must see the answer in the same request | stays inside one flow, on a synchronous transition | `workflow-types.md` §3.2 |

## Telling `S` from `P`

Ask of the described steps: **does the main work stop until they finish?**

- Yes, and their result decides what happens next → `S`. The parent shows the child's status; cancelling the
  parent cancels the child; the child's output is merged by the SubFlow mapping.
- No — the main work goes on, or may end first → `P`. It has its own data and its own lifecycle; nothing
  comes back unless a task or an event carries it.

"Verify identity, then continue", "collect documents before the decision" are `S`. "Start a background
check whose result arrives later" is `P`.

**One call is a task, not a child flow.** "Send a notification" or "write an audit record" is a task on a
transition when it is a single call the transition can make and forget. It becomes a `P` only when the
description gives it a life of its own: its own retries over time, its own steps, an outcome someone looks
at later, or a duration that must not hold the main work's transition open.

## What is NOT a reason to split

- The process is long. Length is states, not flows.
- Different people act at different steps. That is roles on states and transitions (`roles-and-authorization.md`).
- A step calls an external system. That is a task.
- A step shows a different screen. That is a view on a state or a transition.

## What a decomposition must leave decided

For every flow: its key, its type, who starts it, its states and transitions with their trigger types, and
the schemas, tasks, functions and views it uses. For every `S` and `P`: which state or transition of which
parent starts it, what goes in and what comes back. For every external call: the real endpoint and
credentials source, or the explicit statement that it is written against MockLab.

What the description does not answer is written down, never guessed in silence: an OPEN QUESTION when the
answer would change the design, an ASSUMPTION when one ordinary reading exists. A map with open questions
is not built; its assumptions are approved with it.
