---
name: domain-check
description: Use when the user wants a runtime-cost and unused-capability audit of the vNext domain package they are in — triggers "domain check", "domain kontrol", "performans incele", "domain performans", "domain audit", "bu domaini incele". Runs a read-only stdlib scanner (enum labels from the pinned @burgan-tech/vnext-schema, no runtime checkout needed), verifies each candidate in the files, lets the user split must / nice-to-have, then writes a short Turkish report. Not schema validation (/validate), not a convention or dead-reference review (/review-components), not a security review (/security-audit).
---

# Domain check

Reviews the **domain package** the user is working in and answers one question: what is costing
time or reliability at runtime, and which runtime capability would fix it.

Not a code-quality review. Naming, formatting, try/catch hygiene and clean-code concerns are out
of scope — that is `/vnext-ai-toolkit:review-components`. Schema validity is `/validate`; secrets
and authorization are `/vnext-ai-toolkit:security-audit`. Stay on runtime cost and runtime
capability: CacheAside, GetInstances, error-boundary Retry, `P` vs `S` subflows, same-`order`
parallelism, function `scope` and instance-address lookups, `history: none`, attribute indexes,
and the rest of [CHECKS.md](CHECKS.md).

Product teams run this without a vNext runtime checkout and without write access to the vNext
repositories. Everything below works from the domain package, its `node_modules`, the public docs
and the plugin's own helpers.

## Scope check first

The target must be a vNext domain package: a folder with `vnext.config.json` (or a named variant
such as `vnext.credit.config.json`) and the component folders it names. The scanner walks up from
the current directory to find it and exits with code 2 when there is none — then stop and say so;
this skill has nothing to measure.

If the repo holds several domain configs and the user did not say which, ask. Do not guess
between sibling domains.

## Procedure

1. **Scan.**
   `python3 "${CLAUDE_PLUGIN_ROOT}/skills/domain-check/scan.py" [root] [--config FILE]`
   — read-only, standard library only, writes nothing. `--json` gives the same data
   machine-readable; `--schema-dir DIR` points at a vnext-schema `schemas/` folder; `--no-fetch`
   forbids the network fallback.
   Enum labels are read at run time from the domain's pinned `@burgan-tech/vnext-schema`
   (`node_modules`, then parent folders, then the vnext-schema tag for the config's
   `schemaVersion`). The header prints where they came from and the installed version.
   - `!! SCHEMA:` — the installed schema differs from the pin, or none could be loaded. Mention it;
     suggest `npm install`.
   - `!! ENUM: <name> çözülemedi` — the numbers for that enum are raw. Do not write a finding that
     depends on that name until it resolves.
2. **Interpret** the output against [CHECKS.md](CHECKS.md). Every check names the scanner line it
   reads, why it costs, what to verify and what to recommend. Respect the version gates the
   scanner prints (`[runtime X+ gerekir]`, `KIRIK`, "0.0.99'a geciste kirilir").
3. **Open every candidate file before keeping a finding.** The scanner measures structure, not
   intent; several checks are explicitly "candidate, confirm by reading". A finding you have not
   seen in the file does not go in the list.
4. **Confirm runtime behaviour against the published sources, never from memory**:
   - vnext-docs — `https://burgan-tech.github.io/vnext-docs/docs/...` (WebFetch) or Context7
     `/burgan-tech/vnext-docs`; cite the page in the finding;
   - the pinned component schemas in `node_modules/@burgan-tech/vnext-schema/schemas/`;
   - live vnext-meta: `"${CLAUDE_PLUGIN_ROOT}/scripts/vnext-meta-live.sh" features` (also
     `known-issues`, `deprecations`, `version-manifest`); offline it falls back to
     [runtime-feature-matrix.md](../../references/runtime-feature-matrix.md).
   Do not cite runtime source files or internal class paths — the reader cannot open them. A
   finding that says "the runtime does X" and is wrong costs the domain team real work.
5. **Ask which items to keep — before writing anything.** A raw scan produces more findings than
   anyone will act on. Show the verified list (one line each, with its numbers), and let the user
   split it into **must** and **nice-to-have** or drop items. Write only what they kept.
6. **Write the report** in the style below, at the location the user chooses.

If a finding turns out to be a runtime defect, or the docs contradict the schema / vnext-meta /
observed behaviour, do not work around it in the report: say so and suggest filing it with
`/vnext-ai-toolkit:report-issue`.

**Read-only, with one exception: the report file.** Never edit the domain's components, never
commit, never push. Offer the fixes as `**Çözüm:**` text; applying them is a separate request.

## The report

Ask where it goes. Match the repo's existing convention if it has one (a `docs/` folder with dated
or numbered reviews); if a folder index exists, offer to add the row but do not edit the index
without being asked.

Turkish, and written the way a PO or an architect writes, not the way a template generates:

- Each item is a short heading that reads as a sentence, then a few sentences: what is happening,
  where it lives (file and, where it helps, line), what it costs structurally, what to do. Finish
  with a bold `**Çözüm:**` line.
- No repeating `**Dosya:** / **Sorun:** / **Yapılacak:**` scaffolding, no effort or priority table,
  no "Beklenen sonuç" code block.
- Numbers carry the argument. "16 HTTP çağrısı, timeout toplamı 205 sn" beats "çok fazla çağrı".
  These are structural counts from the scan — never a latency figure.
- Two sections, `## Yapılmalı` and `## Yapılsa iyi olur`, matching the user's triage, then a
  one-line suggested order and the measurement paragraph.
- The version pin (check 12) is a one-line note in the intro, not a numbered item.
- Name the runtime capability that solves it (`CacheAsideTask`, `GetInstancesTask` +
  `SetFilterSpec`, aynı `order` ile paralel çalıştırma, error boundary `Retry`, `scope: "D"`,
  `history: "none"`, `x-indexed`) with the type number or label the scanner printed from the
  pinned schema — that is the value this audit adds over the team reading their own code.
- Link the vnext-docs page that backs each runtime claim.

## Measurement

The audit is static. It says where the cost is, not how much it is. Never state a latency
improvement that was not measured. Close the report with how to measure: run the domain locally
(or in a test environment) before and after the change and compare the OpenObserve span durations
for `Instance.Activation`, `Step.*`, `Task.Execute` and `Script.Execute` on the affected flows —
see [Observability](https://burgan-tech.github.io/vnext-docs/docs/how-to/observability) and
[observability.md](../../references/concepts/observability.md).
