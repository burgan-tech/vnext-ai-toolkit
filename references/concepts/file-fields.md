# File Fields — `x-storage` (blob storage)

> Runtime **0.0.100**, schema package **0.0.56**. A master-schema field marked `x-storage` keeps its file
> **bytes in a Dapr output binding** (local disk, S3, MinIO …) instead of the instance data. The client
> sends the bytes once (base64, inside the normal request body); from then on every record and every read
> carries a small **handle**, and the bytes are fetched with `functions/file`. Fields without `x-storage`
> keep bytes inline as before. Bytes never reach PostgreSQL for an `x-storage` field.

## 1. Declaration and placement

```jsonc
// master schema (attributes.type: "master")
"identityDocument": {
  "type": "object",
  "properties": { "name": { "type": "string" }, "mimeType": { "type": "string" }, "size": { "type": "integer" } },
  "x-storage": { "binding": "vnext-blob-local" }
},
"attachments": {
  "type": "array",
  "items": { "type": "object", "x-storage": { "binding": "vnext-blob-local" } }
},
"documents": {
  "type": "array",
  "items": { "type": "object", "properties": {
    "doc": { "type": "object", "x-storage": { "binding": "vnext-blob-s3" } } } }
}
```

| Rule | Detail |
|---|---|
| Shape | `{ "binding": "<name>" }` — required, non-empty, no other member. `binding` = the Dapr binding component name on the **orchestration** sidecar |
| Role | `master` only (package); the runtime acts only on the flow's master schema |
| Node type | the property must be `type: "object"`; it describes the **persisted handle** |
| Allowed placement | reached through nested `properties`, plus **one** array level (`files[]`, or a property inside that array's item schema such as `documents[].doc`) |
| Refused placement (publish error) | schema root, `$defs`, combinators (`allOf`/`anyOf`/`oneOf`), conditionals, nested arrays, inside another `x-storage` node |
| `content` | may **not** be declared under the node's `properties` or `required` (publish error) |
| Not with | `x-computed`. The master validates every merge against the **handle**, so either leave the node open or declare every handle member (`component`, `file`, `name`, `mimeType`, `size`, `eTag`, `owner`) |

**Split the schemas.** The master describes the handle; the **transition schema** describes the upload
(`content` required). Reusing the master as a transition schema breaks uploads. Reference pair:
`vnext-example` `core/Schemas/forge-file-form-lab/ffl-master.json` (master, `x-storage`) and
`ffl-upload.json` (transition, `content`).

```jsonc
// transition schema (attributes.type: "transition")
"identityDocument": {
  "type": "object",
  "required": ["name", "mimeType", "content"],
  "properties": {
    "name": { "type": "string" }, "mimeType": { "type": "string" },
    "size": { "type": "integer" }, "content": { "type": "string" }
  }
}
```

## 2. Write, handle, echo

**Write** (request body, on the way in only):

```json
{ "identityDocument": { "name": "passport.pdf", "mimeType": "application/pdf", "size": 204800, "content": "<base64>" } }
```

**Persisted handle** (instance data, transition record, job/outbox, every read):

```json
{
  "component": "vnext-blob-local",
  "file": "7c9e4c2a-5f7e-4a51-9c11-0b8b6c1d2e3f",
  "name": "passport.pdf",
  "mimeType": "application/pdf",
  "size": 204800,
  "eTag": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "owner": { "domain": "onboarding", "flow": "kyc-main-flow", "instance": "8394783-…" }
}
```

- `file` is a runtime GUID, never the client file name. `size` is the decoded byte count (the client's is
  ignored). `eTag` = SHA-256 of the bytes, lower-case hex. `owner` = the instance whose write created the
  object — call `functions/file` on **that** instance.
- Object key in the store: `{FileStorage:KeyPrefix}{file}`.

| Body node | Result |
|---|---|
| `content` only | decoded (bad base64 → 400), stored, node becomes the handle |
| `file` only (+ any metadata) — an **echo** | must exist at the same path in the instance's latest data (arrays: any element of the same array); replaced by the stored handle, client metadata discarded; otherwise 400. Always 400 on `start` |
| `content` and `file` | 400 `FileReferenceInvalid` |
| `null` / absent | field cleared; **nothing is deleted** from the store |

Runtime-produced payloads (SubFlow input mapping, Start/SubProcess trigger tasks, DirectTrigger, transition
mapping output, task outputs) are "trusted": a valid handle is kept without the latest-data check, so a
mapping can hand a file from another instance down. Validation is two-pass: a rejected request writes nothing
to the store. Scripts read `ScriptContext.RawBody` with the bytes already replaced by the handle.

A transition sent to a parent with an active SubFlow is forwarded; the **leaf** stores the file against its
own master schema and becomes `owner`.

## 3. Reading the bytes

### `functions/file` (clients)

```
GET|HEAD /api/v1/{domain}/workflows/{workflow}/instances/{instance}/functions/file?file=<guid>
```

1. The state's `queryRoles` — denied → **403** (checked in the engine, before the file is located; an
   exception to "the gateway owns `queryRoles`").
