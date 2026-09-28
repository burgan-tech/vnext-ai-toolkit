# Observability — Logs, Spans, Correlation, Debugging Recipes

> Audience: domain authors debugging their own workflow against a local or shared runtime
> (v0.0.97). What to search for, where, and in which order. For lock/cache/discovery behaviour see
> `runtime-operations.md`; for the incident payload and `retry` rules see `incidents-and-retry.md`.

## 1. Log catalogue — `WorkflowLogs` EventIds

Every runtime log line comes from `src/BBT.Workflow.Domain/Logging/WorkflowLogs.cs`
(`[LoggerMessage]`, source-generated). Since #1017 every message has its **own EventId**
(pinned by `WorkflowLogEventIdUniquenessTests`); the single tolerated duplicate is the two
`JobFailed` overloads sharing **40075**.

> **`WorkflowEventIds.cs` in the same folder is stale and unreferenced — do not use it.** Its
> comment claims a 10xxx/20xxx/40xxx layering and Info/Warn/Error sub-ranges that the catalogue
> no longer follows. Search by the numbers below or by message text.

| Range | Region (from `#region` markers) | Named examples |
|---|---|---|
| 10003–10161 | Transition execution, task execution, fan-out (1015x), task coordinator, post-commit (1009x), resource lock (1010x), multi-channel notification (1016x) | `StateChanged` 10003; `ScheduledTransitionsSkippedForChainedNext` 10156 |
| 10074–… | SubFlow (interleaved with 10xxx) | |
| 20008–20050 | Instance management, instance retry | `InstanceStarted` 20008 |
| 20100–20460 | View resolution 201xx, extensions, incidents 202xx, long-poll termination 203xx, state-function cache 204xx, data-function cache 2041x, master/schema cache 2042x, related access 2043x, caller-role provider 2044x, human-task 2045x, instance-query filtering 2046x | `StateFunctionEtagNotModified` 20405; `EffectiveStatusDrift` 20445 (warning); human task dropped 20459 (warning) |
| 40017–40990 | Background jobs 4001x–4007x, cancellation, completion/fault cleanup 4009x, runtime, query ops, event-driven transitions 4099x | `JobFailed` 40075 (error, both overloads) |
| 50001–50030 | Service discovery 5000x, specification validation 5001x, cache invalidation 5002x, authorization | `AuthorizeRequest` 50030 (audit line: Domain, Workflow, Instance, Target, Role, Allowed) |
| 60001–60011 | Server configuration, scripting helpers / sandbox | `ScriptSandboxViolation`, `ScriptHelpersDisabled`, warm-up |
| 70001–70021 | Component cache | `AttributeIndexCatalogFallback` 70021 (warning — `x-indexed` catalog missing, JSON query fallback) |
| 80001–… | Function contract (verbs, schema, view slots) | |
| 90001–… | Deployment lifecycle (`publish/completed` hooks) | |

Kibana / OpenObserve queries key on `EventId` **and** `x_request_id` (below). Saved alarms bound
to pre-#1017 numbers must be updated (see vnext-docs `how-to/observability.md`).

### Script logging (`ScriptBase.Log*`)

`LogTrace/LogDebug/LogInformation/LogWarning/LogError/LogCritical` in `.csx` mappings write through
`IScriptServices.Logger` (category `BBT.Workflow.Scripting.Functions.ScriptServices`) with
**EventId 0** and the caller scope properties `ScriptFile`, `ScriptMethod`, `ScriptLine` — they are
**outside** the `WorkflowLogs` catalogue. Use the named form `args: new object[] { … }` (see
`csx-contracts.md`). Sandbox rejections and helper problems are runtime lines in the 6001x range.

## 2. Spans

Activity sources: `BBT.Workflow.Pipeline`, `.BackgroundJobs`, `.SubFlow`, `.Tasks`, `.Cache`,
`.Scripting`, `.Authorization`, `.Instances.Read`, `.Functions`, `.Extensions`, `.Execution`.
`Telemetry:Tracing:DetailLevel = Business` (default) exports everything with
`span.category=business`; `Verbose` adds task-phase, cache, EF Core and Dapr state-store spans
(restart required).

