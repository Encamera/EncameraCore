#!/usr/bin/env python3
"""
TestFlight Admin Script

Manage TestFlight builds, beta groups, and testers from the command line.
Every command is a thin wrapper over `asc.testflight` — the same functions the
asc MCP server exposes as tools.

Requires the `asc` library: pip install -e scripts/asc

Examples:
  # What's the newest build, and can testers actually install it?
  python testflight_admin.py builds --latest

  # Who's in which group, and who hasn't accepted their invite?
  python testflight_admin.py groups --builds
  python testflight_admin.py testers list --email alex@example.com

  # Share the latest build with someone (creates the tester if needed)
  python testflight_admin.py share --email alex@example.com --name "Alex Freas" \\
      --group External --build latest --dry-run

  # Nudge a tester stuck at state=INVITED
  python testflight_admin.py invite --email alex@example.com

  # Submit the newest build for beta app review (required for external testing)
  python testflight_admin.py submit-review --build latest
"""

import argparse
import sys

try:
    from asc.auth import Credentials
    from asc.client import ASCClient
    from asc import testflight as tf
except ImportError:
    print("Missing required package 'asc'. Install with: pip install -e scripts/asc")
    sys.exit(1)

try:
    from tabulate import tabulate
except ImportError:
    print("Missing required package 'tabulate'. Install with: pip install tabulate")
    sys.exit(1)


def resolve_build(client, app_id, spec):
    """Resolve a --build value to a build resource.

    Accepts ``latest``, a build number like ``1080``, or a raw build id.
    """
    if spec in (None, "latest"):
        build = tf.find_latest_build(client, app_id)
        if not build:
            raise SystemExit("No processed build found for this app.")
        return build
    builds = tf.list_builds_with_versions(client, app_id)
    for b in builds:
        if b["id"] == spec or b.get("attributes", {}).get("version") == spec:
            return b
    raise SystemExit(f"No build matching {spec!r}. Try `builds` to list them.")


def resolve_group(client, app_id, spec):
    """Resolve a --group value (name or id) to a BetaGroup."""
    group = tf.find_beta_group_by_name(client, app_id, spec)
    if group:
        return group
    for g in tf.list_beta_groups_typed(client, app_id):
        if g.id == spec:
            return g
    raise SystemExit(f"No beta group matching {spec!r}. Try `groups` to list them.")


def resolve_tester(client, app_id, email):
    """Find the app-scoped tester for an email, or exit with a useful message."""
    matches = tf.find_testers_by_email(client, email, app_id=app_id)
    if not matches:
        raise SystemExit(
            f"No beta tester with email {email} on this app. "
            "Use `share --email ... ` to create one."
        )
    if len(matches) > 1:
        ids = ", ".join(t.id for t in matches)
        raise SystemExit(f"Multiple testers match {email}: {ids}")
    return matches[0]


def cmd_builds(client, app_id, args):
    if args.latest:
        build = tf.find_latest_build(client, app_id)
        if not build:
            print("No processed builds.")
            return
        detail = tf.get_build_beta_detail(client, build["id"])
        review = tf.get_beta_review_submission(client, build["id"])
        groups = tf.get_build_beta_groups(client, build["id"], app_id)
        print(f"Build {build['attributes']['version']} (v{build['_app_version']})")
        print(f"  id                  {build['id']}")
        print(f"  uploaded            {build['attributes'].get('uploadedDate')}")
        print(f"  processing          {build['attributes'].get('processingState')}")
        print(f"  internal state      {detail.internal_build_state}")
        print(f"  external state      {detail.external_build_state}")
        print(f"  auto-notify         {detail.auto_notify_enabled}")
        print(f"  beta review         {review.beta_review_state if review else 'not submitted'}")
        print(f"  groups              {', '.join(g['attributes']['name'] for g in groups) or '(none)'}")
        return

    builds = tf.list_builds_with_versions(client, app_id)[: args.limit]
    rows = [
        [
            b["attributes"].get("version"),
            b["_app_version"],
            (b["attributes"].get("uploadedDate") or "")[:10],
            b["attributes"].get("processingState"),
            "yes" if b["attributes"].get("expired") else "",
            b["id"],
        ]
        for b in builds
    ]
    print(tabulate(rows, headers=["Build", "Version", "Uploaded", "State", "Expired", "ID"]))


