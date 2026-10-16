# Runtime Operations — Locks, Caches, Discovery, URL Templates

> Audience: domain authors running or debugging a domain against a local or shared runtime
> (v0.0.100). This is the "why did the runtime answer 409 / 304 / stale?" reference. Helm and
> operator detail is kept to what an author needs to *recognise*, not to operate. For tracing and
> log lookup see `observability.md`; for incident/retry see `incidents-and-retry.md`.

## 1. Lock model in plain terms

**Busy is the mutex.** Once a transition is admitted, the instance row is flipped `Active → Busy`
and the whole pipeline (including its auto-chain) runs with **no held lease and no further
checks**. The only distributed lock left is a short status lock `vnext:{domain}:{flow}:{id}` taken
around that flip (a Postgres compare-and-set since #975; the `Transition.Settle` span tags the
outcome as `vnext.settle.cas = flipped | lost | skipped`).

### Admission table (`ITransitionAdmissionService`)

| Request kind | While instance is Busy | Otherwise |
|---|---|---|
| Regular transition (state or shared) | **409** `Instance:100031` | Reserve `Active→Busy` under the short lock, then run |
| `cancel` / `exit` / timeout (workflow-level `attributes.cancel` / `attributes.exit`) | Accepted — takes over the Busy flag under the lock | Same |
| `updateData` | Accepted unconditionally — no Busy check, no flip; writes serialise on the `FOR UPDATE` funnel | Same |
| Owner re-entry (subflow resume, long-poll `ack`, pre-reserved job) | No check, no reserve | — |
| Forwardable transition on a parent with an active SubFlow (0.0.100) | **Proxied to the leaf** — the parent takes no lock, Busy or job; the leaf runs its own admission | Same |

### What the client sees

