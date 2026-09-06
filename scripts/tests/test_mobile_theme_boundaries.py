from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
CHECKER = REPOSITORY / "scripts/check_mobile_theme_boundaries.py"


class MobileThemeBoundaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.mobile = self.root / "Sources/ThreadingMobile"
        self.mobile.mkdir(parents=True)
        (self.mobile / "MobileSettingsChrome.swift").write_text(
            "\n".join([
                "struct ThemedSettingsSection: View {",
                "    var body: some View {",
                "        Section { content }",
                "            .listRowBackground(theme.panel)",
                "            .listRowSeparatorTint(theme.divider)",
                "    }",
                "}",
            ]),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, name: str, lines: list[str]) -> None:
        (self.mobile / name).write_text("\n".join(lines) + "\n", encoding="utf-8")

    def run_checker(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CHECKER), str(self.root)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_a_themed_settings_screen_passes(self) -> None:
        self.write("Settings.swift", [
            "struct Settings: View {",
            "    var body: some View {",
            "        List {",
            "            ThemedSettingsSection {",
            "                Text(\"Keys\")",
            "            }",
            "        }",
            "        .themedSettingsPage(theme)",
            "    }",
            "}",
        ])
        self.assertEqual(self.run_checker().returncode, 0)

    def test_a_bare_section_inside_a_list_fails(self) -> None:
        self.write("Settings.swift", [
            "struct Settings: View {",
            "    var body: some View {",
            "        List {",
            "            Section {",
            "                Text(\"Keys\")",
            "            }",
            "        }",
            "    }",
            "}",
        ])
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("ThemedSettingsSection", result.stderr)

    def test_a_bare_section_nested_under_a_condition_still_fails(self) -> None:
        self.write("Settings.swift", [
            "struct Settings: View {",
            "    var body: some View {",
            "        Form {",
            "            if let message {",
            "                Section(\"Trouble\") {",
            "                    Text(message)",
            "                }",
            "            }",
            "        }",
            "    }",
            "}",
        ])
        self.assertEqual(self.run_checker().returncode, 1)

    def test_a_section_inside_a_menu_is_left_alone(self) -> None:
        self.write("Chrome.swift", [
            "struct Chrome: View {",
            "    var body: some View {",
            "        Menu {",
            "            Section(\"Organize\") {",
            "                Button(\"Rename\") {}",
            "            }",
            "        } label: {",
            "            Text(\"More\")",
            "        }",
            "    }",
            "}",
        ])
        self.assertEqual(self.run_checker().returncode, 0)

    def test_a_menu_inside_a_list_row_is_left_alone(self) -> None:
        self.write("Settings.swift", [
            "struct Settings: View {",
            "    var body: some View {",
            "        List {",
            "            ThemedSettingsSection {",
            "                Menu {",
            "                    Section(\"Organize\") {",
            "                        Button(\"Rename\") {}",
            "                    }",
            "                } label: {",
            "                    Text(\"More\")",
            "                }",
            "            }",
            "        }",
            "    }",
            "}",
        ])
        self.assertEqual(self.run_checker().returncode, 0)

    def test_hand_rolled_row_chrome_fails(self) -> None:
        self.write("Settings.swift", [
            "struct Settings: View {",
            "    var body: some View {",
            "        List(items) { item in",
            "            Row(item)",
            "                .listRowBackground(Color.gray)",
            "        }",
            "        .scrollContentBackground(.hidden)",
            "    }",
            "}",
        ])
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("listRowBackground", result.stderr)
        self.assertIn("scrollContentBackground", result.stderr)

    def test_handing_only_the_palette_to_a_sheet_fails(self) -> None:
        self.write("Detail.swift", [
            "struct Detail: View {",
            "    var body: some View {",
            "        Text(\"Body\")",
            "            .sheet(isPresented: $showsEditor) {",
            "                Editor()",
            "                    .environment(\\.remoteTheme, theme)",
            "            }",
            "    }",
            "}",
        ])
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("mobileTheme", result.stderr)

    def test_handing_the_whole_theme_to_a_sheet_passes(self) -> None:
        self.write("Detail.swift", [
            "struct Detail: View {",
            "    var body: some View {",
            "        Text(\"Body\")",
            "            .sheet(isPresented: $showsEditor) {",
            "                Editor()",
            "                    .mobileTheme(theme)",
            "            }",
            "    }",
            "}",
        ])
        self.assertEqual(self.run_checker().returncode, 0)

    def test_the_theme_environment_file_may_define_the_injection(self) -> None:
        self.write("MobileThemeEnvironment.swift", [
            "extension View {",
            "    func mobileTheme(_ theme: RemoteThemePalette) -> some View {",
            "        environment(\\.remoteTheme, theme)",
            "            .tint(theme.accent)",
            "    }",
            "}",
        ])
        self.assertEqual(self.run_checker().returncode, 0)

    def test_a_raw_prominent_button_fails(self) -> None:
        self.write("Usage.swift", [
            "struct Usage: View {",
            "    var body: some View {",
            "        Button(\"Use Reset\") { useReset() }",
            "            .buttonStyle(",
            "                .borderedProminent",
            "            )",
            "            .tint(theme.accent)",
            "    }",
            "}",
        ])
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("MobileThemedActionButtonStyle", result.stderr)

    def test_a_themed_action_button_passes(self) -> None:
        self.write("Usage.swift", [
            "struct Usage: View {",
            "    var body: some View {",
            "        Button(\"Use Reset\") { useReset() }",
            "            .buttonStyle(MobileThemedActionButtonStyle(",
            "                kind: .primary,",
            "                theme: theme",
            "            ))",
            "    }",
            "}",
        ])
        self.assertEqual(self.run_checker().returncode, 0)

    def test_the_settings_chrome_exception_does_not_hide_a_raw_prominent_button(self) -> None:
        self.write("MobileSettingsChrome.swift", [
            "struct ThemedSettingsSection: View {",
            "    var body: some View {",
            "        Button(\"Apply\") {}",
            "            .buttonStyle(.borderedProminent)",
            "            .listRowBackground(theme.panel)",
            "    }",
            "}",
        ])
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("MobileThemedActionButtonStyle", result.stderr)

    def test_the_names_are_read_as_source_rather_than_prose(self) -> None:
        self.write("Settings.swift", [
            "/// A note about Section inside a List, .listRowBackground(x), and",
            "/// .buttonStyle(.borderedProminent).",
            "struct Settings: View {",
            "    let hint = \"Section { }, .scrollContentBackground(.hidden), and .borderedProminent\"",
            "    var body: some View {",
            "        List {",
            "            ThemedSettingsSection { Text(hint) }",
            "        }",
            "    }",
            "}",
        ])
        self.assertEqual(self.run_checker().returncode, 0)


if __name__ == "__main__":
    unittest.main()
