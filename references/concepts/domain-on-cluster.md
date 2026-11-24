# A domain on a cluster — request, build, addresses

What a product team meets when its domain runs on a platform-managed OpenShift cluster rather than on a
laptop. Used by the `domain-request`, `cluster-publish` and `backoffice-menu` skills.

**This describes a deployment, not the runtime.** It holds where a vNext platform is installed with its
management domain, its agent and a back-office client. A team that deploys its own runtime differently
skips `domain-request` and still uses `cluster-publish`.

## How a domain comes to exist

A domain is REQUESTED, not installed by hand. The back-office client starts the platform's `domain-request`
flow; a person approves it; the environment's agent builds it.

| Stage | What the record reads | Moves offered |
|---|---|---|
| filling in | `1 · Environment and name`, `2 · Access`, `3 · Capacity`, `Packages` | **Continue**, Cancel |
| summary | `4 · Summary` | **Send for approval**, one edit button per step, **Abandon** |
| waiting | `Awaiting approval` | **Approve and build**, **Send back**, **Abandon** |
| building | `Building` — a Build card names the run and its attempt | Abandon; Retry after a failure |
| built | the domain is listed as registered | — |
| given up | `Abandoned`, read in Domains › Requests | — |

- The request record is created by the click that opens the first form, so a walk that is given up is
  **abandoned**, not closed.
- The name becomes the namespace, the gateway route and the registry entry. It cannot change later, and
  removing a domain is irreversible.
- Access is a list of directory user names. Each becomes an admin of the domain's namespace and of nothing
  else. **Publishing needs one of them**: anyone else gets `Forbidden` from the namespace.
- Whether the requester may approve their own request is the platform's four-eyes switch.

## What a built domain has

| What | Name |
|---|---|
| Namespace | `<env>-vnext-<domain>` |
| Orchestrator Service | `vnext-<domain>-orchestrator`, port 5000 — read it, do not assume it |
| Also in the namespace | execution, inbox and outbox workers, the init service, Redis and its lock instance |
| Gateway | the domain's routes under the environment's gateway; definition publish is NOT among them |

Every pod Running and Ready is the fastest sign a build finished:
`oc -n <env>-vnext-<domain> get pods`.

## Finding the addresses

The toolkit ships no address. Resolve them in this order and say which one answered.

1. **The workspace's own file**, `.vnext/environments.local.json` (git-ignored; shape in the plugin's
   `templates/environments.example.json`). Written once, read afterwards.
2. **`oc` itself**, once the person has signed in: `oc whoami --show-server` is the cluster,
   `oc whoami --show-console` carries the applications domain (what follows `console-openshift-console.`).
3. **Build the client's address, then prove it.** A domain owner cannot read the client's Route (its
   namespace answers `Forbidden`), so the host is composed from the platform's naming:
   `https://<env>-vnext-client-<tech>-<name>.<apps domain>` — `<tech>` is `vue` and `<name>` is the shell
   domain (`staff`) unless the person says otherwise. Open it; the client's own first screen is the proof.
   Write the address that worked into the file of step 1.
4. **Ask the person** when the composed address does not open or there is no `oc` session. The environment
   name is always the person's to give.

`oc login` with a password can fail before it asks anything, with a certificate error; the console's
**Copy login command** (a token) is the way in. Never ask for the token in chat and never type a password.

## Secrets a domain reads

A built domain has a Dapr secret store named **`vnext-<domain>-secret`** (HashiCorp Vault, the domain's own
engine). Measured 24.11.2026 on a `dev` domain:

| Fact | Consequence |
|---|---|
| The domain owner has **no** direct Vault access (no CLI token, no rights in the platform's Vault namespace) | secrets are written through the back-office client's **System Flows › \<domain\> › Secrets** screen (a proposal → approve → **apply**). An approved but unapplied proposal writes nothing |
| That screen's model is **one secret = one field, `value`** | design each secret as one value and read it with `GetSecretAsync("vnext-<domain>-secret", "<name>", "value")` — a multi-key bundle cannot be written from there. The screen's "Read with" column shows the exact line |
| The runtime's Dapr component carries its OWN Vault token | never use it to write or read on the person's behalf; that is the runtime's credential, not theirs |
| A missing secret faults the task: `Failed to retrieve secret 'value' from store 'vnext-<domain>-secret'` | the Dapr answer underneath says which: `secret key or version not exist` = not written (check the Secrets list); a timeout/`context canceled` = reachability |
| Script secret reads are cached ~30 s | a value changed in Vault (mock → real URL) takes up to that long to show |

Put **environment-specific addresses** (a base URL that is a mock in one phase and the real service in the next)
in such a secret rather than in task JSON: switching is then one value, with no component publish.

## A published version is final — and a record keeps its version

- Publishing an existing key+version answers `409` and changes nothing. Any change to a component — including a
  `sys-mappings` helper's `.csx` — is a new `version`, and every reference to it (`scripts.helpers`, a view
  reference in a workflow) must be moved to that version too.
- A record runs on the `flowVersion` it started with. After publishing a fix, test it on a **new** record and tell
  the person that tabs opened earlier still show the old behaviour.