| Code | HTTP | Meaning / action |
|---|---|---|
| `Instance:100031` | 409 | "Instance is busy; transition '{key}' cannot be accepted while another transition is queued or executing" — poll state until `metadata.effectiveStatus` leaves `Busy`, then retry |
| `Transition:100009` | 409 | The same async transition is already queued for this instance |
| `Execution:200010` | 409 | `resourceLock` conflict — another instance holds the resource key; the losing instance is marked Faulted (`F`) but the caller gets a clean 409 |
| `Instance:100035` | 409 | Instance-data `FOR UPDATE` lock wait exceeded — retry |
| `Instance:100036` | 503 | Instance-data write statement timeout — transient, relays redeliver |
| `Instance:100032` | 503 | Subflow terminal-outcome lock not acquired — transient, inbox relay redelivers |
| `Instance:100027` | 400 | `retry` on an instance that is not Faulted |
| `Instance:100037` | 404 | `incidents/active` when no incident is open — normal; re-read state |
| `Instance:100031` on a SubFlow parent | 409 | (0.0.100 proxy) the child just completed or does not exist yet behind an open correlation — retry |
| `Instance:100045` | 409 | `retry` on a `history: "none"` instance — not supported (`workflow-types.md` §8) |
| — | 413 | Async transition body over **10 MB** (Kestrel `MaxRequestBodySize`, 0.0.99 #1067; before that > ~2 MiB could strand the instance Busy) |

### SubFlow transition proxy (0.0.100, #1085)

The accept-time "chain reservation" is gone on the sending side. A transition sent to a **parent with
an active SubFlow** is forwarded **unchanged** down the active-correlation chain to the deepest leaf:

- The **parent writes nothing** — no status lock, no Busy flip, no job. The **leaf** validates the
  request, swaps `x-storage` file content, flips its own Busy and schedules its own job.
- **Leaf rejections reach the client synchronously**: 400 / 403 / 409 come back on the call (before
  0.0.100 the parent answered 202 and the failure surfaced later). Update tests that expected a 202.
- The mode is resolved once at the parent (`executionType` → `?sync`) and the leaf runs in it. The
  response carries the **parent's** id and the **child's** status.
- A child that has just completed, or does not exist yet behind an open correlation, answers
  **409 `Instance:100031` on the parent** — retry after re-reading state.
- **Not proxied** (still run on the parent): `updateData`, `cancel`, `exit`, timeouts, and a parent
  shared transition that is available in the parent's current state.
- Mixed-version domains need no action (deprecation `subflow-chain-reserve-claim`; an older parent's
  reserve is still accepted by a 0.0.100 leaf).
- A failed subflow *start* still **faults the parent** with an incident; `retry` repeats the start
  (#1026, 0.0.95).
- `metadata.status` on a parent is Busy for the child's whole lifetime *by design*; branch on
  `metadata.effectiveStatus` (deepest active SubFlow's status) instead.

### Known issue — `pre-reserved-job-failure-can-strand-busy` (open)

An async accept flips Busy before the 202; if the job re-entry then fails with a non-lock Result
error (e.g. policy re-validation), `JobFailed` (EventId 40075) is logged and the instance is left
Busy with **no owner** — retry needs Faulted, and there is no fault. **Recovery:** fire the
workflow's `cancel` or `exit` transition (`PATCH .../transitions/{cancelKey}` — exempt from the 409).
Prefer `?sync=true` for transitions whose policy may change between accept and re-entry.

## 2. Cache & ETag — what a tester must know

### State function (`GET .../functions/state`, long-poll)

- `ETag = h(responseShapeVersion | instanceId | effectiveState | status | flowVersion | callerHash)`,
  `callerHash = h(role | roles | actor | culture | extensions | version)`. Computed from a one-row
  fingerprint projection: a matching `If-None-Match` returns **304 with no cache access and no
  build**. Deterministic across pods, so 304 survives a Redis flush.
- Response header `X-Entity-ETag` is the **DB row version** (RFC 7232 quoted) — a different thing
  from `ETag`; use it for concurrency, not for conditional GET.
- **Accepted gap (#864):** scheduled-transition job rows are not fingerprint material. A same-state
  re-arm (`updateData` / `$self`), an inline `A→B→A` chain, or a fired job rejected under a lock
  conflict can leave a long-poller on 304 with a stale `kind: "scheduled"` / `executeAtUtc` until
  the next state/status change. The `timeout` block adds no gap.

### Data function (`.../functions/data`)

- `etag = h(instanceId | latest InstanceData.ETag | flowVersion | callerHash)`; `callerHash`
  **excludes extensions**. `?version=` bypasses the cache.
- TTL: `InstanceFunctionCache:DefaultTtlSeconds` (60) or per-workflow `functionCache.ttlSeconds`.

### Component cache (#867 / #898)

| Key | Holds |
|---|---|
| `{type}:{domain}:{key}:full:{v}` | full component envelope for one version |
| `{type}:{domain}:{key}:gen` | generation token — publish bumps it |
| `{type}:{domain}:{key}:res:{gen}:{spelling}` | version-resolution memo |

- L1 in-process cache **on** by default (`L1Enabled: true`, `L1SizeLimitMb: 64`), keyed by the same
  Redis keys and invalidated by the generation bump — no separate protocol.
- `ComponentCache:GenerationMemoSeconds` is **5** (`ComponentCacheOptions` code default is 5; the
  runtime page `docs/runtime/component-cache-generation-memo.md` still says code default 0 — stale).
  Consequence: pods other than the publisher may serve the **old** generation for ≤ 5 s after a
  publish, rollback or deactivation. **Wait N + 1–2 s after the last publish before smoke tests.**
- Manual flush: `POST /api/v1/utilities/invalidate`.

## 3. Domain discovery via Dapr

Cross-domain calls (SubFlow/SubProcess/trigger tasks, `context.Related`, remote `authorize`) resolve
the target domain through `ServiceDiscovery:Provider`:

| Provider | Endpoint resolution | Transport |
|---|---|---|
| `http` (default) | registry lookup → base URL | plain HTTP |
| `dapr` (#964 0.0.91, #976 0.0.92, #997 0.0.94, #1022 0.0.95) | convention app-id (no registry call by default) | Dapr service invocation, mTLS |

### App-id convention (`VNextAppIds.cs`)

| Role | App-id |
|---|---|
| Orchestrator | `vnext-{domain}-app` |
| Execution | `vnext-{domain}-execution-app` |
| Inbox / Outbox worker | `vnext-{domain}-worker-inbox-app` / `vnext-{domain}-worker-outbox-app` |
| DB migrator | `vnext-{domain}-db-migrator-app` |

`{domain}` is lower-cased. Config overrides: `OrchestrationApi:AppId`, `ExecutionApi:AppId`.

### Registration at startup (`DomainRegistrationService`)

`POST {ServiceDiscovery:BaseUrl}/{ServiceDiscovery:Domain}/workflows/{RegistryFlow}/instances/start?sync=true`
with `{ domainName, baseUrl, healthUrl, appId }` — `baseUrl` = `vNextApi:BaseUrl`, `healthUrl` =
`{baseUrl}/health`, `appId` = `DAPR_APP_ID`. **`vNextApi:BaseUrl` must not be localhost outside
`Development`** — the host refuses to start.

### Resolution steps (`dapr` provider)

1. `DomainOverrides[domain] == "url"` → fall back to the `http` shape for that domain.
2. `appId = vnext-{domain}-app` (convention).
3. `DomainOverrides[domain]` set to anything else → that is the app-id.
4. `RequireRegistryEntry=true` → registry lookup (cached `CacheSeconds`); unknown domain fails
   `DomainEndpointNotFound`; `PreferRegistryAppId=true` lets the registry's `appId` win.
5. `NamespaceTemplate` non-empty → `{appId}.{namespace}`.
6. Logged as `dapr://{appId}/` (label only; routing is by `EndpointKind`). Unknown domain with the
   default `RequireRegistryEntry=false` surfaces later as sidecar `ERR_DIRECT_INVOKE` →
   `remote_network_error` (transient).

### Retry policy

| Profile | Services | Attempts |
|---|---|---|
| Read | instance query, authorize/permissions, related-data | transport retries |
| Mutating | start, transition, complete, busy, subflow callbacks, retry | **exactly once** — a duplicate `instances/start` is data corruption (`vNextApi:EnableRetryOnMutating` is the emergency switch, keep `false`) |

### Config keys

| Key | Default | Note |
|---|---|---|
| `ServiceDiscovery:Enabled` | `false` | |
| `ServiceDiscovery:Provider` | `http` | `http` \| `dapr`; unknown falls back to `http` |
| `ServiceDiscovery:BaseUrl` / `:Domain` / `:RegistryFlow` | `""` | registry address, registry domain, registration flow |
| `ServiceDiscovery:Dapr:NamespaceTemplate` | `""` | single token `{domain}`; Helm renders it from the release namespace |
| `ServiceDiscovery:Dapr:PreferRegistryAppId` | `true` | only meaningful with `RequireRegistryEntry=true` |
| `ServiceDiscovery:Dapr:RequireRegistryEntry` | `false` | `false` = pure convention, no registry traffic |
| `ServiceDiscovery:Dapr:CacheSeconds` | `60` | positive-lookup cache, errors never cached |
| `ServiceDiscovery:Dapr:DomainOverrides` | `{}` | `domain: appId` or `domain: "url"` |
| `ServiceDiscovery:Cache:Enabled` | `false` | `http` provider only; entries have no TTL |
| `ServiceDiscovery:Cache:RefreshIntervalSeconds` | `0` | 0 = event-driven only |
| `ServiceDiscovery:Cache:DomainListEndpointTemplate` | `/{0}/functions/domain-list` | warm-up reads the whole registry in one call (needs vnext-discovery-runtime ≥ 0.0.7) |

### Cache invalidation is an event (0.0.95)

- **CD must call `POST /api/v1/definitions/publish/completed` once after the last component
  publish.** Status is **always 200**; gate on body `success` (`false` if any hook failed).
  `hooks[].outcome` = `Refreshed | SkippedNotOwner | Disabled | Failed`. `wf sync/update/reset`
  (CLI ≥ 1.0.14) call it automatically. `GET /api/v1/definitions/re-initialize` is **removed** (404).
- Operator shortcut: `POST /api/v1/utilities/discovery/refresh` → `{ "outcome": "Refreshed" | ... }`.
- Unreachable domains are evicted failure-driven (`UnreachableEvictionCooldownSeconds` 30).

### Local development

- Runtime sidecars (`vnext/etc/{orchestration,execution}/dapr/config.yaml`) pin **mdns** and export
  traces with the **`otel:`** key (an `otlp:` block is silently ignored):

  ```yaml
  spec:
    nameResolution:
      component: "mdns"
    tracing:
      samplingRate: "1"
      otel:
        endpointAddress: "otel-collector:4317"
        protocol: "grpc"
        isSecure: false
  ```

  The toolkit's `templates/etc/dapr/config.yaml.tmpl` uses the same block.
- **Cross-domain lab:** `vnext-example/labs/cross-domain` (`lab.sh images | up | verify | status`):
  `core` :4201, `partner` :4211, `credit` :4221, `discovery` :4231. Lab app-ids are
  `vnext-app-{domain}` (not the convention), so it sets `RequireRegistryEntry=true` **and**
  `PreferRegistryAppId=true` in `orchestration.overlay.env`.
- **Helm:** `global.dapr.nameResolution` (`kubernetes` / `v1`,
  `{{.ID}}-dapr.{{.Namespace}}.svc.cluster.local:{{.Port}}`), `global.dapr.crossNamespaceTemplate`,
  `global.dapr.crossDomainTargets`; the chart sets `UrlTemplates__BasePath: ""` → hrefs come back
  **without** the `/api/v1` prefix (gateway adds it). `Provider=dapr` is still set per environment.

## 4. URL templates — single `BasePath` (#871, 0.0.79)

`Effective(href) = override(X) ?? Normalize(BasePath) + BuiltInRelative(X)` — only client-facing hrefs
(state, transition, function, catalog links) are affected; internal `InstanceUrlTemplates` are not.

| `UrlTemplates.BasePath` | hrefs look like | When |
|---|---|---|
| section absent | `/api/v1/{domain}/workflows/…` | plain runtime, no gateway |
| `""` (Helm default) | `/{domain}/workflows/…` | gateway prepends the prefix |
| `/vnext-api/v1` | `/vnext-api/v1/{domain}/…` | gateway with a path prefix |
| `/api` | `/api/{domain}/…` | legacy pre-0.0.79 layout |
| per-endpoint override (`UrlTemplates__Transition=…`) | verbatim, BasePath **not** prepended | route structure differs after the prefix |

Tests must not hard-code `/api/v1` when parsing hrefs; read them from the state body.

## 5. Monitor API removed (#982, 0.0.93)

`BBT.Workflow.Monitor.HttpApi.Host` (`/api/v1/monitor`, port 4203) and its sidecar are gone
(vnext-meta deprecation `monitor-api-host`, severity error). Replacements on the orchestrator:

| Was on Monitor | Use instead |
|---|---|
| instance dashboards / counts | `GET …/instances?filter=…&sort=…` with `groupBy` / `aggregations` (in the filter envelope or as query params) |
| error inspection | `GET …/instances/{id}/incidents`, `…/incidents/active` |
| step detail | `GET …/instances/{id}/functions/tasks`, `…/functions/actions?taskId=` |
| tree view | `GET …/instances/{id}/functions/instance-correlation` (0.0.99; the old `hierarchy` path is **404**, no alias) |
| ad-hoc ops | MCP server `vnext/tools/BBT.Workflow.Mcp.Server`; logs + APM (see `observability.md`) |

## 5.1 Read endpoints added in 0.0.99 / 0.0.100

| Call | Since | Notes |
|---|---|---|
| `GET …/instances/{id}/functions/instance-correlation` | 0.0.99 (#1067, breaking) | `{ "root": node }`; node: `currentState` (deepest active descendant), `ownState`, `subFlowType` `S`/`P`, `terminalOutcome`, links, `children[]`. Batched, parallel, cross-domain; an incomplete subtree has `resolved: false` + `unresolvedReason` `depth-exceeded` \| `hop-failed` \| `instance-missing` \| `hop-unsupported` (partner on an older runtime). Bounds `Workflow:InstanceCorrelation` (`MaxDescentDepth` 20, `FanoutParallelism` 8, `MaxConcurrentHops` 32). Replaces `hierarchy`; MCP tool `get_instance_correlation`; span `Instance.Read/instanceCorrelation`. Add the path to gateway allow-lists |
| `GET …/instances/{id}/transitions/{key}/metrics`, `…/states/{key}/metrics` | 0.0.99 (#1030) | Every attempt with its tasks (`hook`, `order`, status, duration, error) — `observability.md` §5.1 |
| `GET /{domain}/functions/{f}/metrics`, `GET /{domain}/workflows/{wf}/functions/{f}/metrics` | 0.0.99 (#1030) | Only for functions with `attributes.executionLog: "E"` |
| `GET …/instances/{id}/data/history`, `…/data/history/{rowId}` | 0.0.100 (#1079) | **Internal** (Forge Instance Monitor). Same exposure as the data function; hidden from Swagger but **not blocked** — keep it off the public gateway |
| `POST …/instances/schedule?scheduleId=` | 0.0.100 (#1076) | Scheduler-driven start — `workflow-types.md` §6 |
| `GET \| HEAD …/instances/{id}/functions/file?file=` | 0.0.100 (#1085) | `x-storage` file read. **`file` is a reserved system function name** — a domain function keyed `file` is shadowed |

## 5.2 Platform notes with no author action

- **gRPC transport removed** (0.0.100, #1083): Orchestration always calls Execution over Dapr HTTP.
  `ExecutionApi:Transport` / `Kestrel:GrpcPort` are gone; nothing changes in a domain package.
- **Co-hosting several domains** (`APP_DOMAINS`, 0.0.100, #1088/#1089, **experimental**, not in Helm):
  one runtime set serves several domains on one database (co-hosted flow schemas are prefixed
  `<domain>_`; optional `ConnectionStrings:Domains:<domain>`). `APP_DOMAIN` stays the primary. Calls
  between co-hosted domains run in-process. Treat it as a platform decision, not something to
  design a domain around.
- **Runtime topics renamed** (0.0.100, #1095): `vnext.{domain}.{environment}.*`; operators must drain
  the outbox before the upgrade. Domain-authored topics: `observability.md` §7.
- **Sandbox baseline** gained `System.ObjectModel` (0.0.99): `foreach` over an `ExpandoObject` no
  longer fails with CS0012 — no `allowedAssemblies` entry needed for it.

## 6. Local runtime checklist before testing a domain

1. **Ports:** orchestrator `http://localhost:4201` (`.http` `@baseUrl`), init `:3005`, MockLab
   `:3001` (toolkit compose), OpenObserve `:5080`, Kibana `:5601` when the observability profile runs.
2. **After `wf publish` / `npm run build && publish`:** wait `GenerationMemoSeconds + 2` s (≈ 7 s)
   before the first smoke request, or `POST /api/v1/utilities/invalidate`.
3. **Cross-domain in the workspace:** if the domain registers, `vNextApi:BaseUrl` must be
   reachable and non-localhost unless `ASPNETCORE_ENVIRONMENT=Development`; CD must post
   `definitions/publish/completed`.
4. **ETag headers:** send `If-None-Match` from the last `ETag` on state polls; expect 304 with an
   empty body. Do not confuse `ETag` with `X-Entity-ETag`.
5. **No gateway locally ⇒ no 403 on reads:** role headers (`role`, `act_sub`, `sub`) are trusted as
   sent; a 403 you see locally is the runtime's `authorize` decision, not the gateway.
6. **409 `Instance:100031` is not a bug:** poll `metadata.effectiveStatus`, then retry. If it never
   leaves Busy and there is no `incident`, see the known issue in §1 → `cancel`/`exit`. On a SubFlow
   parent (0.0.100) leaf 400/403/409 come back synchronously — assert them on the call itself.
7. **hrefs:** parse `BasePath`-relative links from responses instead of building paths by hand.

## Sources

- Runtime `vnext` @ `f06961ec` (0.0.100):
  `src/BBT.Workflow.Domain/Execution/Transitions/Pipeline/ITransitionAdmissionService.cs`,
  `src/BBT.Workflow.Domain/WorkflowErrorCodes.cs`, `src/BBT.Workflow.Domain/Logging/WorkflowErrors.cs`,
  `src/BBT.Workflow.Application/SubFlow/Services/SubflowProxyService.cs`,
  `src/BBT.Workflow.HttpApi.Shared/Microsoft/Extensions/DependencyInjection/WorkflowApiBaseServiceCollectionExtensions.cs` (error → HTTP status map),
  `src/BBT.Workflow.Execution.Abstractions/VNextAppIds.cs`,
  `src/BBT.Workflow.Application/Discovery/{ServiceDiscoveryOptions,DaprDiscoveryOptions,DiscoveryCacheOptions}.cs`,
  `src/BBT.Workflow.Infrastructure/Discovery/{DaprDomainDiscoveryProvider,DomainRegistrationService}.cs`,
  `src/BBT.Workflow.Application/Caching/ComponentCacheOptions.cs`,
  `orchestration/BBT.Workflow.Orchestration.HttpApi.Host/Controllers/{Utilities/UtilityController,Definitions/DefinitionController,Instances/InstanceController}.cs`,
  `docs/runtime/{remote-app-service-architecture,dapr-invocation-transport,discovery-endpoint-cache,publish-completed-hook,component-cache-generation-memo,state-function-cache-and-etag,dapr-component-footprint,instance-correlation-tree,transition-and-state-metrics,function-execution-metrics}.md`,
  `docs/architecture/{subflow-execution,subflow-transition-proxy}.md`, `docs/domain/scheduled-workflow-start.md`, `etc/{orchestration,execution}/dapr/config.yaml`.
- PRs: #864 (ETag gap decision), #867/#898 (component cache), #871 (BasePath), #964, #975,
  #976, #982, #997, #1022, #1026, #1030, #1067, #1076, #1079, #1083, #1085, #1088/#1089, #1095.
- vnext-docs: `configuration/{service-discovery,caching,url-templates,telemetry}.md`,
  `how-to/{resource-lock,async-sync}.md`, `concepts/transition-pipeline.md`, release notes v0.0.99 / v0.0.100.
- vnext-meta (master): features `discoveryDomainListWarmup` (0.0.94), `discoveryEventDrivenInvalidation`,
  `publishCompletedHook` (0.0.95), `instanceEffectiveStatus`, `instanceCorrelationTree` (0.0.99),
  `instanceDataHistory`, `scheduledWorkflowStart`, `multiDomainHosting` (0.0.100); deprecations `monitor-api-host`,
  `definitions-re-initialize-removed`, `subflow-chain-reserve-claim`; migration `cd-must-call-publish-completed`; known issue
  `pre-reserved-job-failure-can-strand-busy`.
- Helm `vnext-helm-charts/charts/vnext/values.yaml` (`global.dapr.*`, `UrlTemplates__BasePath`).
- Lab: `vnext-example/labs/cross-domain/{README.md,lab.sh,orchestration.overlay.env}`.
