"""ciTestResult operations.

Individual test case results for a ciBuildAction of type TEST. Per-device
outcomes are in destination_test_results.
"""

from asc.client import ASCClient
from asc.xcode_cloud.models import CiTestResult


def list_test_results_for_action(
    client: ASCClient, build_action_id: str
) -> list[CiTestResult]:
    items = client.get_all(f"/v1/ciBuildActions/{build_action_id}/testResults")
    return [CiTestResult.from_api(item) for item in items]


def get_test_result(client: ASCClient, test_result_id: str) -> CiTestResult:
    result = client.get(f"/v1/ciTestResults/{test_result_id}")
    return CiTestResult.from_api(result["data"])
