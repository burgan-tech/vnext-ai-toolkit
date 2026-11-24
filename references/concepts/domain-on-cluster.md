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
  removing a domain is irreversible. A removed domain's discovery entry stays ("removed · discovery keeps
  it"), so the same name cannot be requested again until the platform retires that entry
  (burgan-tech/vnext-platform#10). Deleting the namespace with `oc` removes even less: the request record,
  the discovery entry and the Vault engine all survive. So does the domain's Vault token: its id lived in a Secret
  of the deleted namespace, so the platform can no longer revoke it. A domain requested again under the same name
  gets a policy of the same name, which that old token can read (vnext-platform `agent/internal/step/vault.go`).
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
| That screen's model is **one secret = one field, `value`** | design each secret as one value and read it with `GetSecretAsync("vnext-<domain>-secret", "<name>", "value")` — a multi-key bundle cannot be written from there. The screen's "Read with" column shows the exact line. **But every such secret shares the key name `value`, and the store already holds one (`platform-kafka`); see the startup row below before writing any** |
| The runtime's Dapr component carries its OWN Vault token | never use it to write or read on the person's behalf; that is the runtime's credential, not theirs |
| A missing secret faults the task: `Failed to retrieve secret 'value' from store 'vnext-<domain>-secret'` | the Dapr answer underneath says which: `secret key or version not exist` = not written (check the Secrets list); a timeout/`context canceled` = reachability |
| Script secret reads are cached ~30 s | a value changed in Vault (mock → real URL) takes up to that long to show |
| **The orchestrator loads the WHOLE store as configuration at startup** (`AddDaprSecretStore`, `vaultValueType: map`): every key of every secret becomes one configuration key, so two secrets with the same key name collide | the orchestrator dies at its next start with `InvalidOperationException: A duplicate key 'value' was found in the secret store 'vnext-<domain>-secret'` and stays in CrashLoopBackOff. Publishing, the menu and every start then fail, because they all go through it. Measured 24.11.2026: the platform's own `platform-kafka` secret carries a `value` key, so the FIRST `value`-shaped secret added from the Secrets screen (here `fora-wire-service-url`) took the orchestrator down. It surfaces only at a restart, so it can show up long after the secret was written |

The platform hit the same crash on PRIMUM itself (`duplicate key 'clientId'`, 01.11.2026) and set the rule there:
**one field name, one secret** in any engine a runtime reads as a secret store (vnext-platform `platform-lab/FINDINGS.md` #102).
The domain-side writers do not follow it yet. The agent's `vault-secret` step stores under `value` when no key is given,
and both `secret.write` (the Secrets screen) and `platform-kafka` use that default.

**Before writing a secret into a domain's store**, list what is there (a Dapr bulk read from a pod's sidecar
names the secrets and their keys without printing values). Never add a second secret whose key name another
secret already uses. As long as the Secrets screen only writes `value`, a domain whose store holds
`platform-kafka` cannot take a screen-written secret without this crash. That is a platform fix: raise it on
`burgan-tech/vnext-platform` rather than working around it.

**When the orchestrator is in CrashLoopBackOff**, read its log first (`oc -n <ns> logs deploy/vnext-<domain>-orchestrator --all-containers`).
For "duplicate key", the fix is removing or renaming the colliding secret's key in Vault, not deleting
the domain. A deleted namespace does not take the Vault engine with it, and it locks the name
(`domain-request` § What is the person's).

Put **environment-specific addresses** (a base URL that is a mock in one phase and the real service in the next)
in such a secret rather than in task JSON: switching is then one value, with no component publish.

## Moving a workspace to another domain

When a flow has to move to a different domain (the first domain is broken, or the name is locked), the workspace
is retargeted, not rebuilt. Measured 24.11.2026 moving an IBAN-transfer flow from `iban-transfer` to `mehmet2`:

| Change | Where |
|---|---|
| `vnext.config.json` → `domain`, and `paths.componentsRoot` (rename the folder to match) | config, folder |
| every component envelope's `"domain"` and every reference object's `"domain"` | all component JSON |
| schema `$id` URNs and every view `dataSchema`: `urn:…:schema:<old>:` → `urn:…:schema:<new>:` | Schemas, Views |
| view commands `urn:vnext:flow:transition:<old>:…` | Views |
| MockLab seed routes `api/<old>/…`, its collection name and file name; HTTP task URLs pointing at those routes | seed, Tasks |
| strings inside `.csx` that carry the domain: secret store `vnext-<old>-secret`, idempotency client ids, log tags | mappings, then re-embed if the workspace keeps embedded `code` |
| the menu record: `payload.domain`, and item keys prefixed with the domain | `records/backoffice-side.json` |
| deploy scripts, the namespace `<env>-vnext-<old>`, the orchestrator Service name; test config (`Domain`, app ids) | `deploy/`, `tests/` |

**Never blind-replace the old name.** A workflow key, a schema key or a tag often IS the old domain name (an
`iban-transfer` flow inside an `iban-transfer` domain), and those must not change. Replace the domain only in
the positions above, with patterns anchored on them (`"domain": "<old>"`, `schema:<old>:`, `api/<old>/`,
`vnext-<old>`), then grep for what is left and read each hit. Run `npm run validate` and publish with
`cluster-publish`. Every component is new in the target domain, so versions can stay as they are.

## A published version is final — and a record keeps its version

- Publishing an existing key+version answers `409` and changes nothing. Any change to a component — including a
  `sys-mappings` helper's `.csx` — is a new `version`, and every reference to it (`scripts.helpers`, a view
  reference in a workflow) must be moved to that version too.
- A record runs on the `flowVersion` it started with. After publishing a fix, test it on a **new** record and tell
  the person that tabs opened earlier still show the old behaviour.
