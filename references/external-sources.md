# External Sources — All URLs in One Place

This is the plugin's address book for "live" knowledge — everything an agent might fetch at runtime. When a skill or the architect agent needs information beyond the in-repo references, it comes here.

## Source registry

| Source | URL | What it provides | Access pattern |
|--------|-----|------------------|----------------|
| **vnext-schema / schemas** (CRITICAL — canonical contracts) | https://github.com/burgan-tech/vnext-schema/tree/master/schemas | The official JSON Schema for each component type (workflow, view, task, schema, function, extension). **Every scaffolding skill fetches this BEFORE asking the user anything.** | `https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/schemas/{componentType}.json` |
| **vnext-schema / vocabularies** | https://github.com/burgan-tech/vnext-schema/tree/master/vocabularies | `x-*` keyword definitions consumed by views (x-labels, x-lov, x-lookup, x-conditional, x-validation, x-enum, roles) | `https://raw.githubusercontent.com/burgan-tech/vnext-schema/v{schemaVersion}/vocabularies/{file}.json` |
| **vnext-docs portal** | https://burgan-tech.github.io/vnext-docs/ | Component reference pages, how-to guides, API reference | Context7 MCP (registered) + WebFetch |
| **vnext-docs repo** | https://github.com/burgan-tech/vnext-docs | Markdown source for the portal (sidebar config, both locales) | GitHub raw / `gh` CLI |
| **vnext-example repo** | https://github.com/burgan-tech/vnext-example | The reference workspace — working examples of every component type, MockLab seeds, integration tests | GitHub raw / local clone |
| **mocklab repo** | https://github.com/burgan-tech/mocklab | Authoritative MockLab seed format, rule operators, sequence behavior | GitHub raw / WebFetch |
| **vnext-integration-test SDK** | https://github.com/burgan-tech/vnext-integration-test | Source for `VNext.Testing.Sdk`, `IntegrationTestBase`, `VNextApiClient` | GitHub raw / WebFetch |
| **BBT.Workflow.Domain NuGet** | https://www.nuget.org/packages/BBT.Workflow.Domain/ | Domain primitives consumed by `.csx` mappings | NuGet API; pin to closest `runtimeVersion` |
| **BBT.Workflow.Scripting NuGet** | https://www.nuget.org/packages/BBT.Workflow.Scripting/ | Mapping interfaces (`IMapping`, `IOutputHandler`, `IConditionMapping`, `ITimerMapping`, `ISubFlowMapping`, `INotificationMapping`), `ScriptContext`, `ScriptResponse`, `ScriptBase` | NuGet API |
| **BBT.Workflow.Definitions NuGet** | Companion to `BBT.Workflow.Domain` (same release cadence) | Concrete task types (`HttpTask`, `NotificationTask`, `SoapTask`, ...), `TimerSchedule`, `StandardTaskResponse` | NuGet API |
| **VNext.Testing.Sdk NuGet** | (Built and published from `vnext-integration-test`; verify if public or private) | xUnit collection fixture, API client, Docker stack manager | NuGet API |
| **Context7 — vnext-docs library** | https://context7.com/burgan-tech/vnext-docs | Semantic search index over the docs portal | `mcp__context7__resolve-library-id` + `query-docs` |
| **Material Symbols catalog** | https://fonts.google.com/icons | Source-of-truth for `Icon.name` / `Button.icon` values (lowercase `snake_case`) | Web search (rarely needed; common mappings memorized in `view-roles.md`) |

## Version-tag rule

Whenever a skill fetches from a `vnext-*` repo or a `BBT.Workflow.*` NuGet, it uses the workspace's `vnext.config.json` version fields as the tag selector:

| Workspace field | Pins to |
|-----------------|---------|
| `schemaVersion` | `vnext-schema` repo tag (`v{schemaVersion}`) |
| `runtimeVersion` | `BBT.Workflow.*` NuGet versions (closest compatible) |

If the exact tag is missing:
1. Try `master` (or `main`) branch — warn the user the output may not match the runtime.
2. Fall back to the in-repo snapshot in `references/concepts/component-schemas.md` — warn the user offline mode is in use.
3. If no snapshot covers it, halt and ask the user. **Never guess an enum or required field.**

## Access budget — when to use which

| Question | First try | Then |
|----------|-----------|------|
| "What enum values does workflow `type` accept?" | `vnext-schema/schemas/workflow.json` (always first — schema is law) | — |
| "How does pseudo-UI bind LOV options?" | Context7 (`"pseudo-ui x-lov source"`) | WebFetch `/docs/how-to/view-consept/view-yapisi` |
| "What's the exact `ScriptContext.Body` shape?" | `csx-contracts.md` (this repo) | NuGet symbol package for `BBT.Workflow.Scripting` |
| "Does this MockLab rule operator exist?" | `mocklab-spec.md` (this repo) | GitHub raw on `burgan-tech/mocklab` README |
| "How does the integration SDK's `WaitForStateAsync` work?" | `integration-test-patterns.md` (this repo) | GitHub raw on `vnext-integration-test` |
| "Is there a doc about SubFlow vs SubProcess runtime callback?" | Context7 (`"subflow subprocess runtime callback"`) | WebFetch `/docs/components/workflow` |

Prefer in-repo references for shape and rules of thumb; fall back to live sources for specifics or evolving topics.

## Token-efficient fetching

- **Always fetch raw markdown / JSON**, not rendered HTML pages, when possible. GitHub `raw.githubusercontent.com` URLs cost dramatically less than the docs portal HTML.
- **Cache within a single skill invocation.** If you already fetched `workflow.json` for the user's question 1, don't fetch it again for question 2.
- **Targeted Context7 queries** beat broad WebFetch. Phrase queries with vocabulary words: `"pseudo-ui ScrollView vocabulary"`, `"workflow auto transition complementary pair"`.
- **Don't fetch the world.** If the user asked about Tasks, don't pull workflow + view + schema unless the answer crosses boundaries.
