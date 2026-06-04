---
description: Audit the vNext components already created in this domain — inventory, schema validation, then dispatch reviewer & security-reviewer sub-agents per component for parallel audit
argument-hint: "[type|component-key]  (optional: limit to one type or a single component)"
allowed-tools: Bash(npm run validate), Bash(node validate.js), Read, Grep, Glob
---

# /review-components

Run a **full audit of the components already created** in this domain (not a diff or
PR — the existing component set on disk). Use this when you want to know whether what
has already been authored is still valid, consistent, and safe.

This goes deeper than `/validate` (which only runs schema validation): it also checks
conventions, reference integrity, dead/duplicated components, and security posture.

## Argument

`$ARGUMENTS` is optional and narrows the scope:
- empty → audit **all** existing components.
- one of `workflow | view | task | schema | function | extension` → audit only that type.
- a component `key` (kebab-case) → audit that component **plus every sub-component it
  references, transitively**. Picking a workflow pulls in the tasks, views, schemas,
  functions, and extensions it references (and anything *those* reference); picking a
  function pulls in its tasks, schemas, and views; and so on. Build the closure before
  reviewing so the report covers the whole subtree, not just the named component.

## Precondition

Read `domain` and `componentsRoot` from [vnext.config.json](vnext.config.json). If
`domain` is still the placeholder `{{DOMAIN_NAME}}` (or the `{{DOMAIN_NAME}}/` folder
still exists), the project is not initialized — stop and tell the user to run
`/vnext-init` first; there is nothing to review yet.

## Steps

1. **Inventory & build the scope.** Glob the domain folder for component JSON files.
   - When `$ARGUMENTS` names a **single component `key`**, resolve its reference
     closure: read the component, collect every nested `{ key, domain, flow, version }`
     reference, load each referenced component, and repeat until no new components are
     pulled in (guard against cycles). The audit scope is the named component **plus
     this whole subtree**. Flag any reference that can't be resolved on disk as a
     Blocker right here.
   - When `$ARGUMENTS` names a **type**, scope is all components of that type. When
     empty, scope is everything.

   Produce a short table grouped by type for everything in scope: `key`, `version`,
   `flow`, whether it's listed under `exports` in vnext.config.json, and — for a
   single-component audit — how it was reached (the named root vs. "referenced by X").
   Note immediately any file whose `key` does not match its filename.

2. **Schema validation.** Run `npm run validate` and surface failures the same way
   `/validate` does — component file as a clickable `file://...:line` link, the JSON
   pointer, and the violated schema rule, grouped by file.

3. **Sub-agent review dispatch.** For each component in the in-scope set (from step 1),
   launch a parallel `reviewer` sub-agent to check conventions, references, naming,
   versioning, and integrity. Launch all sub-agents in a single message so they run in
   parallel. Each sub-agent reports back findings for its component (or "Clean" if
   none).

4. **Sub-agent security dispatch.** In parallel with step 3 or sequentially after,
   launch a parallel `security-reviewer` sub-agent for each component in scope to hunt
   for secrets, untrusted hosts, over-broad exports, and unsafe config. Each sub-agent
   reports findings for its component (or "Clean" if none).

   For a single-component audit with many sub-components, running steps 3 and 4 as
   concurrent batches keeps the review fast and the context clean.

5. **Report.** Aggregate all sub-agent findings into one audit, grouped by severity
   (**Blocker / Suggestion / Nit** from reviewer, **High / Medium / Low** from
   security), each citing the file path and JSON pointer. Include the inventory table
   from step 1 to show what was audited and the reference graph. End with a one-line
   verdict: **"Clean"** or **"N issues need attention"**.

Do not edit any component. If the user wants fixes, point them at `/new-component`
(to re-author) or `validate-and-fix` for schema errors.
