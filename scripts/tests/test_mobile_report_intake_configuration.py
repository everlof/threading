import json
import plistlib
import subprocess
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).parents[2]
PROJECT = REPOSITORY / "Threading.xcodeproj/project.pbxproj"
INFO_PLIST = REPOSITORY / "Sources/ThreadingMobile-Info.plist"
PRODUCTION_INTAKE = "https://remote.threading.codes/v1/reports"


class MobileReportIntakeConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        converted = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(PROJECT)],
            check=True,
            capture_output=True,
            text=True,
        )
        cls.objects = json.loads(converted.stdout)["objects"]

    def test_info_plist_expands_the_reviewed_build_setting(self) -> None:
        with INFO_PLIST.open("rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(
            info["ThreadingReportIntakeURL"],
            "$(THREADING_REPORT_INTAKE_URL)",
        )

    def test_debug_is_off_and_release_names_the_private_worker(self) -> None:
        target = next(
            value
            for value in self.objects.values()
            if value.get("isa") == "PBXNativeTarget" and value.get("name") == "ThreadingMobile"
        )
        configuration_list = self.objects[target["buildConfigurationList"]]
        configurations = {
            self.objects[identifier]["name"]: self.objects[identifier]["buildSettings"]
            for identifier in configuration_list["buildConfigurations"]
        }

        self.assertEqual(configurations["Debug"]["THREADING_REPORT_INTAKE_URL"], "")
        self.assertEqual(
            configurations["Release"]["THREADING_REPORT_INTAKE_URL"],
            PRODUCTION_INTAKE,
        )


if __name__ == "__main__":
    unittest.main()
