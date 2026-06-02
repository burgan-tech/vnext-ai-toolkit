---
description: Build the vNext domain package (runtime or reference) and report output
argument-hint: "[runtime|reference] [extra build.js flags]"
allowed-tools: Bash(npm run build:*), Bash(node build.js:*), Read
---

Build the domain package using the repo's build script.

- `$ARGUMENTS` may name a build type (`runtime` or `reference`) and/or extra flags
  for `build.js` (e.g. `-o my-build`, `--skip-validation`).
- Default to `npm run build` (runtime) when no type is given.
- Map `reference` → `npm run build:reference`, `runtime` → `npm run build:runtime`.
- Pass through extra flags after `--` (e.g. `npm run build -- -o my-build`).

After building, report the build type, output directory, and a short summary of
what was produced. If the build runs validation and it fails, surface those errors
the same way `/validate` does.
