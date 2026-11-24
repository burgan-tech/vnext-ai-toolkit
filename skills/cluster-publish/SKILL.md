---
name: cluster-publish
description: Use when the user wants this workspace's components loaded into a domain that runs on a cluster — triggers "cluster'a yükle", "tanımları yükle", "flowları yükle", "publish to the cluster", "deploy the definitions". Proves the target and the caller's rights, opens a port-forward to the domain's orchestrator, lists what would be sent, publishes on the person's yes, and starts a record to prove the load works. Not for the local docker runtime (use the workspace's own publish there).
---

# cluster-publish — load the workspace into a domain on a cluster

There is no upload in the back-office client, and definition publish is not behind the gateway. The way in
is a port-forward to the domain's own orchestrator and a plain HTTP publish, named out loud. Background, both in the plugin rather than the workspace:
`${CLAUDE_PLUGIN_ROOT}/references/concepts/domain-on-cluster.md`; what publish does and the cache event it needs:
`${CLAUDE_PLUGIN_ROOT}/references/concepts/runtime-operations.md`.

Needs: `oc` signed in, Node 18+, and a workspace that validates.

## 1. Clean before the cluster sees it

```bash
npm run validate
```

Fix failures with the `validate-and-fix` skill first. A file the validator refuses is never sent.
Warnings about the package itself (a missing file in its `files` list) do not block a publish.

The domain's namespace is `<env>-vnext-<domain>` — environment `dev` and domain `orders` give
`dev-vnext-orders`. Use that name in every command below.

## 2. Prove where the writes will go, and that you may

```bash
oc whoami --show-server
oc auth can-i create pods/portforward -n <env>-vnext-<domain>
oc -n <env>-vnext-<domain> get svc
```

- A laptop's `oc` context is often a local cluster. Say the server out loud before going on.
- `no` means the caller is not one of the domain's access users; everything in the namespace answers
  `Forbidden`. That is an access decision, not an obstacle to work around — the person is added through
  the platform's grant request.
- READ the orchestrator's Service and port from the list (`vnext-<domain>-orchestrator`, 5000 on the builds
  read so far). Do not assume them.

## 3. Forward, and check what answers

The forward blocks its shell, so run it in the background and keep its pid:

```bash
nohup oc -n <env>-vnext-<domain> port-forward svc/<orchestrator service> <local port>:<service port> > /tmp/vnext-forward.log 2>&1 &
echo $! > /tmp/vnext-forward.pid
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:<local port>/health
oc -n <env>-vnext-<domain> get deploy <orchestrator service> -o jsonpath='{..image}'
```

The Deployment carries the Service's name. Pick a local port nothing else uses — 4201 is the local
runtime's; something in the 4300s is a safe habit (`lsof -i :<local port>` printing nothing means it is free). `200` from `/health` is the forward working; it can take a few seconds to answer, so retry before
concluding anything. The image tag is the runtime version the
domain actually runs — compare it with the workspace's `runtimeVersion` and say so when they differ.

## 4. List, ask, publish

```bash
DRY=1 VNEXT_RUNTIME_URL=http://localhost:<local port> node ${CLAUDE_PLUGIN_ROOT}/scripts/cluster-publish.mjs
VNEXT_RUNTIME_URL=http://localhost:<local port> node ${CLAUDE_PLUGIN_ROOT}/scripts/cluster-publish.mjs
```

Show the DRY list and publish on the person's yes — this is a shared stage. A yes given with the request
("…and publish it") counts; a request that only said "load" or "check" does not. The script has no default
target, publishes in dependency order, inlines sibling `.csx` files, and ends with `publish/completed`.

Read the lines, not the exit code:

| Mark | Meaning |
|---|---|
| `✓ [200]` | landed |
| `= [409]` | this key and version is already there. Right for an unchanged file; a CHANGED file needs a new version. **A 409 does not say the content matches** — the script compares nothing. A file edited since its last publish and not re-versioned is silently NOT loaded; before trusting a run that sent nothing, check what changed since the last publish (the repository's diff; without one, ask the person what they edited) |
| `✗ [400]` | refused and not landed — fix and publish again |

**Never `wf update` or `wf reset` against a forwarded runtime.** They delete the existing key and version row
from a Postgres they reach on `DB_HOST` — `localhost` by default — which is the developer's own database.

## 5. Prove it runs, then close

**A 200 from publish is not a working flow.** A definition the runtime cannot run is still accepted: a flow
with a malformed schema reference published with 200 and answered its first start with 500. Start a record
of one published flow before calling the load done:

```
POST  <origin>/api/v1/<domain>/workflows/<flow>/instances/start?sync=true     { "key": "…", "attributes": { … } }
PATCH <origin>/api/v1/<domain>/workflows/<flow>/instances/<key>/transitions/<transition>?sync=true   { "attributes": { … } }
```

`attributes` follows the schema the move names — `attributes.startTransition.schema` for the start,
`states[].transitions[].schema` for a transition. Each is a reference; the fields are in that schema's own
file under the Schemas folder.
The answer carries `flowVersion` — the version that actually ran. On a 500, read the orchestrator's log
(`oc -n <namespace> logs deploy/<orchestrator deployment>`); the fix is a new version, because a published
one cannot be replaced.

Then stop the forward and see that it is gone — a forward left open is a path to a shared runtime:

```bash
kill "$(cat /tmp/vnext-forward.pid)"; rm -f /tmp/vnext-forward.pid
curl -s -o /dev/null -m 3 -w '%{http_code}\n' http://localhost:<local port>/health    # 000 = closed
pgrep -fl 'port-forward svc/<orchestrator service>' || echo 'no forward process'
```

In the back-office client, the domain's Flows list shows each published flow by key.

## Measured since, and not measured

- **`.csx` through this script** — measured 24.11.2026: workflow mappings, rules and transition mappings, and a
  `sys-mappings` helper (its own `attributes.location`), all inlined and run on the cluster. A helper is
  published before the components that list it in `scripts.helpers`.
- **Changing a helper or a view** means a new version for it AND for every reference to it; otherwise the publish
  answers `409` for the reference holder and the cluster keeps the old code. A record keeps the `flowVersion` it
  started with — prove a fix on a new record (`domain-on-cluster.md` § A published version is final).
- **A flow that reads secrets**: write them first (`domain-on-cluster.md` § Secrets a domain reads); a start that
  reaches the reading task with no secret ends Faulted with an incident.
- **A flow whose tasks call MockLab** (`http://mocklab:5000/...`): a built domain has no MockLab, so those tasks
  fail on the cluster until one runs in the namespace. Measured 24.11.2026: a domain access user (namespace admin)
  can run one. Copy `templates/cluster-mocklab/` into the workspace as `deploy/mocklab/` and replace `{{domain}}`
  and `{{namespace}}`. Run it before the proving start, with the person's yes: it creates a Deployment, a Service
  `mocklab:5000` and a ConfigMap `mocklab-seed` built from the seed folder. Re-run it after a seed change. The DB is an
  emptyDir, so every restart is a clean import. A ConfigMap holds at most 1 MiB of seed. Once the real upstream
  exists, point the task at it through a secret rather than editing task JSON (`domain-on-cluster.md`).
- Not measured: a domain whose flows are pinned by a version-registry pointer (a newly published version then
  stays pending until the pointer moves — see `runtime-operations.md`). Say so in the report when it applies.

## Example requests

```text
ornek domaini dev'de açık. Bu workspace'teki tanımları yükle. Önce neyin gideceğini göster.
```
