# Changelog

All notable changes to the vNext AI Toolkit will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Plugin uses [Semantic Versioning](https://semver.org/).

## [Unreleased] — 0.0.11

**Runtime coverage: vNext runtime 0.0.106 / schema 0.0.61** (previously 0.0.105 / 0.0.60). Milestone v0.0.106 is folded in. It was released 2026-11-13 with vnext PRs #1143, #1303 and #1304. `@burgan-tech/vnext-meta` 0.0.106 is on npm, so the matrix comes from `scripts/sync-vnext-meta.sh --npm 0.0.106` and `metaPackageVersion` is 0.0.106. No vnext PR in this milestone hands work to the toolkit (#1143's `## Product impact` table is empty, and #1303 / #1304 say `no`). The resource-lock changes are author-facing, so they are covered here.

### Added

- **`references/concepts/resource-lock.md`** (new, copied into workspaces). It covers the `resourceLock` contract and the three answers to losing the race:
  - `Abort` (default): the instance is Faulted and the caller gets `409 Execution:200010`.
  - `Reject` (vnext #1143, runtime 0.0.106, schema 0.0.61): the instance is untouched and the caller gets `409 Execution:200014`, so it can repeat the same call.
  - Abort plus an `errorBoundary` rule for `Execution:200010` that names a `transition`: the instance is rerouted from the state it never left, and an incident with `errorLayer: Pipeline` is written.

  It also covers the parking-state pattern, Release / terminal cleanup after commit, Extend and the Dapr `SET NX` caveat, the `ResourceLock:Provider` choice (`dapr` | `postgres`), the publish rules, the `workflow_resource_lock_hold_duration_ms` histogram, logs 10263 / 10264 and a design checklist.
- **domain-check check 22** (`## surum gecisi (0.0.106)`, `resourceLock` in `--json`). The scanner flags:
  - `ttlSeconds` ≤ 0;
  - `onConflict: "Reject"` below runtime 0.0.106 / schema 0.0.61;
  - Retry rules on the lock codes;
  - `Execution:200010` boundary reroutes on an older runtime;
  - a state boundary that routes a lock code to a transition that state cannot take;
  - a boundary target that carries its own lock;
  - `Extend` (provider caveat);
  - floating component references on runtimes 0.0.45–0.0.105 (known issue `floating-version-resolution-loads-every-version`).

  A fixture workflow `limit-reserve` and smoke-test assertions cover each line. `scripts/test-domain-check.sh` now documents schema 0.0.61.
- **Tests:** `WorkflowTestBase.TryTransitionAsync` makes one `?sync=true` attempt and returns status and body, so a test can assert lock outcomes. `integration-test-patterns.md` § Resource-lock conflicts has a Reject example. `TEST-SCENARIOS.md` and the `.http` template explain the difference between 200010 and 200014.

### Changed

- **Resource-lock design questions** are now asked by `workflow-scaffold`, `architect`, `vnext-architect` and `authoring-vnext-components`. The reviewer, `component-author`, `validate-and-fix` and `CLAUDE.md.tmpl` (reference index and mental model step 4a) follow the same rules: key = resource kind + business id, a decided conflict policy, never Retry on lock codes, and the reroute target carries no lock.
- **References:**
  - `runtime-operations.md`: `Execution:200010` no longer says "Faulted but a clean 409"; `Execution:200014` is added; there are new notes on the provider and commit-time release.
  - `transition-pipeline.md`: step 25 and the ErrorBoundary profile skipping the lock step.
  - `incidents-and-retry.md`: pipeline failures routed by a boundary.
  - `observability.md`: hold-duration metric, logs 10263 / 10264.
  - `schema-runtime-gaps.md`: resource-lock publish rules, the `Reject` validate error on schema ≤ 0.0.60, and the stale vnext-docs `how-to/resource-lock` statement "only Abort".
- **Floating version resolution** (vnext #1303 / #1304, fixed in 0.0.106). `runtime-operations.md` § Component cache explains the known issue: hundreds of large versions led to OOM and an older version being started silently, and the cached answer survives pod restarts. It gives the 0.0.103–0.0.105 workaround (pin the full version, raise memory), the `s3` cache shape (one cold resolution per pod after the upgrade), and the open pre-release caveat for partial requests.
- Current-version statements move to 0.0.106 / 0.0.61. `scripts/lint-references.sh` bans three phrasings: "only `Abort` is supported", "the caller gets a clean 409", and Retry "resolving" a lock conflict.

## [0.0.10] — 2026-11-12


**Runtime coverage: vNext runtime 0.0.105 / schema 0.0.60** (previously 0.0.103 / 0.0.59). Milestones v0.0.104 (released 2026-11-09, schema unchanged at 0.0.59) and v0.0.105 (open; vnext-schema 0.0.60 not published yet) folded in. The 0.0.105 facts come from vnext / vnext-schema master (`08e59d61` / `ae8ab2c`) and the `vnext-meta/unreleased/` fragments. **Merge this after vnext-schema 0.0.60 is on npm:** CI installs `knownSchemaVersion`, and `/vnext-init` offers it as the bump target. Once runtime 0.0.105 ships, re-run `scripts/sync-vnext-meta.sh --npm 0.0.105`. The only vnext PR that hands work to the toolkit is #1299 (`context.Caller`); every other `## Product impact` row says `vnext-ai-toolkit: no`.

### Added

- **Rule-based transition payload schemas** (`schemas`, vnext #1225, schema 0.0.60). Covered in `transition-pipeline.md` §1.1:
  - Every transition kind takes `[{ rule?, schema }]`. The first match wins, and a rule-less fallback goes last; publish rejects a fallback in any other position.
  - Not allowed on auto or timer transitions.
  - No match → `400 Transition:100025`.
  - The rule's `body` is the instance's latest data. The instance `schema` function answers 404 on no match, and `hasSchema` is declared-only.

  `workflow-scaffold`, the architects and `authoring-vnext-components` offer it. Schema-runtime gap **D15** records that on schema ≤ 0.0.59 `schemas` passes unchecked on state and shared transitions and is ignored by older runtimes.
- **`$Everyone`** predefined role (vnext #1196): `deny $Everyone` hides from every caller and `allow $Everyone` admits every caller.
  - Refused at publish in `x-masking` / `x-encryption` exemption lists and in row-security rules (RS-E05). The spelling is ordinal.
  - `schema-design` offers "hide from every caller" as a field-protection option and replaces the `deny` + `allow $InstanceStarter` trick.
  - Covered in `roles-and-authorization.md`, `field-protection.md` and `row-security.md`.
- **Workflow-scoped start check** `GET …/workflows/{wf}/functions/authorize?type=instance` (vnext #1211). It evaluates `startTransition.roles` for the gateway's start rule.
  - Instance-bound grants never match there, so `allow $InstanceStarter` alone closes the flow.
  - A missing or unknown `type` is `400 Authorization:110005`.
  - New `.http` request, test helper `AuthorizeStartAsync`, and a `WorkflowPath` helper in `WorkflowTestBase`.
- **Caller roles in scripts — `context.Caller`** (vnext #1299, 0.0.105). This answers the vnext handoff `docs/integration/vnext-ai-toolkit/script-caller-roles.md`:
  - `csx-contracts.md` § Caller roles covers `HasRoleAsync`, `RolesAsync`, `IsAvailable`, `ResolutionFailed` and `RolesFromHeader`, with the per-surface table. Roles are readable in selection rules (transition `schemas`, function slots, views), automatic rules and timers on caller-driven hops, and SubFlow output mappings. They are unavailable in task, transition and event mappings.
  - System hops have no caller, so automatic rules and timers need an `IsAvailable` guard.
  - Fail closed: if a rule reads roles while the provider is down, the request gets `503 Authorization:110006` (log 20519) and the fallback is not used.
  - Selection is not authorization: use positive tests and make the fallback the least privileged entry.
  - `workflow-scaffold`, `view-design`, `component-function`, `authoring-vnext-components`, the reviewers, the security checklist and `CLAUDE.md.tmpl` now scaffold role rules with `await context.Caller.HasRoleAsync("x")` instead of parsing `Headers.role`.
- **domain-check check 21**: behaviour changes on the way to 0.0.104 / 0.0.105. The scanner flags:
  - a rule-based function `inputSchema` without a rule-less fallback;
  - transition `schemas` without a fallback;
  - scripts matching `FanOut:ItemFailed`;
  - the old hide-from-all `x-roles` pair;
  - `$Everyone` on a runtime < 0.0.105, in an exemption list, row rule, or miscased;
  - `startTransition.roles` made only of instance-bound allows;
  - scripts that parse the `role` header by hand, `context.Caller` on a runtime < 0.0.105, `context.Caller` inside task/transition/event mappings, and automatic rules / timers / SubFlow mappings that read it without an `IsAvailable` guard.

  The fixture and the smoke test cover each line.
- `scripts/sync-vnext-meta.sh --next <runtime>:<schema>` folds the unreleased vnext-meta fragments into the matrix, stamped as the coming version. It skips back-merge leftovers recorded in `released-fragments.json`. The matrix now covers 0.0.104 plus the 9 fragments of 0.0.105; `metaPackageVersion` is 0.0.104.

### Changed

- **Breaking in 0.0.105:** a rule-based function `inputSchema` that matches no entry rejects a request with a body (`400 Function:800006`). Before, it skipped validation. `component-function`, `function-mapping-pattern.md` §9, the reviewer and the security checklist now ask for a rule-less last entry.
- **FanOut** (0.0.104, #1180): an item whose boundary Ignores / Logs the failure keeps the inner code (`Task:<type>:<key>:<status>`), message and data. `FanOut:ItemFailed` is now only the no-code fallback, and `fan-out.md` has the migration note.
- **`authorize?queryRoles`** (0.0.104, #1184): while a SubFlow child is still being created, the deepest existing instance decides. `reason: "instance-not-found"` is documented on a 403 for a missing instance, along with log 50046 and the `vnext.auth.fallback` tag.
- **Sync start/transition responses** carry `currentState` / `effectiveState` (0.0.104, #1185). `task-types.md` shows how a sync SubProcess / StartTrigger output mapping reads the child's state: `data.value.currentState` on the same domain, `data.currentState` across domains.
- **Human-task rows** carry optional `dueBy` / `priority` from the leaf's `humanTask` data (0.0.104, #1178). The list order is unchanged.
- **`modifiedAt`** moves with every transition and every `updateData` data row (0.0.104, #1183) — `instance-query.md`.
- **Operations** (`runtime-operations.md`, `observability.md`, `long-poll-interaction.md`):
  - concurrent `updateData` calls continue a parked interaction wait once (0.0.105; `ContinuationClaimedAt`, log 10182, DbMigrator before the hosts);
  - the data-function ETag covers the instance state, so a data-less transition no longer answers 304 with stale extension output (0.0.105, #1188);
  - a one-time ETag change for escaped strings;
  - artifact-version references prefer package rows (#1175);
  - fewer DB round trips per hop (#1177, #1195);
  - Postgres `Application Name`;
  - task log lines moved to Debug;
  - new error codes `Transition:100025`, `Function:800006`, `Authorization:110005`, `Authorization:110006`.
- Current-version statements move to 0.0.105 / 0.0.60. `scripts/lint-references.sh` bans "instance-scoped only" authorize claims, the fail-open `inputSchema` wording, the old `FanOut:ItemFailed` row, `D1–D14` and miscased `$Everyone`.

## [0.0.9] — 2026-11-05

**Runtime coverage: vNext runtime 0.0.103 / schema 0.0.59** (previously 0.0.100 / 0.0.56). Closed milestones v0.0.101, v0.0.102 and v0.0.103 folded in. The npm package `@burgan-tech/vnext-meta` has caught up with vnext master (0.0.103), so `metaPackageVersion` follows it again (`scripts/sync-vnext-meta.sh --npm 0.0.103`; same content as master).

### Added

- **Python task (type 23) as a handler container** (vnext #1157, breaking; answers the vnext handoff `docs/integration/vnext-ai-toolkit/python-task-container.md`):
  - `component-task` emits only `handler` / `input` / `timeoutSeconds` (never `script` or `executionMode`) and offers to scaffold the domain side.
  - New templates `templates/python-runtime/` (`Dockerfile` `FROM ghcr.io/burgan-tech/vnext/python-runtime:<runtimeVersion>`, hash-pinned `requirements.txt`, `handlers/` with `@handler`) and `templates/etc/runtime/docker-compose.python.override.yml.tmpl` (runtime + daprd sidecar, `Workflow__PythonRuntime__AppId`). `/vnext-init` writes them only when a type-23 task exists.
  - The e2e preflight flags the removed inline-script form, a missing `AppId` and an unreachable runtime; Testcontainers cannot run Python tasks, so those suites go to local mode.
- **Row security** (`attributes.rowSecurity`, vnext #1134, schema 0.0.58, experimental): new reference `row-security.md` (contract, parameters, never-widen evaluation, filtered vs unfiltered surfaces, RS-E/W codes, design checklist, gateway precondition, rollback). The scaffold and the architects ask the row-visibility question after the roles gate; the security reviewer flags `QueryParameters` rules, headers the gateway does not own and unfiltered instance-addressed routes.
- **Flow default version — publish ≠ activate** (vnext #1130): `runtime-operations.md` §2.1 (`sys-version-registry`, pin modes, resolution, `set-default`, `Instance:100051/52/53`, `flowVersion` on start, pilot and cross-domain runbooks); `.http` and `CLAUDE.md` templates carry the registry calls.
- **Streamed `x-storage` uploads** (`transport: inline|stream|any`), verified reads, `PutFileAsync` / `ScriptFile.OpenRead` / `FileObjectKey`, DaprBinding delete/list/get recipes (vnext #1144); `schema-design` asks inline vs stream.
- **`x-validation` remote rule** (schema 0.0.57): `source`, `resultField`, `messageField`, `trigger`, `debounce`.
- **Interaction wait** pattern (Busy subtype + `interaction`; `updateData` or the timer takes the parked Busy over, vnext #1128).

### Changed

- **Automatic transition order** (vnext #1140, schema 0.0.58): `priority` (absent = 100, lower first, ties in declaration order, `triggerKind: 10` last; first satisfied rule wins). The old "complementary pairs, no defined behaviour" guidance is replaced by "cover every branch" across references, agents, skills and the CLAUDE.md template; the reviewer flags states that mix an absent `triggerKind` with `triggerKind: 0` (order changed).
- **SubFlow carried headers** (vnext #1141): the parent `OutputHandler` reads the settling request's headers and the resumed hop runs with them; switches, deny floor and the `AdditionalDenied` known issue documented (csx-contracts, runtime-operations, roles-and-authorization, security checklist).
- Schema↔runtime gap **D1** rewritten: type 23 validates on schema 0.0.59 only as a handler reference; new publish-time rows for `rowSecurity`, `priority` and the Python input size.
- Scripting: the in-memory `System.IO` / `System.IO.Compression` stream carve-out and the new banned reflection / `Environment` members (migration `script-sandbox-member-bans`); `rawResponse` functions answer `byte[]` / `ScriptFile` as bytes; SqlClient plugins need the ICU/GSSAPI images (0.0.101) plus `System.Data.Common` and `System.ComponentModel.Primitives`.
- Operations and observability: `functions/tasks` lists completed tasks only (0.0.102); HTTP client pool dials on both hosts; same-domain parallel reads at one `order` were broken before 0.0.103 (#1166); `Db.LockAndReadHead` / `Db.InsertInstanceData` spans, `workflow_longpoll_resume_total` and log 20308, flow-version / row-security / settle / carried-header tags, baggage `+` → `_` (#1173).
- Current-version statements, fixtures and examples move to 0.0.103 / 0.0.59; `scripts/lint-references.sh` bans `Python:Enabled`, inline Python `main(input)`, "23 does not validate", the old auto-pair claim and a `rowSecurity` `default` member.

## [0.0.8] — 2026-10-16

**Runtime coverage: vNext runtime 0.0.100 / schema 0.0.56** (previously 0.0.97 / 0.0.54). Closed milestones v0.0.98, v0.0.99 and v0.0.100 folded in. `vnext-meta` is now read live from vnext master; the npm package (0.0.53) lags behind it, so `metaPackageVersion` stays 0.0.53.

The toolkit's audience is now stated explicitly: product teams with no write access to the vNext runtime, vnext-schema, vnext-docs or vnext-example repositories. The toolkit only reads those repositories and sends runtime defects to `/vnext-ai-toolkit:report-issue`.

### Added

- **`domain-check` skill + `/vnext-ai-toolkit:domain-check`** (closes #27). A port of the runtime repo's `domain-performance-audit`:
  - The scanner is stdlib-only and needs no runtime checkout. Enum labels (task, trigger, error action, extension type and scope, function scope) come from the pinned `@burgan-tech/vnext-schema`, falling back to the raw-GitHub tag; any label it cannot resolve prints `!! ENUM`.
  - Checks 1–19 are adapted for domain teams and cite public docs only. Check 15 is corrected, since GetSecret has been cached since 0.0.80. A new check 20 covers `history: none` eligibility.
  - Also flagged: 0.0.99/0.0.100 breaks (CacheAside `keyExpression`, `functions/hierarchy`), same-order `variableKey` collisions, and filtered fields without `x-indexed`.
  - Output is a Turkish report written after the user triages the findings. A CI smoke test runs against the fixture in `tests/domain-check/`.
- **`report-runtime-issue` skill + `/vnext-ai-toolkit:report-issue`**. It turns a suspected runtime problem into a detailed issue on `burgan-tech/vnext`, in this order:
  1. Triage: known schema↔runtime gaps, live `vnext-meta` known issues, deprecations and migrations, the docs, and domain-side causes.
  2. Duplicate search.
  3. Evidence: versions, request and response, `X-Request-Id`, incidents, task and metrics endpoints.
  4. Mandatory redaction of secrets, PII and internal hosts.
  5. An English draft.
  6. An approval gate. Nothing is filed without a yes.

  Without `gh`, it writes the draft to `.vnext/issues/` and gives a prefilled new-issue URL. `validate-and-fix` offers it for runtime-side failures.
- **`e2e-local` skill + `/vnext-ai-toolkit:e2e`**. It runs the integration suite end to end:
  - Testcontainers by default, with the image pinned to `runtimeVersion`. On request, it runs against a local runtime you already have running, after asking for the port.
  - Preflight script, failure triage (environment, fixture, domain, runtime), a `TEST-SCENARIOS.md` row and a `.claude/vnext-e2e.json` stamp.
  - Test templates: `WorkflowTestBase` with the five authorization header scenarios, `OptionalDomainEndpoint`, runsettings, and a pre-run checklist. Also a MockLab morph-idm `get-roles` seed and a local blob-storage binding overlay for `x-storage`.
  - Integration tests are expected for every workflow. Missing ones are reported as **warnings** by the validator, reviewer, `review-components`, `workflow-scaffold` and a PostToolUse reminder hook; they never block.
- **`references/concepts/field-protection.md`**: `x-roles` (read-only pruning), `x-masking`, `x-encryption` (runtime `hash`/`encrypt`; client HPKE/RSA via `source`), `x-computed`, the order they apply in, read surfaces, `DecryptAsync`, settings and known issues.
- **`references/concepts/file-fields.md`**: `x-storage` placement, the write shape and handle, `functions/file`, `GetFileAsync` (no authorization check), FileStorage settings, the Helm `global.blobStorageComponents` binding, the local binding, error codes 100047–100050, and the reserved `file` function key.
- **`scripts/vnext-meta-live.sh`** prints one `vnext-meta` file live from vnext master. It caches for one hour and falls back to the offline snapshot.
- Lint checks for every stale fact removed in this release. The domain-check sources must not reference runtime source paths, and every Python script must compile.

### Changed

- **Authorization and human tasks** (0.0.99–0.0.100):
  - A credential-header model: `sub`, `act_sub`, `role`, `position` and `client_id`, which map to `CreatedBy`/`CreatedByBehalfOf` and are forwarded outbound when the mapping leaves them empty. All are self-asserted; the gateway is the trust boundary.
  - The full catalog of reserved `$` roles.
  - `allOf`/`anyOf` grant combinators with three-valued evaluation.
  - **Leaf-only `authorize?queryRoles=true`**, which loosens access where only the root declared it.
  - The morph-idm provider's configuration and flow, plus a recipe for running it locally.
  - An identity-aware human-task list and the "role AND acting for the starter" approval pattern.
  - The `terminate: false` interaction block is restored (0.0.98).
  - State function response shape v14: labels, the `target` object, and `timeout.target` as an object.
  - Security review gains checks for field protection, files, combinators and SubFlow leaves.
- **Workflows, tasks and functions**:
  - Optional Initial state with an implicit `$start`.
  - `executionType` S/A.
  - `variableKey`.
  - `attributes.history: "none"` for one-shot flows.
  - The CacheAside rewrite: the source runs as a task, and `key` is a string or a script.
  - `instance-correlation` replaces `hierarchy`.
  - Metrics endpoints and `executionLog`.
  - Scheduled start.
  - SubFlow transition proxy, so leaf errors now come back synchronously.
  - Topic names `vnext.{domain}.{env}.*`, which Kafka needs.
  - `X-Request-Id` and `context.Incident` fixes.
  - The scaffold and architect questions and the `.http` template are updated to match.
- **Schemas** (0.0.56):
  - `attributes.type` is now a **role**: master, transition, function or component. Legacy values fail the package validation. Multi-role schemas are split.
  - A role × keyword matrix.
  - Corrected `x-enum`, `x-lov`, `x-validation`, `x-conditional` and `x-errorMessages` shapes.
  - `x-filterOperators` takes the 14 declaration names only.
  - **`x-indexed` on every filtered or sorted field** (toolkit rule).
  - `x-context-source`/`x-context-target`, which are applied by the client only.
  - `schema-design` asks for a protection decision on every sensitive field.
  - The reviewer gains blockers for the new publish rejections.
- **Scripting**: `Instance.DecryptAsync`, `ScriptBase.GetFileAsync`, `ScriptContext.CancellationToken`, `ICacheKeyMapping`, audit-only `InputHandler`, the `allowedAssemblies` publish check, the `System.ObjectModel` baseline, and script plugins loaded once per process.
- **Workspace templates**:
  - `CLAUDE.md.tmpl` is updated for all of the above, including credential headers, the "runtime defect → report-issue" rule, and `npm test` vs the e2e suite.
  - The compose images are pinned and the network is `vnext-development` (vnext-runtime's network).
- `scripts/sync-vnext-meta.sh` defaults to `burgan-tech/vnext@master`. `--from` and `--npm` still work.

## [0.0.7] — 2026-09-29

**Runtime coverage: vNext runtime 0.0.97 / schema 0.0.54 / `@burgan-tech/vnext-meta` 0.0.53** (previously 0.0.79). Released from `release-v0.0` (the heading previously read "Unreleased — 0.2.0"). Closed milestones v0.0.80 … v0.0.97 folded in.

### Added

- **New runtime references** under `references/concepts/` (all copied into workspaces via `workspaceReferences`):
  `task-types.md` (full task `type` catalog 1–23 with default execution location — Local on Orchestration vs Remote — and the schema 0.0.54 ceiling 1–21; task/action history functions),
  `fan-out.md` (FanOut task 21: `itemsPath`/`ItemSelector`, `IFanOutMapping`, single-write join, four join policies, limits, when-vs-SubFlow/SubProcess),
  `transition-pipeline.md` (LifecycleOrder with Auto 80 before Schedule 90 since 0.0.90, admission kinds, full `updateData` semantics incl. the `+Self` profile and parent-with-subflow data-only path, `annotations` placement, extensions read-only since 0.0.93),
  `long-poll-interaction.md` (`interaction.longPoll` terminate/fallback/roles|rule, ack endpoint, rule-arm pitfalls, when to acknowledge),
  `state-function-response.md` (shape v12: `transitions[]` kinds incl. `updateData`/`exit`/`scheduled`, `correlations[]`, `functions`, `interaction`, `incident`, `timeout`, ETag/`X-Entity-ETag`/304, `metadata.effectiveStatus`/`type`),
  `human-task.md` (human approval = state `subType: 6` + fail-closed `queryRoles` + `humanTask` data + `GET /{domain}/functions/human-task` — **not** task type 5),
  `subflow-overrides.md` (`subFlow.overrides` key catalog, resolution rules, deprecated `viewOverrides`),
  `instance-query.md` (list endpoint, wire vs schema-side operator names, `x-indexed`, limits, error codes 900010–900014, sort JSON, `instanceType`/`effectiveStatus`),
  `incidents-and-retry.md` (incident endpoints and retry rules since 0.0.92),
  `runtime-operations.md` (Busy-as-mutex lock model and 409 codes, cache/ETag/generation memo, Dapr service discovery and the `publish/completed` hook, URL BasePath, Monitor API removal),
  `observability.md` (WorkflowLogs EventId ranges, span/tag names, correlation headers, local OpenObserve/Elastic APM, "debug a failed transition" recipe),
  `schema-runtime-gaps.md` (where vnext-schema 0.0.54 and runtime 0.0.97 disagree, with author workarounds).
- **`references/runtime-feature-matrix.md`** — generated snapshot of `@burgan-tech/vnext-meta` (feature → since/status, task types, deprecations, migrations, known issues, security policies, performance profiles) via the new **`scripts/sync-vnext-meta.sh`** (`--from <dir>` | `--npm [ver]` | `--check`). The script also stamps `vnext.knownRuntimeVersion` / `knownSchemaVersion` / `metaPackageVersion` into `plugin.json`.
- **Runtime-version awareness**: the SessionStart hook now also compares the workspace `runtimeVersion` with the toolkit's `knownRuntimeVersion` (older → "features newer than your runtime are unavailable, see the matrix"; newer → "toolkit knowledge lags"); the six command preambles, `/vnext-init` Step 2 and a new `/vnext-update` Step 1b say the same; `CLAUDE.md` gains a "Runtime version awareness" section fed by the new `{{knownRuntimeVersion}}` placeholder.
- **`scripts/lint-references.sh`** — fails on stale runtime facts (task enum 15/16, HumanTask as type 5, wrong schema filenames, wire operator names in `x-filterOperators`, zipkin, POST transitions, `$CurrentUser`, deleted template paths) and on manifest/link drift (every reference listed, every `.claude/references/*` link resolvable, matrix version = `knownRuntimeVersion`, CLAUDE.md placeholders allow-listed). `<!-- lint:allow -->` opts a line out. Wired into a new **`.github/workflows/ci.yml`** (PRs + master) and into `publish-plugin.yml`.
- `.http.tmpl` gains conditional state polling (`If-None-Match`), `updateData`, cancel/exit, `longpoll/ack`, `authorize` probes, function catalog/info/view/schema discovery, task/action history, incidents, human-task inbox and a filter+sort JSON query.

### Changed

- **Single source for reference guides.** The byte-identical copies under `templates/` were deleted; `/vnext-init` and `/vnext-update` copy every entry of `plugin.json` → `vnext.workspaceReferences[]` from `references/` into `.claude/references/` (22 guides now, was 4) with one batched confirmation instead of a prompt per file. The stamp `files[]` is derived from the manifest.
- **`AGENTS.md` is rendered from `CLAUDE.md.tmpl`** (placeholders `{{agentFile}}`, `{{agentAudience}}`, `{{peerFile}}`, `{{peerAudience}}`); `templates/AGENTS.md.tmpl` is gone and the two files are identical by construction except lines 1, 4 and 6.
- **`CLAUDE.md.tmpl` restructured** (311 → ~235 lines while covering more): a Reference index table up front, short rule summaries with pointers, new sections *Runtime version awareness*, *Authorization model (0.0.95+)* and *Debugging a failed transition*; the View, Functions, MockLab and `.http` sections were cut to essentials.
- **Authorization model rewritten** (`roles-and-authorization.md`, `security-review-checklist.md`, architect/vnext-architect/reviewer/security-reviewer agents, security-audit skill): `authorize` is the single decision point (selectors `transitionKey` | `functionKey` | `queryRoles` | `ack`), built-in reads and ack are visibility-only in the runtime since 0.0.95, the gateway ("middle tier") enforces; grant rule (deny AND / allow OR / empty allows / roleless caller cannot clear a role-bound deny since 0.0.96); `availableIn` with roles; caller-role providers `default` / `morph-idm` and the role-header precedence (0.0.97).
- **Task knowledge**: `component-task` skill type picker covers 17–23 with routing notes and FanOut prompts; `function-vs-extension-vs-task.md` task table replaced by a "most used" table + pointer; `authoring-vnext-components` task line corrected (`"1"`–`"21"` validated, 22/23 runtime-only); `csx-contracts.md`/`mapping-types.md` gain `IFanOutMapping`, numeric precision (0.0.85), secret cache and `using`-merge (0.0.87) notes.
- **Workflow authoring**: `workflow-scaffold` asks about human states, long-poll hand-over, `subFlow.overrides`, `annotations` and `updateData`; the workflow `timeout` sample is now the real shape (`{ key, target, versionStrategy, timer: { reset, duration }, annotations? }`) and the two contradicting samples were unified; `workflow-types.md` §5 rewritten (state-level SubFlow is `S` only; `P` via `SubProcessTask` 14; sync starts; `effectiveStatus`; failed start faults the parent).
- **Schema knowledge**: `schema-vocabularies.md`, `schema-design` skill and `CLAUDE.md` use the schema-side `x-filterOperators` names (`gte`/`lte`/`neq`/`contains`/…) and document `x-indexed`; `component-schemas.md` now names the real `*-definition.schema.json` files, makes `node_modules` the primary source and drops the fictional `schemas-snapshot/` appendix; the six skills that restated a wrong raw-GitHub URL point at it instead.
- `validate-and-fix` triages known schema↔runtime gaps before proposing edits; `reviewer` lists runtime-acceptance blockers (state-level `subFlow.type "P"`, task 22/23, duplicate function task keys, wire operator names, `x-indexed` off-master, `longPoll` without `roles`|`rule`, non-lowercase `grant`).
- `templates/etc/dapr/config.yaml.tmpl` aligned with the runtime's local Dapr config (`mdns` name resolution, `otel:` tracing to `otel-collector:4317` instead of zipkin).
- `function-mapping-pattern.md` § 9 covers the function list/catalog/info endpoints, error codes 800001–800005, and the multi-task `TaskResponse` isolation + duplicate-key publish rejection (0.0.95).
- `plugin.json` version 0.2.0 (release branch `release-v0.2`; the pre-existing `v0.1.0` tag blocks 0.1.x).

### Removed

- `templates/csx-contracts.md`, `templates/function-mapping-pattern.md`, `templates/mocklab-seed-format.md`, `templates/view-author-guide.md` (duplicates of `references/`), `templates/AGENTS.md.tmpl` (derived), the `schemas-snapshot/` appendix in `component-schemas.md`.

### Fixed

- HumanTask described as task type 5; task enum stated as 1–15 / 1–16; `x-filterOperators` examples with wire names; transition endpoint shown as POST in places; `Authorization.Decide` span name (real: `Auth.Decide`); flow-level `authorize` route (does not exist).

## [0.0.6] — 2026-08-12

### Added

- **Transition admission & locking documentation (v0.0.79, vnext PR #877 — Busy-as-mutex).** New
  `workflow-types.md` § 3.1: the Busy status is the execution mutex; normal shared/state transitions
  **409 while Busy**, `cancel`/`exit` hold the status lock but **bypass the busy check**, and
  **`updateData` bypasses all lock/busy checks** (status-neutral reserve transition) — the only way
  to write data and advance an instance under parallel requests. `updateData` semantics per
  situation: plain instance → data write + normal pipeline (advances the flow); active subflow →
  the **parent answers** (no forwarding, parent data updated, flow left in place, autos still
  evaluated). Design guidance for parallel branches, fan-in states, and loops (409 handling, when
  to add an `updateData` definition, distinct task definitions per parallel branch at the same
  order, two data rows per accepted updateData) baked into the `workflow-scaffold` skill, the
  `architect`/`vnext-architect` transition steps, and the CLAUDE/AGENTS templates.
- **Delta-only mapping rule** added to the csx-contracts golden rules (and templates copy): under
  the v0.0.79 immediate-persistence write model, `ScriptResponse.Data` must contain only changed
  fields — a full instance-data echo overwrites concurrent writers' fresher values.

- **Function mode decision — BFF API vs BFF View, confirm-first.** Functions now have an explicit
  two-mode model across the design surface: a **BFF API** (pure programmatic endpoint — verbs +
  schemas, no view fields) or a **BFF View** (stateless single input→output page — the function
  declares `inputView`/`outputView` itself). The `vnext-architect` Phase 1 discovery and the
  `architect` agent gained a "Function gate": when the user describes a stateless single page or
  pure API need, they propose a **Function instead of a workflow** and ask for confirmation. The
  `component-function` skill now settles the mode with the user in step 2 (no view need → design
  like an API; view fields only on confirmed view need) and drives the contract step from it.
  Also reflected in `references/decision-tree.md` (new early branch + split M2/M3 leaves),
  `function-vs-extension-vs-task.md`, `function-mapping-pattern.md` § 9, and the CLAUDE/AGENTS
  templates.

- **`/vnext-update` command** — refreshes the toolkit-owned workspace files (CLAUDE.md, AGENTS.md,
  the four `.claude/references/` guides, docker-compose, dapr config) after a plugin update:
  reads the installed plugin version from `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`,
  compares it with the workspace stamp, then diffs and confirms **per file** (overwrite/skip/merge —
  never silent). Supports `--force` and a legacy path for workspaces with no stamp yet.
- **Workspace version stamp** — `/vnext-init` and `/vnext-update` now write
  `.claude/vnext-toolkit.json` (`toolkitVersion`, `updatedAt`, tracked `files[]`), and the rendered
  CLAUDE.md/AGENTS.md carry an `<!-- vnext-ai-toolkit v{{toolkitVersion}} -->` comment via the new
  `{{toolkitVersion}}` template placeholder.
- **SessionStart staleness hook** (`hooks/hooks.json` + `hooks/check-toolkit-version.sh`) — on
  session start in a vNext workspace, compares the workspace stamp against the installed plugin
  version and injects a non-blocking reminder to run `/vnext-update` (or to update the plugin, when
  the stamp is newer). Silent no-op outside vNext workspaces; always exits 0; no jq dependency.
- **Freshness preamble in commands** — `/new-component`, `/vnext-design-process`, `/validate`,
  `/review-components`, `/build`, `/security-audit` now start with an identical non-blocking check
  that suggests `/vnext-update` when the workspace stamp is missing or older than the plugin.

### Changed

- **`/vnext-init` template paths are now plugin-rooted** (`${CLAUDE_PLUGIN_ROOT}/templates/...`
  instead of ambiguous bare `templates/...`), the placeholder substitution is an explicit allowlist
  (`{{domain}}`, `{{workflowKey}}`, `{{toolkitVersion}}` — REST Client variables like `{{baseUrl}}`
  / `{{apiVersion}}` / `{{instanceId}}` must survive verbatim), and a final step writes the
  `.claude/vnext-toolkit.json` stamp.

- **`csx-contracts.md` rewritten against the runtime source** (`Models.cs`, `ScriptBase.cs`,
  `Scripting/Contracts/*`): the verified `ScriptContext` surface (no `QueryString` — the query string
  is `QueryParameters`; adds `CurrentTransition`, `RawBody`, `EventPayload`, `Incident`,
  `OutputResponse`, `Related`), the dynamic runtime type model (every `dynamic` is an
  `ExpandoObject` / `List<object?>` with camelCase keys; a missing member access **throws**
  `RuntimeBinderException` — `?.` does not guard it), the full `ScriptBase` helper reference
  (`HasProperty`, `GetPropertyValue<T>`, list ops, `CreateObject`/`SetProperty`, XML, logging
  `args:` rule, config & Dapr secrets), and previously missing interfaces (`ISubProcessMapping`,
  `IEventMapping`, `IStateNotificationMapping`). Fixed two wrong method names: `IOutputHandler`'s
  method is `OutputHandler` (not `Handler`) and `INotificationMapping`'s is `ChannelHandler`.
- **All `.csx` skeletons and examples** (component-function / component-extension / component-task
  skills, mapping-types, function-mapping-pattern, CLAUDE/AGENTS templates) now inherit `ScriptBase`
  and read dynamic data via `HasProperty` / `GetPropertyValue` instead of direct dynamic access;
  the reflection-based `ResolveParam` (which probed a non-existent `QueryString` property) is gone.
- **`TaskResponse` vs `OutputResponse` vs `Body`** semantics unified across docs (previously
  contradictory): each task's `StandardTaskResponse` is merged into `Body` *and* stored in
  `TaskResponse[taskKey]`; a task's own output-mapping result goes to `OutputResponse[taskKey]`.
- **`sys-mappings` promoted to the primary reuse method** for repeated mapping structures
  (mappings-and-scripts, mapping-types, component-mapping skill, component-author agent, templates).
- **Roles are now confirm-first**: architect/vnext-architect agents, workflow-scaffold skill, and
  roles-and-authorization.md instruct asking the user whether a flow should configure roles at all
  before adding any (default: no roles — they add complexity for vNext newcomers).
- `templates/function-mapping-pattern.md` re-synced with `references/` (it was stale — missing the
  `rawResponse` section) and the duplicate "§ 5" heading fixed.

### Added

- **`context.Related` documentation (v0.0.79+, vnext PR #857)** in csx-contracts + templates:
  `HasParent` / `ParentAsync` / `SubAsync` / `SubsAsync` / `SubKeysAsync`, `RelatedInstanceView`
  fields, `IsCompleted` vs `CorrelationCompleted`, absence-vs-failure semantics, resolution cap,
  x-roles copy warning — and the rule that `Related` is for correlation data only (anything else
  goes through a task).
- **Function BFF contract documentation (vnext PRs #679/#858/#868)**: `verbs[]` (405 + `Allow`),
  `inputSchema` (400 validation), `outputSchema` (declarative), `inputView`/`outputView`
  (rule-based slots, first match wins), `cache`, `/info` + `view|schema?target=` discovery
  endpoints, the "BFF View" stateless-page pattern, and the missing `F` scope semantics —
  in function-mapping-pattern § 9, function-vs-extension-vs-task, component-function skill,
  and the CLAUDE/AGENTS templates.
- **State `interaction.longPoll` documentation** (`terminate`, `fallbackTimeoutSeconds`, `roles`)
  in workflow-types § 2.3 and the templates — the client stop/keep-polling handover signal.
- `csx-contracts.md` added to the `/vnext-init` `.claude/references/` copy list (and to
  `templates/`), so user workspaces carry the interface contracts even without the plugin.

## [0.0.5] — 2026-07-21

### Added

- **Security audit workflow** — new `security-audit` skill and `/security-audit` command for
  OWASP-inspired reviews of secrets, authz, injection, SSRF/path traversal, weak crypto,
  dependency issues, and configuration risk, with output written to `security-report/SECURITY-REPORT.md`.
  The audit follows a four-phase pipeline (recon → hunt → verify → report): candidates are
  checked for reachability, existing mitigations, and test/mock context, confidence-scored
  (0–100) with severity capped by confidence, and reported with CWE / OWASP Top 10
  references. The `security-review-checklist.md` reference carries vNext-specific hunt
  patterns (`roles`/`queryRoles`/`x-roles`, `.csx` `ScriptContext` data flow, `allowedHosts`,
  `REF`/`allowedAssemblies` supply chain) and false-positive rules; the `security-reviewer`
  agent follows the same rubric. (Methodology informed by utkusen/sast-skills,
  mfkocalar/OWASP-Security-Skills, and ersinkoc/security-check.)

  When no `vnext.config.json` exists, it runs `npx @burgan-tech/vnext-template <domain>` to create the
  base project (config, `package.json`, component folders) instead of re-implementing it. In an
  existing workspace it skips the CLI and only layers the toolkit's value-add files.
- **Revise-with-diff**: toolkit-owned files (CLAUDE.md, AGENTS.md, docker-compose + mocklab, dapr
  config, `.claude/references`, `.http`/api-tests, integration tests) are now diffed against the
  latest templates and confirmed per file before overwriting — no longer skip-only.
- **Version bump prompt**: `/vnext-init` checks `runtimeVersion`/`schemaVersion` against the latest
  published releases and offers to update `vnext.config.json` (the one CLI-owned file it may edit).
- **Integration tests now use the official `VNext.Testing.Template`.** `/vnext-init` and the
  `integration-test` skill scaffold the test project with `dotnet new vnext-integration-test`
  (`--DomainName`/`--AppDomain`) instead of copying hand-rolled templates. The generated test surface
  is corrected to the real SDK API (`RunTransitionAsync`, `VNextApiResponse.Body`, `GetCurrentState`,
  `[Collection("VNextIntegration")]`, env overrides `Domain`/`DatabaseName`/`VNextImage`, target
  `net10.0`) — the previously documented `ExecuteTransitionAsync`/`WaitForStateAsync`/`GetStateAsync`
  and per-domain collections were inaccurate and have been removed.
- **Removed `urn:amorphie` legacy framing** from the URN docs. vNext is pre-release, so there is no
  legacy scheme — the docs now present `urn:vnext` / `urn:client` directly.

### Removed

- `templates/vnext.config.json.tmpl` and `templates/package.json.tmpl` — produced by
  `@burgan-tech/vnext-template`. The config/package/component-folder scaffolding steps are dropped.
- `templates/tests/*` — the integration test project is now scaffolded by the official
  `VNext.Testing.Template` (`dotnet new vnext-integration-test`).

## [0.0.4] — 2026-06-12

### Added

- **`.claude-plugin/marketplace.json`** — makes the repo installable as the `burgan-tech`
  marketplace (`claude plugin marketplace add burgan-tech/vnext-ai-toolkit` →
  `claude plugin install vnext-ai-toolkit@burgan-tech`).
- **`.github/workflows/publish-plugin.yml`** — on push to a `release-v*` branch, validates
  the plugin (`claude plugin validate`), auto-increments the patch version, commits the
  bump, tags, and cuts a GitHub Release. Manual `workflow_dispatch` supports an explicit
  version and a dry run.

## [0.0.3] — 2026-06-04

### Changed

- **Restructured around a multi-agent pipeline.** Replaced the single `vnext-architect`
  orchestrator with seven specialized agents — `analyst`, `architect`, `component-author`,
  `validator`, `security-reviewer`, `doc-writer`, and `reviewer` — wired together by the
  commands (analyst → architect → component-author → validator → security-reviewer +
  doc-writer in parallel).
- **New command set.** Replaced `/vnext-design-process`, `/vnext-init`, `/vnext-validate`
  with `/new-domain`, `/new-component`, `/validate`, and `/build`, aligned to the
  `@burgan-tech/vnext-template` project lifecycle (`npm run setup` / `validate` / `build`).
- **Added the `authoring-vnext-components` skill** as the core reference (component
  envelope, type-specific `attributes`, `.csx` `scriptCode` shape, transition triggers,
  validate-fix loop), alongside the eight focused authoring skills.
- **Schema source is now the pinned npm package.** Components are authored against
  `node_modules/@burgan-tech/vnext-schema/schemas/*.json` (the version pinned in the
  project's `package.json`), with Context7 MCP / `WebFetch` for docs — replacing the
  raw-GitHub-tag fetch chain.
- Rewrote `README.md` to match the new structure.

## [0.0.0] — 2026-06-02 — initial release

> Git tag `v0.1.0`. The version scheme restarted at 0.0.x when the release-branch CI was introduced; `0.1.x` is therefore skipped.

### Added

- **Plugin manifest** (`.claude-plugin/plugin.json`) — Claude Code Plugin format with manifest pointing at agents, skills, commands, and references.
- **`vnext-architect` subagent** — multi-turn orchestrator that walks users through Discovery → Flow Architecture → Component Design → Workflow Assembly → Test & Validate phases. Enforces the canonical schema-first rule.
- **Eight skills**:
  - `workflow-scaffold` — state machine + transitions + `.csx` mappings + `.http` test file
  - `view-design` — renderer choice + pseudo-UI vocabulary loading + view tree generation
  - `schema-design` — interactive field gathering with localization and role-based access
  - `component-task` — task type from schema + per-type config + MockLab seed matching
  - `component-function` — scope D/I + single/multi-task composition + `IMapping`/`IOutputHandler` `.csx`
  - `component-extension` — type × scope matrix from schema + performance warnings
  - `integration-test` — xUnit class generation against `VNext.Testing.Sdk`
  - `validate-and-fix` — `npm run validate` interpretation with canonical-schema-cited fix proposals
- **Three slash commands**: `/vnext-design-process` (dispatch architect), `/vnext-init` (9-step workspace bootstrap with integration tests), `/vnext-validate` (shortcut to validate-and-fix).
- **Reference knowledge base** (`references/`):
  - Eight concept docs: `workflow-types`, `view-roles`, `function-vs-extension-vs-task`, `mapping-types`, `csx-contracts`, `schema-vocabularies`, `component-schemas`, `mocklab-spec`, `integration-test-patterns`
  - `decision-tree.md` — full Mermaid diagram and per-phase question summaries
  - `external-sources.md` — every upstream URL the plugin may fetch + version-tag rule
  - Three ported pattern guides: `view-author-guide`, `function-mapping-pattern`, `mocklab-seed-format`
- **Bootstrap templates** (`templates/`): `vnext.config.json`, `package.json`, `docker-compose.yml`, `etc/dapr/config.yaml`, `etc/docker/config/seed/example-collection.json`, `.gitignore`, `CLAUDE.md`, `AGENTS.md`, `.http`, full integration test scaffold (`{{Domain}}.IntegrationTests.csproj`, `Infrastructure/`, `SmokeTests`, `test.runsettings` + `.local.example`).
- **Prerequisite check script** (`scripts/check-prerequisites.sh`).

### Design principle

**Canonical schema-first**: every scaffolding skill fetches the matching JSON Schema from [`burgan-tech/vnext-schema`](https://github.com/burgan-tech/vnext-schema/tree/master/schemas) at the workspace's `schemaVersion` tag before asking the user anything. Enum values, required fields, and JSON shapes come from the schema — never from hardcoded tables in the plugin. Fallback chain: `v{schemaVersion}` tag → `master` branch → in-repo snapshot → halt and ask user.

### Notes

- Plugin compatibility tags: `claude-code` (primary), `codex` (via mirrored `AGENTS.md`). Cursor support planned.
- `VNext.Testing.Sdk` is pinned to `0.0.3` in the template; adjust to match the workspace's `runtimeVersion`.
- The `bbt-development` Docker network must exist before `docker compose up` — `docker network create bbt-development`.
