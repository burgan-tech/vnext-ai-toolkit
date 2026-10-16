# Mappings, `scripts`, and `REF` encoding

vNext has a reusable-code component, **`sys-mappings`** (folder `Mappings/`), plus two cross-cutting
extensions on every mapping object: a **`scripts`** block (shared helpers + allowed assemblies) and a
**`REF`** code encoding (point `code` at a `sys-mappings` component instead of inlining it).

> **Primary rule: if a mapping structure repeats, extract it into `sys-mappings` first.** Reuse via
> `scripts.helpers` / `REF` is the default approach for any repeated `.csx` logic — inline duplication
> is the exception that needs justifying, not the other way around.

> This file is the authoring summary. The full schema, the script sandbox/security model, helper
> runtime-linking, and the designer UX live in the vNext docs portal (and MCP).

## The `sys-mappings` component

A reusable C# class (a helper like `RsaCryptoHelper`/`JsonHelper`, or a whole mapping like
`InitialTransMapping`) that other components reference instead of duplicating code.

- Folder `Mappings/`; `flow: "sys-mappings"`; `vnext.config.json` `paths.mappings` + `exports.mappings`.
- Envelope `attributes`: `name` (the C# class name, e.g. `RsaCryptoHelper`), `location` (`./src/X.csx`),
  `code` (the script body), `encoding` — **`B64` or `NAT` only**. A `sys-mappings` component **cannot
  use `REF`** (it is the reference *target*; no self-reference).

```jsonc
{
  "key": "rsa-crypto", "version": "1.0.0", "domain": "core",
  "flow": "sys-mappings", "flowVersion": "1.0.0", "tags": ["crypto"],
  "attributes": { "name": "RsaCryptoHelper", "location": "./src/RsaCryptoHelper.csx", "code": "...", "encoding": "NAT" }
}
```

A **`mappingRef`** (used by `scripts.helpers` and by `REF` code) is:
`{ "key": "...", "version": "...", "domain": "...", "flow": "sys-mappings" }`.

## The `scripts` block

Any mapping object (transition/state/task/function/extension/subflow `mapping`, `rule`, `timer`, view
`viewRule`) **and** the workflow `attributes.scripts` may carry:

```jsonc
"scripts": {
  "helpers": [ { "key": "json-helper", "version": "1.0.0", "domain": "core", "flow": "sys-mappings" } ],
  "allowedAssemblies": [ "Newtonsoft.Json" ]
}
```

- **`helpers`** — `sys-mappings` refs whose static classes become callable in the script. The mapping
  code then calls them directly by class name (e.g. `JsonHelper.Serialize(x)`, `RsaCryptoHelper.Encrypt(...)`).
- **`allowedAssemblies`** — the .NET assemblies the script is permitted to use (e.g.
  `System.Security.Cryptography`). Declare every assembly the helper or inline code needs. Use the
  simple name, without `.dll`.
  - **Since 0.0.99 every name must resolve at publish** (#1069): a framework assembly, or a DLL in the
    environment's plugin directory. An unresolvable name fails the publish with **400 naming the field**
    (e.g. `sys-flows.states[0].onEntries[1].mapping.scripts.allowedAssemblies[0]`), even where the sandbox
    is off. Remove stale/misspelled names; for a missing DLL, ask the platform team / environment owner.
  - The check does not compile: an assembly the script uses but never declares still fails only at run time.
  - `System.ObjectModel` (needed to `foreach` over an `ExpandoObject`) is in the sandbox baseline since
    0.0.99; on older sandboxed environments grant it here.

Flow-level `attributes.scripts` applies workflow-wide; per-mapping `scripts` is local to that mapping.
The two are unioned (helpers deduped, assemblies merged) on top of the environment's baseline.

### Script plugins (third-party DLLs)

There is no per-domain DLL upload. The **platform team** mounts approved DLLs (e.g. a database driver)
in the environment's plugin directory (`Scripting:Sandbox:PluginDirectory`); a mapping uses one by listing
its name in `allowedAssemblies`. Product teams do not control this directory or runtime config — ask the
platform team / environment owner. Since **0.0.100** (#1090):

- a plugin is loaded **once per process** and shared by every script and helper (one connection pool);
- a **helper-less mapping** can call a plugin type directly (before, it compiled and then failed with
  `FileNotFoundException` — on older runtimes keep plugin calls inside a `sys-mappings` helper);
- a DLL **added** after start is found after at most `PluginRescanIntervalSeconds` (default 30) —
  re-publish a component rejected before it arrived; **replacing** a loaded DLL needs a restart;
- pass `context.CancellationToken` to driver calls.

Details and the cancellation/security notes: `csx-contracts.md` § Runtime notes.

## `REF` encoding — reference a mapping instead of inlining

`scriptCode` / task `mapping` / extension `mapping` / CacheAside `key` script `encoding` accepts `B64`
(default), `NAT`, or **`REF`**. With `REF`, `code` is a `mappingRef` (not a string):

```jsonc
"mapping": {
  "encoding": "REF",
  "code": { "key": "initial-mapping", "version": "1.0.0", "flow": "sys-mappings", "domain": "core" }
}
```

## When to extract a helper

Inline `.csx` is fine for one-off logic. Extract into a `sys-mappings` helper (then reference via
`scripts.helpers`, or the whole mapping via `encoding:"REF"`) **as the primary method** when the same
logic is needed in more than one place, or when it's a self-contained utility (crypto, serialization,
formatting). When reviewing or writing mappings, actively look for repeated structures and propose the
`sys-mappings` extraction rather than copying the code. Keep helper classes as plain
`public static class` types — see `csx-contracts.md`.

## Sources

- Schema: `node_modules/@burgan-tech/vnext-schema/schemas/mapping-definition.schema.json` (+ the
  `scripts`/`mappingRef`/`scriptCode` definitions inside `workflow`/`function`/`extension` schemas).
- Deep model (script sandbox, helper linking, REF designer UX, versioning): vNext docs portal + MCP —
  `docs/configuration/scripting` and `docs/components/mappings`.
- Runtime: vnext `docs/custom-script-helpers.md` §3–§4; vnext-meta migration
  `publish-rejects-unavailable-allowed-assemblies` (0.0.99), known issue
  `sandbox-baseline-missing-system-objectmodel` (fixed 0.0.99); release notes vnext-docs
  `blog/2026-10-15-v0-0-100.md` (#1090).
- Plugin example: `vnext-example/core/Functions/script-plugin-lab/` (helper-less and helper paths) +
  `vnext-example/plugins/ScriptPluginLab.Sql`.
- Working examples: `vnext-example/core/Mappings/account-opening/` and the `scripts`/`REF` usage in
  `vnext-example/core/Workflows/account-opening/account-opening-workflow.json`.
