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
class BetaGroup:
    """A TestFlight group. Internal groups are limited to App Store Connect
    users and get builds automatically when ``has_access_to_all_builds`` is set;
    external groups need each build added explicitly and gated on beta review."""

    id: str
    name: str
    is_internal: bool
    has_access_to_all_builds: bool
    public_link_enabled: bool
    public_link: Optional[str]
    feedback_enabled: bool
    created_date: Optional[str]

    @classmethod
    def from_api(cls, data: dict) -> "BetaGroup":
        attrs = data.get("attributes", {})
        return cls(
            id=data["id"],
            name=attrs.get("name", ""),
            is_internal=bool(attrs.get("isInternalGroup")),
            has_access_to_all_builds=bool(attrs.get("hasAccessToAllBuilds")),
            public_link_enabled=bool(attrs.get("publicLinkEnabled")),
            public_link=attrs.get("publicLink"),
            feedback_enabled=bool(attrs.get("feedbackEnabled")),
            created_date=attrs.get("createdDate"),
        )


@dataclass
class BetaTester:
    """A TestFlight tester. ``state`` is INVITED until they accept the emailed
    invitation, then ACCEPTED / INSTALLED."""

    id: str
    email: Optional[str]
    first_name: Optional[str]
    last_name: Optional[str]
    state: Optional[str]
    invite_type: Optional[str]
    beta_group_ids: list[str]
    beta_group_names: list[str]

    @classmethod
    def from_api(cls, data: dict, included: Optional[list] = None) -> "BetaTester":
        """``beta_group_ids`` is only populated when the request asked for
        ``include=betaGroups`` — the collection endpoint returns relationship
        links but no ``data`` otherwise. ``beta_group_names`` additionally needs
        the ``included`` resources passed through."""
        attrs = data.get("attributes", {})
        groups = data.get("relationships", {}).get("betaGroups", {}).get("data") or []
        included_map = {inc["id"]: inc for inc in (included or [])}
        return cls(
            id=data["id"],
            email=attrs.get("email"),
            first_name=attrs.get("firstName"),
            last_name=attrs.get("lastName"),
            state=attrs.get("state"),
            invite_type=attrs.get("inviteType"),
            beta_group_ids=[g["id"] for g in groups],
            beta_group_names=[
                included_map.get(g["id"], {}).get("attributes", {}).get("name", g["id"])
                for g in groups
            ],
        )


@dataclass
class BuildBetaDetail:
    """TestFlight distribution state for one build.

    ``external_build_state`` walks WAITING_FOR_BETA_REVIEW → IN_BETA_REVIEW →
    IN_BETA_TESTING (or BETA_REJECTED); NOT_APPLICABLE means the build was never
    submitted for beta review. ``internal_build_state`` is independent — internal
    testers get builds without review.
    """

    id: str
    internal_build_state: Optional[str]
    external_build_state: Optional[str]
    auto_notify_enabled: bool

    @classmethod
    def from_api(cls, data: dict) -> "BuildBetaDetail":
        attrs = data.get("attributes", {})
        return cls(
            id=data["id"],
            internal_build_state=attrs.get("internalBuildState"),
            external_build_state=attrs.get("externalBuildState"),
            auto_notify_enabled=bool(attrs.get("autoNotifyEnabled")),
        )


@dataclass
class BetaAppReviewSubmission:
    """A build's submission to Apple's beta app review, required before any
    external group can install it. The resource id equals the build id."""

    id: str
    beta_review_state: Optional[str]
    submitted_date: Optional[str]

    @classmethod
    def from_api(cls, data: dict) -> "BetaAppReviewSubmission":
        attrs = data.get("attributes", {})
        return cls(
            id=data["id"],
            beta_review_state=attrs.get("betaReviewState"),
            submitted_date=attrs.get("submittedDate"),
        )


@dataclass
class BetaBuildLocalization:
    """Per-build, per-locale "What to Test" text."""

    id: str
    locale: str
    whats_new: Optional[str]

    @classmethod
    def from_api(cls, data: dict) -> "BetaBuildLocalization":
        attrs = data.get("attributes", {})
        return cls(
            id=data["id"],
            locale=attrs.get("locale", ""),
            whats_new=attrs.get("whatsNew"),
        )


@dataclass
class CrashSubmission:
    id: str
    created_date: Optional[str]
    comment: Optional[str]
    email: Optional[str]
    device_model: Optional[str]
    os_version: Optional[str]
    app_platform: Optional[str]
    architecture: Optional[str]
    locale: Optional[str]
    app_uptime_ms: Optional[int]
    build_id: Optional[str]
    build_number: Optional[str]

    @classmethod
    def from_api(cls, data: dict, included: Optional[list] = None) -> "CrashSubmission":
        attrs = data.get("attributes", {})
        build_id = None
        build_number = None
        build_rel = data.get("relationships", {}).get("build", {}).get("data")
        if build_rel:
            build_id = build_rel.get("id")
            included_map = {inc["id"]: inc for inc in (included or [])}
            build_obj = included_map.get(build_id)
            if build_obj:
                build_number = build_obj.get("attributes", {}).get("version")
        return cls(
            id=data["id"],
            created_date=attrs.get("createdDate"),
            comment=attrs.get("comment"),
            email=attrs.get("email"),
            device_model=attrs.get("deviceModel"),
            os_version=attrs.get("osVersion"),
            app_platform=attrs.get("appPlatform"),
            architecture=attrs.get("architecture"),
            locale=attrs.get("locale"),
            app_uptime_ms=attrs.get("appUptimeInMilliseconds"),
            build_id=build_id,
            build_number=build_number,
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
