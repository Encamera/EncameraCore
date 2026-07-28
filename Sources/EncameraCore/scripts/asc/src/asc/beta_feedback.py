"""TestFlight beta feedback operations (crash submissions and crash logs).

Backed by the betaFeedbackCrashSubmissions endpoints Apple added to the
App Store Connect API at WWDC25. The crash log itself is a separate
sub-resource — list/read submissions first, then fetch the log text.
"""

from typing import Any, Optional

from asc.client import ASCClient
from asc.models import CrashSubmission

_LIST_PATH = "/v1/apps/{app_id}/betaFeedbackCrashSubmissions"


def list_crash_submissions(
    client: ASCClient,
    app_id: str,
    build_ids: Optional[list[str]] = None,
    device_model: Optional[str] = None,
    os_version: Optional[str] = None,
    limit: Optional[int] = None,
) -> list[CrashSubmission]:
    """List TestFlight crash feedback submissions for an app, newest first.

    ``build_ids`` filters to specific builds (ASC build IDs, not build numbers —
    resolve numbers via ``find_builds_by_build_number``). With ``limit`` set,
    fetches a single page of at most ``limit`` items; otherwise paginates
    through everything.
    """
    params: dict[str, Any] = {
        "sort": "-createdDate",
        "include": "build",
        "fields[builds]": "version",
        "limit": min(limit, 200) if limit else 200,
    }
    if build_ids:
        params["filter[build]"] = ",".join(build_ids)
    if device_model:
        params["filter[deviceModel]"] = device_model
    if os_version:
        params["filter[osVersion]"] = os_version

    path = _LIST_PATH.format(app_id=app_id)
    if limit is not None:
        body = client.get(path, params=params)
        data = body.get("data", [])
        included = body.get("included", [])
    else:
        result = client.get_all_paginated_with_includes(path, params=params)
        data = result["data"]
        included = result["included"]
    return [CrashSubmission.from_api(item, included) for item in data]


def get_crash_submission(client: ASCClient, submission_id: str) -> CrashSubmission:
    """Read one crash feedback submission (metadata only, no log text)."""
    result = client.get(
        f"/v1/betaFeedbackCrashSubmissions/{submission_id}",
        params={"include": "build", "fields[builds]": "version"},
    )
    return CrashSubmission.from_api(result["data"], result.get("included", []))


def get_crash_log_text(client: ASCClient, submission_id: str) -> str:
    """Fetch the full crash log text for a crash feedback submission."""
    result = client.get(f"/v1/betaFeedbackCrashSubmissions/{submission_id}/crashLog")
    return result.get("data", {}).get("attributes", {}).get("logText", "")


def find_builds_by_build_number(
    client: ASCClient, app_id: str, build_number: str
) -> list[dict[str, Any]]:
    """Builds whose build number (CFBundleVersion) equals ``build_number``.

    Can return more than one build when the same build number was reused
    across marketing versions.
    """
    return client.get_all(
        "/v1/builds",
        params={
            "filter[app]": app_id,
            "filter[version]": build_number,
            "fields[builds]": "version,uploadedDate,processingState",
        },
    )
