---
name: component-mapping
description: Use when the user wants to create a vNext Mapping (sys-mappings) component — a reusable C# helper/code class (e.g. a crypto or JSON helper) that other components reference via scripts.helpers or encoding REF. Fetches mapping-definition.schema.json first, scaffolds the Mappings/{key}.json envelope + the .csx static class, and explains wiring it into consumers.
---

# Component Mapping (`sys-mappings`)

A **Mapping** is a reusable C# class shared across components — a helper (`RsaCryptoHelper`,
`JsonHelper`) or a whole reusable mapping (`InitialTransMapping`). Other components load it via a
`scripts.helpers` reference, or reference a whole mapping with `encoding: "REF"`. This avoids
duplicating `.csx` logic across workflows/tasks/functions.

See `references/concepts/mappings-and-scripts.md` for the concept and `references/concepts/csx-contracts.md`
for the C# side.

## Prerequisites
- Working directory is a vNext domain project (`vnext.config.json` present).
- You know the helper's purpose and its C# class name.

## Canonical schema-first (mandatory pre-step)

> Before producing JSON, read `mapping-definition.schema.json` for the workspace's pinned schema
> (`node_modules/@burgan-tech/vnext-schema/schemas/mapping-definition.schema.json`; if `node_modules`
> is absent, `npm install` or fall back to `references/concepts/mappings-and-scripts.md`). Drive the
> envelope from the schema, never from memory.

## Steps

### 1. Resolve paths from `vnext.config.json`
Capture `paths.componentsRoot`, `paths.mappings` (e.g. `Mappings`), `domain`. Target write path:
`{componentsRoot}/{paths.mappings}/{domain-subfolder}/{key}.json` with the `.csx` under its `src/`.

### 2. Gather the mapping
- **`key`** (kebab-case, e.g. `rsa-crypto`) and the **C# class name** (`name`, PascalCase, e.g. `RsaCryptoHelper`).
- **Kind**: a *helper* (plain `public static class` with utility methods) or a *reusable mapping*
  (implements a mapping interface — see `csx-contracts.md`).
- **External assemblies** it needs (e.g. `System.Security.Cryptography`, `Newtonsoft.Json`) — consumers
  must list these in `allowedAssemblies`.

### 3. Scaffold the `.csx`
A helper is a plain static class (no `IMapping`):

```csharp
using System.Security.Cryptography;
namespace Acme.Helpers;

public static class RsaCryptoHelper
{
    public static string Encrypt(string plain, string publicKeyBase64) { /* ... */ }
}
```

PascalCase class matching `name`; one class per file; kebab-case filename. **Never hand-base64 `code`** —
the VS Code extension encodes the `.csx` into `code` on save.

### 4. Write the component JSON

```jsonc
{
  "key": "{key}", "version": "1.0.0", "domain": "{domain}",
  "flow": "sys-mappings", "flowVersion": "1.0.0", "tags": ["{tag}"],
  "attributes": {
    "name": "{ClassName}",
    "location": "./src/{ClassName}.csx",
    "code": "",
    "encoding": "NAT"   // sys-mappings supports B64 or NAT only — NEVER REF (it is the ref target)
  }
}
```

### 5. Wire it into consumers (explain to the user)
- **Use a helper class**: add a `scripts` block to the consumer's mapping (or workflow `attributes.scripts`):
  ```jsonc
  "scripts": {
    "helpers": [ { "key": "{key}", "version": "1.0.0", "domain": "{domain}", "flow": "sys-mappings" } ],
    "allowedAssemblies": [ "System.Security.Cryptography" ]
  }
  ```
  The helper's static class is then callable by name in the consumer's `.csx`.
- **Reference a whole mapping**: set the consumer mapping's `encoding: "REF"` and `code` to the
  `mappingRef` `{ key, version, domain, flow: "sys-mappings" }`.

### 6. Validate
`npm run validate`. Hand failures to `validate-and-fix`.

## Notes
- `sys-mappings` `encoding` is **`B64` or `NAT` only** — it cannot be `REF` (no self-reference).
- Register in `exports.mappings` (vnext.config.json) only if shared cross-domain.
- The sandbox/security model for `allowedAssemblies` and helper runtime linking is documented on the
  vNext docs portal — fetch it if a consumer's script fails to resolve a helper or assembly.
