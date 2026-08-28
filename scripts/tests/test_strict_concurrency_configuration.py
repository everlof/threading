import json
import subprocess
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).parents[2]
PROJECT = REPOSITORY / "Threading.xcodeproj/project.pbxproj"


class StrictConcurrencyConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        converted = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(PROJECT)],
            check=True,
            capture_output=True,
            text=True,
        )
        cls.objects = json.loads(converted.stdout)["objects"]

    def test_every_native_target_configuration_uses_complete_checking(self) -> None:
        missing = []
        for target in self.objects.values():
            if target.get("isa") != "PBXNativeTarget":
                continue
            configuration_list = self.objects[target["buildConfigurationList"]]
            for identifier in configuration_list["buildConfigurations"]:
                configuration = self.objects[identifier]
                actual = configuration["buildSettings"].get("SWIFT_STRICT_CONCURRENCY")
                if actual != "complete":
                    missing.append(f"{target['name']} {configuration['name']}: {actual!r}")

        self.assertEqual(missing, [])

    def test_extension_helper_generator_preserves_complete_checking(self) -> None:
        generator = (REPOSITORY / "scripts/add_helper_targets.rb").read_text(encoding="utf-8")

        self.assertIn("settings['SWIFT_STRICT_CONCURRENCY'] = 'complete'", generator)


if __name__ == "__main__":
    unittest.main()
