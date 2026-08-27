import pathlib
import unittest


REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


class MobileTestGateTests(unittest.TestCase):
    def text(self, relative_path: str) -> str:
        return (REPOSITORY / relative_path).read_text(encoding="utf-8")

    def test_full_runner_owns_the_lane_and_selects_the_whole_target(self) -> None:
        runner = self.text("scripts/test-mobile.sh")

        self.assertIn('source "${script_directory}/coresimulator_lane_lock.sh"', runner)
        self.assertIn('threading_acquire_coresimulator_lane "mobile unit tests"', runner)
        self.assertIn("-scheme ThreadingMobile", runner)
        self.assertIn("test \\\n", runner)
        self.assertNotIn("-only-testing:", runner)

    def test_required_gates_invoke_the_full_mobile_runner(self) -> None:
        invocation = '"${script_directory}/test-mobile.sh"'

        self.assertIn(invocation, self.text("scripts/test.sh"))
        self.assertIn(invocation, self.text("scripts/ci.sh"))

    def test_connectivity_lane_remains_a_focused_subset(self) -> None:
        connectivity = self.text("scripts/test-connectivity.sh")

        self.assertIn("-only-testing:ThreadingMobileTests/", connectivity)


if __name__ == "__main__":
    unittest.main()
