"""ciBuildRun operations.

A build run is one end-to-end execution of a workflow. It's the top-level
unit for "why did this fail" investigations — drill from here into build
actions and then issues.
"""

from typing import Any, Optional

from asc.client import ASCClient
from asc.models import Build
from asc.xcode_cloud.models import CiBuildRun


def list_build_runs_for_workflow(
    client: ASCClient,
    workflow_id: str,
    limit: Optional[int] = None,
) -> list[CiBuildRun]:
    params: dict[str, Any] = {"sort": "-number"}
    if limit:
        params["limit"] = limit
    items = client.get_all(f"/v1/ciWorkflows/{workflow_id}/buildRuns", params=params)
    return [CiBuildRun.from_api(item) for item in items]


def list_build_runs_for_product(
    client: ASCClient,
    product_id: str,
    limit: Optional[int] = None,
) -> list[CiBuildRun]:
    """Build runs across every workflow under a product.

    /ciProducts/{id}/buildRuns does not accept a sort param (unlike the
    per-workflow endpoint), so results come in the API's default order.
    """
    params: dict[str, Any] = {}
    if limit:
        params["limit"] = limit
    items = client.get_all(
        f"/v1/ciProducts/{product_id}/buildRuns", params=params or None
    )
    return [CiBuildRun.from_api(item) for item in items]


def get_build_run(client: ASCClient, build_run_id: str) -> CiBuildRun:
    result = client.get(f"/v1/ciBuildRuns/{build_run_id}")
    return CiBuildRun.from_api(result["data"])


def start_build_run(
    client: ASCClient,
    workflow_id: str,
    source_branch_or_tag_id: Optional[str] = None,
    pull_request_id: Optional[str] = None,
) -> CiBuildRun:
    """Start a new build run for a workflow.

    Exactly one of source_branch_or_tag_id or pull_request_id should be set,
    unless the workflow is fully manual.
    """
    relationships: dict[str, Any] = {
        "workflow": {"data": {"type": "ciWorkflows", "id": workflow_id}}
    }
    if source_branch_or_tag_id:
        relationships["sourceBranchOrTag"] = {
            "data": {"type": "scmGitReferences", "id": source_branch_or_tag_id}
        }
    if pull_request_id:
        relationships["pullRequest"] = {
            "data": {"type": "scmPullRequests", "id": pull_request_id}
        }
    body = {"data": {"type": "ciBuildRuns", "relationships": relationships}}
    result = client.post("/v1/ciBuildRuns", body)
    return CiBuildRun.from_api(result["data"])


def list_builds_for_build_run(
    client: ASCClient, build_run_id: str
) -> list[Build]:
    """Resulting App Store Connect builds (TestFlight/archive uploads) for a run.

    Empty for runs that didn't archive (PR validation runs, test-only runs,
    failed runs that never reached the upload step).
    """
    items = client.get_all(f"/v1/ciBuildRuns/{build_run_id}/builds")
    return [Build.from_api(item) for item in items]


def find_build_runs_by_commit(
    client: ASCClient,
    commit_sha: str,
    product_id: Optional[str] = None,
    workflow_id: Optional[str] = None,
    limit: int = 200,
) -> list[CiBuildRun]:
    """Find ciBuildRuns whose source commit matches commit_sha.

    Apple's ciBuildRuns endpoint exposes sourceCommit as a nested attribute
    (not a filter), so this walks recent runs and matches client-side.
    Pass workflow_id to scope to one workflow (faster, sortable by -number);
    otherwise pass product_id to scan every workflow under the product.
    Matches on full SHA or any unambiguous prefix (>=7 chars).
    """
    if not commit_sha or len(commit_sha) < 7:
        raise ValueError("commit_sha must be at least 7 characters")
    if workflow_id:
        runs = list_build_runs_for_workflow(client, workflow_id, limit=limit)
    elif product_id:
        runs = list_build_runs_for_product(client, product_id, limit=limit)
    else:
        raise ValueError("Must provide either workflow_id or product_id")
    needle = commit_sha.lower()
    return [r for r in runs if r.source_commit_sha and r.source_commit_sha.lower().startswith(needle)]


def cancel_build_run(client: ASCClient, build_run_id: str) -> CiBuildRun:
    """Cancel a running build by patching executionProgress to CANCELED."""
    body = {
        "data": {
            "type": "ciBuildRuns",
            "id": build_run_id,
            "attributes": {"executionProgress": "CANCELED"},
        }
    }
    result = client.patch(f"/v1/ciBuildRuns/{build_run_id}", body)
    return CiBuildRun.from_api(result["data"])
