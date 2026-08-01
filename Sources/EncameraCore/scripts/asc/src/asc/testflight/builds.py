"""TestFlight build operations: listing, expiration, beta state, release notes."""

from typing import Any, Optional

from asc.client import ASCClient
from asc.models import BetaBuildLocalization, BuildBetaDetail


def list_builds_with_versions(
    client: ASCClient,
    app_id: str,
    limit: int = 200,
) -> list[dict[str, Any]]:
    """List builds for an app with preReleaseVersion attached.

    Each returned build dict gets an extra ``_app_version`` key set to the
    marketing version string from the related preReleaseVersion, or ``"?"``
    when no preReleaseVersion is associated.
    """
    params = {
        "filter[app]": app_id,
        "limit": limit,
        "sort": "-uploadedDate",
        # preReleaseVersion must be listed here too — see AGENTS.md "sparse fieldsets gotcha"
        "fields[builds]": "version,uploadedDate,expired,processingState,buildAudienceType,minOsVersion,preReleaseVersion",
        "include": "preReleaseVersion",
        "fields[preReleaseVersions]": "version",
    }
    result = client.get_all_paginated_with_includes("/v1/builds", params=params)

    version_map: dict[str, str] = {}
    for item in result.get("included", []):
        if item.get("type") == "preReleaseVersions":
            version_map[item["id"]] = item.get("attributes", {}).get("version", "?")

    builds = result["data"]
    for build in builds:
        rel = build.get("relationships", {}).get("preReleaseVersion", {}).get("data")
        build["_app_version"] = version_map.get(rel["id"], "?") if rel else "?"
    return builds


def list_builds_for_version(
    client: ASCClient,
    app_id: str,
    version_string: str,
    processing_state: Optional[str] = None,
) -> list[dict[str, Any]]:
    """Builds whose preReleaseVersion marketing version equals ``version_string``.

    Optionally further filtered to a specific ``processingState``
    (e.g. ``"VALID"`` for ready-to-attach builds or ``"PROCESSING"`` for builds
    still being processed by Apple).
    """
    builds = list_builds_with_versions(client, app_id)
    out = [b for b in builds if b.get("_app_version") == version_string]
    if processing_state:
        out = [
            b for b in out
            if b.get("attributes", {}).get("processingState") == processing_state
        ]
    return out


def find_latest_build(
    client: ASCClient,
    app_id: str,
    processing_state: Optional[str] = "VALID",
    include_expired: bool = False,
) -> Optional[dict[str, Any]]:
    """The most recently uploaded build, or ``None`` if there isn't one.

    Defaults to the newest build Apple has finished processing — that's the one
    a tester can actually install. Pass ``processing_state=None`` to include
    builds still in PROCESSING.
    """
    builds = list_builds_with_versions(client, app_id)
    if processing_state:
        builds = [
            b for b in builds
            if b.get("attributes", {}).get("processingState") == processing_state
        ]
    if not include_expired:
        builds = [b for b in builds if not b.get("attributes", {}).get("expired")]
    if not builds:
        return None
    # list_builds_with_versions already sorts by -uploadedDate
    return builds[0]


def get_build(client: ASCClient, build_id: str) -> dict[str, Any]:
    """Read a single build resource."""
    return client.get(f"/v1/builds/{build_id}")["data"]


def expire_build(client: ASCClient, build_id: str) -> dict[str, Any]:
    """Mark a build as expired (sets ``expired = true``)."""
    return client.patch(
        f"/v1/builds/{build_id}",
        {
            "data": {
                "type": "builds",
                "id": build_id,
                "attributes": {"expired": True},
            }
        },
    )


def get_build_beta_detail(client: ASCClient, build_id: str) -> BuildBetaDetail:
    """TestFlight distribution state for a build — internal/external build state
    and whether testers are auto-notified when it becomes available.

    Check ``external_build_state`` before expecting external testers to see a
    build: anything other than IN_BETA_TESTING means it isn't distributable yet.
    """
    result = client.get(f"/v1/builds/{build_id}/buildBetaDetail")
    return BuildBetaDetail.from_api(result["data"])


def set_build_auto_notify(
    client: ASCClient, build_beta_detail_id: str, enabled: bool
) -> dict[str, Any]:
    """Toggle automatic tester notification for a build.

    ``build_beta_detail_id`` comes from :func:`get_build_beta_detail`.
    """
    return client.patch(
        f"/v1/buildBetaDetails/{build_beta_detail_id}",
        {
            "data": {
                "type": "buildBetaDetails",
                "id": build_beta_detail_id,
                "attributes": {"autoNotifyEnabled": enabled},
            }
        },
    )


def get_build_localizations(
    client: ASCClient, build_id: str
) -> list[BetaBuildLocalization]:
    """Per-locale "What to Test" text for a build."""
    items = client.get_all(f"/v1/builds/{build_id}/betaBuildLocalizations")
    return [BetaBuildLocalization.from_api(item) for item in items]


def set_build_whats_new(
    client: ASCClient,
    build_id: str,
    whats_new: str,
    locale: str = "en-US",
) -> dict[str, Any]:
    """Set the "What to Test" notes for a build in one locale.

    Patches the existing localization for ``locale`` if there is one, otherwise
    creates it. Apple pre-creates an en-US localization for most builds.
    """
    for loc in get_build_localizations(client, build_id):
        if loc.locale == locale:
            return client.patch(
                f"/v1/betaBuildLocalizations/{loc.id}",
                {
                    "data": {
                        "type": "betaBuildLocalizations",
                        "id": loc.id,
                        "attributes": {"whatsNew": whats_new},
                    }
                },
            )
    return client.post(
        "/v1/betaBuildLocalizations",
        {
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": locale, "whatsNew": whats_new},
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}}
                },
            }
        },
    )


def notify_testers_of_build(client: ASCClient, build_id: str) -> dict[str, Any]:
    """Send the "new build available" TestFlight notification for a build.

    Only useful for builds whose auto-notify is off, or to re-ping testers.
    Fails if the build isn't in a distributable state.
    """
    return client.post(
        "/v1/buildBetaNotifications",
        {
            "data": {
                "type": "buildBetaNotifications",
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}}
                },
            }
        },
    )