| Span | Meaning |
|---|---|
| `TransitionJob.Execute/{key}` | **The transaction on the async path** — APM groups jobs by transition |
| `Transition.{key}` | Group span for a chained hop (hop ≥ 2) |
| `Step.{Name}` | One pipeline step that did work; tags `vnext.step.order`, `vnext.step.outcome` (`continue` / `stop` / `skipTo:{n}`) |
| `Transition.Intake` → `Transition.LoadContext` → `Transition.Validate` / `ValidatePolicy` → `Transition.Enqueue` → `Transition.Settle` → `Uow.Commit` | Sync/async accept, load, validation, 202 enqueue (`vnext.enqueue.path` Direct \| Outbox), Busy→Active flip (`vnext.settle.cas`), commit |
| `Transition.Continuation/{mode}` | Between hops (`Inline`) |
| `Instance.Load` / `Create` / `AppendData` / `Fault` / `Persist` | Aggregate load, start, data version write (`vnext.data.version`, `vnext.data.size_bytes`), fault path |
| `Instance.Activation/{key}` | **Synthetic**, one per activation episode, backdated to the request — "how long until the flow was available"; `vnext.activation.outcome` `active \| completed \| canceled \| faulted \| busy.parked \| busy.subtype` |
| `Instance.Read/{kind}` | Built-in instance read (`state`, `data`, `view`, `schema`, `master`, `hierarchy`…); the 304 branch creates **no span** — see `vnext.read.fastpath` on the transaction |
| `Task.Execute.{key}` → `Task.Resolve` / `PrepareInput` / `Invoke` / `ProcessOutput` / `Journal.*` | One task; children are the mapping phases |
| `Script.Compile/{identity}` / `Script.Execute` / `Script.Invoke` | Compile (hit or miss, `vnext.script.cache.hit`), subflow/function output scripts |
| `Cache.Get/{key}` / `Cache.Write` / `Cache.Set` / `Cache.Remove` / `Cache.GenerationGet/{key}` | Component cache path (`cache.hit`, `cache.source` l1 \| l2 \| backend, `cache.generation`) |
| `Lock.Acquire/{lockKey}` / `Lock.Release/{lockKey}` | `vnext.lock.acquired=false` on a Busy 409 — a span, not an exception |
| `PostCommit.{job}` / `PostCommit.Coordinate` / `PostCommit.Settle` / `PostCommit.Fault` / `PostCommit.EventRelay` | Work after `Uow.Commit`: subflow forward, parent settle, event relay |
| `BackgroundJob.Arm/{type}/{key}` | Timer / timeout / ack-fallback job scheduling |
| `Trigger.Local` | In-process trigger task branch |
| `Auth.ResolveRoles` / `Auth.Decide` | Caller-role resolution and the `authorize` / role-grant decision (`vnext.auth.*` tags) |

### Tags worth filtering on

| Tag | Value |
|---|---|
| `vnext.domain`, `vnext.flow.key`, `vnext.flow.version` | Component identity |
| `vnext.instance.id`, `vnext.root.instance.id`, `vnext.parent.instance.id`, `vnext.subflow.instance.id` | Instance tree |
| `vnext.transition.key`, `vnext.step.order`, `vnext.step.outcome` | Pipeline position |
| `vnext.task.key`, `vnext.task.type`, `vnext.task.trigger` (OnExecute \| OnEntry \| OnExit \| Extension) | Task identity |
| `vnext.job.type`, `vnext.job.name` | Background job |
| `vnext.trace.lane`, `vnext.trace.lane.anchor`, `vnext.lane.seq`, `vnext.hop.predecessor`, `vnext.chain.depth` | Lane bookkeeping for chained hops |
| `vnext.settle.cas` (`flipped` \| `lost` \| `skipped`), `vnext.instance.busy` | Busy mutex outcome |
| `vnext.activation.*` | Activation episode |
| `vnext.layer` (`orchestration` \| `execution`), `span.category` (`business` \| `diagnostic`) | Layer / export class |
| `vnext.discovery.resolution` (`convention` \| `registry` \| `cache`), `vnext.dapr.app_id` | Cross-domain routing |
| `vnext.origin.trace_id`, `vnext.origin.span_id` | Link from a job's fresh trace back to the request that armed it |
| `x_request_id`, `correlation.id`, `workflow.instance.id` | Correlation (below) |

