"""ciIssue operations.

Issues are compile errors, warnings, analyzer findings, and test failures
attached to a ciBuildAction. This is the "what actually broke" surface.
"""

from asc.client import ASCClient
from asc.xcode_cloud.models import CiIssue


def list_issues_for_action(
    client: ASCClient, build_action_id: str
) -> list[CiIssue]:
    items = client.get_all(f"/v1/ciBuildActions/{build_action_id}/issues")
    return [CiIssue.from_api(item) for item in items]


def get_issue(client: ASCClient, issue_id: str) -> CiIssue:
    result = client.get(f"/v1/ciIssues/{issue_id}")
    return CiIssue.from_api(result["data"])
