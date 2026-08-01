"""TestFlight beta testers: lookup, creation, group membership, per-build
assignment, and invitations.

Two things bite here and both are handled below:

1. ``/v1/betaTesters`` is team-wide, not app-scoped. Filtering by email alone
   can return stale records left over from other apps — records with no apps and
   no groups that look identical. Always pass ``filter[apps]``.
2. A tester sitting at ``state = INVITED`` has been created and attached to
   groups but has never accepted the emailed invitation, so they see nothing in
   TestFlight. Adding them to more groups won't help; they need
   :func:`resend_invitation`.
"""

from typing import Any, Optional

from asc.client import ASCClient
from asc.models import BetaTester

_TESTER_FIELDS = "email,firstName,lastName,state,inviteType,betaGroups"

def _tester_params(include_groups: bool) -> dict[str, Any]:
    """Query params for tester reads.

    The betaTesters collection returns relationship *links* but no relationship
    *data* unless you explicitly include the related resource — without the
    include, group membership on every returned tester silently reads as empty.
    The sub-resource paths (``/betaGroups/{id}/betaTesters``,
    ``/builds/{id}/individualTesters``) reject ``include`` outright with a 400,
    so they opt out and come back with empty group lists.
    """
    params: dict[str, Any] = {"fields[betaTesters]": _TESTER_FIELDS, "limit": 200}
    if include_groups:
        params["include"] = "betaGroups"
        params["fields[betaGroups]"] = "name"
    return params


def _list_testers(
    client: ASCClient,
    path: str,
    extra: Optional[dict] = None,
    include_groups: bool = True,
) -> list[BetaTester]:
    params = _tester_params(include_groups)
    params.update(extra or {})
    result = client.get_all_paginated_with_includes(path, params=params)
    return [BetaTester.from_api(item, result["included"]) for item in result["data"]]


def find_testers_by_email(
    client: ASCClient,
    email: str,
    app_id: Optional[str] = None,
) -> list[BetaTester]:
    """Find beta testers by email address.

    Pass ``app_id`` to scope the search to one app — without it the ASC API
    searches the whole team and can return duplicate-looking records that belong
    to other apps or to nothing at all.
    """
    extra: dict[str, Any] = {"filter[email]": email}
    if app_id:
        extra["filter[apps]"] = app_id
    return _list_testers(client, "/v1/betaTesters", extra)


def get_beta_tester(client: ASCClient, tester_id: str) -> BetaTester:
    """Read one beta tester by id.

    ``state`` comes back ``None`` here — it is per-app, so it is only populated
    on an app-scoped query. Use :func:`find_testers_by_email` with ``app_id``
    when you need to know whether someone is INVITED or ACCEPTED.
    """
    params = _tester_params(include_groups=True)
    params.pop("limit")
    result = client.get(f"/v1/betaTesters/{tester_id}", params=params)
    return BetaTester.from_api(result["data"], result.get("included", []))


def list_testers_in_group(
    client: ASCClient, group_id: str, limit: int = 200
) -> list[BetaTester]:
    """Testers who are members of a beta group.

    ``beta_group_ids`` is empty on the results — this path rejects ``include``.
    """
    return _list_testers(
        client,
        f"/v1/betaGroups/{group_id}/betaTesters",
        {"limit": limit},
        include_groups=False,
    )


def create_beta_tester(
    client: ASCClient,
    email: str,
    first_name: Optional[str] = None,
    last_name: Optional[str] = None,
    group_ids: Optional[list[str]] = None,
    build_ids: Optional[list[str]] = None,
) -> BetaTester:
    """Create a beta tester and optionally attach them to groups and/or builds.

    ``email`` is the only required attribute; the name fields just make the
    TestFlight invite and the ASC UI friendlier. Attaching ``build_ids`` here is
    equivalent to calling :func:`add_individual_testers_to_build` afterwards.
    """
    attrs: dict[str, Any] = {"email": email}
    if first_name:
        attrs["firstName"] = first_name
    if last_name:
        attrs["lastName"] = last_name

    relationships: dict[str, Any] = {}
    if group_ids:
        relationships["betaGroups"] = {
            "data": [{"type": "betaGroups", "id": gid} for gid in group_ids]
        }
    if build_ids:
        relationships["builds"] = {
            "data": [{"type": "builds", "id": bid} for bid in build_ids]
        }

    body: dict[str, Any] = {"data": {"type": "betaTesters", "attributes": attrs}}
    if relationships:
        body["data"]["relationships"] = relationships
    result = client.post("/v1/betaTesters", body)
    return BetaTester.from_api(result["data"])