2. The `x-roles` grants of the file's path and every ancestor — hidden → **404** (existence not revealed).
3. The handle must be in **this** instance's latest data at an `x-storage` path (no SubFlow descent, no
   history) → else 404 `FileNotFound`. Missing `file` query → 400.

Response: raw bytes, `Content-Type` = stored `mimeType` (else `application/octet-stream`), `ETag: "<eTag>"`,
`Cache-Control: private, max-age=31536000, immutable`, `X-Content-Type-Options: nosniff`,
`Content-Security-Policy: sandbox; default-src 'none'`, `Content-Disposition: inline` — **`attachment`** for
active types (HTML, XHTML, SVG, XML/`+xml`, JavaScript). `If-None-Match` → 304 without a store read;
`Range` → 206/416 (the object is still read whole into memory); `HEAD` = headers only.

### `ScriptBase.GetFileAsync` (scripts)

```csharp
// pass the handle's owner.domain / owner.flow / owner.instance and file
ScriptFile f = await GetFileAsync(domain, flow, instance, file);   // Content, Name, MimeType, Size, ETag
```

Same domain in-process; another domain via its `internal/file` route. **No authorization** on this path —
no caller identity, `queryRoles` or `x-roles`. A script that serves a file to a caller must make its own
access decision first (security-reviewer flags `GetFileAsync` without one). Available only where scripts run
(orchestration). Signature: `csx-contracts.md` (File fields).

### `file` is a reserved function key

`file` is a system function key (like `data`, `state`, `schema`). Never name a custom function `file`.

## 4. Configuration

| Where | Setting |
|---|---|
| Runtime | `FileStorage:KeyPrefix` (default `""`): prefix for every object key, e.g. `vnext-runtime/` in a shared bucket. **Never change it after the first write** — handles carry no key, stored objects become unreachable |
| Runtime | `FileStorage:AllowedBindings` (list, default empty): bindings a handle may name besides the flow's own `x-storage` bindings (files handed across flows). Helm deployments list their blob component names here (`FileStorage__AllowedBindings__0=…`) |
| Helm (chart ≥ 1.0.123) | `global.blobStorageComponents: []` — `{ name, spec: { type, version, metadata[] }, auth? }`, scoped to the **orchestrator** sidecar only; `name` = the schema's `binding`. Credentials via `secretKeyRef`. The chart ships no component |
| Request size | Kestrel `MaxRequestBodySize` 10 MiB (≈ 7.5 MiB of file after base64) → `413`; the sidecar's `--max-body-size` (64Mi in the reference setup) bounds binding calls and Dapr hops |

The platform team owns these. A product team requests the binding name and the `AllowedBindings` entry for
its domain; it never edits runtime or chart repositories.

### Local development binding (what is needed)

The published runtime images (vnext-runtime compose) ship **no** blob binding. A local run of a domain with
`x-storage` needs, on the **orchestration daprd sidecar**:

1. A component file in the sidecar's resources path, name = the schema's `binding`:

   ```yaml
   apiVersion: dapr.io/v1alpha1
   kind: Component
   metadata:
     name: vnext-blob-local
   spec:
     type: bindings.localstorage
     version: v1
     metadata:
       - name: rootPath
         value: /blobs
   ```
