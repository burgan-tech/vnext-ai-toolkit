---
name: vnext-validate
description: Run npm run validate, categorize any failures, and propose fixes. A shortcut to the validate-and-fix skill. Use before committing or any time you suspect schema drift.
---

# /vnext-validate

Quick path to the `validate-and-fix` skill. Use this:

- Before committing component changes
- After running `/vnext-design-process` to make sure everything generated passes
- Any time `npm run validate` is red and you want help interpreting the errors

## What it does

Dispatches the `validate-and-fix` skill, which:

1. Runs `npm run validate` and captures the full output.
2. Categorizes failures: JSON syntax / schema mismatch / broken reference / filename inconsistency / version format / auto-transition rule / other.
3. For each unclear error, queries Context7 or fetches the relevant canonical schema page.
4. Proposes targeted fixes with file + line + the rule each fix satisfies.
5. Waits for your approval per fix (or `fix all`).
6. Re-validates after applying. Loops up to 3 times before handing back to you with a remaining-failures report.

## Anti-patterns the skill refuses

- Editing `vnext.config.json` to relax `strictMode` / `validateSchemas` / `allowUnknownProperties` to silence errors.
- Adding `"additionalProperties": true` to a schema to make a stray field pass.
- Removing a required field to avoid supplying data.
- Wrapping a `.csx` mapping in try/catch to hide a contract mismatch.

These would defeat the point of validation. The skill fixes the data, not the rules.