def ensure_tester(
    client: ASCClient,
    email: str,
    app_id: str,
    first_name: Optional[str] = None,
    last_name: Optional[str] = None,
    group_ids: Optional[list[str]] = None,
    build_ids: Optional[list[str]] = None,
) -> tuple[BetaTester, bool]:
    """Find the tester for ``email`` on ``app_id``, creating them if absent.

    Returns ``(tester, created)``. Idempotent — safe to call repeatedly, which is
    what makes it usable as the entry point for both the CLI and the MCP tools.
    Raises if the app-scoped lookup somehow matches more than one record, since
    silently picking one would attach builds to the wrong tester.
    """
    existing = find_testers_by_email(client, email, app_id=app_id)
    if len(existing) > 1:
        ids = ", ".join(t.id for t in existing)
        raise ValueError(
            f"Multiple beta testers match {email} on app {app_id}: {ids}. "
            "Resolve the duplicate in App Store Connect before continuing."
        )
    if existing:
        return existing[0], False
    tester = create_beta_tester(
        client, email, first_name, last_name, group_ids=group_ids, build_ids=build_ids
    )
    return tester, True


def add_testers_to_groups(
    client: ASCClient, tester_id: str, group_ids: list[str]
) -> None:
    """Add one tester to one or more beta groups."""
    if not group_ids:
        return
    client.post(
        f"/v1/betaTesters/{tester_id}/relationships/betaGroups",
        {"data": [{"type": "betaGroups", "id": gid} for gid in group_ids]},
    )


def remove_testers_from_groups(
    client: ASCClient, tester_id: str, group_ids: list[str]
) -> None:
    """Remove one tester from one or more beta groups."""
    if not group_ids:
        return
    client.delete(
        f"/v1/betaTesters/{tester_id}/relationships/betaGroups",
        data={"data": [{"type": "betaGroups", "id": gid} for gid in group_ids]},
    )


def add_testers_to_group(
    client: ASCClient, group_id: str, tester_ids: list[str]
) -> None:
    """Add several testers to one beta group (the inverse of
    :func:`add_testers_to_groups`)."""
    if not tester_ids:
        return
    client.post(
        f"/v1/betaGroups/{group_id}/relationships/betaTesters",
        {"data": [{"type": "betaTesters", "id": tid} for tid in tester_ids]},
    )


def list_individual_testers(
    client: ASCClient, build_id: str, limit: int = 200
) -> list[BetaTester]:
    """Testers assigned directly to a build rather than through a group."""
    return _list_testers(
        client,
        f"/v1/builds/{build_id}/individualTesters",
        {"limit": limit},
        include_groups=False,
    )


def add_individual_testers_to_build(
    client: ASCClient, build_id: str, tester_ids: list[str]
) -> None:
    """Give specific testers access to one build without adding them to a group.

    This is the ASC "individual testers" mechanism. It grants access to that
    build only; external testers still can't install until the build clears beta
    app review.
    """
    if not tester_ids:
        return
    client.post(
        f"/v1/builds/{build_id}/relationships/individualTesters",
        {"data": [{"type": "betaTesters", "id": tid} for tid in tester_ids]},
    )


def remove_individual_testers_from_build(
    client: ASCClient, build_id: str, tester_ids: list[str]
) -> None:
    """Revoke individual-tester access to a build."""
    if not tester_ids:
        return
    client.delete(
        f"/v1/builds/{build_id}/relationships/individualTesters",
        data={"data": [{"type": "betaTesters", "id": tid} for tid in tester_ids]},
    )


def resend_invitation(client: ASCClient, app_id: str, tester_id: str) -> dict[str, Any]:
    """(Re)send the TestFlight invitation email for a tester on an app.

    This is the fix for a tester stuck at ``state = INVITED``: they already have
    whatever group and build access you granted, they just never accepted.
    """
    return client.post(
        "/v1/betaTesterInvitations",
        {
            "data": {
                "type": "betaTesterInvitations",
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}},
                    "betaTester": {"data": {"type": "betaTesters", "id": tester_id}},
                },
            }
        },
    )


def delete_beta_tester(client: ASCClient, tester_id: str) -> None:
    """Delete a beta tester entirely, removing them from every group and build."""
    client.delete(f"/v1/betaTesters/{tester_id}")
