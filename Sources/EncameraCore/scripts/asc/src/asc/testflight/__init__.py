"""TestFlight build, beta group, tester, and beta review operations.

Split into submodules; every public name is re-exported here so
``from asc.testflight import expire_build`` keeps working.

| Submodule | Covers |
|---|---|
| ``builds`` | listing builds, expiration, beta state, "What to Test", notifications |
| ``groups`` | beta groups and the build↔group relationship |
| ``testers`` | tester lookup/creation, group membership, per-build assignment, invitations |
| ``review`` | beta app review submissions and the app's review contact details |
"""

from asc.testflight.builds import (
    expire_build,
    find_latest_build,
    get_build,
    get_build_beta_detail,
    get_build_localizations,
    list_builds_for_version,
    list_builds_with_versions,
    notify_testers_of_build,
    set_build_auto_notify,
    set_build_whats_new,
)
from asc.testflight.groups import (
    add_build_to_beta_groups,
    create_beta_group,
    delete_beta_group,
    find_beta_group_by_name,
    get_beta_group,
    get_build_beta_groups,
    list_beta_groups,
    list_beta_groups_typed,
    list_builds_in_group,
    remove_build_from_beta_groups,
)
from asc.testflight.review import (
    get_beta_app_review_detail,
    get_beta_review_submission,
    list_beta_review_submissions,
    submit_build_for_beta_review,
    update_beta_app_review_detail,
)
from asc.testflight.testers import (
    add_individual_testers_to_build,
    add_testers_to_group,
    add_testers_to_groups,
    create_beta_tester,
    delete_beta_tester,
    ensure_tester,
    find_testers_by_email,
    get_beta_tester,
    list_individual_testers,
    list_testers_in_group,
    remove_individual_testers_from_build,
    remove_testers_from_groups,
    resend_invitation,
)

__all__ = [
    # builds
    "expire_build",
    "find_latest_build",
    "get_build",
    "get_build_beta_detail",
    "get_build_localizations",
    "list_builds_for_version",
    "list_builds_with_versions",
    "notify_testers_of_build",
    "set_build_auto_notify",
    "set_build_whats_new",
    # groups
    "add_build_to_beta_groups",
    "create_beta_group",
    "delete_beta_group",
    "find_beta_group_by_name",
    "get_beta_group",
    "get_build_beta_groups",
    "list_beta_groups",
    "list_beta_groups_typed",
    "list_builds_in_group",
    "remove_build_from_beta_groups",
    # testers
    "add_individual_testers_to_build",
    "add_testers_to_group",
    "add_testers_to_groups",
    "create_beta_tester",
    "delete_beta_tester",
    "ensure_tester",
    "find_testers_by_email",
    "get_beta_tester",
    "list_individual_testers",
    "list_testers_in_group",
    "remove_individual_testers_from_build",
    "remove_testers_from_groups",
    "resend_invitation",
    # review
    "get_beta_app_review_detail",
    "get_beta_review_submission",
    "list_beta_review_submissions",
    "submit_build_for_beta_review",
    "update_beta_app_review_detail",
]
