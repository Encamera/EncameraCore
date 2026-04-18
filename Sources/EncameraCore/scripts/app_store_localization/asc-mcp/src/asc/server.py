"""MCP server for App Store Connect API."""

import os
from dataclasses import asdict
from typing import Optional

from mcp.server.fastmcp import FastMCP

from asc.auth import Credentials
from asc.client import ASCClient
from asc.pricing import iap, subscriptions
from asc import releases

mcp = FastMCP("App Store Connect")

_client: Optional[ASCClient] = None


def _get_client() -> ASCClient:
    global _client
    if _client is None:
        yaml_path = os.environ.get("ASC_CREDENTIALS_PATH")
        creds = Credentials.load(yaml_path)
        _client = ASCClient(creds)
    return _client


@mcp.tool()
def list_subscription_groups(app_id: Optional[str] = None) -> list[dict]:
    """List all subscription groups for the app.
    Returns id and name for each group. Use the group id with list_subscriptions to see the subscriptions in that group."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    groups = subscriptions.list_subscription_groups(client, aid)
    return [asdict(g) for g in groups]


@mcp.tool()
def list_subscriptions(group_id: str) -> list[dict]:
    """List all subscriptions in a subscription group.
    Returns id, name, product_id, state for each subscription.
    Use the subscription id with get_subscription_prices or get_subscription_price_points."""
    client = _get_client()
    subs = subscriptions.list_subscriptions(client, group_id)
    return [asdict(s) for s in subs]


@mcp.tool()
def get_subscription_prices(subscription_id: str) -> list[dict]:
    """Get current prices for a subscription across all territories.
    Returns territory (3-letter code like USA, IND), currency, price, and start_date for each territory.
    This shows what customers currently pay, not the available price tiers."""
    client = _get_client()
    prices = subscriptions.get_subscription_prices(client, subscription_id)
    return [asdict(p) for p in prices]


@mcp.tool()
def get_subscription_price_points(
    subscription_id: str,
    territory: Optional[str] = None,
    target_price: Optional[float] = None,
) -> list[dict]:
    """Get available price points (tiers) that a subscription can be set to.
    These are NOT current prices — use get_subscription_prices for that.
    Use territory (3-letter code, e.g. 'USA', 'IND') to filter to one country.
    Use target_price to find the closest match — returns 3 price points above and below the target.
    Always use target_price with territory to avoid massive result sets.
    The returned price point id is needed for set_subscription_price."""
    client = _get_client()
    points = subscriptions.get_subscription_price_points(client, subscription_id, territory)
    if target_price is not None:
        points.sort(key=lambda p: float(p.customer_price))
        below = [p for p in points if float(p.customer_price) <= target_price][-3:]
        above = [p for p in points if float(p.customer_price) > target_price][:3]
        points = below + above
    return [asdict(p) for p in points]


@mcp.tool()
def set_subscription_price(
    subscription_id: str, price_point_id: str, start_date: Optional[str] = None
) -> dict:
    """Set the price for a subscription in a specific territory using a price point ID from get_subscription_price_points.
    For approved subscriptions that already have prices, a start_date (YYYY-MM-DD) is REQUIRED —
    the API rejects creating an "initial" price again. The start_date must be at least 2 days in the future.
    The price point ID encodes the subscription, territory, and price tier, so no separate territory param is needed.
    IAP prices are set differently — use set_iap_price_schedule for those."""
    client = _get_client()
    return subscriptions.set_subscription_price(client, subscription_id, price_point_id, start_date)


@mcp.tool()
def delete_subscription_price(price_id: str) -> str:
    """Delete a scheduled subscription price change. Only works for future-dated price changes, not current prices.
    The price_id comes from get_subscription_prices."""
    client = _get_client()
    subscriptions.delete_subscription_price(client, price_id)
    return "Deleted"


@mcp.tool()
def list_in_app_purchases(app_id: Optional[str] = None) -> list[dict]:
    """List all in-app purchases for the app.
    Returns id, name, product_id, iap_type (CONSUMABLE, NON_CONSUMABLE), and state.
    Use the id with get_iap_price_schedule or get_iap_price_points."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    iaps = iap.list_in_app_purchases(client, aid)
    return [asdict(i) for i in iaps]


@mcp.tool()
def get_iap_price_points(
    iap_id: str,
    territory: Optional[str] = None,
    target_price: Optional[float] = None,
) -> list[dict]:
    """Get available price points (tiers) that an IAP can be set to.
    These are NOT current prices — use get_iap_price_schedule for that.
    Use territory (3-letter code, e.g. 'USA', 'IND') to filter to one country.
    Use target_price to find the closest match — returns 3 price points above and below the target.
    Always use target_price with territory to avoid massive result sets.
    The returned price point id is needed for set_iap_price_schedule."""
    client = _get_client()
    points = iap.get_iap_price_points(client, iap_id, territory)
    if target_price is not None:
        points.sort(key=lambda p: float(p.customer_price))
        below = [p for p in points if float(p.customer_price) <= target_price][-3:]
        above = [p for p in points if float(p.customer_price) > target_price][:3]
        points = below + above
    return [asdict(p) for p in points]


