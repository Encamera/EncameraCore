"""ciProduct operations.

A ciProduct is the Xcode Cloud-side record for an app or framework. Each
App Store Connect app has at most one ciProduct — resolving from an app_id
is the common entry point for every other Xcode Cloud call.
"""

from typing import Optional

from asc.client import ASCClient
from asc.xcode_cloud.models import CiProduct


def list_products(client: ASCClient) -> list[CiProduct]:
    items = client.get_all("/v1/ciProducts", params={"include": "app"})
    return [CiProduct.from_api(item) for item in items]


def get_product(client: ASCClient, product_id: str) -> CiProduct:
    result = client.get(f"/v1/ciProducts/{product_id}", params={"include": "app"})
    return CiProduct.from_api(result["data"])


def get_product_for_app(client: ASCClient, app_id: str) -> Optional[CiProduct]:
    """Find the ciProduct tied to an App Store Connect app.

    The API has no filter[app] on /ciProducts, so we list and match on the
    relationship. Product counts per team are small, so this is fine.
    """
    for product in list_products(client):
        if product.app_id == app_id:
            return product
    return None
