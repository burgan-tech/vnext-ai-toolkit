---
name: domain-request
description: Use when the user wants a NEW vNext domain opened on a platform-managed OpenShift cluster — triggers "domain aç", "openshift'te domain aç", "cluster'da domain oluştur", "domain request", "open a domain on the cluster". Settles the inputs, walks the back-office client's domain-request wizard (driving a browser when one is available, narrating otherwise), stops for the person at the summary and at approval, and watches the build to Ready. Not for scaffolding a workspace (that is /vnext-ai-toolkit:vnext-init).
---

# domain-request — open a domain on the cluster

A domain on a platform-managed cluster is requested through the back-office client, approved by a person and
built by the environment's agent. This skill is the order of work; the stages, the names and how addresses
are found are in the plugin's `${CLAUDE_PLUGIN_ROOT}/references/concepts/domain-on-cluster.md` — read it first (it is in the plugin, not in
the workspace).

It applies where the platform's management domain and back-office client are deployed. Without them there
is nothing to request: say so and stop.

## What is the person's, and what is yours

- **The person signs in** — environment, password, second factor. Never type a password or a token, and
  never retry a refused sign-in (it locks the user).
- **The person approves.** `Approve and build` is always their click.
- **Nothing is sent without a yes.** A build creates a namespace, a database, a Vault engine and gateway
  routes on a shared cluster, and the name cannot change afterwards.
- **Remove is never a cleanup step.** A failed build is retried, not removed.

## 1. Settle the inputs

Ask for what is missing; never invent a name or a directory user.

| Input | Rule |
|---|---|
| Environment | one the client offers in its picker |
| Domain name | `^[a-z][a-z0-9-]{0,28}[a-z0-9]$`, not already listed among the client's domains |
| Description, owner team | read by the approver; owner team is required, the description is optional |
| Access | 1–10 directory user names. **Include whoever will publish** — only these can reach the namespace. Do not assume the requester is added: name them |
| Capacity | one of the environment's profiles; the default is prefilled |
| Dependencies | postgres · redis · kafka — only what the environment allows; defaults are prefilled |
| Packages | the mandatory ones are prefilled. An application package only when the domain will carry a client's configuration |

## 2. Find the client

Resolve the back-office client's address as `domain-on-cluster.md` § Finding the addresses describes: the
workspace's local file, else composed from `oc` and proved by opening it, else asked. Say which it was.

- The proof is the client's own first screen: it asks the person to **choose an environment**. A page that
  merely answers 200 is not it. A cluster's routes often carry an internal certificate — a browser shows a
  warning the person accepts, and `curl` needs `-k` to read the page.
- Outside a vNext workspace (no `vnext.config.json`) there is no local file to write: report the address
  and go on.
- Whether the name is free and which environments exist are read on the client's own screens (its Domains
  list, the wizard's Environment picker) once the person has signed in — there is no other way to ask.

## 3. Walk the wizard

Domains › All › **New domain**. With a browser tool, drive it; without one, give the person each step's
values and confirm from the screen they describe.

1. `1 · Environment and name` — environment, name, description, owner team → **Continue**.
2. `2 · Access` — the directory users → **Continue**. A person who prefers to type their own user name does so
   in the open form; then continue.
3. `3 · Capacity` — leave the defaults unless asked → **Continue**.
4. `Packages` → **Continue**. This form carries no number.
5. `4 · Summary` — the fifth screen, numbered four.

The next form appearing is the proof the last one was accepted; allow it up to 90 seconds. A refusal returns
to the SAME step with its reason — read it, it names the cause.

**Read the packages on the summary, not on the form.** The Packages form has been seen reopening with every
catalog package ticked after a Continue that showed only the mandatory one. If the summary lists more than
was chosen: reopen the step from the summary, untick in the dropdown's list, continue, read the summary
again. The dialog changes width with its chips — click its buttons by reference, not by an old coordinate.

## 4. Stop at the summary

Read back the environment, the name, the namespace it will get, the access list, the capacity and the
packages. Say which values you supplied rather than the person. **Send for approval** only on their yes.

A walk that must build nothing ends with **Abandon** — offered on the summary and while awaiting approval.

## 5. Approval and the build

The record reads `Awaiting approval`. Tell the person where **Approve and build** is and wait. After it the
record reads `Building`. Watch the namespace rather than the page:

```bash
oc -n <env>-vnext-<domain> get pods
```

Done is every pod Running and Ready with the jobs Completed. A failed build names its step on the record;
**Retry** is the person's call and keeps what each step already made.

## 6. Report, then hand on

The environment, the domain and its namespace; who requested and who approved; the pods as read; what was
not checked. A built domain is empty: its definitions go in with the `cluster-publish` skill, and its place
in the client's menu with `backoffice-menu`.

## Example requests

```text
dev ortamında "ornek" domainini aç. Erişim <SICIL>, sahip ekip ornek-ekip. Özet ekranında dur.
```

```text
domain request wizard'ını "ornek-prova" adıyla özet ekranına kadar yürüt, sonra Abandon ile bırak.
```