@mcp.tool()
def get_iap_price_schedule(iap_id: str, territory: Optional[str] = None) -> list[dict]:
    """Get the current prices for an IAP across all territories, with resolved price amounts.
    Returns territory, currency, price, and whether it's a manual or automatic price.
    Manual prices are ones you explicitly set; automatic prices are Apple's equalized prices for other territories.
    Filter by territory (3-letter code, e.g. 'USA', 'IND') to see just one country."""
    client = _get_client()
    prices = iap.get_iap_price_schedule(client, iap_id, territory)
    return [asdict(p) for p in prices]


@mcp.tool()
def set_iap_price_schedule(
    iap_id: str, base_territory: str, manual_prices: list[dict]
) -> dict:
    """Set the price schedule for an in-app purchase. Takes effect immediately.
    IMPORTANT: You MUST always include the base territory (usually 'USA') price point in manual_prices,
    otherwise the API returns a 409 ENTITY_ERROR.BASE_TERRITORY_INTERVAL_REQUIRED error.
    To set a custom price for one territory while keeping others auto-equalized:
    1. Get the current base territory price point id via get_iap_price_points
    2. Get the target territory price point id via get_iap_price_points
    3. Include both in manual_prices

    manual_prices: list of {"territory_id": str, "price_point_id": str}
    base_territory: 3-letter territory code (e.g. 'USA')"""
    client = _get_client()
    return iap.set_iap_price_schedule(client, iap_id, base_territory, manual_prices)


@mcp.tool()
def list_app_store_versions(app_id: Optional[str] = None, platform: Optional[str] = None) -> list[dict]:
    """List all App Store versions for the app, with their current state and attached build.
    States include PREPARE_FOR_SUBMISSION, WAITING_FOR_REVIEW, IN_REVIEW, READY_FOR_SALE, etc.
    Filter by platform (IOS, MAC_OS, TV_OS, VISION_OS) if the app supports multiple."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    versions = releases.list_app_store_versions(client, aid, platform)
    return [asdict(v) for v in versions]


@mcp.tool()
def get_app_store_version(version_id: str) -> dict:
    """Get details for a specific App Store version, including its state and attached build."""
    client = _get_client()
    version = releases.get_app_store_version(client, version_id)
    return asdict(version)


@mcp.tool()
def create_app_store_version(
    version_string: str,
    platform: str = "IOS",
    release_type: Optional[str] = None,
    app_id: Optional[str] = None,
) -> dict:
    """Create a new App Store version (release) for the app.
    version_string: the public version number, e.g. '2.4.1'.
    platform: IOS, MAC_OS, TV_OS, or VISION_OS. Defaults to IOS.
    release_type: optional — MANUAL or AFTER_APPROVAL. If omitted, uses the app's default."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    version = releases.create_app_store_version(client, aid, version_string, platform, release_type)
    return asdict(version)


@mcp.tool()
def set_build_for_version(version_id: str, build_id: str) -> dict:
    """Attach a build to an App Store version. The build must have finished processing.
    Use list_builds to find available builds and their IDs.
    version_id: the App Store version ID from list_app_store_versions or create_app_store_version.
    build_id: the build ID from list_builds."""
    client = _get_client()
    version = releases.set_build_for_version(client, version_id, build_id)
    return asdict(version)


@mcp.tool()
def list_builds(
    app_id: Optional[str] = None,
    processing_state: Optional[str] = None,
) -> list[dict]:
    """List builds uploaded to App Store Connect.
    Filter by processing_state: PROCESSING, FAILED, INVALID, VALID.
    Returns id, version (build number), processing state, upload date, and min OS version."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    builds = releases.list_builds(client, aid, processing_state)
    return [asdict(b) for b in builds]


@mcp.tool()
def get_version_localizations(version_id: str) -> list[dict]:
    """Get all localizations for an App Store version — description, keywords, what's new,
    promotional text, and URLs for each locale.
    version_id: the App Store version ID from list_app_store_versions."""
    client = _get_client()
    locs = releases.get_version_localizations(client, version_id)
    return [asdict(loc) for loc in locs]


@mcp.tool()
def submit_for_review(version_id: str, app_id: Optional[str] = None) -> dict:
    """Submit an App Store version for review.
    The version must have a build attached and all required metadata filled in.
    version_id: the App Store version ID from list_app_store_versions."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    return releases.submit_for_review(client, aid, version_id)


def main():
    mcp.run()


if __name__ == "__main__":
    main()
