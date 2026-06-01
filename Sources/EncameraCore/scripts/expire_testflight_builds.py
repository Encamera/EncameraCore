#!/usr/bin/env python3
"""
Expire Old TestFlight Builds Script
Expires all TestFlight builds older than a specified number of days and
removes builds from their build groups.

Build groups in TestFlight are represented as betaGroups in the ASC API.

Requires the `asc` library: pip install -e scripts/asc
"""

import argparse
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    from asc.auth import Credentials
    from asc.client import ASCClient
    from asc.testflight import (
        delete_beta_group,
        expire_build,
        get_build_beta_groups,
        list_beta_groups,
        list_builds_with_versions,
        remove_build_from_beta_groups,
    )
except ImportError:
    print("Missing required package 'asc'. Install with: pip install -e scripts/asc")
    sys.exit(1)

try:
    from tabulate import tabulate
except ImportError:
    print("Missing required package 'tabulate'. Install with: pip install tabulate")
    sys.exit(1)


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

    # Load credentials and initialize client
    print(f"Loading credentials from: {credentials_path}")
    creds = Credentials.load(credentials_path)
    if not creds.bundle_id and not creds.app_id:
        print("credentials.yml must set app.bundle_id or app.app_id")
        sys.exit(1)
    print(f"  Key ID: {creds.key_id}")
    print(f"  Bundle ID: {creds.bundle_id or '(not set)'}")

    client = ASCClient(creds)

    # Find app
    if creds.bundle_id:
        print(f"\nFinding app: {creds.bundle_id}")
        app = client.find_app_by_bundle_id(creds.bundle_id)
        app_id = app["id"]
        app_name = app["attributes"]["name"]
        print(f"  Found: {app_name} (ID: {app_id})")
    else:
        app_id = creds.app_id
        print(f"\nUsing configured app ID: {app_id}")

    # List all builds
    print("\nFetching all builds...")
    builds = list_builds_with_versions(client, app_id)
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
        build_groups = list_beta_groups(client, app_id)
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
                    groups = get_build_beta_groups(client, build_id)
                    if groups:
                        group_ids = [g["id"] for g in groups]
                        group_names = [g.get("attributes", {}).get("name", g["id"]) for g in groups]
                        remove_build_from_beta_groups(client, build_id, group_ids)
                        print(f"  Removed {label} from groups: {', '.join(group_names)}")
                        time.sleep(0.3)
                except Exception as e:
                    print(f"  Warning: could not remove {label} from groups: {e}")

            # Expire the build (skip if already expired)
            if not b["expired"]:
                try:
                    expire_build(client, build_id)
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
                delete_beta_group(client, group_id)
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
