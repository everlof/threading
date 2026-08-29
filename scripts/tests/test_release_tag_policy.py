"""The release tag grammar and version ordering, exercised through the shell library itself.

The rules live in bash because publishing does, and a rule that only runs inside a CI job on a
tag push is one nobody can try. These drive `scripts/release_tag_policy.sh` as a subprocess, so
what is asserted is the same code path publish_release.sh sources.
"""

from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
POLICY = REPOSITORY / "scripts/release_tag_policy.sh"


def run(*arguments: str, published: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(POLICY), *arguments],
        input=published,
        capture_output=True,
        text=True,
        check=False,
    )


def releases(*entries: tuple[str, bool]) -> str:
    """The shape `gh release list --json isPrerelease,tagName` produces."""
    return "".join(
        f"{'true' if is_prerelease else 'false'}\t{tag}\n" for tag, is_prerelease in entries
    )


class TagGrammarTests(unittest.TestCase):

    def test_a_v_tag_is_a_stable_release(self) -> None:
        result = run("describe", "v0.2.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "release 0.2.0")

    def test_a_beta_v_tag_is_a_beta_of_the_version_it_names(self) -> None:
        result = run("describe", "beta-v0.1.9")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "beta 0.1.9")

    def test_a_suffix_is_refused_because_sparkle_cannot_order_it(self) -> None:
        """`v0.2.0-beta1` is the shape everyone reaches for first, and it is the one that
        breaks: the version reaches SUStandardVersionComparator, which reads dotted digits and
        nothing else."""
        for tag in ("v0.2.0-beta", "v0.2.0-beta1", "v0.2.0rc1"):
            with self.subTest(tag=tag):
                self.assertNotEqual(run("describe", tag).returncode, 0)

    def test_other_near_misses_are_refused(self) -> None:
        for tag in ("beta-0.1.9", "0.1.9", "nightly", "v", "beta-v", "", "release-v0.1.0"):
            with self.subTest(tag=tag):
                self.assertNotEqual(run("describe", tag).returncode, 0)

    def test_every_channel_this_grammar_produces_is_one_release_sh_accepts(self) -> None:
        """release.sh validates --channel with a bash whitelist, so a channel this grammar can
        produce but that whitelist refuses fails in CI at publish time, after the tag is pushed,
        with nothing in Swift to have caught it."""
        release_script = (REPOSITORY / "scripts/release.sh").read_text()
        whitelist = re.search(r"^\s*(\S+(?:\|\S+)*)\)\s*;;\s*$", release_script, re.MULTILINE)
        self.assertIsNotNone(whitelist, "release.sh no longer has a channel case statement")
        accepted = set(whitelist.group(1).split("|"))
        self.assertIn("release", accepted, "the parsed line is not the channel whitelist")

        for tag in ("v1.0.0", "beta-v0.9.9"):
            with self.subTest(tag=tag):
                channel = run("describe", tag).stdout.split()[0]
                self.assertIn(channel, accepted)


class VersionOrderingTests(unittest.TestCase):

    def test_ordering_is_numeric_rather_than_lexical(self) -> None:
        self.assertEqual(run("compare", "0.1.10", "0.1.9").stdout.strip(), "1")
        self.assertEqual(run("compare", "0.1.9", "0.1.10").stdout.strip(), "-1")

    def test_a_missing_component_is_zero(self) -> None:
        self.assertEqual(run("compare", "1.2", "1.2.0").stdout.strip(), "0")
        self.assertEqual(run("compare", "1.2", "1.2.1").stdout.strip(), "-1")

    def test_a_zero_padded_component_is_decimal_not_octal(self) -> None:
        """The nightly version is built from `date` output with padding stripped for exactly
        this reason; a padded component reaching here must still compare as the number it looks
        like."""
        self.assertEqual(run("compare", "2026.08.09", "2026.8.9").stdout.strip(), "0")

    def test_a_beta_below_its_stable_orders_correctly(self) -> None:
        """The allocation rule in one assertion: 0.1.9x sits above the stable already out and
        below the stable it precedes, so a tester is offered the beta and then offered the
        release that supersedes it."""
        self.assertEqual(run("compare", "0.1.90", "0.1.0").stdout.strip(), "1")
        self.assertEqual(run("compare", "0.1.90", "0.2.0").stdout.strip(), "-1")

    def test_a_beta_sharing_its_stables_version_is_not_newer(self) -> None:
        """Which is the whole defect: equal is not newer, so Sparkle offers that tester
        nothing and they sit on the prerelease forever."""
        self.assertEqual(run("compare", "0.2.0", "0.2.0").stdout.strip(), "0")

    def test_a_version_that_is_not_dotted_digits_is_refused(self) -> None:
        for version in ("0.2.0-beta", "v0.2.0", "", "1.2.x"):
            with self.subTest(version=version):
                self.assertNotEqual(run("compare", version, "1.0.0").returncode, 0)


