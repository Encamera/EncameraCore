#!/usr/bin/env python3
"""
Expire Old TestFlight Builds Script
Expires all TestFlight builds older than a specified number of days and
removes builds from their build groups. Uses the same credential setup as localize.py.

Build groups in TestFlight are represented as betaGroups in the ASC API.
"""

import argparse
import inspect
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import jwt
import requests
import yaml

try:
    from tabulate import tabulate
except ImportError:
    print("Missing required package 'tabulate'. Install with: pip install tabulate")
    sys.exit(1)


class AppStoreConnectAPI:
    """Handles App Store Connect API interactions with JWT authentication."""

    BASE_URL = "https://api.appstoreconnect.apple.com/v1"

    def __init__(self, key_id, issuer_id, private_key):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.private_key = private_key
        self.token = None
        self.token_expires_at = 0

    def _get_token(self):
        now = int(time.time())
        if self.token and now < self.token_expires_at:
            return self.token

        payload = {
            "iss": self.issuer_id,
            "iat": now,
            "exp": now + 20 * 60,
            "aud": "appstoreconnect-v1",
        }

        encode_params = inspect.signature(jwt.encode).parameters
        if "additional_headers" in encode_params:
            self.token = jwt.encode(
                payload,
                self.private_key,
                algorithm="ES256",
                additional_headers={"kid": self.key_id},
            )
        else:
            self.token = jwt.encode(
                payload,
                self.private_key,
                algorithm="ES256",
                headers={"kid": self.key_id},
            )

        self.token_expires_at = now + 19 * 60
        return self.token

    def _headers(self):
        return {
            "Authorization": f"Bearer {self._get_token()}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def _get(self, url, params=None):
        response = requests.get(url, headers=self._headers(), params=params)
        if response.status_code != 200:
            print(f"  API error {response.status_code}: {response.text[:300]}")
        response.raise_for_status()
        return response.json()

    def _patch(self, url, data):
        response = requests.patch(url, headers=self._headers(), json=data)
        if response.status_code != 200:
            print(f"  API error {response.status_code}: {response.text[:300]}")
        response.raise_for_status()
        return response.json()

    def _delete(self, url, data=None):
        response = requests.delete(url, headers=self._headers(), json=data)
        if response.status_code not in (200, 204):
            print(f"  API error {response.status_code}: {response.text[:300]}")
        response.raise_for_status()

    def find_app_by_bundle_id(self, bundle_id):
        data = self._get(f"{self.BASE_URL}/apps", params={"filter[bundleId]": bundle_id})
        apps = data.get("data", [])
        if not apps:
            raise ValueError(f"App with bundle ID '{bundle_id}' not found")
        return apps[0]

    def list_builds(self, app_id, limit=200):
        """List all builds for an app, handling pagination."""
        all_builds = []
        url = f"{self.BASE_URL}/builds"
        params = {
            "filter[app]": app_id,
            "limit": limit,
            "sort": "-uploadedDate",
            "fields[builds]": "version,uploadedDate,expired,processingState,buildAudienceType,minOsVersion",
            "include": "preReleaseVersion",
            "fields[preReleaseVersions]": "version",
        }

        while url:
            data = self._get(url, params=params)
            builds = data.get("data", [])
            included = data.get("included", [])

            # Build a map of preReleaseVersion id -> version string
            version_map = {}
            for item in included:
                if item.get("type") == "preReleaseVersions":
                    version_map[item["id"]] = item.get("attributes", {}).get("version", "?")

            for build in builds:
                pre_release_rel = build.get("relationships", {}).get("preReleaseVersion", {}).get("data")
                if pre_release_rel:
                    build["_app_version"] = version_map.get(pre_release_rel["id"], "?")
                else:
                    build["_app_version"] = "?"

            all_builds.extend(builds)

            next_url = data.get("links", {}).get("next")
            if next_url:
                url = next_url
                params = None
            else:
                url = None

        return all_builds

    def expire_build(self, build_id):
        """Set a build's expired attribute to true."""
        url = f"{self.BASE_URL}/builds/{build_id}"
        data = {
            "data": {
                "type": "builds",
                "id": build_id,
                "attributes": {"expired": True},
            }
        }
        return self._patch(url, data)

    def get_build_beta_groups(self, build_id):
        """Get build groups (betaGroups) associated with a specific build."""
        url = f"{self.BASE_URL}/builds/{build_id}/betaGroups"
        try:
            data = self._get(url)
            return data.get("data", [])
        except requests.exceptions.HTTPError:
            return []

    def remove_build_from_groups(self, build_id, group_ids):
        """Remove a build from its build groups by deleting the relationship."""
        if not group_ids:
            return
        url = f"{self.BASE_URL}/builds/{build_id}/relationships/betaGroups"
        data = {"data": [{"type": "betaGroups", "id": gid} for gid in group_ids]}
        self._delete(url, data=data)

    def list_build_groups(self, app_id):
        """List all build groups (betaGroups) for an app."""
        all_groups = []
        url = f"{self.BASE_URL}/apps/{app_id}/betaGroups"
        params = {"limit": 200}

        while url:
            data = self._get(url, params=params)
            all_groups.extend(data.get("data", []))
            next_url = data.get("links", {}).get("next")
            if next_url:
                url = next_url
                params = None
            else:
                url = None

        return all_groups

    def delete_build_group(self, group_id):
        """Delete a build group."""
        self._delete(f"{self.BASE_URL}/betaGroups/{group_id}")


def load_credentials(credentials_path):
    """Load credentials from YAML file (same format as localize.py)."""
    with open(credentials_path, "r", encoding="utf-8") as f:
        config = yaml.safe_load(f)

    asc = config.get("app_store_connect", {})
    app = config.get("app", {})

    key_id = asc.get("key_id", "").strip()
    issuer_id = asc.get("issuer_id", "").strip()
    bundle_id = app.get("bundle_id", "").strip()

    if not key_id or not issuer_id or not bundle_id:
        print("Missing required fields in credentials.yml (key_id, issuer_id, bundle_id)")
        sys.exit(1)

    # Load private key
    private_key_file = asc.get("private_key_file")
    private_key_content = asc.get("private_key_content")

    if private_key_file:
        key_path = Path(private_key_file)
        if not key_path.is_absolute():
            key_path = Path(credentials_path).parent / key_path
        if not key_path.exists():
            print(f"Private key file not found: {key_path}")
            sys.exit(1)
        with open(key_path, "r") as f:
            private_key = f.read()
    elif private_key_content:
        private_key = private_key_content
    else:
        print("No private key configured in credentials.yml")
        sys.exit(1)

    return key_id, issuer_id, private_key, bundle_id


def parse_uploaded_date(date_str):
    """Parse ISO 8601 date string from API response."""
    if not date_str:
        return None
    date_str = date_str.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(date_str)
    except ValueError:
        return None


def main():
    parser = argparse.ArgumentParser(
        description="Expire old TestFlight builds and remove them from build groups.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Dry run - see what would be expired (default 30 days)
  python expire_testflight_builds.py --dry-run

  # Expire builds older than 30 days
  python expire_testflight_builds.py

  # Expire builds older than 60 days
  python expire_testflight_builds.py --days 60

  # Also remove expired builds from their build groups
  python expire_testflight_builds.py --remove-from-groups

  # Delete all build groups entirely
  python expire_testflight_builds.py --delete-build-groups

  # Use specific credentials file
  python expire_testflight_builds.py --credentials ./credentials.yml --dry-run
""",
    )
    parser.add_argument(
        "--credentials",
        type=str,
        help="Path to credentials.yml (default: auto-detect in script or cwd)",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=30,
        help="Expire builds older than this many days (default: 30)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without making changes",
    )
    parser.add_argument(
        "--remove-from-groups",
        action="store_true",
        default=True,
        help="Remove expired builds from their build groups (default: true)",
    )
    parser.add_argument(
        "--delete-build-groups",
        action="store_true",
        help="Delete all build groups for the app",
    )
    parser.add_argument(
        "--include-already-expired",
        action="store_true",
        help="Also process builds that are already marked as expired",
    )
    args = parser.parse_args()

    # Find credentials file
    if args.credentials:
        credentials_path = args.credentials
    else:
        script_dir = Path(__file__).parent
        candidates = [
            script_dir / "app_store_localization" / "credentials.yml",
            script_dir / "credentials.yml",
            Path.cwd() / "credentials.yml",
        ]
        credentials_path = None
        for candidate in candidates:
            if candidate.exists():
                credentials_path = str(candidate)
                break

        if not credentials_path:
            print("Could not find credentials.yml. Specify with --credentials.")
            sys.exit(1)

    print("=== TestFlight Build Expiration Tool ===")
    if args.dry_run:
        print("*** DRY RUN MODE - no changes will be made ***")
    print()

    # Load credentials
    print(f"Loading credentials from: {credentials_path}")
    key_id, issuer_id, private_key, bundle_id = load_credentials(credentials_path)
    print(f"  Key ID: {key_id}")
    print(f"  Bundle ID: {bundle_id}")

    # Initialize API
    api = AppStoreConnectAPI(key_id, issuer_id, private_key)

    # Find app
    print(f"\nFinding app: {bundle_id}")
    app = api.find_app_by_bundle_id(bundle_id)
    app_id = app["id"]
    app_name = app["attributes"]["name"]
    print(f"  Found: {app_name} (ID: {app_id})")

    # List all builds
    print("\nFetching all builds...")
    builds = api.list_builds(app_id)
    print(f"  Found {len(builds)} total build(s)")

    if not builds:
        print("No builds found. Nothing to do.")
        return

    # Categorize builds
    now = datetime.now(timezone.utc)
    cutoff_days = args.days
    builds_to_expire = []
    builds_already_expired = []
    builds_to_keep = []

    for build in builds:
        attrs = build.get("attributes", {})
        build_id = build["id"]
        build_number = attrs.get("version", "?")
        app_version = build.get("_app_version", "?")
        uploaded_date_str = attrs.get("uploadedDate")
        is_expired = attrs.get("expired", False)
        processing_state = attrs.get("processingState", "UNKNOWN")

        uploaded_date = parse_uploaded_date(uploaded_date_str)
        age_days = (now - uploaded_date).days if uploaded_date else None

        build_info = {
            "id": build_id,
            "build_number": build_number,
            "app_version": app_version,
            "uploaded_date": uploaded_date_str,
            "age_days": age_days,
            "expired": is_expired,
            "processing_state": processing_state,
        }

        if is_expired and not args.include_already_expired:
            builds_already_expired.append(build_info)
        elif age_days is not None and age_days > cutoff_days:
            builds_to_expire.append(build_info)
        else:
            builds_to_keep.append(build_info)

    # Display summary
    print(f"\n--- Build Summary (cutoff: {cutoff_days} days) ---")
    print(f"  Builds to expire:    {len(builds_to_expire)}")
    print(f"  Already expired:     {len(builds_already_expired)}")
    print(f"  Builds to keep:      {len(builds_to_keep)}")

    if builds_to_expire:
        print(f"\nBuilds to EXPIRE ({len(builds_to_expire)}):")
        table_data = []
        for b in builds_to_expire:
            table_data.append([
                b["app_version"],
                b["build_number"],
                b["uploaded_date"][:10] if b["uploaded_date"] else "?",
                f"{b['age_days']}d" if b["age_days"] is not None else "?",
                b["processing_state"],
                "yes" if b["expired"] else "no",
            ])
        print(tabulate(
            table_data,
            headers=["App Version", "Build #", "Uploaded", "Age", "State", "Expired?"],
            tablefmt="simple",
        ))

    if builds_to_keep:
        print(f"\nBuilds to KEEP ({len(builds_to_keep)}):")
        table_data = []
        for b in builds_to_keep:
            table_data.append([
                b["app_version"],
                b["build_number"],
                b["uploaded_date"][:10] if b["uploaded_date"] else "?",
                f"{b['age_days']}d" if b["age_days"] is not None else "?",
                b["processing_state"],
            ])
        print(tabulate(
            table_data,
            headers=["App Version", "Build #", "Uploaded", "Age", "State"],
            tablefmt="simple",
        ))

    # Handle build groups
    build_groups = []
    if args.delete_build_groups:
        print("\nFetching build groups...")
        build_groups = api.list_build_groups(app_id)
        print(f"  Found {len(build_groups)} build group(s)")

        if build_groups:
            print("\nBuild groups to DELETE:")
            table_data = []
            for group in build_groups:
                g_attrs = group.get("attributes", {})
                table_data.append([
                    group["id"],
                    g_attrs.get("name", "?"),
                    "yes" if g_attrs.get("isInternalGroup", False) else "no",
                    "yes" if g_attrs.get("publicLinkEnabled", False) else "no",
                ])
            print(tabulate(
                table_data,
                headers=["ID", "Name", "Internal?", "Public Link?"],
                tablefmt="simple",
            ))

    # Dry run stops here
    if args.dry_run:
        print("\n*** DRY RUN COMPLETE - no changes were made ***")
        if builds_to_expire:
            print(f"  Would expire {len(builds_to_expire)} build(s)")
        if args.remove_from_groups:
            print(f"  Would remove expired builds from their build groups")
        if build_groups and args.delete_build_groups:
            print(f"  Would delete {len(build_groups)} build group(s)")
        return

    # Nothing to do check
    if not builds_to_expire and not (args.delete_build_groups and build_groups):
        print("\nNothing to do!")
        return

    # Confirm
    print("\n--- Confirm Actions ---")
    if builds_to_expire:
        print(f"  Will expire {len(builds_to_expire)} build(s)")
        if args.remove_from_groups:
            print(f"  Will remove those builds from their build groups first")
    if build_groups and args.delete_build_groups:
        print(f"  Will delete {len(build_groups)} build group(s)")

    confirm = input("\nProceed? (y/N): ").strip().lower()
    if confirm not in ("y", "yes"):
        print("Cancelled.")
        return

    # Step 1: Remove builds from their groups, then expire them
    if builds_to_expire:
        print(f"\nProcessing {len(builds_to_expire)} build(s)...")
        success_count = 0
        error_count = 0

        for b in builds_to_expire:
            build_id = b["id"]
            label = f"v{b['app_version']} ({b['build_number']})"

            # Remove from build groups first
            if args.remove_from_groups:
                try:
                    groups = api.get_build_beta_groups(build_id)
                    if groups:
                        group_ids = [g["id"] for g in groups]
                        group_names = [g.get("attributes", {}).get("name", g["id"]) for g in groups]
                        api.remove_build_from_groups(build_id, group_ids)
                        print(f"  Removed {label} from groups: {', '.join(group_names)}")
                        time.sleep(0.3)
                except Exception as e:
                    print(f"  Warning: could not remove {label} from groups: {e}")

            # Expire the build (skip if already expired)
            if not b["expired"]:
                try:
                    api.expire_build(build_id)
                    print(f"  Expired: {label}")
                    success_count += 1
                except Exception as e:
                    print(f"  FAILED to expire {label}: {e}")
                    error_count += 1
            else:
                print(f"  Already expired: {label} (group removal only)")
                success_count += 1

            # Rate limiting
            time.sleep(0.5)

        print(f"\nBuild processing complete: {success_count} succeeded, {error_count} failed")

    # Step 2: Delete build groups
    if args.delete_build_groups and build_groups:
        print(f"\nDeleting {len(build_groups)} build group(s)...")
        success_count = 0
        error_count = 0

        for group in build_groups:
            group_id = group["id"]
            group_name = group.get("attributes", {}).get("name", "?")
            try:
                api.delete_build_group(group_id)
                print(f"  Deleted: {group_name} ({group_id})")
                success_count += 1
            except Exception as e:
                print(f"  FAILED: {group_name} - {e}")
                error_count += 1

            time.sleep(0.5)

        print(f"\nBuild group deletion complete: {success_count} succeeded, {error_count} failed")

    print("\nDone!")


if __name__ == "__main__":
    main()
