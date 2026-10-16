# Checks

Each check names the scanner line it reads, why it costs, what to verify, and what to
recommend. Order is rough impact order, not a required sequence. A check that finds nothing is
not reported.

Verify every candidate by opening the file. The scanner sees structure; intent lives in the code.

**Where runtime claims come from.** Every "the runtime does X" sentence below is backed by a
public page — cite it in the report, and re-read it before you rely on it:

- vnext-docs: `https://burgan-tech.github.io/vnext-docs/docs/<page>` (pages named below), also
  reachable through Context7 (`/burgan-tech/vnext-docs`).
- The component JSON Schemas of the domain's pinned `@burgan-tech/vnext-schema` — the scanner
  reads its labels from there, and field descriptions there are normative.
- vnext-meta, live: `${CLAUDE_PLUGIN_ROOT}/scripts/vnext-meta-live.sh features` (also
  `known-issues`, `deprecations`, `version-manifest`); offline snapshot:
  [runtime-feature-matrix.md](../../references/runtime-feature-matrix.md).

**Version gates.** The scanner tags version-dependent lines with `[runtime X+ gerekir]` when the
domain's `runtimeVersion` is older than the feature. A recommendation that needs a newer runtime
than the domain pins is only valid together with the upgrade — say so in the finding.

**Enum names.** If the header shows `!! ENUM: <name> çözülemedi` or `!! SCHEMA:`, the labels of that
enum are missing. Do not write a finding that depends on that name (task type, trigger type, error
action, extension type/scope, function scope, state type/subtype) until it resolves — install the
pinned schema (`npm install`) or pass `--schema-dir`.

---

## 1. Reference data with no cache

**Scanner:** `## extensions` lines marked `NETWORK`; `!! <wf>::<state> okuma basina N agli cagri`;
`!! global + agli extension`; `## functions` rows whose task is an HTTP/Dapr call;
`hic kullanilmayan yetenek: ... Cache Aside ...`; the `cache` flag on functions.

Lookup data — cities, districts, countries, occupation codes, cancellation reasons, product
catalogues — fetched from a backend on every read. Extensions are the worst case: an extension
attached to a state's view runs on every instance read that renders it, and a `Global` /
`GlobalAndRequested` extension runs on reads of every flow. The `okuma basina N agli cagri`
figure is per read and multiplies by the state's traffic.

**Verify:** that the data really is reference data (does not depend on the instance), and how
often it changes — ask the user if the code does not say.

**Recommend:** a `CacheAsideTask` wrapping the source task, TTL matched to how often the data
changes; `StateStoreTask` when the domain wants to manage the cache itself. For a lookup served
as a custom function, the function-level `cache` block caches the whole response. Use the
labels and type numbers the scanner printed from the pinned schema.

