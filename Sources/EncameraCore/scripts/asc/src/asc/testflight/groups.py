"""TestFlight beta groups and the build↔group relationship.

Note on direction: Apple allows only CREATE and DELETE on
``/v1/builds/{id}/relationships/betaGroups`` — reading it back returns 403
``The relationship 'betaGroups' does not allow 'GET_RELATED'``. To find out
which groups a build is in you have to query from the group side, which is what
:func:`get_build_beta_groups` does.
"""

from typing import Any, Optional

from asc.client import ASCClient
from asc.models import BetaGroup

_GROUP_FIELDS = "name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled,publicLink,feedbackEnabled,createdDate"


def list_beta_groups(client: ASCClient, app_id: str) -> list[dict[str, Any]]:
    """List all beta (TestFlight build) groups for an app, as raw API dicts."""
    return client.get_all(f"/v1/apps/{app_id}/betaGroups", params={"limit": 200})


def list_beta_groups_typed(client: ASCClient, app_id: str) -> list[BetaGroup]:
    """Same as :func:`list_beta_groups` but returns :class:`BetaGroup` records."""
    items = client.get_all(
        f"/v1/apps/{app_id}/betaGroups",
        params={"limit": 200, "fields[betaGroups]": _GROUP_FIELDS},
    )
    return [BetaGroup.from_api(item) for item in items]


def get_beta_group(client: ASCClient, group_id: str) -> BetaGroup:
    """Read one beta group by id."""
    result = client.get(
        f"/v1/betaGroups/{group_id}", params={"fields[betaGroups]": _GROUP_FIELDS}
    )
    return BetaGroup.from_api(result["data"])


def find_beta_group_by_name(
    client: ASCClient, app_id: str, name: str
) -> Optional[BetaGroup]:
    """Find a group by its exact display name (case-insensitive), or ``None``."""
    target = name.strip().lower()
    for group in list_beta_groups_typed(client, app_id):
        if group.name.strip().lower() == target:
            return group
    return None


def create_beta_group(
    client: ASCClient,
    app_id: str,
    name: str,
    *,
    is_internal: bool = False,
    has_access_to_all_builds: Optional[bool] = None,
    public_link_enabled: Optional[bool] = None,
    feedback_enabled: Optional[bool] = None,
) -> BetaGroup:
    """Create a beta group.

    ``has_access_to_all_builds`` is only meaningful for internal groups — it is
    what makes new builds reach those testers without being attached one by one.
    """
    attrs: dict[str, Any] = {"name": name, "isInternalGroup": is_internal}
    if has_access_to_all_builds is not None:
        attrs["hasAccessToAllBuilds"] = has_access_to_all_builds
    if public_link_enabled is not None:
        attrs["publicLinkEnabled"] = public_link_enabled
    if feedback_enabled is not None:
        attrs["feedbackEnabled"] = feedback_enabled
    result = client.post(
        "/v1/betaGroups",
        {
            "data": {
                "type": "betaGroups",
                "attributes": attrs,
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
    )
    return BetaGroup.from_api(result["data"])


def delete_beta_group(client: ASCClient, group_id: str) -> None:
    """Delete a beta group."""
    client.delete(f"/v1/betaGroups/{group_id}")


def list_builds_in_group(
    client: ASCClient, group_id: str, limit: int = 200
) -> list[dict[str, Any]]:
    """Builds attached to a beta group. Note ASC rejects ``sort`` on this path."""
    return client.get_all(
        f"/v1/betaGroups/{group_id}/builds",
        params={"limit": limit, "fields[builds]": "version,uploadedDate,expired"},
    )


def get_build_beta_groups(
    client: ASCClient, build_id: str, app_id: str
) -> list[dict[str, Any]]:
    """The beta groups a build is attached to.

    Queried group-by-group because the build→betaGroups relationship is
    write-only (see the module docstring). ``app_id`` scopes which groups get
    checked.
    """
    matches = []
    for group in list_beta_groups(client, app_id):
        builds = client.get_all(
            "/v1/builds",
            params={
                "filter[betaGroups]": group["id"],
                "filter[app]": app_id,
                "limit": 200,
                "fields[builds]": "version",
            },
        )
        if any(b["id"] == build_id for b in builds):
            matches.append(group)
    return matches


def add_build_to_beta_groups(
    client: ASCClient, build_id: str, group_ids: list[str]
) -> None:
    """Attach a build to the given beta groups, making it available to their testers.

    For external groups the build must have passed beta app review first —
    otherwise testers see nothing even though the attachment succeeds.
    """
    if not group_ids:
        return
    client.post(
        f"/v1/builds/{build_id}/relationships/betaGroups",
        {"data": [{"type": "betaGroups", "id": gid} for gid in group_ids]},
    )


def remove_build_from_beta_groups(
    client: ASCClient, build_id: str, group_ids: list[str]
) -> None:
    """Detach a build from the given beta groups."""
    if not group_ids:
        return
    body = {"data": [{"type": "betaGroups", "id": gid} for gid in group_ids]}
    client.delete(f"/v1/builds/{build_id}/relationships/betaGroups", data=body)
