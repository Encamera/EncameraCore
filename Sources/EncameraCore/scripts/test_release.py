"""Unit tests for release.py preflight and release-branch logic.

Run with: python3 -m unittest test_release

The CloudKit schema preflight is the release gate for the #1 silent-failure
risk (plans/cloudkit-migration/08-release-rollout-tests.md §1): shipping a
build that writes a record type never deployed to the Production CloudKit
environment. These tests pin the prompt's contract: it can never pass
silently — only an explicit "yes" counts as deployed.
"""

import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

# release.py hard-exits when the App Store Connect client package is missing.
# The logic under test is git and prompt logic, so stub the asc modules out
# rather than requiring the release environment to run the tests. Every name
# release.py imports from asc must be listed here, or the import fails.
for _name, _attrs in {
    "asc": [],
    "asc.auth": ["Credentials"],
    "asc.client": ["ASCClient"],
    "asc.releases": [
        "clear_build_for_version",
        "confirm_review_submission",
        "find_editable_version",
        "prepare_review_submission",
        "set_build_for_version",
        "set_version_release_type",
    ],
    "asc.testflight": ["list_builds_for_version", "list_builds_with_versions"],
    "asc.xcode_cloud": [],
    "asc.xcode_cloud.build_runs": [
        "get_build_run",
        "list_build_runs_for_workflow",
        "list_builds_for_build_run",
        "start_build_run",
    ],
    "asc.xcode_cloud.scm": ["find_workflow_git_reference"],
}.items():
    if _name not in sys.modules:
        _module = types.ModuleType(_name)
        for _attr in _attrs:
            setattr(_module, _attr, object())
        sys.modules[_name] = _module

import release
from release import preflight_cloudkit_schema_deployed  # noqa: E402


class CloudKitSchemaPreflightTests(unittest.TestCase):
    def test_empty_answer_defaults_to_not_deployed(self):
        """Hitting Enter must NOT pass the gate — a distracted release cannot auto-pass."""
        self.assertFalse(preflight_cloudkit_schema_deployed(input_fn=lambda _: ""))

    def test_explicit_no_fails_the_gate(self):
        self.assertFalse(preflight_cloudkit_schema_deployed(input_fn=lambda _: "n"))
        self.assertFalse(preflight_cloudkit_schema_deployed(input_fn=lambda _: "no"))

    def test_only_explicit_yes_passes(self):
        self.assertTrue(preflight_cloudkit_schema_deployed(input_fn=lambda _: "y"))
        self.assertTrue(preflight_cloudkit_schema_deployed(input_fn=lambda _: "Yes"))

    def test_whitespace_or_garbage_fails_the_gate(self):
        self.assertFalse(preflight_cloudkit_schema_deployed(input_fn=lambda _: "  "))
        self.assertFalse(preflight_cloudkit_schema_deployed(input_fn=lambda _: "sure"))


def _run(cwd, *args):
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


