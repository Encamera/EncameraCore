"""TestFlight build and beta group operations."""

from typing import Any, Optional

from asc.client import ASCClient


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


def list_beta_groups(client: ASCClient, app_id: str) -> list[dict[str, Any]]:
    """List all beta (TestFlight build) groups for an app."""
    return client.get_all(f"/v1/apps/{app_id}/betaGroups", params={"limit": 200})


def get_build_beta_groups(client: ASCClient, build_id: str) -> list[dict[str, Any]]:
    """Get the beta groups a build is attached to."""
    result = client.get(f"/v1/builds/{build_id}/betaGroups")
    return result.get("data", [])


def remove_build_from_beta_groups(
    client: ASCClient, build_id: str, group_ids: list[str]
) -> None:
    """Detach a build from the given beta groups."""
    if not group_ids:
        return
    body = {"data": [{"type": "betaGroups", "id": gid} for gid in group_ids]}
    client.delete(f"/v1/builds/{build_id}/relationships/betaGroups", data=body)


def delete_beta_group(client: ASCClient, group_id: str) -> None:
    """Delete a beta group."""
    client.delete(f"/v1/betaGroups/{group_id}")
