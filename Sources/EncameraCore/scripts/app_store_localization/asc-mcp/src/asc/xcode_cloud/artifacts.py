"""ciArtifact operations.

Artifacts are the files a build action produced — archives, logs, result
bundles. Use the download URL (short-lived) to pull them.
"""

from asc.client import ASCClient
from asc.xcode_cloud.models import CiArtifact


def list_artifacts_for_action(
    client: ASCClient, build_action_id: str
) -> list[CiArtifact]:
    items = client.get_all(f"/v1/ciBuildActions/{build_action_id}/artifacts")
    return [CiArtifact.from_api(item) for item in items]


def get_artifact(client: ASCClient, artifact_id: str) -> CiArtifact:
    result = client.get(f"/v1/ciArtifacts/{artifact_id}")
    return CiArtifact.from_api(result["data"])
