# asc-mcp

MCP server for the App Store Connect API. Exposes tools for managing subscription and in-app purchase pricing.

## Prerequisites

- Python 3.10+
- An App Store Connect API key (ES256 `.p8` file) — see [Creating API Keys](https://developer.apple.com/documentation/appstoreconnectapi/creating_api_keys_for_app_store_connect_api)

## Setup

```bash
cd asc-mcp
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

## Configuration

The server loads credentials in two ways. It checks for a YAML file first, then falls back to environment variables.

### Option A: YAML credentials file

Create a `credentials.yml` (keep this out of version control):

```yaml
app_store_connect:
  key_id: "YOUR_KEY_ID"
  issuer_id: "YOUR_ISSUER_ID"
  # Either inline the key content:
  private_key_content: |
    -----BEGIN EC PRIVATE KEY-----
    ...
    -----END EC PRIVATE KEY-----
  # Or reference the .p8 file (relative to this YAML file, or absolute):
  # private_key_file: AuthKey_XXXXXX.p8

app:
  bundle_id: "com.example.yourapp"   # optional — used to resolve the app ID automatically
  app_id: "123456789"                # optional — if set, skips the bundle_id lookup
```

Then point the server at it:

```bash
export ASC_CREDENTIALS_PATH=/path/to/credentials.yml
```

### Option B: Environment variables

```bash
export ASC_KEY_ID="YOUR_KEY_ID"
export ASC_ISSUER_ID="YOUR_ISSUER_ID"
export ASC_PRIVATE_KEY_FILE="/path/to/AuthKey_XXXXXX.p8"
# or: export ASC_PRIVATE_KEY="-----BEGIN EC PRIVATE KEY-----\n..."

# Optional:
export ASC_BUNDLE_ID="com.example.yourapp"
export ASC_APP_ID="123456789"
```

## Running the server

```bash
asc-mcp
```

Or directly:

```bash
python -m asc.server
```

## Using with Claude Code

Add to your Claude Code MCP config (`~/.claude.json` or project settings):

```json
{
  "mcpServers": {
    "asc": {
      "command": "/path/to/asc-mcp/.venv/bin/asc-mcp",
      "env": {
        "ASC_CREDENTIALS_PATH": "/path/to/credentials.yml"
      }
    }
  }
}
```

## Available tools

### Releases and builds

| Tool | Description |
|---|---|
| `list_app_store_versions` | List all App Store versions with state and attached build |
| `get_app_store_version` | Get details for a specific version |
| `create_app_store_version` | Create a new App Store version (release) |
| `set_build_for_version` | Attach a build to a version |
| `list_builds` | List uploaded builds, optionally filtered by processing state |
| `get_version_localizations` | Get localized metadata (description, keywords, what's new) for a version |

### Subscription pricing

| Tool | Description |
|---|---|
| `list_subscription_groups` | List subscription groups for an app |
| `list_subscriptions` | List subscriptions in a group |
| `get_subscription_prices` | Get current prices for a subscription across territories |
| `get_subscription_price_points` | Get available price tiers a subscription can be set to |
| `set_subscription_price` | Set the price for a subscription in a territory |
| `delete_subscription_price` | Delete a scheduled future price change |

### In-app purchase pricing

| Tool | Description |
|---|---|
| `list_in_app_purchases` | List all IAPs for an app |
| `get_iap_price_points` | Get available price tiers for an IAP |
| `get_iap_price_schedule` | Get current IAP prices across territories |
| `set_iap_price_schedule` | Set the price schedule for an IAP |
