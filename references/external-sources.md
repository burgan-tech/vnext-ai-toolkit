# External Sources — All URLs in One Place

This is the plugin's address book for "live" knowledge — everything an agent might fetch at runtime. When a skill or the architect agent needs information beyond the in-repo references, it comes here.

## Source registry

| Source | URL | What it provides | Access pattern |
|--------|-----|------------------|----------------|
| **vnext-schema / schemas** (CRITICAL — canonical contracts) | https://github.com/burgan-tech/vnext-schema/tree/master/schemas | The official JSON Schema for each component type — files are `{type}-definition.schema.json` (`workflow`, `task`, `view`, `schema`, `function`, `extension`, `mapping`). **Every scaffolding skill loads this BEFORE asking the user anything.** | Primary: `node_modules/@burgan-tech/vnext-schema/schemas/{type}-definition.schema.json`; fallback: `https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/{type}-definition.schema.json` — resolution order lives in `component-schemas.md` |
| **vnext-schema / vocabularies** | https://github.com/burgan-tech/vnext-schema/tree/master/vocabularies | `x-*` keyword definitions consumed by views (x-labels, x-lov, x-lookup, x-conditional, x-validation, x-enum, x-roles, x-filterOperators, x-sortable, x-displayFormat) — `view-vocab.json`, `data-vocab.json`, `roles-vocab.json`. The `x-filterOperators` enum lists wire names; see `schema-runtime-gaps.md` D9 | `node_modules/@burgan-tech/vnext-schema/vocabularies/{file}.json`; fallback `https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/vocabularies/{file}.json` |
| **@burgan-tech/vnext-meta** (runtime metadata) | npm `@burgan-tech/vnext-meta`; source dir `vnext/vnext-meta/` | Machine-readable runtime facts per version: `version-manifest.json` (runtime ↔ schema version, release-note URL), `features.json` (id, `since`, `schemaPath`, `apiEndpoints`), `deprecations.json`, `migrations.json`, `known-issues.json` (`fixedIn == null` = open), `component-registry.json` (task types), `security-policy.json`, `performance-profiles.json`. Synced into `references/runtime-feature-matrix.md` by `scripts/sync-vnext-meta.sh` | Local generated matrix first; `npm view @burgan-tech/vnext-meta` / `https://raw.githubusercontent.com/burgan-tech/vnext/master/vnext-meta/{file}.json` for the live copy |
| **vnext-docs portal** | https://burgan-tech.github.io/vnext-docs/ | Component reference pages, how-to guides, API reference. Page paths are `/docs/{section}/{page}` — see the page map below | Context7 MCP (registered) + WebFetch |
| **vnext-docs release notes** | https://burgan-tech.github.io/vnext-docs/blog/release-v0-0-NN | One post per runtime release (`release-v0-0-79` … `release-v0-0-96-97`; combined posts use `release-v0-0-81-84`, `release-v0-0-96-97`): PR list, schema version, behaviour changes. `vnext-meta/version-manifest.json` carries the exact URL per version | WebFetch; raw source `https://raw.githubusercontent.com/burgan-tech/vnext-docs/master/blog/{date}-v0-0-NN.md` |
| **vnext-docs breaking changes** | https://burgan-tech.github.io/vnext-docs/blog/breaking-changes/breaking-changes-v0-0-NN | Per-release breaking-change posts (source dir `blog-breaking-changes/`) — read before bumping `runtimeVersion` | WebFetch |
| **vnext-docs repo** | https://github.com/burgan-tech/vnext-docs | Markdown source for the portal (sidebar config, both locales) | GitHub raw / `gh` CLI |
| **vnext-example repo** | https://github.com/burgan-tech/vnext-example | The reference workspace — working examples of every component type, MockLab seeds, integration tests. Runtime-behaviour fixtures under `core/Workflows/*-lab`: `authorization-chain-lab`, `cross-domain-lab`, `data-integrity-lab`, `error-boundary-lab`, `event-driven-lab`, `role-matrix-lab`, `script-perf-lab`, `script-race-lab`, `secret-cache-lab`, `subflow-override-lab`, `subflow-start-failure-lab`, `task-invocation-lab`, `timeout-lab`; plus `fan-out-documents`, `fan-out-config-matrix`, `human-task-chain`, `chain-busy`, `schedule-after-auto`, `payload-modes` | GitHub raw / local clone |
| **mocklab repo** | https://github.com/burgan-tech/mocklab | Authoritative MockLab seed format, rule operators, sequence behavior | GitHub raw / WebFetch |
| **vnext-integration-test SDK** | https://github.com/burgan-tech/vnext-integration-test | Source for `VNext.Testing.Sdk`, `VNext.Testing.Template` (`dotnet new vnext-integration-test`), `IntegrationTestBase`, `VNextApiClient` | GitHub raw / WebFetch |
| **vnext-integration-test — Getting Started** | https://github.com/burgan-tech/vnext-integration-test/blob/master/GETTING_STARTED.md | Authoritative setup: package/template install, csproj, config files, fixtures, API surface, example tests | `https://raw.githubusercontent.com/burgan-tech/vnext-integration-test/master/GETTING_STARTED.md` (WebFetch) |
| **BBT.Workflow.Domain NuGet** | https://www.nuget.org/packages/BBT.Workflow.Domain/ | Domain primitives consumed by `.csx` mappings | NuGet API; pin to closest `runtimeVersion` |
| **BBT.Workflow.Scripting NuGet** | https://www.nuget.org/packages/BBT.Workflow.Scripting/ | Mapping interfaces (`IMapping`, `IOutputHandler`, `IConditionMapping`, `ITimerMapping`, `ISubFlowMapping`, `INotificationMapping`), `ScriptContext`, `ScriptResponse`, `ScriptBase` | NuGet API |
| **BBT.Workflow.Definitions NuGet** | Companion to `BBT.Workflow.Domain` (same release cadence) | Concrete task types (`HttpTask`, `NotificationTask`, `SoapTask`, ...), `TimerSchedule`, `StandardTaskResponse` | NuGet API |
| **VNext.Testing.Sdk NuGet** | (Built and published from `vnext-integration-test`; verify if public or private) | xUnit collection fixture, API client, Docker stack manager | NuGet API |
| **Context7 — vnext-docs library** | https://context7.com/burgan-tech/vnext-docs | Semantic search index over the docs portal | `mcp__context7__resolve-library-id` + `query-docs` |
| **Material Symbols catalog** | https://fonts.google.com/icons | Source-of-truth for `Icon.name` / `Button.icon` values (lowercase `snake_case`) | Web search (rarely needed; common mappings memorized in `view-roles.md`) |

