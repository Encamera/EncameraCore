"""Data models for App Store Connect API responses."""

from dataclasses import dataclass
from typing import Optional


@dataclass
class SubscriptionGroup:
    id: str
    name: str

    @classmethod
    def from_api(cls, data: dict) -> "SubscriptionGroup":
        return cls(id=data["id"], name=data["attributes"]["referenceName"])


@dataclass
class Subscription:
    id: str
    name: str
    product_id: str
    group_id: str
    state: str

    @classmethod
    def from_api(cls, data: dict) -> "Subscription":
        attrs = data["attributes"]
        group_id = data.get("relationships", {}).get("group", {}).get("data", {}).get("id", "")
        return cls(
            id=data["id"],
            name=attrs["name"],
            product_id=attrs["productId"],
            group_id=group_id,
            state=attrs["state"],
        )


@dataclass
class SubscriptionPrice:
    id: str
    territory: str
    currency: str
    price: str
    start_date: Optional[str]
    subscription_id: str

    @classmethod
    def from_api(cls, data: dict, included: Optional[list] = None) -> "SubscriptionPrice":
        attrs = data["attributes"]
        territory = ""
        currency = ""
        price = ""
        included_map = {inc["id"]: inc for inc in (included or [])}
        territory_rel = data.get("relationships", {}).get("territory", {}).get("data", {})
        if territory_rel:
            territory = territory_rel.get("id", "")
            terr_obj = included_map.get(territory)
            if terr_obj:
                currency = terr_obj.get("attributes", {}).get("currency", "")
        pp_rel = data.get("relationships", {}).get("subscriptionPricePoint", {}).get("data", {})
        if pp_rel:
            pp_obj = included_map.get(pp_rel.get("id"))
            if pp_obj:
                price = pp_obj.get("attributes", {}).get("customerPrice", "")
        sub_rel = data.get("relationships", {}).get("subscription", {}).get("data", {})
        return cls(
            id=data["id"],
            territory=territory,
            currency=currency,
            price=price,
            start_date=attrs.get("startDate"),
            subscription_id=sub_rel.get("id", ""),
        )


@dataclass
class PricePoint:
    id: str
    territory: str
    currency: str
    customer_price: str
    proceeds: str

    @classmethod
    def from_api(cls, data: dict, included: Optional[list] = None) -> "PricePoint":
        attrs = data["attributes"]
        territory = ""
        currency = ""
        included_map = {inc["id"]: inc for inc in (included or [])}
        terr_rel = data.get("relationships", {}).get("territory", {}).get("data", {})
        if terr_rel:
            territory = terr_rel.get("id", "")
            terr_obj = included_map.get(territory)
            if terr_obj:
                currency = terr_obj.get("attributes", {}).get("currency", "")
        return cls(
            id=data["id"],
            territory=territory,
            currency=currency,
            customer_price=attrs.get("customerPrice", ""),
            proceeds=attrs.get("proceeds", ""),
        )


@dataclass
class IAPPrice:
    id: str
    territory: str
    currency: str
    price: str
    manual: bool

    @classmethod
    def from_api(cls, data: dict, included: Optional[list] = None) -> "IAPPrice":
        attrs = data["attributes"]
        territory = ""
        currency = ""
        price = ""
        included_map = {inc["id"]: inc for inc in (included or [])}
        terr_rel = data.get("relationships", {}).get("territory", {}).get("data", {})
        if terr_rel:
            territory = terr_rel.get("id", "")
            terr_obj = included_map.get(territory)
            if terr_obj:
                currency = terr_obj.get("attributes", {}).get("currency", "")
        pp_rel = data.get("relationships", {}).get("inAppPurchasePricePoint", {}).get("data", {})
        if pp_rel:
            pp_obj = included_map.get(pp_rel.get("id"))
            if pp_obj:
                price = pp_obj.get("attributes", {}).get("customerPrice", "")
        return cls(
            id=data["id"],
            territory=territory,
            currency=currency,
            price=price,
            manual=attrs.get("manual", False),
        )


@dataclass
class InAppPurchase:
    id: str
    name: str
    product_id: str
    iap_type: str
    state: str

    @classmethod
    def from_api(cls, data: dict) -> "InAppPurchase":
        attrs = data["attributes"]
        return cls(
            id=data["id"],
            name=attrs["name"],
            product_id=attrs["productId"],
            iap_type=attrs["inAppPurchaseType"],
            state=attrs["state"],
        )


@dataclass
class AppStoreVersion:
    id: str
    version_string: str
    platform: str
    state: str
    release_type: Optional[str]
    created_date: Optional[str]
    build_id: Optional[str]
    build_version: Optional[str]

    @classmethod
    def from_api(cls, data: dict, included: Optional[list] = None) -> "AppStoreVersion":
        attrs = data["attributes"]
        build_id = None
        build_version = None
        build_rel = data.get("relationships", {}).get("build", {}).get("data")
        if build_rel:
            build_id = build_rel.get("id")
            if included:
                included_map = {inc["id"]: inc for inc in included}
                build_obj = included_map.get(build_id)
                if build_obj:
                    build_version = build_obj.get("attributes", {}).get("version")
        return cls(
            id=data["id"],
            version_string=attrs.get("versionString", ""),
            platform=attrs.get("platform", ""),
            state=attrs.get("appStoreState", ""),
            release_type=attrs.get("releaseType"),
            created_date=attrs.get("createdDate"),
            build_id=build_id,
            build_version=build_version,
        )


@dataclass
class Build:
    id: str
    version: str
    processing_state: str
    uploaded_date: Optional[str]
    expiration_date: Optional[str]
    min_os_version: Optional[str]

    @classmethod
    def from_api(cls, data: dict) -> "Build":
        attrs = data["attributes"]
        return cls(
            id=data["id"],
            version=attrs.get("version", ""),
            processing_state=attrs.get("processingState", ""),
            uploaded_date=attrs.get("uploadedDate"),
            expiration_date=attrs.get("expirationDate"),
            min_os_version=attrs.get("minOsVersion"),
        )


@dataclass
class AppStoreVersionLocalization:
    id: str
    locale: str
    description: Optional[str]
    keywords: Optional[str]
    whats_new: Optional[str]
    promotional_text: Optional[str]
    marketing_url: Optional[str]
    support_url: Optional[str]

    @classmethod
    def from_api(cls, data: dict) -> "AppStoreVersionLocalization":
        attrs = data["attributes"]
        return cls(
            id=data["id"],
            locale=attrs.get("locale", ""),
            description=attrs.get("description"),
            keywords=attrs.get("keywords"),
            whats_new=attrs.get("whatsNew"),
            promotional_text=attrs.get("promotionalText"),
            marketing_url=attrs.get("marketingUrl"),
            support_url=attrs.get("supportUrl"),
        )
