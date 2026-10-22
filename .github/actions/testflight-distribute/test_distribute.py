"""Distribution must verify ASC state, including idempotent conflicts."""
import contextlib
import copy
import importlib.util
import io
import os
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("distribute", Path(__file__).with_name("distribute.py"))
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)


class DistributionTests(unittest.TestCase):
    def run_distribution(self, *, group_error=None, review_error=None,
                         commit_group=True, commit_review=True):
        state = {"id": "build-id", "attributes": {"processingState": "VALID",
                 "usesNonExemptEncryption": False}, "_groups": set(), "_review": None}
        initial = copy.deepcopy(state)

        class Client:
            def call(self, method, path, body):
                if "/relationships/builds" in path:
                    if commit_group:
                        state["_groups"].add("Testers")
                    if group_error:
                        raise group_error
                else:
                    if commit_review:
                        state["_review"] = "WAITING_FOR_REVIEW"
                    if review_error:
                        raise review_error

        group = {"id": "group-id", "attributes": {"name": "Testers",
                 "isInternalGroup": False, "publicLinkEnabled": True}}
        environment = {"BUNDLE_ID": "com.example.app", "BUILD_NUMBER": "42",
                       "PLATFORM": "TV_OS", "SUBMIT_FOR_REVIEW": "true"}
        with patch.dict(os.environ, environment, clear=True), \
             patch.object(subject, "Client", return_value=Client()), \
             patch.object(subject, "find_app", return_value="app-id"), \
             patch.object(subject, "wait_for_build", return_value=initial), \
             patch.object(subject, "find_build", side_effect=lambda *a: copy.deepcopy(state)), \
             patch.object(subject, "list_groups", return_value=[group]), \
             patch.object(subject.time, "sleep"), contextlib.redirect_stdout(io.StringIO()):
            subject.main()

    def test_unrelated_group_conflict_is_not_success(self):
        with self.assertRaises(subject.ApiError):
            self.run_distribution(group_error=subject.ApiError(409, "STATE_ERROR"), commit_group=False)

    def test_unrelated_review_conflict_is_not_success(self):
        with self.assertRaises(subject.ApiError):
            self.run_distribution(review_error=subject.ApiError(409, "STATE_ERROR"), commit_review=False)

    def test_forbidden_error_containing_already_is_not_success(self):
        with self.assertRaises(subject.ApiError):
            self.run_distribution(group_error=subject.ApiError(403, "already unavailable"), commit_group=False)

    def test_verified_duplicate_group_and_review_are_idempotent(self):
        self.run_distribution(group_error=subject.ApiError(409, "duplicate"),
                              review_error=subject.ApiError(409, "duplicate"))

    def test_success_response_without_group_assignment_is_not_success(self):
        with self.assertRaises(SystemExit):
            self.run_distribution(commit_group=False)

    def test_success_response_without_review_submission_is_not_success(self):
        with self.assertRaises(SystemExit):
            self.run_distribution(commit_review=False)

    def test_successful_assignment_and_submission(self):
        self.run_distribution()


if __name__ == "__main__":
    unittest.main()
