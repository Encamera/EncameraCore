"""ciBuildAction operations.

A build run contains multiple actions (BUILD, TEST, ANALYZE, ARCHIVE).
When a run fails, the action list tells you WHICH phase failed; then
drill into that action's issues/artifacts/test_results.
"""

from asc.client import ASCClient
from asc.xcode_cloud.models import CiBuildAction


def list_build_actions_for_run(
    client: ASCClient, build_run_id: str
) -> list[CiBuildAction]:
    items = client.get_all(f"/v1/ciBuildRuns/{build_run_id}/actions")
    return [CiBuildAction.from_api(item) for item in items]


def get_build_action(client: ASCClient, build_action_id: str) -> CiBuildAction:
    result = client.get(f"/v1/ciBuildActions/{build_action_id}")
    return CiBuildAction.from_api(result["data"])
