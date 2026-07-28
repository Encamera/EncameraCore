"""Unit tests for release.py preflight logic.

Run with: python3 -m unittest test_release

The CloudKit schema preflight is the release gate for the #1 silent-failure
risk (plans/cloudkit-migration/08-release-rollout-tests.md §1): shipping a
build that writes a record type never deployed to the Production CloudKit
environment. These tests pin the prompt's contract: it can never pass
silently — only an explicit "yes" counts as deployed.
"""

import sys
import types
import unittest

# release.py hard-exits when the App Store Connect client package is missing.
# The preflight under test is pure prompt logic, so stub the asc modules out
# rather than requiring the release environment to run the tests.
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
    "asc.xcode_cloud.build_runs": ["list_build_runs_for_workflow"],
}.items():
    if _name not in sys.modules:
        _module = types.ModuleType(_name)
        for _attr in _attrs:
            setattr(_module, _attr, object())
        sys.modules[_name] = _module

from release import preflight_cloudkit_schema_deployed


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


if __name__ == "__main__":
    unittest.main()
