"""Beta app review — the gate a build must clear before external TestFlight
groups can install it.

Internal testers never need this. External distribution does: submit the build,
wait for ``betaReviewState`` to reach APPROVED, then attach the build to an
external group.
"""

from typing import Any, Optional

from asc.client import ASCClient
from asc.models import BetaAppReviewSubmission


def submit_build_for_beta_review(
    client: ASCClient, build_id: str
) -> BetaAppReviewSubmission:
    """Submit a build for Apple's beta app review.

    Requires the app's beta app review detail (contact info, demo account if the
    app needs one) to already be filled in — see
    :func:`get_beta_app_review_detail`. Submitting a build that's already been
    submitted is an error, so check :func:`get_beta_review_submission` first.
    """
    result = client.post(
        "/v1/betaAppReviewSubmissions",
        {
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}}
                },
            }
        },
    )
    return BetaAppReviewSubmission.from_api(result["data"])


def get_beta_review_submission(
    client: ASCClient, build_id: str
) -> Optional[BetaAppReviewSubmission]:
    """The beta review submission for a build, or ``None`` if never submitted.

    ``beta_review_state`` walks WAITING_FOR_REVIEW → IN_REVIEW → APPROVED
    (or REJECTED).
    """
    result = client.get(f"/v1/builds/{build_id}/betaAppReviewSubmission")
    data = result.get("data")
    return BetaAppReviewSubmission.from_api(data) if data else None


def list_beta_review_submissions(
    client: ASCClient, app_id: str, limit: int = 200
) -> list[BetaAppReviewSubmission]:
    """All beta review submissions for an app, newest first."""
    items = client.get_all(
        "/v1/betaAppReviewSubmissions",
        params={"filter[builds.app]": app_id, "limit": limit},
    )
    return [BetaAppReviewSubmission.from_api(item) for item in items]


def get_beta_app_review_detail(client: ASCClient, app_id: str) -> dict[str, Any]:
    """The app-level review contact and demo-account info used for beta review."""
    return client.get(f"/v1/apps/{app_id}/betaAppReviewDetail")["data"]


def update_beta_app_review_detail(
    client: ASCClient,
    detail_id: str,
    *,
    contact_first_name: Optional[str] = None,
    contact_last_name: Optional[str] = None,
    contact_phone: Optional[str] = None,
    contact_email: Optional[str] = None,
    demo_account_name: Optional[str] = None,
    demo_account_password: Optional[str] = None,
    demo_account_required: Optional[bool] = None,
    notes: Optional[str] = None,
) -> dict[str, Any]:
    """Update the app's beta review contact / demo account details.

    ``detail_id`` is the id from :func:`get_beta_app_review_detail` (it equals
    the app id). Only the fields you pass are sent.
    """
    api_keys = {
        "contactFirstName": contact_first_name,
        "contactLastName": contact_last_name,
        "contactPhone": contact_phone,
        "contactEmail": contact_email,
        "demoAccountName": demo_account_name,
        "demoAccountPassword": demo_account_password,
        "demoAccountRequired": demo_account_required,
        "notes": notes,
    }
    attrs = {k: v for k, v in api_keys.items() if v is not None}
    return client.patch(
        f"/v1/betaAppReviewDetails/{detail_id}",
        {
            "data": {
                "type": "betaAppReviewDetails",
                "id": detail_id,
                "attributes": attrs,
            }
        },
    )
