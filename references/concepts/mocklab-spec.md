# MockLab — Seed Format & Behavior

MockLab is vNext's canonical mock API (Mockoon has been removed). Image `ghcr.io/burgan-tech/mocklab`, pinned to **0.0.10** in the toolkit's `docker-compose.yml` and test environment. It answers on `http://localhost:3001` **from the host** (browser, curl, `.http` files) and on `http://mocklab:5000` **from runtime containers** on the `vnext-development` network; in Testcontainers runs the SDK starts its own MockLab at `http://test-mocklab:5000`. A `mocklab-dapr` sidecar is colocated for Dapr service invocation (app-id `mocklab`).

> **HTTP task URLs never hard-code a host.** They carry the `API_BASEURL` placeholder, resolved by the task's input mapping from configuration (below). `http://localhost:3001` inside a task works only for a runtime run as a host process — never for Testcontainers or vnext-runtime, where `localhost` is the runtime container itself.

## Authoritative source

```
https://github.com/burgan-tech/mocklab
```

The seed format may evolve. When in doubt — and especially when adding rules with operators or sequences not shown below — fetch the current README and schema from the repo. The snapshot below is the baseline.

## Seed file layout

Seed files live under `etc/docker/config/seed/` and are imported on container startup. **One collection per business domain** — don't split a domain across files.

```jsonc
{
  "collection": {
    "name": "<domain>",
    "description": null,
    "color": "#6366f1"
  },
  "folders": [],
  "mocks": [
    {
      "httpMethod": "GET | POST | PUT | PATCH | DELETE",
      "route": "api/{domain}/{resource}/{action}",
      "queryString": null,
      "requestBody": "",
      "statusCode": 200,
      "responseBody": "<JSON string; Scriban interpolation supported>",
      "contentType": "application/json",
      "description": "...",
      "delayMs": null,
      "isActive": true,
      "isSequential": false,
      "folderIndex": null,
      "rules": [
        {
          "conditionField": "query.X | body.X | header.X | route.X | method | path",
          "conditionOperator": "equals | regex | contains | startsWith | endsWith | exists | notExists | greaterThan | lessThan",
          "conditionValue": "...",
          "statusCode": 200,
          "responseBody": "...",
          "contentType": "application/json",
          "priority": 0,
          "responseHeaders": []
        }
      ],
      "sequenceItems": []
    }
  ]
}
```

## Rule operators (current)

| Operator | Meaning |
|----------|---------|
| `equals` | Exact match |
| `regex` | Regex match (anchored as the implementation defines; verify) |
| `contains` | Substring |
| `startsWith` | Prefix |
| `endsWith` | Suffix |
| `exists` | Field is present (any value) |
| `notExists` | Field is absent |
| `greaterThan` | Numeric `>` |
| `lessThan` | Numeric `<` |

`conditionField` patterns:
- `query.X` — query string parameter
- `body.X` — JSON body field (dotted path supported)
- `header.X` — request header
- `route.X` — path parameter
- `method` — HTTP verb
- `path` — request path

Rules are evaluated in `priority` order (lower = first); first match wins. The default response (`statusCode`/`responseBody` at the mock level) is used when no rule matches.

## Scriban templating

`responseBody` supports Scriban expressions:

```
{{ guid }}                                   # new GUID (or {{ helpers.guid }})
{{ iso_timestamp }}                          # current timestamp ISO 8601 ({{ timestamp }} = Unix)
{{ random_string 8 }}                        # random string ({{ random_alpha_numeric 8 }} = alphanumeric)
{{ random_int 1000 9999 }}                   # random integer in range
{{ request.body.amount }}                    # value from request JSON body
{{ request.query["userId"] }}                # query parameter (bracket syntax)
{{ request.headers["Authorization"] }}       # header
{{ request.route.id }}                       # route parameter
```

Helpers take **space-separated args, no parentheses**. The exact helper set depends on the MockLab
version — verify the current list at `https://github.com/burgan-tech/mocklab/blob/master/docs/user-guide.md`
(or via Context7). Invalid forms from older docs: `helpers.guid()`, `helpers.now()`,
`random.integer`, `request.json.X`, `request.header['X']`.

## Sequential responses (`isSequential: true`)

For retry/rate-limit demos, set `isSequential: true` and provide `sequenceItems[]`:

```jsonc
{
  "isSequential": true,
  "sequenceItems": [
    { "statusCode": 503, "responseBody": "{\"error\":\"unavailable\"}" },
    { "statusCode": 503, "responseBody": "{\"error\":\"unavailable\"}" },
    { "statusCode": 200, "responseBody": "{\"ok\":true}" }
  ]
}
```

The mock cycles through items per request; useful for testing workflow retry policies.

## URL conventions in HTTP tasks

Task JSON ships the placeholder; the input mapping swaps in the configured base URL:

```jsonc
{
  "type": "6",
  "config": {
    "url": "API_BASEURL/api/{domain}/{resource}/{action}",
    "method": "POST"
  }
}
```

```csharp
public Task<ScriptResponse> InputHandler(WorkflowTask task, ScriptContext context)
{
    if (task is HttpTask http)
        http.SetUrl(http.Url.Replace("API_BASEURL",
            GetConfigValue("<Domain>:ApiBaseUrl", "http://mocklab:5000")));   // ':'-nested key
    return Task.FromResult(new ScriptResponse());
}
```

`<Domain>` = PascalCase of the domain. The value is configuration, set per environment as the env var
`<Domain>__ApiBaseUrl` on **both** orchestration and execution:

| Where the runtime runs | `<Domain>__ApiBaseUrl` |
|---|---|
| Testcontainers (`dotnet test`, CI) | `http://<MocklabHost>:5000` — set by the toolkit `VNextTestEnvironment` (`MocklabHost` = `test-mocklab`) |
| vnext-runtime released images | default `http://mocklab:5000` (MockLab compose alias); override in `domains/<d>/.env.orchestration` and `.env.execution` |
| Shared / production environments | the real upstream base URL (Helm `appEnvConfig`) |

**Dapr service invocation** of MockLab: use a `DaprService` task with `appId: "mocklab"` — the call goes
through the runtime's own sidecar. `http://localhost:3500/v1.0/invoke/mocklab/method/…` reaches MockLab's
sidecar from the host only (manual probing).

## Re-import gotcha (CRITICAL)

MockLab keys collections by `collection.name`. **If a collection with that name already exists in MockLab's DB, the new seed is skipped.** Editing the seed file alone does NOT update MockLab on next start.

To force a clean re-import:

```bash
docker compose down -v && docker compose up -d mocklab
```

The `-v` removes the MockLab volume so the DB starts empty and reimports all seeds. Alternative: push updates via MockLab's admin API (no restart required).

## Skill behavior

When `component-task` adds an HTTP task that calls a new endpoint:

1. Determine the collection name (`<domain>` from `vnext.config.json`).
2. Locate `etc/docker/config/seed/{collection}.json` — create if missing.
3. **Append** a `mocks[]` entry; never create a parallel collection file for the same domain.
4. Remind the user to run the re-import command after saving.

## Sources

- Live spec: `https://github.com/burgan-tech/mocklab`
- Working seeds: `vnext-example/etc/docker/config/seed/*.json`
- Pattern reference: `vnext-example/.claude/references/mocklab-seed-format.md`
