"""Catalogs of Xcode Cloud build environments (macOS + Xcode versions).

Needed when creating or patching a workflow — workflows reference specific
macOS/Xcode versions by id.
"""

from asc.client import ASCClient
from asc.xcode_cloud.models import CiMacOsVersion, CiXcodeVersion


def list_macos_versions(client: ASCClient) -> list[CiMacOsVersion]:
    items = client.get_all("/v1/ciMacOsVersions")
    return [CiMacOsVersion.from_api(item) for item in items]


def list_xcode_versions(client: ASCClient) -> list[CiXcodeVersion]:
    items = client.get_all("/v1/ciXcodeVersions")
    return [CiXcodeVersion.from_api(item) for item in items]
