# Runtime issue template — report-runtime-issue

Loaded at step 5 (draft). Everything here is English, regardless of the conversation language.

## Title rules

- Format `[type] <observable behaviour>` — `type` ∈ `bug`, `enhancement`, `docs`, `performance`.
- **≤ 72 characters**, sentence case, no trailing period.
- Name the surface the reader recognises (endpoint, task type, schema keyword, transition kind) and
  the symptom. Not the guessed cause, not the domain name, not a customer or host.

| Weak | Good |
|---|---|
| `[bug] Runtime broken in onboarding` | `[bug] Data function returns 304 while a SubFlow is active` |
| `[bug] Cache problem` | `[bug] CacheAside source task runs with empty input on cache miss` |
| `[enhancement] Better incidents` | `[enhancement] Filter functions/tasks by transition key` |

Labels: `bug` · `enhancement` · `documentation` · `performance`, plus `needs-info` when the repro
is incomplete. Reporters without triage rights may not be able to set labels — the title prefix
still carries the type.

## Body template

Fill every section; write `n/a` rather than deleting one (except Workaround for enhancements).

~~~markdown
## Summary
<!-- 2–4 sentences: what you did, what the runtime did, why that is wrong (cite docs if they say otherwise). -->

## Impact
<!-- Who is blocked and how badly: flows that cannot complete, data exposure, wrong results, latency.
     Frequency: always / intermittent (n of m). Business context generic ("an onboarding flow"). -->

## Steps to Reproduce
<!-- Numbered, minimal, against a clean local runtime or Testcontainers when possible. -->
1.
2.
3.

## Expected
<!-- Per docs / schema / vnext-meta — link the page or clause. -->

## Actual
<!-- Status code, body excerpt, error code, EventId. -->

## Environment
| | |
|---|---|
| Runtime | `0.0.NN` (image `…:0.0.NN`) |
| Schema package | `@burgan-tech/vnext-schema 0.0.NN` |
| Toolkit | `vnext-ai-toolkit 0.0.N` |
| Role provider | `default` \| `morph-idm` \| unknown |
| Deployment | local vnext-runtime (docker compose) \| Testcontainers (VNext.Testing.Sdk) \| shared test env |
| Reproduces on clean local runtime | yes / no / not tried |

## Evidence
<!-- Minimal component JSON excerpt, request/response, incident fields, functions/tasks excerpt,
     metrics, log EventIds. Keep X-Request-Id / trace id. Redacted values use <placeholders>. -->

## Suspected area
<!-- Observed behaviour only — which surface/endpoint/feature, what correlates with the failure.
     No assumed source paths. Public docs, schema clauses and vnext-meta ids may be cited. -->

## Workaround
<!-- What the reporter does in the meantime, or "none found". -->

---
_Reported via vnext-ai-toolkit vX.Y.Z · redacted: <categories>_
~~~

## Worked example — bug (anonymised, illustrative)

**Title:** `[bug] Data function returns 304 while a SubFlow is active`
**Labels:** `bug`

~~~markdown
## Summary
`GET …/instances/{id}/functions/data` keeps answering `304 Not Modified` for as long as the polled
instance has an active SubFlow, although the `extensions` block in the response changes while the
SubFlow advances. The client therefore never receives the extension output.

## Impact
A parent flow waits in one state for the whole SubFlow lifetime and surfaces the child's progress to
the client through extensions. Every poll after the first returns 304, so the OTP and approval screens
in an authentication flow never render their data. Reproduces every time.

## Steps to Reproduce
1. Publish a parent workflow whose state `wait-child` starts SubFlow `child-flow` (`subFlow.type: "S"`)
   and an extension whose output the data function resolves from the active SubFlow.
2. Start the parent; call `GET …/instances/{id}/functions/data` → `200`, keep the `ETag`.
3. Transition the child (`PATCH …/child-flow/instances/{childId}/transitions/send-otp`) → `200`;
   the child's data changes.
4. Call `functions/data` on the parent again with `If-None-Match: <etag>`.

