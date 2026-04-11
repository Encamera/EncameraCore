"""In-app purchase pricing operations."""

from typing import Optional

from asc.client import ASCClient
from asc.models import IAPPrice, InAppPurchase, PricePoint


def list_in_app_purchases(client: ASCClient, app_id: str) -> list[InAppPurchase]:
    items = client.get_all(f"/v1/apps/{app_id}/inAppPurchasesV2")
    return [InAppPurchase.from_api(item) for item in items]


def get_iap_price_points(
    client: ASCClient, iap_id: str, territory: Optional[str] = None
) -> list[PricePoint]:
    params = {"include": "territory"}
    if territory:
        params["filter[territory]"] = territory
    result = client.get_all_paginated_with_includes(
        f"/v2/inAppPurchases/{iap_id}/pricePoints", params=params
    )
    return [PricePoint.from_api(item, result["included"]) for item in result["data"]]


def get_iap_price_schedule(
    client: ASCClient, iap_id: str, territory: Optional[str] = None
) -> list[IAPPrice]:
    """Get current IAP prices with resolved price amounts.

    Fetches manual prices first, then automatic prices, with their
    price points and territories included so we get actual currency amounts.
    """
    prices: list[IAPPrice] = []
    for price_type in ("manualPrices", "automaticPrices"):
        params = {"include": "inAppPurchasePricePoint,territory"}
        if territory:
            params["filter[territory]"] = territory
        result = client.get_all_paginated_with_includes(
            f"/v1/inAppPurchasePriceSchedules/{iap_id}/{price_type}",
            params=params,
        )
        prices.extend(
            IAPPrice.from_api(item, result["included"]) for item in result["data"]
        )
    return prices


def set_iap_price_schedule(
    client: ASCClient,
    iap_id: str,
    base_territory: str,
    manual_prices: list[dict],
) -> dict:
    """Set IAP price schedule.

    manual_prices: list of {"territory_id": str, "price_point_id": str}
    """
    price_relationships = []
    for i, mp in enumerate(manual_prices):
        price_relationships.append({
            "type": "inAppPurchasePrices",
            "id": f"${{{i}}}",
        })

    included = []
    for i, mp in enumerate(manual_prices):
        included.append({
            "type": "inAppPurchasePrices",
            "id": f"${{{i}}}",
            "relationships": {
                "inAppPurchasePricePoint": {
                    "data": {
                        "type": "inAppPurchasePricePoints",
                        "id": mp["price_point_id"],
                    }
                },
            },
        })

    body = {
        "data": {
            "type": "inAppPurchasePriceSchedules",
            "relationships": {
                "inAppPurchase": {
                    "data": {"type": "inAppPurchases", "id": iap_id}
                },
                "baseTerritory": {
                    "data": {"type": "territories", "id": base_territory}
                },
                "manualPrices": {
                    "data": price_relationships,
                },
            },
        },
        "included": included,
    }
    return client.post("/v1/inAppPurchasePriceSchedules", body)
