#!/usr/bin/env python3
"""The phone's half of the theme boundary.

The Mac's boundary is about constructing AppKit controls. iOS has a different failure: SwiftUI
hands a `List` or `Form` its *rows* from UIKit, so a screen can hide the scroll background, paint
the theme's ground behind it, and still draw every row on `secondarySystemGroupedBackground` with
`separator` hairlines between them. That is what shipped on Terminal Keys and its four editors,
Notifications, Diagnostics, Mac appearance, Ask for input and the issue report: a themed page with
a slab of system grey standing on it.

Five rules keep application-owned mobile chrome in one place:

1. `scrollContentBackground`, `listRowBackground` and `listRowSeparatorTint` belong to
   `MobileSettingsChrome.swift`. Feature code asks for `themedSettingsPage`, `themedSettingsRow`
   or `ThemedSettingsSection` instead, so there is one definition of what a themed row looks like.
2. A `Section` inside a `List` or `Form` must be a `ThemedSettingsSection`. A bare `Section` is
   exactly the construct that reintroduces the grey plate, and it does so silently. `Section`
   inside a `Menu` or `Picker` is untouched: that is system menu chrome with no plate to paint.
3. `confirmationDialog` belongs to `ThemedDialog.swift`. The bottom-anchored confirmation is
   the operating system's action sheet now, for the same reason the share sheet and the
   permission prompts are: presentation and trust belong to iOS there. Feature code still says
   `themedConfirmationDialog`, so there is one component for these prompts and one place that
   decides what they are made of.
4. The palette is handed across a presentation boundary by `mobileTheme(_:)`, never by
   `environment(\\.remoteTheme,)` alone. A sheet is its own hosting scene and inherits neither
   the palette nor the four presentation values read from it, so re-stating only the palette
   left the sheet with a system-tinted switch, a blue accent and the wrong keyboard appearance
   under an authored theme. That is what half the sheets in this app were doing.
5. Feature code never uses SwiftUI's `.borderedProminent` button style directly. That style
   chooses its own foreground independently of a Mac-supplied accent, so a pale accent can produce
   pale text on a pale fill. `MobileThemedActionButtonStyle` owns the accent foreground, authored
   radius, press response and disabled treatment as one construction.
"""

import pathlib
import re
import sys

MOBILE_SOURCE_ROOT = "Sources/ThreadingMobile"
CHROME_FILE = "MobileSettingsChrome.swift"
THEME_ENVIRONMENT_FILE = "MobileThemeEnvironment.swift"
DIALOG_FILE = "ThemedDialog.swift"

PALETTE_INJECTION = re.compile(r"environment\s*\(\s*\\\.remoteTheme\b")

RESERVED_MODIFIERS = (
    "scrollContentBackground",
    "listRowBackground",
    "listRowSeparatorTint",
)

SYSTEM_PRESENTATION = re.compile(r"\.confirmationDialog\s*\(")
SYSTEM_PROMINENT_BUTTON = re.compile(
    r"\.buttonStyle\s*\(\s*\.borderedProminent\s*\)"
)

LIST_OPENER = re.compile(r"\bList\s*(\([^()]*\))?\s*$")
FORM_OPENER = re.compile(r"\bForm\s*(\([^()]*\))?\s*$")
MENU_OPENER = re.compile(
    r"(\bMenu\s*(\([^()]*\))?|\.contextMenu\s*|\bPicker\s*\([^()]*\))\s*$"
)
SECTION_TOKEN = re.compile(r"(?<![\w.])Section\s*[({]")


