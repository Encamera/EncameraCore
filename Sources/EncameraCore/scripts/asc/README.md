# asc

Python client library for the [App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi).

Used by:
- [`asc-mcp`](../asc-mcp/) — exposes the library as Model Context Protocol tools
- [`scripts/expire_testflight_builds.py`](../expire_testflight_builds.py) — expires old TestFlight builds
- [`scripts/app_store_localization/localize.py`](../app_store_localization/localize.py) — translates App Store metadata

## Install

Editable install from a sibling venv:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e /path/to/scripts/asc
```

Or in a `requirements.txt`:

```
-e ../asc
```

## Credentials

Either point `ASC_CREDENTIALS_PATH` at a YAML file:

```yaml
app_store_connect:
  key_id: "YOUR_KEY_ID"
  issuer_id: "YOUR_ISSUER_ID"
  private_key_file: AuthKey_XXXXXX.p8     # relative to this YAML, or absolute
  # or inline: private_key_content: |
  #   -----BEGIN PRIVATE KEY-----
  #   ...
app:
  bundle_id: "com.example.yourapp"        # optional — used to resolve app_id
  app_id: "123456789"                     # optional — set this to skip lookup
```

Or set environment variables:

```bash
export ASC_KEY_ID=...
export ASC_ISSUER_ID=...
export ASC_PRIVATE_KEY_FILE=/path/to/AuthKey_XXXXXX.p8   # or ASC_PRIVATE_KEY=...
export ASC_BUNDLE_ID=com.example.yourapp                 # optional
export ASC_APP_ID=123456789                              # optional
```

`Credentials.load()` tries the YAML path first (argument or `ASC_CREDENTIALS_PATH` env var), then falls back to env vars.

## Quick start

```python
from asc.auth import Credentials
from asc.client import ASCClient
from asc.pricing.iap import list_in_app_purchases

client = ASCClient(Credentials.load())          # uses ASC_CREDENTIALS_PATH or env
app_id = client.resolve_app_id()                # honors bundle_id or app_id
for iap in list_in_app_purchases(client, app_id):
    print(iap.product_id, iap.state)
```

## Modules

| Module | What it covers |
|---|---|
| `asc.auth` | `Credentials` (YAML + env loading), `TokenManager` (ES256 JWT generation with auto-refresh) |
| `asc.client` | `ASCClient` — HTTP wrapper with bearer-token auth, `get`/`post`/`patch`/`delete`, `get_all` and `get_all_paginated_with_includes` for paginated endpoints, plus `find_app_by_bundle_id` and `resolve_app_id` |
| `asc.models` | Dataclasses (`Subscription`, `InAppPurchase`, `Build`, `AppStoreVersion`, `AppStoreVersionLocalization`, …) with `from_api` constructors |
| `asc.releases` | App Store versions, builds, version localizations, review submissions |
| `asc.pricing.iap` | One-time IAP price points and schedules |
| `asc.pricing.subscriptions` | Subscription groups, subscriptions, prices |
| `asc.testflight` | Build expiration, beta groups, build/group relationships |
| `asc.xcode_cloud` | Xcode Cloud products, workflows, build runs, actions, issues, artifacts, test results, environments |

## Extending

Most functions take an `ASCClient` as the first positional argument and either return a dataclass (preferred for shapes used in multiple places) or a raw API dict (preferred for one-off calls). Pagination is handled by `client.get_all` (data only) or `client.get_all_paginated_with_includes` (data + included resources, deduped).

To add a new operation, add a function to the appropriate module — see `asc.testflight.expire_build` for a one-call PATCH example, `asc.testflight.list_builds_with_versions` for a paginated list with included relationships, or `asc.releases.create_version_localization` for a POST that builds a JSON:API request body.

When working with `fields[…]` sparse fieldsets: relationships are stripped unless the relationship name is included in the field list. If a call you expected to populate `relationships.X.data` is coming back without it, check that `X` is in `fields[<resource>]`.
