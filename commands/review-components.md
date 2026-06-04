---
description: Audit the vNext components already created in this domain — dispatch hierarchical reviewer & security-reviewer sub-agents: main agents per workflow/function, each spawning sub-agents for sub-components
argument-hint: "[type|component-key]  (empty = all workflows & functions; type = all of that type; key = that component & closure)"
allowed-tools: Bash(npm run validate), Bash(node validate.js), Read, Grep, Glob
---

# /review-components

Run a **full audit of the components already created** in this domain (not a diff or
PR — the existing component set on disk). Use this when you want to know whether what
has already been authored is still valid, consistent, and safe.

This goes deeper than `/validate` (which only runs schema validation): it also checks
conventions, reference integrity, dead/duplicated components, and security posture.

## Argument

`$ARGUMENTS` controls the hierarchical dispatch pattern:

- **empty** → audit **all components**: identify all workflows and all functions in the
  domain. Dispatch a main `reviewer` sub-agent for each workflow (with instructions to
  spawn sub-agents for its sub-components), and a main `reviewer` sub-agent for each
  function (same pattern). This creates a two-level hierarchy: workflow/function
  reviewers → sub-component reviewers.

- **`workflow` or `function`** → audit only that type: dispatch a main sub-agent for
  each workflow (or function) in the domain, each spawning sub-agents for its
  sub-components. Skips the other type.

- **a component `key`** (kebab-case) → audit that component **plus its closure**: read
  the component, resolve its reference closure (guard against cycles), dispatch a
  `reviewer` sub-agent for the named component that itself dispatches parallel
  sub-agents for each sub-component in the closure.

## Precondition

Read `domain` and `componentsRoot` from [vnext.config.json](vnext.config.json). If
`domain` is still the placeholder `{{DOMAIN_NAME}}` (or the `{{DOMAIN_NAME}}/` folder
still exists), the project is not initialized — stop and tell the user to run
`/vnext-init` first; there is nothing to review yet.

## Steps

1. **Inventory & scope determination.** Glob the domain folder for component JSON files.
   - **If `$ARGUMENTS` is empty** (all components): glob **all workflows** and **all
     functions**. These are the main audit targets; all other components (tasks, views,
     schemas, extensions) will be reviewed as sub-components of workflows/functions.
   - **If `$ARGUMENTS` names a type** (`workflow` or `function`): glob only that type.
     Audit each one as a main target, with its sub-components reviewed underneath.
   - **If `$ARGUMENTS` names a single component `key`**: resolve its reference closure
     (read the component, collect every nested `{ key, domain, flow, version }`
     reference, load each, repeat until no new components are found; guard against
     cycles). The audit scope is the named component plus this whole subtree.

   Produce a short inventory table grouped by type for everything in scope: `key`,
   `version`, `flow`, whether it's listed under `exports` in vnext.config.json, and —
   for a single-component audit — how it was reached (root vs. "referenced by X"). Note
   immediately any file whose `key` does not match its filename.

2. **Schema validation.** Run `npm run validate` and surface failures the same way
   `/validate` does — component file as a clickable `file://...:line` link, the JSON
   pointer, and the violated schema rule, grouped by file.

3. **Hierarchical sub-agent review dispatch.** Dispatch sub-agents based on scope:

   **When auditing all components or a type:**
   - Inventory all **workflows** and all **functions** in scope (the main components).
   - Launch a parallel `reviewer` sub-agent for each workflow, instructing it to:
     - Review the workflow itself (conventions, naming, versioning)
     - Dispatch a parallel `reviewer` sub-agent for each of the workflow's
       sub-components (tasks, views, schemas, functions, extensions it references)
     - Aggregate sub-component findings and report back
   - Launch a parallel `reviewer` sub-agent for each function with the same pattern
     (function itself, then sub-agents for its referenced tasks/schemas/views)
   - Launch all main sub-agents in a single message for parallel execution.

   **When auditing a single component `key`:**
   - Launch a `reviewer` sub-agent for the named component.
   - That sub-agent dispatches parallel `reviewer` sub-agents for each of its
     sub-components in the closure (same pattern as above).

4. **Hierarchical sub-agent security dispatch.** Mirror step 3 but using
   `security-reviewer`: dispatch main security sub-agents for each workflow and
   function (when auditing all/type) or for the named component and its closure
   (when auditing a single key). Each main security sub-agent spawns parallel
   security sub-agents for its sub-components. Launch all in parallel to match step 3.

5. **Hierarchical report aggregation.** Collect findings from all main sub-agents
   (workflow/function reviewers and security reviewers) and their spawned sub-agents
   (sub-component reviewers). Merge everything into one audit, grouped by:
   - **Main component** (workflow or function key)
   - **Within each main**: findings for the main component itself, then findings from
     its sub-components, grouped by severity (**Blocker / Suggestion / Nit** from
     reviewer, **High / Medium / Low** from security)

   Each finding cites the file path and JSON pointer. Include the inventory table from
   step 1. End with a one-line verdict: **"Clean"** or **"N issues need attention"**.

Do not edit any component. If the user wants fixes, point them at `/new-component`
(to re-author) or `validate-and-fix` for schema errors.
