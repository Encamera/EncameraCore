#!/usr/bin/env python3
"""Expire all TestFlight builds produced by Xcode Cloud for a given branch.

Walks Xcode Cloud build runs to find which ASC builds originated from the
branch, then expires each one.  Already-expired builds are patched
idempotently (expired = True is a no-op on an already-expired build).

Required env vars (same as the ``asc`` library):
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY (or ASC_PRIVATE_KEY_FILE)
  ASC_APP_ID  (or ASC_BUNDLE_ID)
"""

import argparse
import sys

from asc.auth import Credentials
from asc.client import ASCClient
from asc.testflight.builds import expire_build as do_expire_build
from asc.xcode_cloud.build_runs import (
    list_build_runs_for_workflow,
    list_builds_for_build_run,
)
from asc.xcode_cloud.products import get_product_for_app
from asc.xcode_cloud.scm import get_repository_for_workflow, list_git_references
from asc.xcode_cloud.workflows import list_workflows_for_product


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Expire TestFlight builds for a deleted branch",
    )
    parser.add_argument("branch", help="Branch name whose builds should be expired")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List builds that would be expired without expiring them",
    )
    args = parser.parse_args()

    client = ASCClient(Credentials.load())
    app_id = client.resolve_app_id()

    product = get_product_for_app(client, app_id)
    if not product:
        print("No Xcode Cloud product found for this app")
        sys.exit(1)

    workflows = list_workflows_for_product(client, product.id)
    if not workflows:
        print("No Xcode Cloud workflows found")
        sys.exit(1)

    repo = None
    for wf in workflows:
        repo = get_repository_for_workflow(client, wf.id)
        if repo:
            break
    if not repo:
        print("No repository found for any workflow")
        sys.exit(1)

    refs = list_git_references(client, repo.id, kind="BRANCH", include_deleted=True)
    branch_ref = next((r for r in refs if r.name == args.branch), None)
    if not branch_ref:
        print(f"No git reference found for branch '{args.branch}' — nothing to expire")
        sys.exit(0)

    print(
        f"Found git reference {branch_ref.id} for branch '{args.branch}'"
        f" (deleted={branch_ref.is_deleted})"
    )

    build_ids: set[tuple[str, str]] = set()
    for wf in workflows:
        runs = list_build_runs_for_workflow(client, wf.id, limit=200)
        for run in runs:
            if run.source_branch_or_tag_id == branch_ref.id:
                builds = list_builds_for_build_run(client, run.id)
                for b in builds:
                    build_ids.add((b.id, b.version))

    if not build_ids:
        print("No TestFlight builds found for this branch")
        sys.exit(0)

    print(f"Found {len(build_ids)} build(s) from branch '{args.branch}'")

    expired = 0
    failed = 0
    for build_id, build_number in sorted(build_ids, key=lambda x: x[1]):
        if args.dry_run:
            print(f"  Would expire: build {build_number} ({build_id})")
            expired += 1
        else:
            try:
                do_expire_build(client, build_id)
                print(f"  Expired: build {build_number} ({build_id})")
                expired += 1
            except Exception as e:
                print(f"  Failed to expire build {build_number} ({build_id}): {e}")
                failed += 1

    action = "would expire" if args.dry_run else "expired"
    print(f"\nDone: {action} {expired} build(s)" + (f", {failed} failed" if failed else ""))
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