## Expected
`200` with the new `extensions` content — the response body differs, so the ETag should differ
(conditional-request semantics; vnext-docs `components/functions/built-in`).

## Actual
`304 Not Modified`, every time, until the SubFlow completes. Without `If-None-Match` the body does
contain the new extension output.

## Environment
| | |
|---|---|
| Runtime | `0.0.97` (image `…:0.0.97`) |
| Schema package | `@burgan-tech/vnext-schema 0.0.54` |
| Toolkit | `vnext-ai-toolkit 0.0.6` |
| Role provider | `default` |
| Deployment | local vnext-runtime (docker compose) |
| Reproduces on clean local runtime | yes |

## Evidence
Step 4 request/response:
```http
GET /api/v1/acme/workflows/parent-flow/instances/<id>/functions/data
If-None-Match: "a1b2c3"
→ 304 Not Modified
X-Request-Id: 6f0d1c2e-…   X-Trace-Id: 4bf92f35…
```
Same call without `If-None-Match` → `200`, `ETag: "a1b2c3"` (unchanged), body
`"extensions": { "otpInput": { "maskedPhone": "<phone>", "wrongOtp": true } }` (was `false` before step 3).
Logs for the request: data-function cache lines (`2041x`), no warning or error.

## Suspected area
The data-function ETag appears to depend only on the polled instance's own data; extension output
read from the active SubFlow does not change it. Observed: the ETag changes only when the parent's
own data changes.

## Workaround
Poll the child instance's `functions/data` directly while the parent is in `wait-child`, or drop
`If-None-Match` for that state (costs a full response per poll).

---
_Reported via vnext-ai-toolkit v0.0.6 · redacted: phone (1), internal host (1), user ids (2)_
~~~

## Worked example — enhancement (illustrative)

**Title:** `[enhancement] Filter functions/tasks by transition key`
**Labels:** `enhancement`

~~~markdown
## Summary
`GET …/instances/{id}/functions/tasks` returns every executed task of the instance. For long-running
instances with retries and loops, finding the tasks of one transition run means paging through
hundreds of rows client-side.

## Impact
Incident triage on instances with 300+ task executions takes several requests and manual matching
on timestamps. Affects every team debugging faulted instances through the documented recipe
(incident → `functions/tasks` → `functions/actions?taskId=`).

## Steps to Reproduce
1. Run an instance through a looping state ~50 times (each loop runs 6 tasks).
2. Fault it on the last transition; read `incidents/active` → `transition: "submit"`.
3. Call `functions/tasks` → all ~300 rows, no way to narrow to the faulted `submit` run.

## Expected
An optional `transitionKey` (and ideally `transitionId`) query parameter on `functions/tasks`
returning only that transition's tasks, same response shape.

## Actual
No filter; the full list is returned (paged).

## Environment
| | |
|---|---|
| Runtime | `0.0.100` |
| Schema package | `@burgan-tech/vnext-schema 0.0.56` |
| Toolkit | `vnext-ai-toolkit 0.0.7` |
| Role provider | n/a |
| Deployment | Testcontainers (VNext.Testing.Sdk) |
| Reproduces on clean local runtime | yes |

## Evidence
`GET …/functions/tasks?page=1&pageSize=100` → `200`, `hasNext: true`, 3 pages for one instance.

## Suspected area
Instance read surfaces (`functions/tasks`). The 0.0.99 `transitions/{transitionKey}/metrics` endpoint
already scopes by transition, which suggests the data is available.

## Workaround
Call `transitions/{key}/metrics` to get the run's time window, then filter `functions/tasks` by
timestamp client-side.

---
_Reported via vnext-ai-toolkit v0.0.7 · redacted: none_
~~~

## Comment on an existing issue (duplicate found)

~~~markdown
Also seen on runtime `0.0.NN` / schema `0.0.NN` (<deployment>).

<what is new: another trigger, smaller repro, extra evidence — redacted>

---
_Reported via vnext-ai-toolkit vX.Y.Z_
~~~