## vnext-docs page map (runtime ≥ 0.0.80 topics)

All under `https://burgan-tech.github.io/vnext-docs/docs/`. Source: `vnext-docs/sidebars.ts` + `docs/` tree @ `adf9bf4`.

| Topic | Page(s) |
|---|---|
| Task types | `components/tasks/index` (full 1–23 table), `components/tasks/{http,script,soap,notification,trigger,get-instances,get-instance,fan-out,state-store,cache-aside,dapr-conversation,external-http,python,dapr-http-endpoint,dapr-binding,dapr-service,dapr-pubsub}` |
| Functions | `components/functions/{index,built-in,custom}` |
| Concepts | `concepts/{authorization,incidents,transition-pipeline,instance-data,user-integration}` |
| How-to | `how-to/{human-task-approval,subflow-overrides,instance-filtering,attribute-indexes,observability,async-sync,error-handling,event-driven-workflows,resource-lock,view-selection}` |
| Configuration | `configuration/{service-discovery,task-invocation,caller-role-provider,caching,telemetry,scripting,python,workflow-execution,header-limits,server-timeout,url-templates}` |
| API | `api-reference/rest-api` (transitions are `PATCH …/transitions/{key}`), `api-reference/init-service` |
| Views (pseudo-ui) | `how-to/view-consept/{index,view-structure,data-flow,designer-guide,schema-definition,aksiyonlar}` |
| Tools | `tools/{workflow-cli,template-cli,forge-studio,mcp-runtime,quick-runner,ai-assisted-development}` |

## Version-tag rule

Whenever a skill fetches from a `vnext-*` repo or a `BBT.Workflow.*` NuGet, it uses the workspace's `vnext.config.json` version fields as the tag selector:

| Workspace field | Pins to |
|-----------------|---------|
| `schemaVersion` | `vnext-schema` repo tag (`v{schemaVersion}`) |
| `runtimeVersion` | `BBT.Workflow.*` NuGet versions (closest compatible) |

If the exact tag is missing:
1. Try `master` (or `main`) branch — warn the user the output may not match the runtime.
2. Prefer the workspace's own `node_modules/@burgan-tech/vnext-schema` copy — that is what `npm run validate` uses (`component-schemas.md`).
3. If neither is available, halt and ask the user. **Never guess an enum or required field.**

## Access budget — when to use which

| Question | First try | Then |
|----------|-----------|------|
| "What enum values does workflow `type` accept?" | `workflow-definition.schema.json` via `component-schemas.md` (always first — schema is law) | — |
| "Since which runtime version does X exist / is it deprecated?" | `runtime-feature-matrix.md` (this repo, generated from vnext-meta) | `vnext-meta/features.json` raw, then the `release-v0-0-NN` blog post |
| "Validate rejects it but the runtime accepts it (or vice versa)?" | `schema-runtime-gaps.md` (this repo) | vnext-meta `known-issues.json` / `migrations.json` |
| "How does pseudo-UI bind LOV options?" | Context7 (`"pseudo-ui x-lov source"`) | WebFetch `/docs/how-to/view-consept/view-structure` |
| "What's the exact `ScriptContext.Body` shape?" | `csx-contracts.md` (this repo) | NuGet symbol package for `BBT.Workflow.Scripting` |
| "Does this MockLab rule operator exist?" | `mocklab-spec.md` (this repo) | GitHub raw on `burgan-tech/mocklab` README |
| "How do I scaffold/run an integration test (template, API surface)?" | `integration-test-patterns.md` (this repo) | `GETTING_STARTED.md` raw on `vnext-integration-test` |
| "Is there a doc about SubFlow vs SubProcess runtime callback?" | Context7 (`"subflow subprocess runtime callback"`) | WebFetch `/docs/components/workflow` |

Prefer in-repo references for shape and rules of thumb; fall back to live sources for specifics or evolving topics.

## Token-efficient fetching

- **Always fetch raw markdown / JSON**, not rendered HTML pages, when possible. GitHub `raw.githubusercontent.com` URLs cost dramatically less than the docs portal HTML.
- **Cache within a single skill invocation.** If you already loaded `workflow-definition.schema.json` for the user's question 1, don't load it again for question 2.
- **Targeted Context7 queries** beat broad WebFetch. Phrase queries with vocabulary words: `"pseudo-ui ScrollView vocabulary"`, `"workflow auto transition complementary pair"`.
- **Don't fetch the world.** If the user asked about Tasks, don't pull workflow + view + schema unless the answer crosses boundaries.