2. A volume mounted at `rootPath` **in the daprd container** (e.g. `./data/blobs:/blobs`) — the binding
   runs in the sidecar, not in the orchestration container.
3. daprd started with `--max-body-size 64Mi` (the default body limit is far below a file upload).
4. On the orchestration container, `FileStorage__AllowedBindings__0=vnext-blob-local` when files are handed
   across flows (SubFlow input, mappings copying a handle).

The toolkit will ship this as a compose overlay (`/vnext-ai-toolkit:vnext-init` writes it when a master
schema declares `x-storage`); until then add the four items to your local compose override. Integration
tests: the e2e preflight checks the binding when a master schema uses `x-storage`.

## 5. Status codes

| HTTP | Code | When | Retry? |
|---|---|---|---|
| 400 | `Instance:100048` `FileReferenceInvalid` | `content` + `file`, bad/non-string base64, unknown or foreign reference, reference on `start`, missing `file` query | no — fix the body |
| 403 | — | `functions/file`: state `queryRoles` refuse the caller | no |
| 404 | `Instance:100049` `FileNotFound` | not in this instance's latest data, invalid stored handle, or path hidden by `x-roles` | check `owner` |
| 409 | `InstanceBusy` | forwarded transition during a SubFlow completion window, or busy target | yes, short backoff |
| 413 | — | body above the Kestrel / sidecar limit | no — smaller file |
| 503 | `Instance:100047` `FileStoreUnavailable` | binding call failed (also a `get` of a **missing** object); returned before any `202`; failed `start` creates no instance | yes, backoff |
| 503 | `Instance:100050` `FileSchemaUnavailable` | master schema cannot be loaded and the body carries a `content`/`file` member, or a file read | yes, once the schema resolves |

## 6. Known issues (vnext-meta, `>=0.0.100`, unfixed)

| id | Effect | What to do |
|---|---|---|
| `file-store-no-delete` | clearing/replacing never deletes the old object; no retention or GC | lifecycle rules in the store; never change `KeyPrefix` |
| `file-store-orphans-on-rollback` | object written before commit/accept; rollback or a late `409` leaves an orphan | bucket expiry scoped by `KeyPrefix` (orphans are harmless) |
| `file-in-task-record` | bytes a mapping puts in a task request/response are stored in the task record | pass the **handle** through mappings; read bytes with `GetFileAsync` only where needed; never echo bytes into task responses |
| `file-trusted-payload-cross-domain` | a content-less handle sent to another domain is `400 Instance:100048` there | send `content` cross-domain, or read with `GetFileAsync` in the owning domain |
| `file-seed-data-not-offloaded` | `x-storage` content in definition seed data stays inline | upload through a transition after start |
| `file-missing-object-503` | an expired/deleted object answers 503 like an outage | do not expire referenced objects |
| `file-async-proxy-overlapping-revert` | overlapping async requests through one parent can clear each other's Busy stamp (self-heals) | do not fire overlapping async transitions at one parent |
| `file-duplicate-property-names` | duplicate member names in a file node → undefined outcome | send well-formed JSON |

`x-storage` is not encryption: objects sit in the store as uploaded. Protect the store (bucket policy,
encryption at rest) and the `functions/file` path (`queryRoles`, `x-roles`).

## Sources

- Runtime v0.0.100: `docs/runtime/file-storage.md`; `FileStorageSchemaParser`, `FileOffloadService`, `FileAdmission`, `InstanceFileAppService`, `FileFunctionHandler`, `FunctionTypeConst.File`; local reference component `etc/orchestration/dapr/components/vnext-blob-local.yaml` and `etc/docker/docker-compose.yml` (read-only reference)
- vnext-meta known-issues `file-*`
- vnext-schema v0.0.56: `vocabularies/view-vocab.json` (`x-storage`), `record-vocab.json`
- vnext-docs: `how-to/file-fields.md`, `how-to/view-consept/schema-definition.md` (`x-storage`), `deployment/helm-chart.md` (`global.blobStorageComponents`, chart 1.0.123)
- Fixtures: `vnext-example` `core/Schemas/forge-file-form-lab/`, `core/Workflows/file-offload-lab/`, `core/Workflows/file-offload-xd/`
