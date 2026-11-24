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
- **Never delete the namespace yourself to start again** (`oc delete project <env>-vnext-<domain>`). The
  platform still holds the domain:
  - the request record, the discovery entry ("removed · discovery keeps it" in Domains › All) and the Vault
    engine stay;
  - a new request for the same name is refused at step 1 with "'<env>.<domain>' is already a domain built
    through PRIMUM — choose another name" (burgan-tech/vnext-platform#10).

  A broken domain is fixed in place (often one Vault value, see `domain-on-cluster.md` § Secrets). Give it up
  only through the platform's own remove, and only on the person's explicit yes. Say that the name stays
  locked until the platform retires the entry.

## 1. Settle the inputs

Ask for what is missing; never invent a name or a directory user.

| Input | Rule |
|---|---|
| Environment | one the client offers in its picker — short codes (`dev`, `test`), not the display name in the client's header |
| Domain name | `^[a-z][a-z0-9-]{0,28}[a-z0-9]$`, not already listed under Domains › All. That list holds built domains only: a pending request for the same name is not visible there, and the wizard's first step is what refuses a taken name |
| Description, owner team | read by the approver; owner team is required, the description is optional |
| Access | 1–10 directory user names. **Include whoever will publish** — only these can reach the namespace. Do not assume the requester is added: name them |
| Capacity | one of the environment's profiles; the default is prefilled |
| Dependencies | postgres · redis · kafka — only what the environment allows; defaults are prefilled |
| Packages | the mandatory ones are prefilled. An application package only when the domain will carry a client's configuration |

## 2. Find the client

Resolve the back-office client's address as `domain-on-cluster.md` § Finding the addresses describes: the
workspace's local file, else composed from `oc` and proved by opening it, else asked. Say which it was.

- The proof is the client itself: signed out, its first screen asks the person to **choose an environment**;
  signed in, its header names the environment and its menu has **Domains**. A page that merely answers 200
  is not it. A cluster's routes often carry an internal certificate — a browser shows a
  warning the person accepts, and `curl` needs `-k` to read the page.
- Outside a vNext workspace (no `vnext.config.json`) there is no local file to write: report the address
  and go on.
- Whether the name is free and which environments exist are read on the client's own screens (its Domains
  list, the wizard's Environment picker) once the person has signed in — there is no other way to ask.

## 3. Walk the wizard

Domains › All › **New domain** — `Domains` is a collapsed group low in the left menu; expand it to reach
`All` and `Requests`. A dialog that is not part of the wizard (a prompt to update a profile detail, a
notice) is dismissed with its "later" button, never filled in. With a browser tool, drive it; without one, give the person each step's
values and confirm from the screen they describe.

1. `1 · Environment and name` — Environment (a picker), Domain name, Description, Owner team → **Continue**.
2. `2 · Access` — one text box, `Sicils with access` (a sicil is a directory user name) → **Continue**. A
   person who prefers to type their own does so in the open form; then continue.
3. `3 · Capacity` — `Capacity profile` (a text box, prefilled with the default profile's name), a
   `Customise the values` switch, and the three dependency pickers (Postgres · Redis · Kafka, prefilled; an
   option reads "The environment's shared one" or "The domain's own", which the summary words as `shared`
   and `dedicated`). Leave all of it unless asked → **Continue**.
4. `Packages` — `vNext packages`, a multi-select of chips → **Continue**. This form carries no number.
5. `4 · Summary` — the fifth screen, numbered four. Its sections are headed `1 · Environment and name`,
   `2 · Access`, `3 · Capacity and dependencies`, `4 · vNext packages`.

Behind every form the record's own page reads "This stage has no view" above a dump of raw fields. That is
the record without a screen, not an error — leave its `Later` button and the form's Cancel alone.

**Never reload or navigate the tab to a record's URL.** A full page load signs the client out, and the
person has to sign in again. Move inside the client: its menu, its tabs, its buttons.

The next form appearing is the proof the last one was accepted — usually within seconds; allow up to 90
before calling it stuck. A refusal returns
to the SAME step with its reason — read it, it names the cause.

**Read the packages on the summary, not on the form.** The Packages form has been seen reopening with every
catalog package ticked after a Continue that showed only the mandatory one. If the summary lists more than
was chosen: reopen the step from the summary (its edit buttons are `Environment / name`, `Access`,
`Capacity`, `Packages`), untick in the dropdown's list, continue, read the summary again. The dialog changes width with its chips — click its buttons by reference, not by an old coordinate.

## 4. Stop at the summary

The summary's moves are a row at the very BOTTOM of the page — scroll to it: **Send for approval** first,
the edit buttons, **Abandon** last.

Read back the environment, the name, the namespace it will get, the access list, the capacity and the
packages. Say which values you supplied rather than the person. **Send for approval** only on their yes.

A walk that must build nothing ends with **Abandon** — offered on the summary and while awaiting approval.
It is two clicks: Abandon opens a dialog titled `Abandon` with an optional `Reason`, and that dialog's
**Submit** is what abandons (it sends nothing for approval). The record's tab then closes back to the
Domains list; **Domains › Requests** shows the request as `Abandoned`. That list names no domain — find
the row by its Created time and open it (inside the client) to read the Domain before saying which
request was abandoned.

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
