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
        self.assertIn('push_outer_ref "HEAD:refs/heads/$RELEASE_BRANCH"', source)
        self.assertIn('push_outer_ref "refs/tags/$TAG:refs/tags/$TAG"', source)

    def test_the_tag_is_annotated_and_ci_cannot_race_the_local_publisher(self) -> None:
        source = DRIVER.read_text()
        disable = source.rindex('gh workflow disable "$RELEASE_WORKFLOW"')
        tag_push = source.index('push_outer_ref "refs/tags/$TAG:refs/tags/$TAG"')
        publish = source.rindex('"$ROOT/scripts/publish_release.sh"')
        restore = source.rindex("restore_release_workflow \\")

        self.assertIn('git -C "$ROOT" tag -a "$TAG"', source)
        self.assertLess(disable, tag_push)
        self.assertLess(tag_push, publish)
        self.assertLess(publish, restore)

    def test_a_partial_remote_publish_is_retryable(self) -> None:
        source = PUBLISHER.read_text()
        self.assertIn(
            'release_version_is_publishable "$CHANNEL" "$VERSION" "$TAG"',
            source,
        )


if __name__ == "__main__":
    unittest.main()