class ReleaseBranchTestCase(unittest.TestCase):
    """A bare 'origin' plus a clone of it, with release.REPO_ROOT pointed at the clone."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.origin = root / "origin.git"
        self.clone = root / "clone"
        _run(root, "init", "--bare", "-b", "main", str(self.origin))
        _run(root, "clone", str(self.origin), str(self.clone))
        for key, value in (("user.name", "Test"), ("user.email", "test@example.com")):
            _run(self.clone, "config", key, value)
        _run(self.clone, "checkout", "-b", "main")
        self.commit("first")
        _run(self.clone, "push", "-u", "origin", "main")
        patcher = mock.patch.object(release, "REPO_ROOT", self.clone)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self._tmp.cleanup)

    def commit(self, name):
        (self.clone / name).write_text(name)
        _run(self.clone, "add", name)
        _run(self.clone, "commit", "-m", name)
        return _run(self.clone, "rev-parse", "HEAD")

    def head_branch(self):
        return _run(self.clone, "rev-parse", "--abbrev-ref", "HEAD")


class ReleaseBranchNameTests(unittest.TestCase):
    def test_patch_versions_share_their_minor_branch(self):
        self.assertEqual(release.release_branch_for("3.0.0"), "release/3.0")
        self.assertEqual(release.release_branch_for("3.0.1"), "release/3.0")
        self.assertEqual(release.release_branch_for("2.10.3"), "release/2.10")

    def test_two_part_version(self):
        self.assertEqual(release.release_branch_for("3.1"), "release/3.1")


class LatestVersionTagTests(ReleaseBranchTestCase):
    def test_picks_highest_version_tag_and_ignores_other_tags(self):
        _run(self.clone, "tag", "2.9.2")
        _run(self.clone, "tag", "2.10.0")
        _run(self.clone, "tag", "pr-284-artifacts")
        _run(self.clone, "tag", "testflight-release-1")
        self.assertEqual(release.latest_version_tag(), "2.10.0")

    def test_finds_tags_that_are_not_ancestors_of_head(self):
        _run(self.clone, "checkout", "-b", "release/2.10")
        self.commit("hotfix")
        _run(self.clone, "tag", "2.10.0")
        _run(self.clone, "checkout", "main")
        self.assertEqual(release.latest_version_tag(), "2.10.0")

    def test_none_without_version_tags(self):
        _run(self.clone, "tag", "backup/pr228-preupdate")
        self.assertIsNone(release.latest_version_tag())


class UpsertReleaseBranchTests(ReleaseBranchTestCase):
    def test_cuts_missing_branch_from_origin_main_and_pushes_it(self):
        main_sha = _run(self.clone, "rev-parse", "origin/main")
        # A local-only commit on main must not leak into the release branch.
        self.commit("unpushed-on-main")

        ok = release.upsert_release_branch("release/3.0", confirm_fn=lambda *a, **k: True)

        self.assertTrue(ok)
        self.assertEqual(self.head_branch(), "release/3.0")
        self.assertEqual(_run(self.clone, "rev-parse", "HEAD"), main_sha)
        self.assertEqual(
            _run(self.origin, "rev-parse", "refs/heads/release/3.0"), main_sha
        )
        self.assertEqual(
            _run(self.clone, "rev-parse", "--abbrev-ref", "release/3.0@{upstream}"),
            "origin/release/3.0",
        )

    def test_declining_creates_nothing(self):
        ok = release.upsert_release_branch("release/3.0", confirm_fn=lambda *a, **k: False)

        self.assertFalse(ok)
        self.assertEqual(self.head_branch(), "main")
        self.assertEqual(_run(self.clone, "branch", "--list", "release/3.0"), "")

    def test_dry_run_creates_nothing_and_never_prompts(self):
        def fail_prompt(*_a, **_k):
            raise AssertionError("dry run must not prompt")

        ok = release.upsert_release_branch("release/3.0", dry_run=True, confirm_fn=fail_prompt)

        self.assertFalse(ok)
        self.assertEqual(self.head_branch(), "main")
        self.assertEqual(_run(self.origin, "branch", "--list", "release/3.0"), "")

    def test_existing_remote_branch_is_checked_out_without_main(self):
        _run(self.clone, "checkout", "-b", "release/3.0")
        release_sha = self.commit("hotfix")
        _run(self.clone, "push", "-u", "origin", "release/3.0")
        _run(self.clone, "checkout", "main")
        _run(self.clone, "branch", "-D", "release/3.0")
        self.commit("main-moves-on")
        _run(self.clone, "push", "origin", "main")

        ok = release.upsert_release_branch("release/3.0", confirm_fn=lambda *a, **k: True)

        self.assertTrue(ok)
        self.assertEqual(self.head_branch(), "release/3.0")
        self.assertEqual(_run(self.clone, "rev-parse", "HEAD"), release_sha)

    def test_existing_branch_warns_how_far_behind_main_and_lists_unlanded_fixes(self):
        _run(self.clone, "checkout", "-b", "release/3.0")
        self.commit("release-only-fix")
        _run(self.clone, "push", "-u", "origin", "release/3.0")
        _run(self.clone, "checkout", "main")
        self.commit("main-1")
        self.commit("main-2")
        _run(self.clone, "push", "origin", "main")

        with mock.patch("builtins.print") as printed:
            ok = release.upsert_release_branch("release/3.0")

        output = "\n".join(" ".join(map(str, c.args)) for c in printed.call_args_list)
        self.assertTrue(ok)
        self.assertIn("release/3.0 is 2 commit(s) behind origin/main", output)
        self.assertIn("1 commit(s) on release/3.0 have no patch-equivalent", output)
        self.assertIn("release-only-fix", output)


class LocalMatchesRemoteTests(ReleaseBranchTestCase):
    def test_in_sync_and_ahead(self):
        _run(self.clone, "checkout", "-b", "release/3.0")
        _run(self.clone, "push", "-u", "origin", "release/3.0")
        self.assertTrue(release.preflight_local_release_matches_remote("release/3.0"))
        self.commit("unpushed")
        with mock.patch("builtins.print"):
            self.assertFalse(release.preflight_local_release_matches_remote("release/3.0"))


if __name__ == "__main__":
    unittest.main()
