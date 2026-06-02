---
name: validate-and-fix
description: Use when the user asks to validate components or fix validation errors, or before committing. Runs `npm run validate`, categorizes failures, queries the docs for the relevant rule, and proposes targeted fixes with user approval before applying.
---

# Validate and Fix

`npm run validate` is the gatekeeper for every component change. This skill runs it, categorizes the failures, and proposes fixes — without bypassing validation by editing schemas or disabling rules.

## Canonical schema-first (mandatory for error interpretation)

> When interpreting a validation failure, fetch the relevant component schema from `vnext-schema` at the workspace's `schemaVersion`. Error messages then reference the exact contract clause (e.g., `properties.attributes.properties.type.enum`) instead of guessing.

```
1. Read vnext.config.json → schemaVersion.
2. For each failing file, identify its component type (from `flow` field: sys-workflows / sys-views / ...).
3. Fetch the matching schema:
   https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/{componentType}.json
4. Compare the failing field against the schema clause.
5. Cite the clause in your fix proposal: "schema v0.0.42 / properties.attributes.required missing 'transitions'".
```

This is what makes proposals precise instead of speculative. See `references/concepts/component-schemas.md`.

## Steps

### 1. Run the validator

```bash
npm run validate
```

Capture the full output. Do not summarize away the error block — categorize from the raw output.

### 2. Categorize each error

Group failures by type:

- **JSON syntax** — trailing commas, missing quotes, unclosed braces
- **Schema mismatch** — `additionalProperties` violation, type mismatch, missing required field
- **Reference broken** — `{domain}/{flow}/{key}/{version}` points to something that doesn't exist
- **Filename / key inconsistency** — file name doesn't match `key` field (kebab-case enforcement)
- **Version format** — not semver
- **Auto-transition rule** — lone conditional auto transition (must be paired or unconditional)
- **Other** — anything that doesn't fit above

### 3. Look up the rule for unclear failures

For each category whose fix isn't obvious from the error message, query Context7:

- `mcp__context7__query-docs` with the error keyword(s), e.g. `"reference resolution strictMode"`, `"schema additionalProperties"`, `"auto transition rule complementary"`
- Fallback to WebFetch on `/docs/components/{matching-section}`.

### 4. Propose fixes (one at a time)

For each error, present the user with:
- The file + line
- The exact violation
- The proposed change (diff-like preview)
- The rule it satisfies

Wait for approval (`y/n` or "fix all") before applying. **Never** disable a validation rule or relax the schema to make an error go away — fix the component instead.

### 5. Apply the fix

Use `Edit` (preferred) or `Write` only when the change is wholesale. After each fix, mentally note what changed; do not batch-apply blindly.

### 6. Re-validate

```bash
npm run validate
```

If new errors appeared (a fix uncovered another issue), loop back to step 2. Cap the loop at **3 iterations**; if errors persist, stop and summarize the remaining failures to the user.

### 7. Report

When green, summarize what was fixed (one line per error). When still red after 3 iterations, list the remaining failures with what's known and what's unclear.

## Anti-patterns (do not do these)

- Editing `vnext.config.json` to relax `strictMode` / `validateSchemas` / `allowUnknownProperties`
- Adding `"additionalProperties": true` to a schema to silence a property error
- Removing a required field from a schema instead of supplying the data
- Wrapping the workflow in a try/catch in `.csx` to hide a mapping error
- Skipping validation with `--no-verify` on commit