def cmd_groups(client, app_id, args):
    rows = []
    for g in tf.list_beta_groups_typed(client, app_id):
        testers = tf.list_testers_in_group(client, g.id)
        builds = tf.list_builds_in_group(client, g.id) if args.builds else []
        newest = ""
        if args.builds:
            versions = sorted(
                (int(b["attributes"]["version"]) for b in builds
                 if str(b["attributes"].get("version", "")).isdigit()),
                reverse=True,
            )
            newest = str(versions[0]) if versions else "(none)"
        rows.append([
            g.name,
            "internal" if g.is_internal else "external",
            "yes" if g.has_access_to_all_builds else "",
            len(testers),
            *( [len(builds), newest] if args.builds else [] ),
            g.id,
        ])
    headers = ["Group", "Kind", "All builds", "Testers"]
    if args.builds:
        headers += ["Builds", "Newest"]
    headers += ["ID"]
    print(tabulate(rows, headers=headers))


def cmd_testers(client, app_id, args):
    if args.testers_action == "list":
        if args.email:
            testers = tf.find_testers_by_email(client, args.email, app_id=app_id)
        elif args.group:
            testers = tf.list_testers_in_group(client, resolve_group(client, app_id, args.group).id)
        elif args.build:
            build = resolve_build(client, app_id, args.build)
            testers = tf.list_individual_testers(client, build["id"])
        else:
            raise SystemExit("Pass one of --email, --group, or --build.")
        rows = [
            [t.email, f"{t.first_name or ''} {t.last_name or ''}".strip(),
             t.state, ", ".join(t.beta_group_names), t.id]
            for t in testers
        ]
        print(tabulate(rows, headers=["Email", "Name", "State", "Groups", "ID"]) if rows else "No testers found.")
        return

    tester = resolve_tester(client, app_id, args.email)
    if args.testers_action == "remove":
        if args.group:
            group = resolve_group(client, app_id, args.group)
            if args.dry_run:
                print(f"[dry-run] Would remove {tester.email} from group {group.name}")
                return
            tf.remove_testers_from_groups(client, tester.id, [group.id])
            print(f"Removed {tester.email} from group {group.name}")
        elif args.build:
            build = resolve_build(client, app_id, args.build)
            if args.dry_run:
                print(f"[dry-run] Would remove {tester.email} from build {build['attributes']['version']}")
                return
            tf.remove_individual_testers_from_build(client, build["id"], [tester.id])
            print(f"Removed {tester.email} from build {build['attributes']['version']}")
        else:
            raise SystemExit("Pass --group or --build to say what to remove them from.")


def cmd_share(client, app_id, args):
    first_name = last_name = None
    if args.name:
        parts = args.name.split(None, 1)
        first_name = parts[0]
        last_name = parts[1] if len(parts) > 1 else None

    group = resolve_group(client, app_id, args.group) if args.group else None
    build = resolve_build(client, app_id, args.build) if args.build else None

    existing = tf.find_testers_by_email(client, args.email, app_id=app_id)
    if args.dry_run:
        who = existing[0].id if existing else "(would be created)"
        print(f"[dry-run] Tester {args.email}: {who}")
        if group:
            if existing and group.id in existing[0].beta_group_ids:
                print(f"[dry-run] Already in group {group.name} — no change")
            else:
                print(f"[dry-run] Would add to group: {group.name} ({group.id})")
        if build:
            label = f"{build['attributes']['version']} ({build['id']})"
            already = existing and any(
                t.id == existing[0].id
                for t in tf.list_individual_testers(client, build["id"])
            )
            if already:
                print(f"[dry-run] Already an individual tester on build {label} — no change")
            else:
                print(f"[dry-run] Would add as individual tester on build {label}")
        if not group and not build:
            print("[dry-run] Nothing to attach — pass --group and/or --build.")
        return

    tester, created = tf.ensure_tester(
        client, args.email, app_id,
        first_name=first_name, last_name=last_name,
        group_ids=[group.id] if group else None,
        build_ids=[build["id"]] if build else None,
    )
    print(f"{'Created' if created else 'Found'} tester {tester.email} ({tester.id}), state={tester.state}")

    # ensure_tester only attaches on creation; attach explicitly for existing testers.
    if not created:
        if group and group.id not in tester.beta_group_ids:
            tf.add_testers_to_groups(client, tester.id, [group.id])
            print(f"Added to group {group.name}")
        elif group:
            print(f"Already in group {group.name}")
        if build:
            already = any(t.id == tester.id for t in tf.list_individual_testers(client, build["id"]))
            if already:
                print(f"Already an individual tester on build {build['attributes']['version']}")
            else:
                tf.add_individual_testers_to_build(client, build["id"], [tester.id])
                print(f"Added as individual tester on build {build['attributes']['version']}")

    if build:
        detail = tf.get_build_beta_detail(client, build["id"])
        print(f"Build beta state: internal={detail.internal_build_state} "
              f"external={detail.external_build_state}")


