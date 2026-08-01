# Agent guide — `asc` library

Instructions for AI agents working with this library. Read this before adding new ASC functionality to scripts.

## Don't reinvent the API client

Every previous standalone script in `scripts/` reimplemented JWT generation and HTTP wrapping inline. **Don't do that.** If a script needs to call App Store Connect:

1. `from asc.auth import Credentials` — handles YAML config + env-var fallback + private-key file resolution
2. `from asc.client import ASCClient` — handles auth headers, token refresh, pagination
3. Either use an existing helper from `asc.releases` / `asc.pricing` / `asc.testflight` / `asc.xcode_cloud`, or call `client.get` / `client.post` / `client.patch` / `client.delete` directly

```python
from asc.auth import Credentials
from asc.client import ASCClient

client = ASCClient(Credentials.load(yaml_path))   # yaml_path optional; falls back to env
app_id = client.resolve_app_id()                  # honors app.bundle_id or app.app_id
```

## Where to add new functionality

| You're adding... | Put it in |
|---|---|
| A new ASC HTTP capability with no good home | a new `asc/<area>.py` module (see `asc/beta_feedback.py` for the pattern) |
| A subscription/IAP pricing call | `asc/pricing/iap.py` or `asc/pricing/subscriptions.py` |
| An app store version / build / localization call | `asc/releases.py` |
| A TestFlight build, "What to Test", or notification call | `asc/testflight/builds.py` |
| A beta-group call, or anything about build↔group membership | `asc/testflight/groups.py` |
| A beta-tester call — lookup, creation, group/build assignment, invitations | `asc/testflight/testers.py` |
| A beta app review call | `asc/testflight/review.py` |
| An Xcode Cloud call | one of the `asc/xcode_cloud/*.py` modules |

Anything added under `asc/testflight/` must also be re-exported from `asc/testflight/__init__.py` (both the import and `__all__`) — callers and the MCP server import from the package root, not the submodules.
| A new dataclass | `asc/models.py` (or `asc/xcode_cloud/models.py` for that subpackage) |

**Do not add MCP-specific code to `asc`.** The `asc` library must not import from `mcp`. MCP wrappers live in `../asc-mcp/src/asc_mcp/server.py`. If you add a library function that should be MCP-exposed, also add a `@mcp.tool()` in `server.py` that calls it.

## Function conventions

- First positional argument is always `client: ASCClient`.
- For list endpoints, paginate with `client.get_all(path, params=...)` (data only) or `client.get_all_paginated_with_includes(path, params=...)` (data + deduped `included`).
- For mutating endpoints, return the raw dict the API gives back (or the relevant subsection) rather than wrapping in a dataclass — keeps it usable for one-off scripts.
- Use the dataclasses in `asc/models.py` when the same shape is consumed in multiple places. `from_api(item)` constructs from a JSON:API resource dict; `from_api(item, included=[...])` resolves relationship lookups.
- When the API uses snake-cased Python keyword args mapped to camelCased JSON attributes, mirror the pattern in `asc.releases._localization_attributes`.

## Sparse fieldsets gotcha

ASC honors `fields[<resource>]` — but if you set that without listing the relationship names you want, the relationships are stripped from the response. Symptom: `build["relationships"]["preReleaseVersion"]["data"]` is missing and your include lookup always misses.

Fix: include the relationship name in `fields[<resource>]`:

```python
params = {
    "fields[builds]": "version,uploadedDate,preReleaseVersion",   # ← include the rel name
    "include": "preReleaseVersion",
    "fields[preReleaseVersions]": "version",
}
```

## Relationships you can write but not read

Not every JSON:API relationship is readable. `builds → betaGroups` allows only CREATE and DELETE:

```
GET /v1/builds/{id}/betaGroups                → 403 "does not allow 'GET_RELATED'"
GET /v1/builds/{id}/relationships/betaGroups  → 403 "does not allow 'GET_RELATIONSHIP'"
```

Read it from the other side instead — `GET /v1/builds?filter[betaGroups]=<group_id>` — which is what `asc.testflight.get_build_beta_groups` does, and why it needs an `app_id` to know which groups to check.

Similarly, `include` is rejected outright (400) on `/v1/betaGroups/{id}/betaTesters` and `/v1/builds/{id}/individualTesters`, so tester records from those paths come back with empty group membership. See `_tester_params` in `asc/testflight/testers.py`.

## betaTesters is team-wide, not app-scoped

`GET /v1/betaTesters?filter[email]=…` searches the whole team and will happily return stale records left behind by other apps — same email, same name, zero groups. **Always pass `filter[apps]=<app_id>`.** `find_testers_by_email` takes an optional `app_id` for this; `ensure_tester` requires one.

Related: a tester's `state` (INVITED / ACCEPTED / INSTALLED) is per-app, so it comes back `None` from an unscoped single-resource `GET /v1/betaTesters/{id}`.

## Relationship data needs an explicit `include`

Distinct from the sparse-fieldset gotcha above: on collection endpoints, `relationships.<name>.data` is omitted entirely — you get only `links` — unless the request asks for `include=<name>`. Listing `<name>` in `fields[<resource>]` is not enough. Symptom: a relationship id list that is always empty with no error.

## DELETE with a body

JSON:API relationship deletions require a request body (`{"data": [{"type": "...", "id": "..."}]}`). `ASCClient.delete(path, data=...)` supports this. Don't reach for `requests` directly.

## Running and testing

- The library is installed editable in `../asc-mcp/.venv` via `requirements.txt`. Edits to `asc/**` are picked up immediately — no reinstall needed.
- Smoke-test new code by running it against the live ASC API from that venv:
  ```bash
  scripts/asc-mcp/.venv/bin/python -c "
  from asc.auth import Credentials
  from asc.client import ASCClient
  c = ASCClient(Credentials.load('scripts/app_store_localization/credentials.yml'))
  # call your new function here
  "
  ```
- Verify the MCP still works after a non-trivial library change:
  ```bash
  printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}\n' \
    | ASC_CREDENTIALS_PATH=scripts/app_store_localization/credentials.yml \
      scripts/asc-mcp/.venv/bin/asc-mcp | head -c 400
  ```

## Credentials path

The real credentials live at `scripts/app_store_localization/credentials.yml` (the path predates the asc-mcp move; it stays there because `localize.py` reads other config from the same dir). Both standalone scripts and the MCP server load from there via the `ASC_CREDENTIALS_PATH` env var, configured in `~/.claude.json` for the MCP.

## When extending breaks the MCP

`asc/__init__.py` re-exports `Credentials`, `TokenManager`, `ASCClient`. Don't change those public names without updating `asc_mcp/server.py`. Other modules can be freely refactored — `server.py` imports them by full path (`from asc.pricing import iap`, etc.).
