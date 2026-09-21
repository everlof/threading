"""Structural tripwires for the local release driver's irreversible boundaries."""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
DRIVER = REPOSITORY / "scripts/publish_local_release.sh"
PUBLISHER = REPOSITORY / "scripts/publish_release.sh"


class LocalReleaseDriverTests(unittest.TestCase):

    def test_live_report_contract_is_checked_before_any_ref_can_move(self) -> None:
        source = DRIVER.read_text()
        probe = source.index('node "$ROOT/scripts/verify_report_deployment.mjs"')
        gate = source.index('"$ROOT/scripts/ci.sh" --mac-release')
        self.assertLess(probe, gate)
        release = (REPOSITORY / "scripts/release.sh").read_text()
        self.assertLess(release.index('node "$ROOT/scripts/verify_report_deployment.mjs"'),
                        release.index('say "Archiving $SCHEME ($CHANNEL)"'))

    def test_server_deploy_checks_the_candidate_before_mutation_and_live_service_after(self) -> None:
        service = REPOSITORY / "Service/ThreadingControlPlane"
        deploy = (service / "scripts/deploy-production.mjs").read_text()
        candidate = deploy.index('["scripts/verify-report-candidate.mjs"]')
        migration = deploy.index('"migrations", "apply"')
        upload = deploy.index('"wrangler", "deploy"')
        live = deploy.index('["scripts/verify-production.mjs"]')
        self.assertLess(candidate, migration)
        self.assertLess(migration, upload)
        self.assertLess(upload, live)
        self.assertIn('then(() => verifyShippingReportDeployment())',
                      (service / "scripts/verify-production.mjs").read_text())

    def test_the_driver_is_valid_bash(self) -> None:
        result = subprocess.run(
            ["bash", "-n", str(DRIVER)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_every_push_goes_through_the_nonrecursive_outer_ref_primitive(self) -> None:
        source = DRIVER.read_text()
        logical_source = source.replace("\\\n", " ")
        executable_lines = "\n".join(
            line for line in logical_source.splitlines() if not line.lstrip().startswith("#")
        )
        git_pushes = re.findall(r"^.*\bgit\b.*\bpush\b.*$", executable_lines, re.MULTILINE)

        self.assertEqual(len(git_pushes), 1, git_pushes)
        self.assertIn("-c submodule.recurse=false", git_pushes[0])
        self.assertIn("--recurse-submodules=no", git_pushes[0])
        self.assertNotIn("--force", git_pushes[0])
        self.assertNotIn("--tags", git_pushes[0])
        self.assertIn(
            'push_outer_ref "$HEAD_COMMIT:refs/heads/$RELEASE_BRANCH"',
            source,
        )
        self.assertIn('push_outer_ref "refs/tags/$TAG:refs/tags/$TAG"', source)

    def test_the_tag_is_annotated_and_ci_cannot_race_the_local_publisher(self) -> None:
        source = DRIVER.read_text()
        quality_gate = source.index('"$ROOT/scripts/ci.sh"')
        snapshot_check = source.index("assert_release_snapshot", quality_gate)
        credential_recheck = source.index(
            'say "Rechecking release credentials before publishing refs"'
        )
        second_snapshot_check = source.index(
            "assert_release_snapshot", credential_recheck
        )
        branch_push = source.index(
            'push_outer_ref "$HEAD_COMMIT:refs/heads/$RELEASE_BRANCH"'
        )
        disable = source.rindex('gh workflow disable "$RELEASE_WORKFLOW"')
        tag_push = source.index('push_outer_ref "refs/tags/$TAG:refs/tags/$TAG"')
        publish = source.rindex(
            'THREADING_SKIP_RELEASE_CHECKS=1 "$ROOT/scripts/publish_release.sh"'
        )
        restore = source.rindex("restore_release_workflow \\")

        self.assertIn(
            'git -C "$ROOT" tag -a "$TAG" -m "Threading $VERSION" "$HEAD_COMMIT"',
            source,
        )
        self.assertLess(quality_gate, snapshot_check)
        self.assertLess(snapshot_check, credential_recheck)
        self.assertLess(credential_recheck, second_snapshot_check)
        self.assertLess(second_snapshot_check, branch_push)
        self.assertLess(disable, tag_push)
        self.assertLess(tag_push, publish)
        self.assertLess(publish, restore)

    def test_the_direct_distribution_gate_is_explicitly_mac_only(self) -> None:
        driver = DRIVER.read_text()
        ci = (REPOSITORY / "scripts/ci.sh").read_text()
        test_runner = (REPOSITORY / "scripts/test.sh").read_text()

        self.assertNotIn('"$ROOT/scripts/test.sh"', driver)
        self.assertIn('"$ROOT/scripts/ci.sh" --mac-release', driver)
        self.assertEqual(driver.count('"$ROOT/scripts/ci.sh" --mac-release'), 1)
        self.assertIn('mac_test_level=fast', ci)
        self.assertRegex(ci, r'if \[\[ "\$\{include_mobile\}" == "0" \]\]; then\s+mac_test_level=mac-all')
        self.assertIn('"${script_directory}/test.sh" "${mac_test_level}"', ci)
        self.assertIn('SWIFT_STRICT_CONCURRENCY=complete', ci)
        self.assertIn('--mac-release) include_mobile=0', ci)
        self.assertIn('if [[ "${include_mobile}" == "1" ]]', ci)
        self.assertIn('all|mac-all) test_plan="Threading-All"', test_runner)
        self.assertIn('if [[ "${level}" == "all"', test_runner)

    def test_shipping_archive_forces_hardened_runtime_on_every_target(self) -> None:
        release = (REPOSITORY / "scripts/release.sh").read_text()
        archive = release[
            release.index('run_xcodebuild "archive"') : release.index('[[ -d "$ARCHIVE" ]]')
        ]

        self.assertIn("ENABLE_HARDENED_RUNTIME=YES", archive)

    def test_the_tested_commit_cannot_be_replaced_during_the_long_gate(self) -> None:
        source = DRIVER.read_text()
        function = source[source.index("assert_release_snapshot() {") :]

        self.assertIn('[[ "$current_commit" == "$HEAD_COMMIT" ]]', function)
        self.assertIn("status --porcelain=v1 --untracked-files=all", function)
        self.assertGreaterEqual(source.count("assert_release_snapshot"), 4)

    def test_volatile_credentials_are_rechecked_before_the_first_ref_moves(self) -> None:
        source = DRIVER.read_text()

        self.assertGreaterEqual(source.count("assert_release_credentials"), 3)
        credential_recheck = source.index(
            'say "Rechecking release credentials before publishing refs"'
        )
        branch_push = source.index(
            'push_outer_ref "$HEAD_COMMIT:refs/heads/$RELEASE_BRANCH"'
        )
        self.assertLess(credential_recheck, branch_push)

    def test_a_partial_remote_publish_is_retryable(self) -> None:
        source = PUBLISHER.read_text()
        self.assertIn(
            'release_version_is_publishable "$CHANNEL" "$VERSION" "$TAG"',
            source,
        )


if __name__ == "__main__":
    unittest.main()