**Docs:** [Cache-Aside Task](https://burgan-tech.github.io/vnext-docs/docs/components/tasks/cache-aside),
[State Store Task](https://burgan-tech.github.io/vnext-docs/docs/components/tasks/state-store),
[Custom Functions → Fonksiyon Cache](https://burgan-tech.github.io/vnext-docs/docs/components/functions/custom),
[Extension](https://burgan-tech.github.io/vnext-docs/docs/components/extension).

## 2. No retry anywhere

**Scanner:** `errorBoundary: ...` — the action histogram labelled from the schema's
`errorAction` enum, plus how many workflows carry no error boundary at all.

A domain whose network calls sit behind `Abort` (or no boundary) turns a transient 5xx into a
faulted instance and a manual recovery.

Two things belong in the finding. Retry lives on the error boundary (task, state or global
level), not on the task definition — the HTTP task has no retry surface. And retry is unsafe to
switch on blindly for calls that create records; tell the team to confirm the backend's
behaviour on a repeated request first.

**Recommend:** the `Retry` action with a `retryPolicy` on lookup and idempotent calls.
`retryPolicy.initialDelay` is required and has no default; take the other defaults from the
pinned schema's `retryPolicy` definition rather than inventing numbers.

**Docs:** [Error Handling](https://burgan-tech.github.io/vnext-docs/docs/how-to/error-handling);
[incidents-and-retry.md](../../references/concepts/incidents-and-retry.md).

## 3. Flows that block each other

**Scanner:** `subflow kenari N tip={...}`; per-workflow `cumTimeout`, `net`, `chain`, `exec=`;
`executionType kullanan workflow`; `!! otomatik transition'da executionType`.

A subflow of type `S` blocks its parent until the child finishes; type `P` (SubProcess) runs
independently. Deep `S` nesting plus a long chain of automatic transitions means one request
holds the whole tree.

`cumTimeout` is the worst case for that workflow alone — the sum of `timeoutSeconds` of every
outbound task its hooks reach. It is an upper bound, not a prediction; say so.

`executionType` (`S`/`A`, runtime 0.0.99+) on the flow or on a transition decides whether the
caller waits; it overrides the caller's `sync` query parameter and the inner (transition) value
wins over the flow's. It is **not honoured on automatic transitions**, which always run inline —
an `executionType` there is dead configuration, report it as such.

A domain with `tip={}` has no subflows and the subflow half does not apply. A domain with no `P`
at all is worth a sentence: something in there probably does not need to be waited for.

**Recommend:** `P` for children the parent gains nothing by awaiting; `executionType: "A"` on
long manual transitions whose callers do not need the result (0.0.99+). Delete wrapper subflows
whose body is one call. Review long timeouts on the worst chain.

**Docs:** [Workflow → SubFlow types](https://burgan-tech.github.io/vnext-docs/docs/components/workflow),
[Async / Sync](https://burgan-tech.github.io/vnext-docs/docs/how-to/async-sync),
[Transition Pipeline](https://burgan-tech.github.io/vnext-docs/docs/concepts/transition-pipeline).

## 4. Decision-only states

**Scanner:** per-workflow `decision=N`, against `states=`.

States with no view, no hook, no subflow and only automatic outgoing transitions. Each one is a
full pipeline pass that exists to evaluate a condition. A quarter of a workflow's states being
decision-only is worth raising; a handful is not.

Also grep the domain's rule mappings for an always-true rule — those transitions carry no
decision at all.

**Recommend:** fold the condition into the previous state's transition and delete the state.

## 5. Independent tasks running serially, and parallel tasks that collide

**Scanner:** `seri hook <state>::<hook>: [(order, task), ...]` — printed when a hook has tasks at
two or more distinct `order` values; `!! ayni order'da ayni slot (...)`.

Tasks with the same `order` in one hook run in parallel; different `order` values run one after
another. A hook whose tasks do not feed each other is paying for ordering it does not need.

**This check produces false positives by design.** A token fetch followed by the call that uses
the token is correctly serial. Read the mappings: the question is whether the later task consumes
the earlier one's output.

**The collision line is a defect, not a suggestion.** Each entry files its response under a slot
(`variableKey`, default: the task key in camelCase). Two entries at the same `order` that land on
the same slot — typically the same task listed twice without `variableKey` — are rejected at
publish from runtime 0.0.99 (earlier runtimes failed at run time with a conflicting-output error).
In functions the slot must be unique across all `onExecutionTasks`, regardless of order. Report it
under **Yapılmalı**.

**Recommend:** give genuinely independent tasks the same `order`; give each repeated entry a
distinct `variableKey`.

**Docs:** [Tasks → Çalıştırma Sırası](https://burgan-tech.github.io/vnext-docs/docs/components/tasks/),
[Custom Functions → variableKey](https://burgan-tech.github.io/vnext-docs/docs/components/functions/custom).

## 6. The domain calling itself over the network

**Scanner:** `!! kendi domainine cagri (N): ...`; `hic kullanilmayan yetenek: ... Get Instances ...`;
`InstanceQuery(fluent)=0` next to a non-zero `JsonSerializer.Serialize`.

Read that last signal against the `(log icinde=M)` figure beside it: `Serialize` inside a log call
is check 19, not a hand-built filter. Only the remainder points here, and it still has to be
confirmed by opening the mapping.

An outbound task (Dapr service / HTTP) whose address contains the domain's own name — an instance
query or a data read going out to the network and back into the same runtime. Usually paired with
a filter hand-built as a dictionary and serialized to JSON in a mapping.

`GetInstancesTask` with `SetFilterSpec` runs **in-process** for the same domain and takes a fluent
filter. Also check those queries for paging: a query with no `pageSize` scans more than it needs
and gets slower as the table grows.

**Verify:** the check matches on `/<domain>/` appearing in the URL, so an external gateway path
that happens to contain the domain name is a false positive. Open the task and look at the host.

**Recommend:** `GetInstancesTask` + `SetFilterSpec`; `CacheAsideTask` for self data reads that
repeat; restore paging where it was removed.

**Docs:** [Get Instances Task](https://burgan-tech.github.io/vnext-docs/docs/components/tasks/get-instances),
[Instance Filtering](https://burgan-tech.github.io/vnext-docs/docs/how-to/instance-filtering);
[instance-query.md](../../references/concepts/instance-query.md).

## 7. Oversized scripts on a hot path

**Scanner:** `## scriptler` largest list; cross it with the `## extensions` and `## functions`
tables.

A large mapping is only a problem where it runs often. An extension mapping is the hot case: it
runs on every read of every state it is attached to. Cross the largest scripts against the
extension table before writing anything.

What to look for once inside: a long `if / else if` chain on the current state (every branch is
evaluated to select one), per-element logging in an output handler, a nested scan over a list
that grows with instance data, repeated parsing of the same value inside a comparator.

**Recommend:** split per-state logic out of the single file, or at minimum turn the chain into a
lookup. Remove per-element logging. Name the line numbers.

## 8. Schemas defined but not bound

**Scanner:** `schema baglama (transition): bagli=N null=M`, and `schemasOrphans`.

`"schema": null` on every transition while schema components sit in the folder means request
payloads are not validated. Bad input then fails somewhere downstream, far from its cause.

**Recommend:** bind the transition schemas (`attributes.type: "transition"`) to the transitions
they were written for. Cheap, and it moves failures to where they can be understood.

**Docs:** [Schema](https://burgan-tech.github.io/vnext-docs/docs/components/schema),
[Şema Rolleri](https://burgan-tech.github.io/vnext-docs/docs/concepts/schema-roles).

## 9. Broken references and dead weight

**Scanner:** `!! functions/hierarchy referansi`; `!! CacheAside keyExpression`; <!-- lint:allow -->
`!! tanimi olmayan subflow`; `!! task tanimi bulunamadi`; `!! ikiz task tanimi`;
`viewsOrphans`, `schemasOrphans`, `tasksOrphans`; `!! x-computed evaluatedBy 'server'`.

Split these two ways. **Broken references come first** — they are defects and may be live:

- `functions/hierarchy` in a task URL or a `.csx`: the route was removed in 0.0.99 with no alias <!-- lint:allow -->
  (it falls through to custom-function resolution and returns 404). The replacement is
  `.../functions/instance-correlation`. Tagged `KIRIK` when the domain pins 0.0.99+, otherwise
  "breaks on upgrade".
- CacheAside `keyExpression`: removed in 0.0.99; the dynamic key moves into `key` as a script
  object (`"key": { "location": "dynamicExpresso", "encoding": "NAT", "code": "..." }`). Same
  tagging. A function's own `cache.keyExpression` is a different field and is still valid.
- `x-computed.evaluatedBy: "server"`: refused from 0.0.100; use `"runtime"`. <!-- lint:allow -->
- A subflow target with no workflow behind it, an extension pointing at a task that does not
  exist. Check whether the target lives in another domain (a dependency) before calling it broken.

Unreferenced components are clutter; quantify them — "half the views are unused" lands where a
list of filenames does not. Look at the names before recommending deletion: a whole set sharing a
prefix is usually a superseded generation; one lonely file may be work in progress.

**Twin definitions are the case orphan-scanning misses.** `!! ikiz task tanimi` groups task
components whose `type` **and** `config` are byte-identical. Both are referenced, so neither is an
orphan, yet a change to one has to be made to the other. Script tasks are excluded (their code
lives in the mapping, so an empty config would make every one of them a twin). A hook supplies its
own `mapping` on the task reference, so two components with the same config can still do different
work. Say "consolidate these" only where the callers also agree; otherwise report it as
duplication to be aware of.

**Docs:** [Built-in Functions → Instance Correlation](https://burgan-tech.github.io/vnext-docs/docs/components/functions/built-in),
[Cache-Aside Task](https://burgan-tech.github.io/vnext-docs/docs/components/tasks/cache-aside),
[v0.0.99 breaking changes](https://burgan-tech.github.io/vnext-docs/blog/breaking-changes/breaking-changes-v0-0-99);
`${CLAUDE_PLUGIN_ROOT}/scripts/vnext-meta-live.sh deprecations`.

## 10. Timeouts

**Scanner:** `!! timeout YOK (N): ...`; per-workflow `timeout=var|yok`.

Two different things. An outbound task with no `timeoutSeconds` can hold the pipeline for as long
as the transport allows — the scanner only lists task types whose schema offers `timeoutSeconds`.
A workflow with no `timeout` has no upper bound on how long an instance may sit unfinished — fine
for a short flow, worth asking about for one a human abandons.

Also look at a workflow `timeout` whose `timer.reset` re-arms the timer together with a frequently
invoked `$self` transition: if every call restarts the clock, the timeout may never fire. Confirm
the reset values' meaning on the workflow page first, and say whether it looks deliberate rather
than asserting it is a bug.

**Docs:** [Workflow → timeout](https://burgan-tech.github.io/vnext-docs/docs/components/workflow).

## 11. Embedded base64 weight

**Scanner:** `gomulu base64: X KB / Y KB JSON (%Z), N blob, tekrar ...`

Every mapping is stored twice — the `.csx` on disk and a base64 copy inside the component JSON.
At a high share this dominates file size, merge conflicts and validation cost.

**It is not a compile cost.** Compiled scripts are cached by content hash, so a blob repeated
across files compiles once. Say that explicitly, or the finding reads as bigger than it is.
Report it as build and review friction, and keep it low in the list.

**Docs:** [Scripting → Script Compile Cache](https://burgan-tech.github.io/vnext-docs/docs/configuration/scripting).

## 12. Runtime and schema version pin

**Scanner:** the header — `runtime: X schema: Y (toolkit bilinen: runtime A / schema B)`,
the installed schema version and any `!! SCHEMA:` line.

Compare the domain's pin with the toolkit's `knownRuntimeVersion` / `knownSchemaVersion`
(`${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`, printed in the header) and with the live
manifest: `${CLAUDE_PLUGIN_ROOT}/scripts/vnext-meta-live.sh version-manifest`. A stale pin does
not change what the deployed runtime does — environments run what they run — but validation and
meta checks read it, so it silently drifts from reality. An installed schema that differs from the
pinned `schemaVersion` means `npm install` was not re-run after a bump.

Then run `vnext-meta-live.sh known-issues` and keep the entries whose affected range covers the
pinned runtime **and** whose component appears in this domain (the scanner's task type counts tell
you which). Those are the ones worth a sentence. Fall back to
[runtime-feature-matrix.md](../../references/runtime-feature-matrix.md) when offline.

Treat the pin itself as a one-line note in the report intro, not a numbered finding.

## 13. Copy-pasted workflows and state templates

**Scanner:** `!! ayni state kumesine sahip workflow: ...`; `tekrarlayan state kalibi xN: ...`.

The first line means two or more workflows have an identical set of state keys — the same flow
authored once per data type. The second counts structurally identical states across the domain:
same state type, sub type, transition count, hook tasks and view presence.

A repeated terminal or failure state is normal and not worth reporting on its own. What is worth
reporting is a **whole flow** duplicated, or a template repeated enough that a change has to be
made in twenty places to be made once.

**Recommend:** for duplicated flows, one flow whose behaviour comes from data. For repeated failure
states, a shared transition with `availableIn` instead of one state per failure.

## 14. No event transitions, and hand-rolled waiting

**Scanner:** `event transition: 0` together with a non-zero `$self hedefi`.

Zero event transitions in a domain that clearly waits for an external system means the waiting is
built by hand: a state with an automatic transition guarded by a data check, plus a `$self`
`updateData` the other system calls to push data in and re-activate the state.

It works. It is also a mechanism the domain now owns and must debug. Report it as a design
observation, not a defect, and check whether the events surface fits before recommending it —
some callers genuinely cannot publish.

**Recommend:** an event-triggered transition with an `event` mapping where the upstream can
publish. Where it cannot, say so and leave the pattern alone.

**Docs:** [Event-Driven Workflows](https://burgan-tech.github.io/vnext-docs/docs/how-to/event-driven-workflows).

## 15. Tokens refetched per execution

**Scanner:** `token task kullanimi: <task> xN hook`; the `seri hook` lines that show the token task
in front of the call that consumes it; `GetSecret=N` for context only.

**Secrets are not the cost any more.** Script secret helpers (`GetSecret`, `GetSecrets` and their
async forms) read through a process-wide, short-TTL bundle cache — vnext-meta feature
`scriptSecretCache`; check its `since` against the pin with
`vnext-meta-live.sh features`. Do not report `GetSecret` counts as a finding on a runtime that has
it; on an older pin, mention it only as an upgrade benefit.

What is still refetched is an **auth token produced by a task**: a token task called from four
hooks fetches four tokens for one flow, each a network round trip in front of the real call.

**Verify:** that the token is reusable across calls (same audience/scope, a lifetime longer than
the flow step) — some backends issue single-use tokens.

**Recommend:** wrap the token task in a `CacheAsideTask` with a TTL safely below the token's
lifetime.

**Docs:** [Scripting → Secret Cache](https://burgan-tech.github.io/vnext-docs/docs/configuration/scripting),
[Cache-Aside Task](https://burgan-tech.github.io/vnext-docs/docs/components/tasks/cache-aside).

## 16. Filtered or sorted fields with no index

**Scanner:** `!! filtre/siralama var, x-indexed yok (N): <schema>:<field>(f|s|fs)`;
`x-indexed alan: N`; `filtrelenen attributes yolu (N): ...` (paths used in script filters).

**Rule for this audit: a master-schema field that is filterable (`x-filterOperators`) or sortable
(`x-sortable`) should also be `x-indexed`.** Without it the runtime still filters, but through a
JSON expression over the instance data on every list query, and the cost grows with the table.
`x-indexed` asks for a stored generated column plus a PostgreSQL index; the runtime routes to it
once the DBA has prepared it.

**Verify** before recommending — and say these in the finding:

- `x-indexed` needs runtime 0.0.94+ (the scanner gates it) and is accepted only on a master
  schema (`attributes.type: "master"`) on an explicit scalar field; arrays, references and
  conditional schemas are refused at publish.
- It requests physical preparation; it grants no query permission. The index SQL is generated
  with the CLI and applied by the DBA — adding the keyword alone changes nothing in a database
  nobody prepared.
- `filtrelenen attributes yolu` lists paths used in script filters. A path there whose field has
  no `x-filterOperators` is a query the schema does not allow — open the mapping and check.

**Recommend:** `x-indexed: true` on each filtered/sorted scalar field, then the CLI + DBA steps
from the attribute-index page.

**Docs:** [Attribute Index'leri](https://burgan-tech.github.io/vnext-docs/docs/how-to/attribute-indexes),
[Instance Filtering](https://burgan-tech.github.io/vnext-docs/docs/how-to/instance-filtering);
[instance-query.md](../../references/concepts/instance-query.md).

## 17. View payload weight, loadData and computed fields

**Scanner:** `## en agir viewlar`; `loadData:true: N`; `x-computed alan (master): N`.

A view component is served and cached per read; a 100 KB view is 100 KB on every render.
`loadData` adds the instance's data to that response.

Look at the heaviest views for per-channel twins — the same screen re-authored for web, mobile and
backoffice. That is a maintenance cost first and a payload cost second, so keep it low unless the
sizes are extreme.

`x-computed` fields (runtime 0.0.100+, `evaluatedBy: "runtime"`) are evaluated on every read
surface, list items included, after `x-roles`/masking/encryption. A handful is nothing; dozens on a
schema that is listed in pages are worth a sentence. Report low.

**Recommend:** share the common structure between channel variants; drop `loadData` where the view
does not read instance data.

**Docs:** [View](https://burgan-tech.github.io/vnext-docs/docs/components/view),
[Schema Tanımı → x-computed](https://burgan-tech.github.io/vnext-docs/docs/how-to/view-consept/schema-tanimi).

## 18. Lookup data read through the instance-scoped address

**Scanner:** `!! instance scope (N): ...` and `functionCache.ttlSeconds` under `## functions`;
`!! instance adresinden okuma (N): ...` under `## tasks`.

A custom function is invoked through one of two addresses:

```
/{domain}/functions/{fn}
/{domain}/workflows/{wf}/instances/{id}/functions/{fn}
```

The instance-level address runs the function in the instance's context: the instance is resolved
before the function's tasks run. For a function returning cities, districts, countries or
cancellation reasons — data unrelated to the instance — that resolution is waste.

**`scope` does not trigger the read; it decides which address the client must use.** With
`scope: "I"` (Instance) the client has no choice but the instance address. Keep that distinction in
the finding; "scope causes an instance load" sends the team looking in the wrong place. Scope codes
are the letters the pinned schema lists (`D` Domain, `F` Flow, `I` Instance); the scanner prints the
label next to the code.

**The same cost appears without a function component:** an outbound task whose URL is
`.../instances/{id}/functions/data` reads a reference table through the instance address.

**Verify, do not assert.** Built-in instance function responses (`data`, `view`, `schema`, ...) are
cached (InstanceFunctionCache), with a per-flow override in the workflow's
`config.functionCache.ttlSeconds`. So a `functions/data` read is not automatically an uncached
instance load. Check whether `functionCache` is set for that flow before treating the two as
equivalent, and do not put a number on either without measuring.

**Recommend:** move functions that do not depend on the instance to `scope: "D"`. Two things must be
said with it, or the recommendation is unsafe:

- **It changes the client's URL.** Mobile and web teams have to move with it; this is coordinated
  work, not a domain-side edit.
- **There is no instance under `"D"`.** Any mapping reading the instance (for example returning
  `context.Instance?.Data`) needs its reason established first — that line is the usual reason a
  lookup function was left at `"I"`.

Suggest starting with the one function that visibly does not read instance data, as a pilot.

**Docs:** [Functions](https://burgan-tech.github.io/vnext-docs/docs/components/functions/),
[Built-in Functions](https://burgan-tech.github.io/vnext-docs/docs/components/functions/built-in),
[Caching → InstanceFunctionCache](https://burgan-tech.github.io/vnext-docs/docs/configuration/caching).

## 19. Payloads serialized into log calls, and execution journals

**Scanner:** `JsonSerializer.Serialize=N (log icinde=M)`; `executionLog=E (N; ...)`.

`M` counts `JsonSerializer.Serialize(...)` inside a `Log*` call. Each one is a serialize plus a log
write on every execution of that mapping. On a hot path that is real, though rarely the biggest
number in the report. What makes it worth a finding is usually what is in the body: request bodies
often carry identity numbers, birth dates, contact details — logged at a level no environment
filters out. Name the file and line, do not quote the fields' values, and move on. This is a
cost audit, not a data-protection review — for that, point to `/vnext-ai-toolkit:security-audit`.

`executionLog: "E"` on a function records every invocation in the function-execution journal
(runtime 0.0.99+ for the metrics endpoints). The schema states journaling is asynchronous and never
affects execution time — so this is telemetry and storage volume only. Mention it only for a
high-traffic function nobody reads the metrics of; make no latency claim.

**Recommend:** drop the body log, or lower it to `Debug` **with the fields masked** — lowering the
level alone changes who sees it, not what it contains.

**Docs:** [Telemetry](https://burgan-tech.github.io/vnext-docs/docs/configuration/telemetry),
[Built-in Functions → Fonksiyon Metrikleri](https://burgan-tech.github.io/vnext-docs/docs/components/functions/built-in).

## 20. One-shot flows still writing full history

**Scanner:** `history: none adayi (N): ...` (`+child X` = its `S` child must be converted too);
`history: none olan: ...`; `!! history: none ama uygun degil: <wf> (<reason>)`.

`attributes.history: "none"` (runtime 0.0.100+) marks a flow as one-shot: no transition or task
history rows and a single buffered data write at the end, instead of one data row per write, one
row per transition and task journal rows. For a flow that runs often and that nobody inspects
afterwards — a query, a price or limit calculation, an introspection — that is storage and write
volume the domain pays for nothing.

The scanner lists flows that already satisfy the shape the schema and runtime require:

- every state transition is automatic, and every non-final state reaches a Finish state (no cycle
  without exit, no dead end);
- no `sharedTransitions`, `cancel`, `exit`, `updateData` or workflow `timeout`;
- no Wizard state, no state with the Suspended / Busy / Human sub type, no `interaction.longPoll`,
  no subflow `overrides.timeout`;
- every `S` subflow child is itself `history: "none"`.

`!! history: none ama uygun degil` on a flow that already says `none` is a defect — report it under
**Yapılmalı**.

**Verify:** the structural fit is necessary, not sufficient. Ask whether anyone reads the flow's
transition history, task journal or data history (support tooling, audit, the `retry` endpoint —
which a `none` flow refuses). A stage that stops on a non-final state faults the instance instead
of waiting. If any of that matters, leave the flow at `full`.

**Recommend:** `"history": "none"` at the root of `attributes` (not under `config`) on the
confirmed candidates, together with their `S` children; only on a runtime that is 0.0.100+.

**Docs:** [Workflow → History Modu](https://burgan-tech.github.io/vnext-docs/docs/components/workflow).

## Tooling (optional)

If the user asks about build or validation speed, the template tooling at the domain root is
usually worth a look: whether `validate.js` reads and parses every component more than once, how it
locates the line number for an error, whether `build.js` shells out to a second Node process, and
whether the file walker in `index.js` descends into subfolders. These cost developer seconds, not
production latency — keep them out of the main list unless asked.
