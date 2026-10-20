"""The GPL proxy helper ships without its source, so the source has to ship beside it.

The on-demand ProxyPlugin carries threading-proxyd; Threading.app carries its notices. The
corresponding source is offered from
the GitHub release the app is downloaded from (docs/architecture/releasing.md, "The proxy
helper's source"). Each link in that chain is a different file, and losing any one of them is
silent: the app still builds, installs and updates.
"""

import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest


REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
ARCHIVER = REPOSITORY / "scripts/archive_proxy_source.sh"
VERSION = "0.0.0"
ASSET = f"threading-proxyd-source-{VERSION}"


class ProxySourceDistributionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def archive(self, script: pathlib.Path, commit: str = "HEAD") -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(script), commit, VERSION, str(self.root)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_archive_of_head_is_the_verified_proxy_tree(self) -> None:
        result = self.archive(ARCHIVER)

        self.assertEqual(result.returncode, 0, result.stderr)
        archive = pathlib.Path(result.stdout.strip())
        self.assertEqual(archive.resolve(), self.root.resolve() / f"{ASSET}.tar.gz")
        with tarfile.open(archive) as contents:
            names = contents.getnames()
        self.assertEqual({name.split("/")[0] for name in names}, {ASSET})
        self.assertIn(f"{ASSET}/CMakeLists.txt", names)
        self.assertIn(f"{ASSET}/third_party/manifest.json", names)
        self.assertIn(f"{ASSET}/tools/apple_certificate.py", names)
        # The check directory is the archiver's own; nothing but the archive is left behind.
        self.assertEqual([path.name for path in self.root.iterdir()], [archive.name])

    def test_archive_that_fails_provenance_is_removed(self) -> None:
        repository = self.root / "repository"
        (repository / "scripts").mkdir(parents=True)
        (repository / "Targets/ProxyHost/tests").mkdir(parents=True)
        shutil.copy2(ARCHIVER, repository / "scripts" / ARCHIVER.name)
        (repository / "Targets/ProxyHost/tests/provenance.py").write_text(
            "raise SystemExit('a dependency archive is missing')\n", encoding="utf-8"
        )
        environment = {
            **os.environ,
            "GIT_AUTHOR_NAME": "test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
        }
        for command in (["init", "-q"], ["add", "."], ["commit", "-q", "-m", "fixture"]):
            # No hooks: the developer's global ones (secret scan, LFS) have no business here.
            subprocess.run(
                ["git", "-C", str(repository), "-c", "core.hooksPath=/dev/null", *command],
                check=True,
                env=environment,
            )

        result = self.archive(repository / "scripts" / ARCHIVER.name)

        self.assertEqual(result.returncode, 1)
        self.assertIn("does not verify", result.stderr)
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["repository"])

    def test_release_archives_the_source_and_every_publisher_attaches_it(self) -> None:
        release = (REPOSITORY / "scripts/release.sh").read_text(encoding="utf-8")
        publisher = (REPOSITORY / "scripts/publish_release.sh").read_text(encoding="utf-8")
        nightly = (REPOSITORY / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        nightly_asset = '"build/release/threading-proxyd-source-$THREADING_VERSION.tar.gz"'

        self.assertTrue(
            'archive_proxy_source.sh" "$SOURCE_COMMIT" "$version" "$BUILD_DIR"' in release,
            "release.sh does not archive the proxy source beside the zip",
        )
        self.assertTrue(
            'readonly PROXY_SOURCE="$BUILD_DIR/threading-proxyd-source-$VERSION.tar.gz"' in publisher,
            "publish_release.sh does not name the archive release.sh writes",
        )
        self.assertTrue(
            'gh release create "$TAG" "$ZIP" "$PROXY_SOURCE"' in publisher,
            "a new release is created without the proxy source",
        )
        self.assertTrue(
            'gh release upload "$TAG" "$ZIP" "$PROXY_SOURCE"' in publisher,
            "an existing release is updated without the proxy source",
        )
        # Once for a new rolling release, once for an existing one.
        self.assertEqual(nightly.count(nightly_asset), 2, "a nightly is published without its source")

    def test_bundled_notice_names_the_published_asset(self) -> None:
        notice = (REPOSITORY / "Legal/THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")

        self.assertIn("`threading-proxyd-source-<version>.tar.gz`", notice)
        self.assertIn("<https://github.com/everlof/threading/releases>", notice)

    def test_certificate_tool_is_embedded_in_the_signed_proxy_plugin(self) -> None:
        process = (REPOSITORY / "Sources/Threading/Core/Proxy/ProxyProcess.swift").read_text(
            encoding="utf-8"
        )
        trust = (REPOSITORY / "Sources/Threading/Core/Proxy/ProxyHelperTrust.swift").read_text(
            encoding="utf-8"
        )
        embed = (REPOSITORY / "scripts/embed_proxy_helper.sh").read_text(encoding="utf-8")
        project = (REPOSITORY / "Threading.xcodeproj/project.pbxproj").read_text(encoding="utf-8")

        self.assertIn("ProxyHelperTrust.availableAssets()", process)
        self.assertIn('Contents/Resources/ProxyTools/apple_certificate.py', trust)
        self.assertIn('proxy_tools="${proxy_resources}/ProxyTools"', embed)
        self.assertIn('"$proxy_tools/apple_certificate.py"', embed)
        self.assertIn('cp "$proxy_source/third_party/licenses/"* "$proxy_legal/"', embed)
        self.assertIn("Build and Embed Proxy Payload", project)
        self.assertIn("Prune Legacy Proxy Payload", project)


if __name__ == "__main__":
    unittest.main()
