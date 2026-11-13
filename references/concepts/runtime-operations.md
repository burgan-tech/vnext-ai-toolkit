# Runtime Operations — Locks, Caches, Discovery, URL Templates

> Audience: domain authors running or debugging a domain against a local or shared runtime
> (v0.0.105). This is the "why did the runtime answer 409 / 304 / stale?" reference. Helm and
> operator detail is kept to what an author needs to *recognise*, not to operate. For tracing and
> log lookup see `observability.md`; for incident/retry see `incidents-and-retry.md`.

## 1. Lock model in plain terms

**Busy is the mutex.** Once a transition is admitted, the instance row is flipped `Active → Busy`
and the whole pipeline (including its auto-chain) runs with **no held lease and no further
checks**. The only distributed lock left is a short status lock `vnext:{domain}:{flow}:{id}` taken
around that flip (a Postgres compare-and-set since #975; the `Transition.Settle` span tags the
outcome as `vnext.settle.cas = flipped | lost | skipped`).

A transition-level `resourceLock` is a different thing: a lock on a **business resource** shared by
many instances, keyed by a script. Conflict policy, error-boundary rerouting, release timing and the
provider choice are in `resource-lock.md`.

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
| `Execution:200010` | 409 | `resourceLock` conflict under `onConflict: Abort` (default), or a failed `Extend` — another instance holds the resource key; the losing instance is **Faulted** (`F`). Start a new instance. Since 0.0.106 an `errorBoundary` rule for this code can reroute the instance instead (no 409 then) — `resource-lock.md` §2 |
| `Execution:200014` | 409 | (0.0.106) `resourceLock` conflict under `onConflict: Reject` — the instance is **untouched** (same state, Active, no incident); repeat the same call once the lock frees (`resource-lock.md` §2) |
| `Instance:100035` | 409 | Instance-data `FOR UPDATE` lock wait exceeded — retry |
| `Instance:100036` | 503 | Instance-data write statement timeout — transient, relays redeliver |
| `Instance:100032` | 503 | Subflow terminal-outcome lock not acquired — transient, inbox relay redelivers |
| `Instance:100027` | 400 | `retry` on an instance that is not Faulted |
| `Instance:100037` | 404 | `incidents/active` when no incident is open — normal; re-read state |
| `Instance:100031` on an interaction-wait state (`subType: 5` + `interaction`) | 409 | expected for client transitions; data goes in through `updateData`, and the timer takes the parked Busy over (0.0.102). On ≤ 0.0.101 `updateData` continuations were dropped here — upgrade, then `cancel`/`exit` stuck instances (`long-poll-interaction.md` §3b). Since 0.0.105 concurrent `updateData` calls continue the parked chain **once** (claim on `Instances.ContinuationClaimedAt`; a loser logs 10182) — before that each one re-ran the automatic chain |
| `Instance:100031` on a SubFlow parent | 409 | (0.0.100 proxy) the child just completed or does not exist yet behind an open correlation — retry |
| `Instance:100045` | 409 | `retry` on a `history: "none"` instance — not supported (`workflow-types.md` §8) |
| `Instance:100051` | 404 | (0.0.102) a floating version request (none, `latest`, `2`, `2.1`) matches only **pending** versions above the flow's default — send an explicit version or move the pointer (§2.1) |
| `Instance:100052` | 409 | (0.0.102) the flow's default-version pointer is malformed or matches no published version — start, transition, list and GET of that flow fail closed; fix it with `set-default` (§2.1) |
| `Instance:100053` | 503 | (0.0.102) the version registry could not be read — transient, retry; check the database |
| `Transition:100025` | 400 | (0.0.105) the transition declares rule-based `schemas` and no entry matched — instance unchanged; add a rule-less last entry or fix the rule (`transition-pipeline.md` §1.1) |
| `Function:800006` | 400 | (0.0.105, breaking) a rule-based function `inputSchema` matched no entry for a request with a body (`function-mapping-pattern.md` §9) |
| `Authorization:110006` | 503 | (0.0.105, #1299) a rule read `context.Caller` and the caller-role provider could not answer — the selection / automatic rule / timer fails instead of taking the fallback; retryable (morph-idm reachability, `csx-contracts.md` § Caller roles). Never cached |
| `Authorization:110005` | 400 | (0.0.105) workflow-scoped `authorize` without `type`, or an unknown `type` — only `type=instance` exists (`roles-and-authorization.md`) |
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

- `etag = h(generation | instanceId | latest InstanceData.ETag | effectiveState | flowVersion | callerHash)`;
  `callerHash` **excludes extensions**. `?version=` bypasses the cache. **`effectiveState` joined the
  material in 0.0.105 (#1188):** extension output depends on the state, so up to 0.0.104 a transition that
  wrote no data kept the ETag and a conditional request got **304 with the previous state's extension
  output** (a client then re-sent a stale `nextTransition` and got 403). The cache entry keeps a state-free
  `dataEtag` for the data portion only; extension output is never cached and runs fresh on every 200.
  Clients on older runtimes: re-read the data function **without** `If-None-Match` after a transition when
  you depend on extension output.
- **One-time ETag change (0.0.105, #1195):** representation ETags of bodies containing an escaped `\\`,
  `\"` or `\/` change once (the old hasher dropped a character there) — such clients see one `200` instead of
  a `304` after the upgrade, also between old and new pods during a rolling deploy.
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
- **Floating references on long publish histories** (known issue
  `floating-version-resolution-loads-every-version`, `>=0.0.45`, fixed in **0.0.106**, #1303 / #1304):
  resolving a floating version (`"1.0.0"` artifact, `"1.0"`, `"1"`, `"latest"`, none) — and every
  publish — loaded the stored body of **every** published version. A component with hundreds of large
  versions ran the orchestration pods out of memory, and the swallowed `OutOfMemoryException` dropped the
  newest rows, so an **older version won silently** and stayed cached under the `res` key for up to an
  hour on every pod (restarting pods does not help — the answer lives in Redis). On 0.0.103–0.0.105 with
  such a component: reference the **full** version (`1.0.0-pkg.1.0.123+core`) from consuming flows and
  raise the orchestration memory limit, then upgrade. Since 0.0.106 the choice is made from version
  strings and one body is loaded; an unreadable winning row **fails the request** instead of answering an
  older version. The cache shape moved to `s3` (keys `…:s3:full:…`, `…:s3:res:{gen}:…`): after the
  upgrade each component resolves once per pod from the database. A partial request (`1.0`, `1`,
  `latest`) can still resolve to a pre-release (`1.0.2-beta.1` beats `1.0.1` by SemVer) — open product
  decision; do not publish pre-release builds into a line that floating callers follow.

### 2.1 Flow default version — publish ≠ activate (0.0.102, #1130)

Publishing a version makes it **reachable**; the flow's **default-version pointer** decides which version
a *floating* request starts with (no version, `latest`, `2`, `2.1`). Versions above the pointer stay
**pending** until a caller names them. **Opt-in per flow:** a flow without a pointer behaves exactly as
before (newest published version wins). A domain whose core package lacks the registry flow is unaffected.

The pointer is an instance of the system flow **`sys-version-registry`** (ships with
`@burgan-tech/vnext-core-runtime`), **instance key = flow key**, data
`{ "type": "Flow", "defaultVersion": "…", "reason": "CHG-12345" }` (`type` is informational):

```http
### Create the pointer (once per flow)
POST {{baseUrl}}/api/v1/{{domain}}/workflows/sys-version-registry/instances/start?sync=true
Content-Type: application/json

{ "key": "loan-application", "attributes": { "type": "Flow", "defaultVersion": "1.2.0", "reason": "pin before pilot" } }

### Move it (or "latest" to clear — null does NOT clear an existing pointer)
PATCH {{baseUrl}}/api/v1/{{domain}}/workflows/sys-version-registry/instances/{{registryId}}/transitions/set-default?sync=true
Content-Type: application/json

{ "attributes": { "defaultVersion": "1.2.1", "reason": "pilot finished" } }
```

| Pointer | Mode | New patch in the line | Higher minor / major |
|---|---|---|---|
| `"latest"` / none | Automatic (pre-0.0.102 behaviour) | live | live |
| `2.1.0-pkg.1.0.168` | one package build (write it without `+metadata`; partial `-pkg.1.0` → 409) | pending | pending |
| `2.1.0` | artifact pin (follows re-published builds of 2.1.0) | pending | pending |
| `2.1` | minor line | live | pending |
| `2` | major line | live | live within `2`, `3.0.0` pending |

- **Explicit always wins:** a full (`-pkg.`) or artifact (`2.2.0`) request is served even when it is
  pending or the pointer is broken — that is how pilots and integration tests reach a pending version.
  `sys-*` keys bypass the policy.
- Running instances stay on the version they started with. SubFlow / SubProcess correlations store the
  child's **resolved** version, so a parent never re-resolves a floating child reference mid-flight.
  Cross-domain references resolve with the **callee's** pointer.
- Start responses carry **`flowVersion`** (the resolved version) — assert it in tests and log it in
  clients. Spans: `vnext.flow.version.requested`, `vnext.flow.version`, `vnext.flow.version.pointer`,
  `vnext.flow.version.source` (`automatic|explicit|default|ceiling`); logs 20500–20504.
- A pointer change reaches every pod within ≈ `GenerationMemoSeconds` (5 s). A write with an invalid or
  unmatched pointer is refused with 409 `100052`; the registry instance stays Active.
- Since 0.0.102 the **instance list, GET and `GetInstance(s)` tasks** also load the flow, so a broken
  pointer or registry outage fails reads too (migration `instance-read-fails-on-flow-lookup-error`); the
  same lookup picks the `rowSecurity` rules in force (`row-security.md`).

**Rollout runbook.** *Pilot in one domain* (live `1.2.0`, pilot `1.2.1`): `set-default 1.2.0` (an exact
pin — a line pointer `1.2` would make `1.2.1` live at once) → publish `1.2.1` (pending) → pilot clients
start with `?version=1.2.1` → `set-default 1.2.1` (or `1.2` to let patches flow). Rollback =
`set-default 1.2.0`; instances already on `1.2.1` stay there. *Cross-domain:* publish the callee's new
version (pending), reference it by full version from the pilot caller, flip the callee's default first,
then the caller's — the two registries are not atomic. Symptoms: 404 `100051` → explicit version or move
the pointer; 409 `100052` → `set-default` to a published version or `"latest"`; 503 `100053` → retry.

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

## 5.1a SubFlow carried headers (0.0.102, #1141)

`instance.sub.completed` / `faulted` / `canceled` carry the headers of the request that settled the
child (`csx-contracts.md` § `ISubFlowMapping`). Section `Workflow:SubFlow:CarriedHeaders`:

| Key | Default | Effect |
|---|---|---|
| `Emit` | `true` | `false`: no headers on terminal events |
| `ExposeToOutputMapping` | `true` | parent `OutputHandler` reads them as `context.Headers` |
| `ApplyToResume` | `true` | parent's resumed hop runs with them (completion, fault, cancel) — migration `subflow-resume-carried-headers` (warning): set `false` for the pre-0.0.102 behaviour |
| `AdditionalDenied` | `[]` | extra exact names never carried — add custom secret headers (`x-api-key`) here: the floor only denies names containing `authorization`, `cookie`, `token`, `secret`, `session` (known issue `subflow-carried-headers-denylist`) |
| `MaxEntries` / `MaxValueLength` | `64` / `4096` | caps; dropped counts in log 40140 (Debug), values never logged |

Span tag `vnext.subflow.carried_header_count`. Values reach the outbox row, the Inbox body and the
parent's output mapping.

## 5.1b Sync responses carry the instance state (0.0.104, #1185)

A **sync** start or transition response (`?sync=true` or `executionType: "S"`) carries `currentState`
and `effectiveState` next to `status` / `effectiveStatus`:

```json
{ "id": "8d83…", "status": "A", "effectiveStatus": "A", "currentState": "otp-waiting", "effectiveState": "otp-waiting" }
```

Same names and values as the instance GET's `metadata.currentState` / `metadata.effectiveState` — the
instance's **own** persisted columns, no SubFlow descent. They are not the state function's `state`
(that is the active leaf's). An async `202` carries neither; a pipeline answered by a `ClientResponse`
leaves both `null`. The runtime-internal identity-only answer carries them too, which is what a sync
SubProcess / StartTrigger task output reads (`task-types.md` § 11 / 14). In tests, assert the state on
the sync response instead of a follow-up GET once the workspace runs ≥ 0.0.104.

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
- **Fewer database round trips per hop** (0.0.104, #1177; 0.0.105, #1195): no second status write or
  admission re-read, a two-command instance load, read-only loads 3 → 2 queries, state-function cache miss
  6+R → 4+R. Same rows, statuses and `metadata.modifiedBy`; nothing to change in a domain.
- **Deploy order for 0.0.105:** run **DbMigrator before the hosts** — migration
  `20261109120000_AddInstanceContinuationClaim` adds the nullable `Instances.ContinuationClaimedAt`
  (migration `instances-continuation-claimed-at-column`). Hosts also add `Application Name`
  (`OTEL_SERVICE_NAME`, else `DAPR_APP_ID`, else the host name) to a Postgres connection string that has
  none, so `pg_stat_activity` / PgBouncer `SHOW CLIENTS` name the owning host.
- **Log level (0.0.105):** the per-task "Executing task … with error-aware retry" and "Task … completed
  successfully" lines moved from Information to **Debug** — a log query that counted task executions from
  them finds nothing at Information; use the task metrics endpoints or spans (`observability.md`).
- **Artifact-version references prefer package rows** (0.0.105, #1175): a reference by artifact version
  (`"version": "1.0.0"`) resolves to the highest `1.0.0-pkg.*` row even when a legacy bare `1.0.0` row
  exists. Before, the bare row shadowed every package build and a view (or any component) referenced that
  way served a **stale** definition. Full-version, package-only, partial and major requests resolve as
  before.
- **Resource-lock provider (0.0.106, #1143):** `ResourceLock:Provider` = `dapr` (default) or `postgres`
  (leases in `sys_queues."DistributedLocks"`, real `Extend`, needs `ConnectionStrings:Default`); any other
  non-empty value fails host startup. Terminal-state lock release now runs right after the commit
  instead of waiting for the cleanup event (`resource-lock.md` §3–4).
- **`modifiedAt` moves with every transition** (0.0.104, #1183) — `instance-query.md` §5.

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

- Runtime `vnext` @ `40aad58a` (master, 0.0.105 unreleased): PRs #1175, #1177, #1183, #1185, #1188, #1195, #1211, #1225, #1299; `docs/runtime/{execution-type,status-locking,function-contract-resolution}.md`; vnext-meta fragments `updatedata-continuation-claim`, `data-function-etag-covers-state`, `artifact-version-prefers-pkg-row`, `hot-path-allocations`.
- Runtime `vnext` @ `74587011` (0.0.103): `docs/runtime/flow-default-version.md` (#1130).
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
  #976, #982, #997, #1022, #1026, #1030, #1067, #1076, #1079, #1083, #1085, #1088/#1089, #1095, #1143 (resource lock v3, 0.0.106), #1303 / #1304 (floating version resolution, 0.0.106).
- vnext-docs: `configuration/{service-discovery,caching,url-templates,telemetry}.md`,
  `how-to/{resource-lock,async-sync}.md` (resource-lock describes pre-0.0.106 behaviour), `concepts/transition-pipeline.md`, release notes v0.0.99 / v0.0.100.
- vnext-meta (master): features `discoveryDomainListWarmup` (0.0.94), `discoveryEventDrivenInvalidation`,
  `publishCompletedHook` (0.0.95), `instanceEffectiveStatus`, `instanceCorrelationTree` (0.0.99),
  `instanceDataHistory`, `scheduledWorkflowStart`, `multiDomainHosting` (0.0.100); deprecations `monitor-api-host`,
  `definitions-re-initialize-removed`, `subflow-chain-reserve-claim`; migration `cd-must-call-publish-completed`; known issue
  `pre-reserved-job-failure-can-strand-busy`.
- Helm `vnext-helm-charts/charts/vnext/values.yaml` (`global.dapr.*`, `UrlTemplates__BasePath`).
- Lab: `vnext-example/labs/cross-domain/{README.md,lab.sh,orchestration.overlay.env}`.
