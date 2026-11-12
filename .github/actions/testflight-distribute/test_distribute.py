"""Distribution must verify ASC state, including idempotent conflicts."""
import contextlib
import copy
import importlib.util
import io
import os
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

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


class GroupAssignmentTests(unittest.TestCase):
    def setUp(self):
        self.client = Mock()
        self.group = {"id": "group-id", "attributes": {"name": "Testers"}}
        self.observed = {"id": "build-id", "_groups": set()}
        find_build = patch.object(subject, "find_build", return_value=self.observed)
        sleep = patch.object(subject.time, "sleep")
        self.find_build = find_build.start()
        self.sleep = sleep.start()
        self.addCleanup(find_build.stop)
        self.addCleanup(sleep.stop)

    def assign_group(self):
        with contextlib.redirect_stdout(io.StringIO()):
            subject.assign_group(self.client, self.group, "app-id", "42", "TV_OS", "build-id")

    def test_missing_build_retries_assignment(self):
        missing_build = subject.ApiError(
            404, "There is no resource of type 'builds' with id 'build-id'")
        self.client.call.side_effect = [missing_build, {}]

        self.assign_group()

        self.assertEqual(self.client.call.call_count, 2)
        self.sleep.assert_called_once_with(15)

    def test_persisted_assignment_after_server_error_needs_no_second_post(self):
        self.observed["_groups"].add("Testers")
        self.client.call.side_effect = subject.ApiError(500, "UNEXPECTED_ERROR")

        self.assign_group()

        self.client.call.assert_called_once()
        self.sleep.assert_not_called()

    def test_persistent_server_error_exhausts_retries(self):
        self.client.call.side_effect = subject.ApiError(500, "UNEXPECTED_ERROR")

        with self.assertRaises(subject.ApiError):
            self.assign_group()

        self.assertEqual(self.client.call.call_count, 5)
        self.assertEqual(self.sleep.call_count, 4)

    def test_unrelated_not_found_error_is_not_retried(self):
        self.client.call.side_effect = subject.ApiError(
            404, "There is no resource of type 'betaGroups' with id 'group-id'")

        with self.assertRaises(subject.ApiError):
            self.assign_group()

        self.client.call.assert_called_once()
        self.find_build.assert_not_called()
        self.sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
