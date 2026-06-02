# MockLab — Seed Format & Behavior

MockLab is vNext's canonical mock API (Mockoon has been removed). HTTP tasks during development point at MockLab at `http://localhost:3001`; in workflows that use Dapr service invocation, a `mocklab-dapr` sidecar is colocated (Dapr app-id `mocklab`, HTTP port `3500`).

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
{{ helpers.guid() }}                         # new GUID
{{ helpers.now() }}                          # current timestamp ISO 8601
{{ random.alphabetic 8 }}                    # random letters
{{ random.integer 1000 9999 }}               # random integer
{{ request.json.amount }}                    # value from request JSON body
{{ request.query.userId }}                   # query parameter
{{ request.header['Authorization'] }}        # header
```

The exact helper set depends on the MockLab version — fetch the README for the current list.

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

When workflows call mocked endpoints, point HTTP task config at MockLab:

```jsonc
{
  "type": "6",
  "config": {
    "url": "http://localhost:3001/api/{domain}/{resource}/{action}",
    "method": "POST",
    "...": "..."
  }
}
```

Alternative (Dapr service invocation):
```
http://localhost:3500/v1.0/invoke/mocklab/method/api/{domain}/{resource}/{action}
```

Or use a `DaprService` task with app-id `mocklab`.

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
