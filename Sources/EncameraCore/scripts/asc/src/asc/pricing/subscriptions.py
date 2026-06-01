"""Subscription group and pricing operations."""

from typing import Optional

from asc.client import ASCClient
from asc.models import PricePoint, Subscription, SubscriptionGroup, SubscriptionPrice


def list_subscription_groups(client: ASCClient, app_id: str) -> list[SubscriptionGroup]:
    items = client.get_all(f"/v1/apps/{app_id}/subscriptionGroups")
    return [SubscriptionGroup.from_api(item) for item in items]


def list_subscriptions(client: ASCClient, group_id: str) -> list[Subscription]:
    items = client.get_all(f"/v1/subscriptionGroups/{group_id}/subscriptions")
    return [Subscription.from_api(item) for item in items]


def get_subscription_prices(client: ASCClient, subscription_id: str) -> list[SubscriptionPrice]:
    result = client.get_all_paginated_with_includes(
        f"/v1/subscriptions/{subscription_id}/prices",
        params={"include": "subscriptionPricePoint,territory"},
    )
    return [SubscriptionPrice.from_api(item, result["included"]) for item in result["data"]]


def get_subscription_price_points(
    client: ASCClient, subscription_id: str, territory: Optional[str] = None
) -> list[PricePoint]:
    params = {"include": "territory"}
    if territory:
        params["filter[territory]"] = territory
    result = client.get_all_paginated_with_includes(
        f"/v1/subscriptions/{subscription_id}/pricePoints", params=params
    )
    return [PricePoint.from_api(item, result["included"]) for item in result["data"]]


def set_subscription_price(
    client: ASCClient,
    subscription_id: str,
    price_point_id: str,
    start_date: Optional[str] = None,
) -> dict:
    body = {
        "data": {
            "type": "subscriptionPrices",
            "attributes": {},
            "relationships": {
                "subscription": {
                    "data": {"type": "subscriptions", "id": subscription_id}
                },
                "subscriptionPricePoint": {
                    "data": {"type": "subscriptionPricePoints", "id": price_point_id}
                },
            },
        }
    }
    if start_date:
        body["data"]["attributes"]["startDate"] = start_date
    return client.post("/v1/subscriptionPrices", body)


def delete_subscription_price(client: ASCClient, price_id: str) -> None:
    client.delete(f"/v1/subscriptionPrices/{price_id}")