## 3. Correlation

| Carrier | Field in logs / spans | Scope |
|---|---|---|
| `traceparent` / `tracestate` (W3C) | trace tree | One APM trace across HTTP hops, job payloads and event contracts |
| `X-Request-Id` | `x_request_id` (stamped on **every** log record and span; no dot, so backends keep it flat) | One client HTTP request — the primary search key |
| `X-Correlation-Id` | `correlation.id` (baggage) | One transition execution chain — stable across async hops and auto-chained transitions |
| `X-Workflow-Instance-Id` | `workflow.instance.id` | Vendor-neutral instance id for non-vNext dependencies (`vnext.instance.id` is the internal axis) |

Every response returns `X-Request-Id` (echoed or generated), `X-Trace-Id` / `X-Span-Id` /
`traceparent`, and `X-Workflow: {domain},{workflow},{version},{instanceId}` — the instance id is
available from the **start** response before the body is parsed. Task bindings do **not** forward
`traceparent`, `tracestate`, `baggage`, `x-request-id`, `X-Correlation-Id`, `X-Workflow-Instance-Id`
from `headers` — the runtime injects them itself.

**Jobs open a new trace.** Timer, timeout and ack-fallback firings, and outbox → inbox event
deliveries (`EventTraceMode.IsolatedDelivery`) root their **own** trace; follow
`vnext.origin.trace_id` / `vnext.origin.span_id` (tagged by `BackgroundJobActivityHelper`) back to the
request that armed the job. `correlation.id` still spans both.

## 4. Where logs and traces go

| Setting / component | Local default |
|---|---|
| `Telemetry:Otlp:Endpoint` | `http://localhost:4318` in the hosts' `appsettings.json` — **overrides** `OTEL_EXPORTER_OTLP_ENDPOINT` silently; containers must set `Telemetry__Otlp__Endpoint=http://otel-collector:4318` |
| Dapr sidecar tracing | separate: `etc/*/dapr/config.yaml` → `tracing.otel.endpointAddress: otel-collector:4317` (key **`otel`**, not `otlp`) |
| OTel collector | fans out to OpenObserve (`http://localhost:5080`) and Elastic APM (Kibana `http://localhost:5601`) in `vnext/etc/docker/docker-compose.dev.yml` |
| `Telemetry:Tracing:DetailLevel` | `Business`; `Verbose` for task-phase / cache / EF spans |
| `Telemetry:Logging:Enrichers:RequestHeaderKeyPrefix` | `""` → header fields land flat (`sub`, `act_sub`, `role`, `x_parent_instance_id`) |

Typical lookups: OpenObserve/Kibana logs `x_request_id = '<id>'`; APM transaction
`TransitionJob.Execute/{key}` filtered by `vnext.instance.id`; runtime page
`docs/runtime/trace-elastic-queries.md` has ready-made KQL.

## 5. Recipe — debugging a failed transition

1. **Read the state function** `GET …/instances/{id}/functions/state`. A faulted instance carries
   `incident.active.href` (`metadata.incident` mirrors it); `metadata.effectiveStatus` is `F`.
2. **Fetch the incident** `GET …/instances/{id}/incidents/active` → `state`, `transition`, `task?`,
   `message`, `errorCode`, `errorLayer` (`Transport | Task | Pipeline`), `statusCode?`,
   `boundaryAction?`, **`traceId`**. 404 `Instance:100037` means nothing is open — re-read state.
   If the owner is a subflow, `active.href` points at the subflow instance.
3. **Step detail:** `GET …/instances/{id}/functions/tasks` lists executed tasks with `taskId`;
   `GET …/functions/actions?taskId=` gives that task's actions/outcome and mapped output.
4. **Logs:** search `x_request_id = '<X-Request-Id of the request>'` (or `correlation.id` for the
   whole chain). Errors from tasks sit under 10xxx, retry lines under 2005x, `JobFailed` 40075.
5. **Trace:** open `traceId` from the incident in APM. If the failing hop ran in a job (timer,
   timeout, ack fallback, async 202) it is a **separate trace** — follow `vnext.origin.trace_id`
   to the client request, or search the transaction `TransitionJob.Execute/{key}` by
   `vnext.instance.id`.
