"""App Store version and release operations."""

from typing import Optional

from asc.client import ASCClient
from asc.models import AppStoreVersion, AppStoreVersionLocalization, Build


def list_app_store_versions(
    client: ASCClient, app_id: str, platform: Optional[str] = None
) -> list[AppStoreVersion]:
    params = {"include": "build"}
    if platform:
        params["filter[platform]"] = platform
    result = client.get_all_paginated_with_includes(
        f"/v1/apps/{app_id}/appStoreVersions", params=params
    )
    return [AppStoreVersion.from_api(item, result["included"]) for item in result["data"]]


def get_app_store_version(client: ASCClient, version_id: str) -> AppStoreVersion:
    result = client.get(
        f"/v1/appStoreVersions/{version_id}", params={"include": "build"}
    )
    included = result.get("included", [])
    return AppStoreVersion.from_api(result["data"], included)


def create_app_store_version(
    client: ASCClient,
    app_id: str,
    version_string: str,
    platform: str = "IOS",
    release_type: Optional[str] = None,
) -> AppStoreVersion:
    body: dict = {
        "data": {
            "type": "appStoreVersions",
            "attributes": {
                "versionString": version_string,
                "platform": platform,
            },
            "relationships": {
                "app": {
                    "data": {"type": "apps", "id": app_id}
                }
            },
        }
    }
    if release_type:
        body["data"]["attributes"]["releaseType"] = release_type
    result = client.post("/v1/appStoreVersions", body)
    return AppStoreVersion.from_api(result["data"])


def set_build_for_version(
    client: ASCClient, version_id: str, build_id: str
) -> AppStoreVersion:
    body = {
        "data": {
            "type": "appStoreVersions",
            "id": version_id,
            "relationships": {
                "build": {
                    "data": {"type": "builds", "id": build_id}
                }
            },
        }
    }
    result = client.patch(f"/v1/appStoreVersions/{version_id}", body)
    return AppStoreVersion.from_api(result["data"])


def list_builds(
    client: ASCClient,
    app_id: str,
    processing_state: Optional[str] = None,
) -> list[Build]:
    params: dict = {}
    if processing_state:
        params["filter[processingState]"] = processing_state
    items = client.get_all(f"/v1/apps/{app_id}/builds", params=params or None)
    return [Build.from_api(item) for item in items]


def get_version_localizations(
    client: ASCClient, version_id: str
) -> list[AppStoreVersionLocalization]:
    items = client.get_all(
        f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
    )
    return [AppStoreVersionLocalization.from_api(item) for item in items]


def submit_for_review(client: ASCClient, app_id: str, version_id: str) -> dict:
    # Step 1: Create a review submission for the app
    submission = client.post("/v1/reviewSubmissions", {
        "data": {
            "type": "reviewSubmissions",
            "relationships": {
                "app": {
                    "data": {"type": "apps", "id": app_id}
                }
            },
        }
    })
    submission_id = submission["data"]["id"]

    # Step 2: Add the app store version as a submission item
    client.post("/v1/reviewSubmissionItems", {
        "data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {
                    "data": {"type": "reviewSubmissions", "id": submission_id}
                },
                "appStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": version_id}
                },
            },
        }
    })

    # Step 3: Confirm the submission
    result = client.patch(f"/v1/reviewSubmissions/{submission_id}", {
        "data": {
            "type": "reviewSubmissions",
            "id": submission_id,
            "attributes": {"submitted": True},
        }
    })
    return result
