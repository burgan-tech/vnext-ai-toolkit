# Mappings, `scripts`, and `REF` encoding

vNext has a reusable-code component, **`sys-mappings`** (folder `Mappings/`), plus two cross-cutting
extensions on every mapping object: a **`scripts`** block (shared helpers + allowed assemblies) and a
**`REF`** code encoding (point `code` at a `sys-mappings` component instead of inlining it).

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
  `System.Security.Cryptography`). Declare every assembly the helper or inline code needs.

Flow-level `attributes.scripts` applies workflow-wide; per-mapping `scripts` is local to that mapping.
(How the two combine is in the docs portal.)

## `REF` encoding — reference a mapping instead of inlining

`scriptCode` / task `mapping` / extension `mapping` `encoding` accepts `B64`, `NAT`, or **`REF`**. With
`REF`, `code` is a `mappingRef` (not a string):

```jsonc
"mapping": {
  "encoding": "REF",
  "code": { "key": "initial-mapping", "version": "1.0.0", "flow": "sys-mappings", "domain": "core" }
}
```

## When to extract a helper

Inline `.csx` is fine for one-off logic. Extract into a `sys-mappings` helper (then reference via
`scripts.helpers`, or the whole mapping via `encoding:"REF"`) when the same logic is needed in more
than one place, or when it's a self-contained utility (crypto, serialization, formatting). Keep helper
classes as plain `public static class` types — see `csx-contracts.md`.

## Sources

- Schema: `node_modules/@burgan-tech/vnext-schema/schemas/mapping-definition.schema.json` (+ the
  `scripts`/`mappingRef`/`scriptCode` definitions inside `workflow`/`function`/`extension` schemas).
- Deep model (script sandbox, helper linking, REF designer UX, versioning): vNext docs portal + MCP.
- Working examples: `vnext-example/core/Mappings/account-opening/` and the `scripts`/`REF` usage in
  `vnext-example/core/Workflows/account-opening/account-opening-workflow.json`.
