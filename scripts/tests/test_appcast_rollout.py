"""Immediate release eligibility, including items retained from a previously phased feed."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("rollout", ROOT / "scripts/remove_appcast_rollout.py")
rollout = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rollout)
HEADER = b'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
PHASE = b"<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>"
FOOTER = b"</channel></rss>"


class RolloutTests(unittest.TestCase):
    def test_removes_only_real_metadata_preserving_notes_and_enclosure_bytes(self):
        quoted = b"<![CDATA[Release notes quote " + PHASE + b" verbatim.]]>"
        item = (b"<item><title>0.8.0</title>" + PHASE + b"<description>" + quoted
                + b'</description><enclosure url="https://example.invalid/app.zip" '
                + b'sparkle:edSignature="unchanged"/></item>')
        source = HEADER + item + b"<item>" + PHASE + b"</item>" + FOOTER
        expected = HEADER + item.replace(PHASE, b"", 1) + b"<item></item>" + FOOTER
        result, count = rollout.remove_rollouts(source)
        self.assertEqual(count, 2)
        self.assertEqual(result, expected)
        self.assertEqual(rollout.remove_rollouts(result), (expected, 0))

    def test_namespace_alias_and_self_closing_metadata(self):
        source = (b'<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                  b"<channel><item><s:phasedRolloutInterval /></item></channel></rss>")
        result, count = rollout.remove_rollouts(source)
        self.assertEqual(count, 1)
        self.assertEqual(result, source.replace(b"<s:phasedRolloutInterval />", b""))

    def test_malformed_feed_or_unexpected_metadata_refuses_to_rewrite(self):
        for source in (HEADER + b"<item>" + PHASE, HEADER + PHASE + FOOTER,
                       b'<!DOCTYPE rss SYSTEM "https://example.invalid/dtd"><rss/>',
                       HEADER + b'<item><sparkle:phasedRolloutInterval value=">"/></item>' + FOOTER):
            with self.subTest(source=source), self.assertRaises((ValueError, rollout.expat.ExpatError)):
                rollout.remove_rollouts(source)

    def test_check_mode_never_modifies_the_signed_feed(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "appcast.xml"
            original = HEADER + b"<item>" + PHASE + b"</item>" + FOOTER
            path.write_bytes(original)
            result = subprocess.run(
                ["python3", str(ROOT / "scripts/remove_appcast_rollout.py"), "--check", str(path)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_bytes(), original)

    def test_generator_clears_seeded_rollouts_and_never_passes_a_phase_option(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            for directory in ("scripts", "build/release", "Sources/Threading/Resources", "tools"):
                (root / directory).mkdir(parents=True)
            for name in ("generate_appcast.sh", "remove_appcast_rollout.py"):
                shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
            (root / "build/release/Threading-0.8.0.zip").write_bytes(b"archive fixture")
            (root / "notes.md").write_text("Release notes")
            seed = root / "seed.xml"
            seed.write_bytes(HEADER + b"<item>" + PHASE + b"</item>" + FOOTER)
            tools = root / "tools"
            generator = tools / "generate_appcast"
            generator.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
assert "--phased-rollout-interval" not in args
output = pathlib.Path(args[args.index("-o") + 1])
if output.exists():
    assert "phasedRolloutInterval" not in output.read_text()
channel = args[args.index("--channel") + 1] if "--channel" in args else ""
phase = "<sparkle:phasedRolloutInterval>1</sparkle:phasedRolloutInterval>" if os.environ.get("BAD_GENERATOR") else ""
output.write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item>
<sparkle:version>0.8.0</sparkle:version>
<description sparkle:format="markdown">Notes</description>
<enclosure url="https://example.invalid/Threading-0.8.0.zip" sparkle:edSignature="test"/>
''' + (f"<sparkle:channel>{channel}</sparkle:channel>" if channel else "") + phase + '''
</item>
</channel></rss>
<!-- sparkle-signatures:
edSignature: test
-->
''')
""")
            generator.chmod(0o755)
            verifier = tools / "sign_update"
            verifier.write_text("#!/bin/sh\nexit 0\n")
            verifier.chmod(0o755)
            environment = {
                **os.environ,
                "THREADING_VERSION": "0.8.0",
                "THREADING_SPARKLE_BIN": str(tools),
                "THREADING_SPARKLE_PRIVATE_KEY_FILE": str(root / "unused-fixture-key"),
                "THREADING_RELEASE_NOTES_FILE": str(root / "notes.md"),
                # A stale environment setting must not restore the former rollout.
                "THREADING_SPARKLE_PHASED_ROLLOUT_INTERVAL": "86400",
            }
            for channel in ("", "beta", "nightly"):
                for seeded in (False, True):
                    with self.subTest(channel=channel, seeded=seeded):
                        args = ["bash", str(root / "scripts/generate_appcast.sh")]
                        if channel:
                            args += ["--channel", channel]
                        if seeded:
                            args += ["--seed", seed.as_uri()]
                        result = subprocess.run(args, env=environment, capture_output=True, text=True)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run(
                ["bash", str(root / "scripts/generate_appcast.sh")],
                env={**environment, "BAD_GENERATOR": "1"}, capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("still delays updates", result.stderr)


if __name__ == "__main__":
    unittest.main()
