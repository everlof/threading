#!/usr/bin/env python3
"""Contract tests for the repository-root development launcher."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]


class DevLauncherTests(unittest.TestCase):
    def test_fresh_launch_uses_one_new_home_for_foundation_and_children(self) -> None:
        with tempfile.TemporaryDirectory(prefix="threading-dev-launcher-") as temporary:
            root = Path(temporary)
            checkout = root / "checkout"
            service = checkout / "Service" / "ThreadingControlPlane"
            fake_bin = root / "bin"
            service.mkdir(parents=True)
            fake_bin.mkdir()
            shutil.copy2(REPOSITORY / "dev", checkout / "dev")
            normal_home_marker = checkout / ".build" / "dev" / "home" / "kept.txt"
            normal_home_marker.parent.mkdir(parents=True)
            normal_home_marker.write_text("normal development state\n", encoding="utf-8")

            self.make_command(
                fake_bin,
                "node",
                """
                if [[ "${1:-}" == "--version" ]]; then
                  printf 'v22.0.0\\n'
                  exit 0
                fi
                sleep 1
                """,
            )
            self.make_command(fake_bin, "npm", "exit 0")
            self.make_command(fake_bin, "curl", "exit 0")
            self.make_command(fake_bin, "ps", "printf '424242\\n'")
            self.make_command(
                fake_bin,
                "xcodebuild",
                """
                derived_data=""
                while (($#)); do
                  if [[ "$1" == "-derivedDataPath" ]]; then
                    shift
                    derived_data="$1"
                  fi
                  shift
                done
                mkdir -p "${derived_data}/Build/Products/Debug/Threading.app"
                """,
            )
            self.make_command(fake_bin, "xcrun", "exit 0")
            self.make_command(
                fake_bin,
                "open",
                "printf '%s\\n' \"$@\" > \"${DEV_TEST_OPEN_CAPTURE}\"",
            )

            capture = root / "open-arguments.txt"
            derived_data = root / "DerivedData"
            environment = os.environ.copy()
            environment.pop("THREADING_DEV_HOME", None)
            environment["PATH"] = f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["DEV_TEST_OPEN_CAPTURE"] = str(capture)
            environment["THREADING_DEV_DERIVED_DATA"] = str(derived_data)

            result = subprocess.run(
                [str(checkout / "dev"), "--fresh", "--no-ios"],
                cwd=checkout,
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = capture.read_text(encoding="utf-8").splitlines()
            fixed_home = self.environment_value(arguments, "CFFIXED_USER_HOME")
            child_home = self.environment_value(arguments, "HOME")
            self.assertEqual(child_home, fixed_home)
            self.assertTrue(Path(fixed_home).is_dir())
            self.assertEqual(list(Path(fixed_home).iterdir()), [])
            self.assertEqual(
                Path(fixed_home).parent,
                checkout / ".build" / "dev" / "fresh-homes",
            )
            self.assertEqual(
                normal_home_marker.read_text(encoding="utf-8"),
                "normal development state\n",
            )
            self.assertIn(f"Fresh macOS home: {fixed_home}", result.stdout)
            self.assertEqual(
                arguments[-1],
                str(derived_data / "Build" / "Products" / "Debug" / "Threading.app"),
            )

    def test_fresh_refuses_modes_that_do_not_launch_the_mac_app(self) -> None:
        result = subprocess.run(
            [str(REPOSITORY / "dev"), "--fresh", "--no-mac"],
            cwd=REPOSITORY,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--fresh requires the macOS app", result.stderr)

    def test_fresh_refuses_a_reused_home(self) -> None:
        environment = os.environ.copy()
        environment["THREADING_DEV_HOME"] = "/tmp/threading-existing-dev-home"
        result = subprocess.run(
            [str(REPOSITORY / "dev"), "--fresh", "--no-ios"],
            cwd=REPOSITORY,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--fresh cannot be combined with THREADING_DEV_HOME", result.stderr)

    @staticmethod
    def environment_value(arguments: list[str], name: str) -> str:
        prefix = f"{name}="
        matches = [
            argument.removeprefix(prefix)
            for argument in arguments
            if argument.startswith(prefix)
        ]
        if len(matches) != 1:
            raise AssertionError(f"expected exactly one {name} assignment, got {matches}")
        return matches[0]

    @staticmethod
    def make_command(directory: Path, name: str, body: str) -> None:
        command = directory / name
        command.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            + textwrap.dedent(body).strip()
            + "\n",
            encoding="utf-8",
        )
        command.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