def strip_swift_noise(source: str) -> str:
    """Blank out comments and string literals so braces inside them are not counted."""
    out = []
    index = 0
    length = len(source)
    while index < length:
        char = source[index]
        pair = source[index : index + 2]
        if pair == "//":
            end = source.find("\n", index)
            end = length if end == -1 else end
            out.append(" " * (end - index))
            index = end
            continue
        if pair == "/*":
            end = source.find("*/", index + 2)
            end = length if end == -1 else end + 2
            out.append("".join(c if c == "\n" else " " for c in source[index:end]))
            index = end
            continue
        if source[index : index + 3] == '"""':
            end = source.find('"""', index + 3)
            end = length if end == -1 else end + 3
            out.append("".join(c if c == "\n" else " " for c in source[index:end]))
            index = end
            continue
        if char == '"':
            cursor = index + 1
            while cursor < length:
                if source[cursor] == "\\":
                    cursor += 2
                    continue
                if source[cursor] == '"':
                    cursor += 1
                    break
                if source[cursor] == "\n":
                    break
                cursor += 1
            out.append(" " * (cursor - index))
            index = cursor
            continue
        out.append(char)
        index += 1
    return "".join(out)


def classify_brace(prefix: str) -> str:
    """What construct does the `{` at the end of `prefix` open?"""
    tail = prefix[-160:]
    if LIST_OPENER.search(tail):
        return "list"
    if FORM_OPENER.search(tail):
        return "form"
    if MENU_OPENER.search(tail):
        return "menu"
    return "other"


def enclosing_container(stack):
    for frame in reversed(stack):
        if frame != "other":
            return frame
    return None


def check_file(path: pathlib.Path, relative: str, failures: list) -> None:
    source = path.read_text(encoding="utf-8")
    scrubbed = strip_swift_noise(source)

    for match in SYSTEM_PROMINENT_BUTTON.finditer(scrubbed):
        line = scrubbed.count("\n", 0, match.start()) + 1
        failures.append(
            f"{relative}:{line}: error: borderedProminent chooses its own foreground; "
            "use MobileThemedActionButtonStyle so the accent fill and legible ink are one "
            "themed construction"
        )

    if path.name == CHROME_FILE:
        return

    for modifier in RESERVED_MODIFIERS:
        for match in re.finditer(rf"\b{modifier}\s*\(", scrubbed):
            line = scrubbed.count("\n", 0, match.start()) + 1
            failures.append(
                f"{relative}:{line}: error: {modifier} belongs to {CHROME_FILE}; "
                "use themedSettingsPage, themedSettingsRow or ThemedSettingsSection"
            )

    if path.name != DIALOG_FILE:
        for match in SYSTEM_PRESENTATION.finditer(scrubbed):
            line = scrubbed.count("\n", 0, match.start()) + 1
            failures.append(
                f"{relative}:{line}: error: confirmationDialog belongs to {DIALOG_FILE}; "
                "use themedConfirmationDialog"
            )

    if path.name != THEME_ENVIRONMENT_FILE:
        for match in PALETTE_INJECTION.finditer(scrubbed):
            line = scrubbed.count("\n", 0, match.start()) + 1
            failures.append(
                f"{relative}:{line}: error: hand the palette across a presentation boundary with "
                "mobileTheme(_:), so accent, toggle style, label colour and keyboard appearance "
                "cross with it"
            )

    stack = []
    for index, char in enumerate(scrubbed):
        if char == "{":
            stack.append(classify_brace(scrubbed[:index]))
        elif char == "}":
            if stack:
                stack.pop()
        elif char == "S" and SECTION_TOKEN.match(scrubbed, index):
            if enclosing_container(stack) in ("list", "form"):
                line = scrubbed.count("\n", 0, index) + 1
                failures.append(
                    f"{relative}:{line}: error: a Section inside a List or Form keeps UIKit's "
                    "grey row plate; use ThemedSettingsSection"
                )


def main(repository: str) -> int:
    root = pathlib.Path(repository) / MOBILE_SOURCE_ROOT
    if not root.is_dir():
        print(f"mobile-theme-boundary: missing {MOBILE_SOURCE_ROOT}", file=sys.stderr)
        return 1

    failures: list = []
    for path in sorted(root.rglob("*.swift")):
        check_file(path, str(path.relative_to(repository)), failures)

    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
