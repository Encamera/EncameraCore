"""ciWorkflow operations.

A workflow defines start conditions, environment, and actions for a ciProduct.
Create/update payloads are passed through as raw attribute dicts because
the full shape (branchStartCondition, actions, environment, etc.) is large
and best authored by the caller who is reading Apple's docs.
"""

from typing import Any, Optional

from asc.client import ASCClient
from asc.xcode_cloud.models import CiWorkflow


def list_workflows_for_product(client: ASCClient, product_id: str) -> list[CiWorkflow]:
    items = client.get_all(f"/v1/ciProducts/{product_id}/workflows")
    return [CiWorkflow.from_api(item) for item in items]


def get_workflow(client: ASCClient, workflow_id: str) -> CiWorkflow:
    result = client.get(f"/v1/ciWorkflows/{workflow_id}")
    return CiWorkflow.from_api(result["data"])


def create_workflow(
    client: ASCClient,
    product_id: str,
    repository_id: str,
    attributes: dict[str, Any],
    xcode_version_id: Optional[str] = None,
    macos_version_id: Optional[str] = None,
) -> CiWorkflow:
    relationships: dict[str, Any] = {
        "product": {"data": {"type": "ciProducts", "id": product_id}},
        "repository": {"data": {"type": "scmRepositories", "id": repository_id}},
    }
    if xcode_version_id:
        relationships["xcodeVersion"] = {
            "data": {"type": "ciXcodeVersions", "id": xcode_version_id}
        }
    if macos_version_id:
        relationships["macOsVersion"] = {
            "data": {"type": "ciMacOsVersions", "id": macos_version_id}
        }
    body = {
        "data": {
            "type": "ciWorkflows",
            "attributes": attributes,
            "relationships": relationships,
        }
    }
    result = client.post("/v1/ciWorkflows", body)
    return CiWorkflow.from_api(result["data"])


def update_workflow(
    client: ASCClient, workflow_id: str, attributes: dict[str, Any]
) -> CiWorkflow:
    body = {
        "data": {
            "type": "ciWorkflows",
            "id": workflow_id,
            "attributes": attributes,
        }
    }
    result = client.patch(f"/v1/ciWorkflows/{workflow_id}", body)
    return CiWorkflow.from_api(result["data"])


def delete_workflow(client: ASCClient, workflow_id: str) -> None:
    client.delete(f"/v1/ciWorkflows/{workflow_id}")