def cmd_invite(client, app_id, args):
    tester = resolve_tester(client, app_id, args.email)
    print(f"Tester {tester.email} ({tester.id}) state={tester.state} "
          f"groups={', '.join(tester.beta_group_names) or '(none)'}")
    if args.dry_run:
        print("[dry-run] Would resend the TestFlight invitation.")
        return
    tf.resend_invitation(client, app_id, tester.id)
    print("Invitation sent.")


def cmd_submit_review(client, app_id, args):
    build = resolve_build(client, app_id, args.build)
    label = f"{build['attributes']['version']} (v{build['_app_version']})"
    existing = tf.get_beta_review_submission(client, build["id"])
    if existing:
        print(f"Build {label} was already submitted on {existing.submitted_date} "
              f"— state {existing.beta_review_state}")
        return
    if args.dry_run:
        print(f"[dry-run] Would submit build {label} for beta app review.")
        return
    submission = tf.submit_build_for_beta_review(client, build["id"])
    print(f"Submitted build {label} for beta review — state {submission.beta_review_state}")


def main():
    parser = argparse.ArgumentParser(
        description="Manage TestFlight builds, beta groups, and testers.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--credentials", help="Path to credentials.yml (defaults to ASC_CREDENTIALS_PATH)")
    parser.add_argument("--app-id", help="App Store Connect app ID (defaults to the configured app)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("builds", help="List builds, or inspect the newest one")
    p.add_argument("--latest", action="store_true", help="Show full detail for the newest processed build")
    p.add_argument("--limit", type=int, default=20)

    p = sub.add_parser("groups", help="List beta groups")
    p.add_argument("--builds", action="store_true", help="Also count attached builds (slower)")

    p = sub.add_parser("testers", help="List, or remove, beta testers")
    p.add_argument("testers_action", choices=["list", "remove"])
    p.add_argument("--email")
    p.add_argument("--group", help="Beta group name or id")
    p.add_argument("--build", help="Build number, build id, or 'latest'")
    p.add_argument("--dry-run", action="store_true")

    p = sub.add_parser("share", help="Give someone access to a build and/or group by email")
    p.add_argument("--email", required=True)
    p.add_argument("--name", help='Full name, e.g. "Alex Freas" (optional)')
    p.add_argument("--group", help="Beta group name or id")
    p.add_argument("--build", help="Build number, build id, or 'latest'")
    p.add_argument("--dry-run", action="store_true")

    p = sub.add_parser("invite", help="Resend the TestFlight invitation email")
    p.add_argument("--email", required=True)
    p.add_argument("--dry-run", action="store_true")

    p = sub.add_parser("submit-review", help="Submit a build for beta app review")
    p.add_argument("--build", default="latest", help="Build number, build id, or 'latest'")
    p.add_argument("--dry-run", action="store_true")

    args = parser.parse_args()

    client = ASCClient(Credentials.load(args.credentials))
    app_id = args.app_id or client.resolve_app_id()

    handlers = {
        "builds": cmd_builds,
        "groups": cmd_groups,
        "testers": cmd_testers,
        "share": cmd_share,
        "invite": cmd_invite,
        "submit-review": cmd_submit_review,
    }
    handlers[args.command](client, app_id, args)


if __name__ == "__main__":
    main()