6. **Fix and retry:** correct the MockLab rule / mapping / data, then
   `POST …/instances/{id}/retry?sync=true` (optional body merges attributes before OnExecute).
   200 `status: "F"` means it faulted again and can be retried; success closes all open incidents.

## 6. Recipe — instance looks stuck (Busy)

1. `GET …/instances/{id}` → compare `metadata.status` and `metadata.effectiveStatus`. A parent is
   Busy for its child's whole life; `effectiveStatus` shows the **deepest active SubFlow**.
   `EffectiveStatusDrift` 20445 in logs means the projection disagreed with the live read.
2. State body: is `interaction` present (long-poll `terminate: true` waiting for
   `POST …/longpoll/ack`)? Ack it, or wait for `fallbackTimeoutSeconds` (default 60).
3. Any `transitions[]` entry with `kind: "scheduled"` and a future `executeAtUtc`, or a `timeout`
   block? It is waiting by design. Remember ETag gap #864: a stale `executeAtUtc` behind a 304 is
   possible — poll once **without** `If-None-Match`.
4. `incidents/active` → if an incident exists it is Faulted, not Busy — go to §5.
5. APM: last `Transition.Settle` for the instance — `vnext.settle.cas = lost | skipped` explains
   who flipped it; `Lock.Acquire … vnext.lock.acquired=false` shows rejected concurrent callers.
6. No incident, no interaction, no scheduled entry, `JobFailed` 40075 in logs → known issue
   `pre-reserved-job-failure-can-strand-busy`. Recover with the workflow's `cancel` / `exit`
   transition (exempt from the Busy 409).

## 7. Event publishing modes (#927, #978)

| Mode | Events | Path |
|---|---|---|
| Outbox (default, **all** distributed events) | `InstanceCanceled`, `InstanceCompletedCleanup`, `InstanceFaultedCleanup`, `ChildSubflow*`, `TransitionContinuationRequested` | transactional outbox row → outbox worker → broker → inbox worker → handler |
| Outbox + PostCommitRelay | `InstanceSubCompleted`, `InstanceSubFaulted`, `InstanceSubCanceled`, `InstanceSubStateChanged` | same **plus** an immediate post-commit command relay (`PostCommit.EventRelay` span, `vnext.relay.outcome`); the inbox copy is a deduplicated backup — order by the event's sequence number, not arrival |

Domain business events are **not** in this list — publish them explicitly with a **DaprPubSub task**
(type 4) from a transition; they inherit `traceparent` and `x_request_id` from the task envelope.

## Sources

- Runtime `vnext` @ `eca5b466` (0.0.97): `src/BBT.Workflow.Domain/Logging/{WorkflowLogs,WorkflowEventIds,TelemetryConstants,WorkflowTraceLane,ActivationEpisode}.cs`,
  `src/BBT.Workflow.Application/BackgroundJobs/Handlers/BackgroundJobActivityHelper.cs`,
  `src/BBT.Workflow.Application/Instances/DTOs/{GetInstanceStateOutput,InstanceTimeoutOutput}.cs`,
  `test/BBT.Workflow.Domain.Tests/Logging/WorkflowLogEventIdUniquenessTests.cs`,
  `docs/runtime/{correlation-and-tracing,trace-span-tree,trace-lanes,trace-elastic-queries,event-trace-chain,event-publish-modes}.md`,
  `etc/{orchestration,execution}/dapr/config.yaml`, `etc/docker/docker-compose.dev.yml`.
- Scripting package `BBT.Workflow.Scripting` 0.0.93 (`IScriptServices.Logger`, scope keys `ScriptFile` / `ScriptMethod` / `ScriptLine`).
- PRs: #864 (ETag scheduled-entry gap), #927 (outbox-only), #978 (post-commit relay), #1017 (unique EventIds).
- vnext-docs @ `adf9bf4`: `how-to/observability.md`, `configuration/telemetry.md`, `how-to/async-sync.md`, `concepts/incidents.md`.
- vnext-meta 0.0.53: `stateIncident` (0.0.92), `instanceEffectiveStatus`, known issue `pre-reserved-job-failure-can-strand-busy`.
- Toolkit: `csx-contracts.md` (script `Log*` signature), `incidents-and-retry.md`, `runtime-operations.md`.