class VersionAllocationTests(unittest.TestCase):
    """The rule that keeps a prerelease from becoming a dead end.

    Both directions matter and they fail differently: a beta at or below the newest stable is
    offered to nobody, and a stable at or below the newest beta strands the people who took
    that beta on a build that outranks its own successor.
    """

    def test_a_first_release_has_nothing_to_collide_with(self) -> None:
        self.assertEqual(run("publishable", "release", "0.1.0", published="").returncode, 0)

    def test_a_beta_above_the_newest_stable_is_allowed(self) -> None:
        published = releases(("v0.1.0", False))
        self.assertEqual(run("publishable", "beta", "0.1.90", published=published).returncode, 0)

    def test_a_beta_sharing_the_stables_version_is_refused(self) -> None:
        published = releases(("v0.2.0", False))
        result = run("publishable", "beta", "0.2.0", published=published)
        self.assertEqual(result.returncode, 1)
        self.assertIn("offer it to nobody", result.stderr)

    def test_a_beta_below_the_newest_stable_is_refused(self) -> None:
        published = releases(("v0.2.0", False))
        self.assertEqual(run("publishable", "beta", "0.1.90", published=published).returncode, 1)

    def test_a_stable_at_or_below_a_published_beta_is_refused(self) -> None:
        published = releases(("v0.1.0", False), ("beta-v0.1.90", True))
        result = run("publishable", "release", "0.1.90", published=published)
        self.assertEqual(result.returncode, 1)
        self.assertIn("stranded", result.stderr)

    def test_the_stable_a_beta_preceded_is_allowed(self) -> None:
        published = releases(("v0.1.0", False), ("beta-v0.1.90", True))
        self.assertEqual(run("publishable", "release", "0.2.0", published=published).returncode, 0)

    def test_a_second_beta_must_be_above_the_first(self) -> None:
        published = releases(("v0.1.0", False), ("beta-v0.1.90", True))
        self.assertEqual(run("publishable", "beta", "0.1.90", published=published).returncode, 1)
        self.assertEqual(run("publishable", "beta", "0.1.91", published=published).returncode, 0)

    def test_the_rolling_nightly_tag_is_ignored(self) -> None:
        """Nightly has its own feed and its date version outranks every release, so letting it
        into this comparison would refuse every release forever."""
        published = releases(("v0.1.0", False), ("nightly", True))
        self.assertEqual(run("publishable", "release", "0.2.0", published=published).returncode, 0)

    def test_a_draft_is_the_callers_problem_not_this_rules(self) -> None:
        """Recorded rather than asserted on: publish_release.sh filters drafts out in its jq,
        because a draft serves nothing. This holds that the filter has to stay there."""
        published = releases(("v9.9.9", False))
        self.assertEqual(run("publishable", "release", "0.2.0", published=published).returncode, 1)

    def test_retrying_the_same_published_tag_is_allowed(self) -> None:
        """Release creation and feed upload are separate writes. A retry after the first one
        succeeded must reach the publisher's existing-release recovery path."""
        published = releases(("v0.1.0", False))
        result = run("publishable", "release", "0.1.0", "v0.1.0", published=published)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_another_tag_with_the_same_version_is_still_a_collision(self) -> None:
        published = releases(("v0.1.0", False))
        result = run("publishable", "release", "0.1.0", "v0.1.0-retry", published=published)
        self.assertEqual(result.returncode, 1)


class ChangelogNotesTests(unittest.TestCase):

    def test_exact_section_is_extracted_without_regex_portability(self) -> None:
        changelog = """# Changelog

## [Unreleased]

Not shipped.

## [0.1.0]

### Added

- First release.
- Stable notes.

## [0.0.9]

- Older notes.
"""
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as file:
            file.write(changelog)
            file.flush()
            result = run("notes", "0.1.0", file.name)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            "### Added\n\n- First release.\n- Stable notes.",
        )

    def test_missing_section_yields_no_notes(self) -> None:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as file:
            file.write("# Changelog\n\n## [0.1.0]\n\n- First release.\n")
            file.flush()
            result = run("notes", "9.9.9", file.name)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
