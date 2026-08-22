#!/usr/bin/env python3
"""Checks that first-party UI copy crosses the localization boundary.

The app deliberately uses readable English source strings as localization keys. This checker
therefore has two jobs:

* collect every statically-known key sent through L10n or through a UI helper which localizes;
* reject the common AppKit/control sinks when a new English literal bypasses that boundary.

It is intentionally a source check rather than an Xcode extraction step. The extension SDK and
several AppKit helpers are not visible to Apple's String(localized:) extractor, while this check
runs identically from Xcode, CI, and a package-only checkout.
"""

from __future__ import annotations

import argparse
import html.parser
import json
import pathlib
import re
import sys
from dataclasses import dataclass


APP_SOURCE_ROOTS = ("Sources/Threading",)
CATALOG_PATH = "Sources/Threading/Resources/Localizable.xcstrings"
MOBILE_SOURCE_ROOT = "Sources/ThreadingMobile"
MOBILE_CATALOG_PATH = "Sources/ThreadingMobile/Localizable.xcstrings"
MOBILE_INFO_CATALOG_PATH = "Sources/ThreadingMobile/ThreadingMobile-InfoPlist.xcstrings"
REMOTE_CLIENT_ROOT = "Sources/Threading/Resources/RemoteClient"
REMOTE_LOCALIZATION_SOURCES = (
    "Sources/Threading/Core/Remote/RemoteGitReviewBridge.swift",
    "Sources/Threading/Core/Remote/RemoteNotificationService.swift",
)

# These helpers translate their string arguments internally. Keeping them here makes their call
# sites as terse as AppKit's API while still requiring the source key to exist in the catalog.
LOCALIZING_CALLS: dict[str, tuple[str | int, ...]] = {
    "AppCommand": ("title", "detail"),
    "MCPToolGroup": ("title", "summary"),
    "MCPToolInfo": ("title", "detail"),
    "PreferencesFormBuilder.addSection": (0,),
    "PreferencesFormBuilder.addRow": ("label", "help"),
    "PreferencesFormBuilder.addNote": (0,),
    "SettingsUI.heading": (0,),
    "SettingsUI.caption": (0,),
    "SettingsUI.note": (0,),
    "SettingsUI.section": (0,),
    "SettingsUI.button": (0,),
    "SettingsUI.row": ("title", "subtitle"),
    "SettingsUI.detailRow": ("title", "detail"),
}

# Component Gallery is developer-facing UI, but still ships in the app. Its local helpers apply
# L10n at the rendering boundary.
LOCAL_FILE_HELPERS: dict[str, dict[str, tuple[str | int, ...]]] = {
    "Sources/Threading/UI/Preferences/SettingsPages.swift": {
        "terms": tuple(range(32)),
    },
    "Sources/Threading/UI/Preferences/ThemeColorEditor.swift": {
        "group": (0,),
    },
    "Sources/Threading/UI/Windows/MainWindowMCPTools.swift": {
        "authorizeBrowserAccess": ("purpose",),
        "withAuthorizedBrowser": ("purpose",),
        "confirmSensitiveBrowserAction": (0,),
    },
    "Sources/Threading/UI/Extensions/ComponentCustomizationGalleryFixture.swift": {
        "Story": ("title", "detail"),
    },
    "Sources/Threading/UI/Windows/ComponentGalleryWindowController.swift": {
        "section": (0, "note"),
        "story": (0, 1),
        "galleryToolbarButton": ("label",),
        "labelledControl": (0,),
        "labelledInline": (0,),
        "button": (0,),
        "column": ("title",),
    }
}

# Literal values reaching these APIs are always presentation copy. Symbols, identifiers, URLs,
# process arguments, and protocol strings deliberately do not appear in this list.
PRESENTATION_CALL_ARGUMENTS: dict[str, tuple[str | int, ...]] = {
    "NSTextField": ("labelWithString", "wrappingLabelWithString"),
    "ThemedButton": ("title", "accessibility"),
    "ThemedIconButton": ("accessibility",),
    "ThemedMenuItem": ("title", "subtitle"),
    "ThemedTabItemView": ("title",),
    "NSMenuItem": ("title",),
    "NSImage": ("accessibilityDescription",),
    "DisplayPaneItem": ("title", "subtitle"),
    "addButton": ("withTitle",),
    "addItem": ("withTitle",),
    "setAccessibilityLabel": (0,),
    "setAccessibilityHelp": (0,),
    "setAccessibilityTitle": (0,),
    "setAccessibilityValue": (0,),
    "ConversationRowView.notice": (0,),
    # Spell the type at the call site — `.init(…)` carries no call name to match on.
    "ConfirmationRequest": ("title", "message", "confirmTitle", "cancelTitle"),
    "ChoiceRequest": ("title", "message", "cancelTitle"),
    "ConfirmationOption": ("title",),
    "presentAlert": (0, 1, "title", "message"),
    "showReceipt": (0,),
}

PRESENTATION_ASSIGNMENTS = {
    "informativeText",
    "messageText",
    "placeholder",
    "placeholderString",
    "prompt",
    "stringValue",
    "title",
    "toolTip",
}


@dataclass(frozen=True, order=True)
class Finding:
    path: str
    line: int
    message: str


@dataclass(frozen=True)
class Call:
    name: str
    start: int
    end: int
    arguments: tuple[tuple[str | None, str, int], ...]


def swift_files(root: pathlib.Path) -> list[pathlib.Path]:
    result: list[pathlib.Path] = []
    for relative_root in APP_SOURCE_ROOTS:
        result.extend((root / relative_root).rglob("*.swift"))
    return sorted(result)


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def ignored_on_line(source: str, offset: int) -> bool:
    start = source.rfind("\n", 0, offset) + 1
    end = source.find("\n", offset)
    if end < 0:
        end = len(source)
    previous_end = max(0, start - 1)
    previous_start = source.rfind("\n", 0, previous_end) + 1
    return "localization-ignore:" in source[previous_start:end]


def skip_space_and_comments(source: str, index: int) -> int:
    while index < len(source):
        if source[index].isspace():
            index += 1
        elif source.startswith("//", index):
            newline = source.find("\n", index + 2)
            return len(source) if newline < 0 else skip_space_and_comments(source, newline + 1)
        elif source.startswith("/*", index):
            depth = 1
            index += 2
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        else:
            break
    return index


def string_end(source: str, start: int) -> int | None:
    """Returns the offset after a Swift string, including raw and multiline strings."""
    index = start
    hashes = 0
    while index < len(source) and source[index] == "#":
        hashes += 1
        index += 1
    if index >= len(source) or source[index] != '"':
        return None

    multiline = source.startswith('"""', index)
    delimiter = ('"""' if multiline else '"') + ("#" * hashes)
    index += 3 if multiline else 1
    escape = "\\" + ("#" * hashes)

    while index < len(source):
        if source.startswith(delimiter, index):
            return index + len(delimiter)
        if source.startswith(escape, index):
            # Skip the escaped scalar/delimiter. Interpolation is still part of the token.
            index += len(escape)
            if index < len(source):
                index += 1
        else:
            index += 1
    return None


def split_arguments(source: str, open_paren: int) -> tuple[int, tuple[tuple[str | None, str, int], ...]] | None:
    depth = 1
    index = open_paren + 1
    argument_start = index
    pieces: list[tuple[int, int]] = []

    while index < len(source):
        index = skip_space_and_comments(source, index)
        if index >= len(source):
            return None
        end = string_end(source, index)
        if end is not None:
            index = end
            continue
        if source[index] in "([{":
            depth += 1
        elif source[index] in ")]}":
            depth -= 1
            if depth == 0:
                pieces.append((argument_start, index))
                break
        elif source[index] == "," and depth == 1:
            pieces.append((argument_start, index))
            argument_start = index + 1
        index += 1
    else:
        return None

    arguments: list[tuple[str | None, str, int]] = []
    for start, end_offset in pieces:
        raw = source[start:end_offset]
        leading = len(raw) - len(raw.lstrip())
        value_start = start + leading
        stripped = raw.strip()
        if not stripped:
            continue
        label: str | None = None
        label_match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*", stripped)
        if label_match:
            label = label_match.group(1)
            value_start += label_match.end()
            stripped = stripped[label_match.end():].strip()
            value_start = source.find(stripped, value_start, end_offset) if stripped else value_start
        arguments.append((label, stripped, value_start))
    return index + 1, tuple(arguments)


def discover_calls(source: str) -> list[Call]:
    calls: list[Call] = []
    # A dotted identifier is sufficient here: the names of interest are all ordinary calls, and
    # argument parsing below handles nesting and multiline formatting.
    pattern = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_.]*)\s*\(")
    for match in pattern.finditer(source):
        if ignored_on_line(source, match.start()):
            continue
        open_paren = source.find("(", match.start(), match.end())
        parsed = split_arguments(source, open_paren)
        if parsed is None:
            continue
        end, arguments = parsed
        calls.append(Call(match.group(1), match.start(), end, arguments))
    return calls


def decode_string_token(token: str) -> str | None:
    hashes = len(token) - len(token.lstrip("#"))
    body = token[hashes:]
    multiline = body.startswith('"""')
    quote_count = 3 if multiline else 1
    suffix = quote_count + hashes
    if len(body) < quote_count * 2 or not token.endswith('"' * quote_count + "#" * hashes):
        return None
    value = body[quote_count:len(token) - suffix]

    interpolation_marker = "\\" + ("#" * hashes) + "("
    if interpolation_marker in value:
        return None

    if multiline:
        if value.startswith("\n"):
            value = value[1:]
        closing_line_start = value.rfind("\n")
        closing_indent = value[closing_line_start + 1:] if closing_line_start >= 0 else ""
        if closing_indent.strip():
            closing_indent = ""
        elif closing_line_start >= 0:
            value = value[:closing_line_start]
        if closing_indent:
            value = "\n".join(
                line[len(closing_indent):] if line.startswith(closing_indent) else line
                for line in value.split("\n")
            )
        value = re.sub(r"\\#*\n[ \t]*", "", value)

    if hashes:
        escape = "\\" + ("#" * hashes)
        value = value.replace(escape + '"', '"').replace(escape + "\\", "\\")
        value = value.replace(escape + "n", "\n").replace(escape + "t", "\t")
        return value

    replacements = {
        r"\\": "\\",
        r"\"": '"',
        r"\n": "\n",
        r"\r": "\r",
        r"\t": "\t",
        r"\0": "\0",
    }
    for escaped, decoded in replacements.items():
        value = value.replace(escaped, decoded)
    return value


def static_string(expression: str) -> str | None:
    values: list[str] = []
    index = 0
    needs_string = True
    while True:
        index = skip_space_and_comments(expression, index)
        if index >= len(expression):
            return "".join(values) if values and not needs_string else None
        if needs_string:
            end = string_end(expression, index)
            if end is None:
                return None
            value = decode_string_token(expression[index:end])
            if value is None:
                return None
            values.append(value)
            index = end
            needs_string = False
        else:
            if expression[index] != "+":
                return None
            index += 1
            needs_string = True


def literal_has_language(expression: str) -> bool:
    """True for a literal whose non-interpolated segments contain a human word."""
    index = skip_space_and_comments(expression, 0)
    end = string_end(expression, index)
    if end is None:
        return False
    token = expression[index:end]
    hashes = len(token) - len(token.lstrip("#"))
    body = token[hashes:]
    quote_count = 3 if body.startswith('"""') else 1
    value = body[quote_count:len(token) - quote_count - hashes]
    # Remove interpolation expressions before looking for words. User data alone is not copy.
    value = re.sub(r"\\#*\([^)]*\)", "", value)
    return re.search(r"[A-Za-zÀ-ÖØ-öø-ÿ]{2,}", value) is not None


def selected_arguments(call: Call, selectors: tuple[str | int, ...]) -> list[tuple[str, int]]:
    result: list[tuple[str, int]] = []
    positional = 0
    for label, expression, offset in call.arguments:
        current_position = positional
        positional += 1
        if current_position in selectors or (label is not None and label in selectors):
            result.append((expression, offset))
    return result


def terminal_call_name(name: str) -> str:
    return name.rsplit(".", 1)[-1]


def localizing_selectors(
    relative_path: str,
    call: Call,
) -> tuple[str | int, ...] | None:
    if call.name in LOCALIZING_CALLS:
        return LOCALIZING_CALLS[call.name]
    helpers = LOCAL_FILE_HELPERS.get(relative_path, {})
    return helpers.get(terminal_call_name(call.name))


def presentation_selectors(call: Call) -> tuple[str | int, ...] | None:
    if call.name in PRESENTATION_CALL_ARGUMENTS:
        return PRESENTATION_CALL_ARGUMENTS[call.name]
    return PRESENTATION_CALL_ARGUMENTS.get(terminal_call_name(call.name))


def l10n_key(call: Call) -> tuple[str, int] | None:
    if call.name not in {"L10n.string", "L10n.format"} or not call.arguments:
        return None
    expression, offset = call.arguments[0][1], call.arguments[0][2]
    key = static_string(expression)
    return (key, offset) if key is not None else None


def localized_expression(expression: str) -> bool:
    stripped = expression.lstrip()
    return (
        stripped.startswith("L10n.string(")
        or stripped.startswith("L10n.format(")
        or stripped.startswith("MobileL10n.string(")
        or stripped.startswith("String(localized:")
        or stripped.startswith("NSLocalizedString(")
    )


def assignment_findings(source: str, relative_path: str) -> list[Finding]:
    findings: list[Finding] = []
    names = "|".join(sorted(PRESENTATION_ASSIGNMENTS))
    pattern = re.compile(rf"\.\s*({names})\s*=\s*")
    for match in pattern.finditer(source):
        if ignored_on_line(source, match.start()):
            continue
        start = skip_space_and_comments(source, match.end())
        # A localized call, a variable, and an empty/symbol-only literal are all valid.
        if localized_expression(source[start:start + 40]):
            continue
        if literal_has_language(source[start:]):
            findings.append(Finding(
                relative_path,
                line_number(source, start),
                f'presentation property "{match.group(1)}" contains an unlocalized literal',
            ))
    return findings


def audit_file(path: pathlib.Path, root: pathlib.Path) -> tuple[set[str], list[Finding]]:
    source = path.read_text(encoding="utf-8")
    relative_path = path.relative_to(root).as_posix()
    keys: set[str] = set()
    findings = assignment_findings(source, relative_path)

    for call in discover_calls(source):
        if key := l10n_key(call):
            keys.add(key[0])

        selectors = localizing_selectors(relative_path, call)
        if selectors is not None:
            for expression, offset in selected_arguments(call, selectors):
                key = static_string(expression)
                if key:
                    keys.add(key)

        sink_selectors = presentation_selectors(call)
        if sink_selectors is None:
            continue
        for expression, offset in selected_arguments(call, sink_selectors):
            if localized_expression(expression) or not literal_has_language(expression):
                continue
            findings.append(Finding(
                relative_path,
                line_number(source, offset),
                f'presentation call "{terminal_call_name(call.name)}" contains an unlocalized literal',
            ))

    return keys, findings


def load_catalog(root: pathlib.Path) -> tuple[set[str], list[Finding]]:
    path = root / CATALOG_PATH
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return set(), [Finding(CATALOG_PATH, 1, f"cannot read string catalog: {error}")]

    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        return set(), [Finding(CATALOG_PATH, 1, 'catalog must contain a "strings" object')]

    findings: list[Finding] = []
    for key, entry in strings.items():
        unit = (
            entry.get("localizations", {})
            .get("sv", {})
            .get("stringUnit", {})
            if isinstance(entry, dict)
            else {}
        )
        if unit.get("state") != "translated" or not str(unit.get("value", "")).strip():
            findings.append(Finding(
                CATALOG_PATH,
                1,
                f'Swedish translation is missing for "{key}"',
            ))
    return set(strings), findings


FORMAT_PLACEHOLDER_RE = re.compile(
    r"%(?:[1-9][0-9]*\$)?(?:lld|ld|llu|lu|d|u|f|g|@)"
)


def placeholder_signature(value: str) -> list[str]:
    result: list[str] = []
    for match in FORMAT_PLACEHOLDER_RE.finditer(value):
        token = match.group(0).rsplit("$", 1)[-1]
        result.append(token.lstrip("%"))
    return sorted(result)


def load_translated_catalog(
    root: pathlib.Path,
    relative_path: str,
    *,
    source_keys_are_format_strings: bool = True,
) -> tuple[set[str], list[Finding]]:
    path = root / relative_path
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return set(), [Finding(relative_path, 1, f"cannot read string catalog: {error}")]
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        return set(), [Finding(relative_path, 1, 'catalog must contain a "strings" object')]

    findings: list[Finding] = []
    for key, entry in strings.items():
        unit = (
            entry.get("localizations", {})
            .get("sv", {})
            .get("stringUnit", {})
            if isinstance(entry, dict)
            else {}
        )
        value = str(unit.get("value", ""))
        if unit.get("state") != "translated" or not value.strip():
            findings.append(Finding(
                relative_path,
                1,
                f'Swedish translation is missing for "{key}"',
            ))
        elif (
            source_keys_are_format_strings
            and placeholder_signature(key) != placeholder_signature(value)
        ):
            findings.append(Finding(
                relative_path,
                1,
                f'placeholder mismatch in Swedish translation for "{key}"',
            ))
    return set(strings), findings


MOBILE_LOCALIZING_CALLS: dict[str, tuple[str | int, ...]] = {
    "MobileRowSwipeAction": (0,),
    "ThemedDialogAction": (0,),
    "ThemedDialogTextField": (0,),
    "themedAlert": (0, "message"),
    "themedConfirmationDialog": (0, "message"),
    "diagnosticRow": (0,),
    "loadingView": (0,),
    "RemoteExpandableMessageView": ("title",),
    "unavailable": (0,),
}

MOBILE_SWIFTUI_CALLS: dict[str, tuple[str | int, ...]] = {
    "Text": (0,),
    "Label": (0,),
    "Button": (0,),
    "Section": (0,),
    "TextField": (0,),
    "SecureField": (0,),
    "Picker": (0,),
    "Toggle": (0,),
    "ContentUnavailableView": (0,),
    "navigationTitle": (0,),
    "searchable": ("prompt",),
    "accessibilityLabel": (0,),
    "accessibilityHint": (0,),
}

MOBILE_MACHINE_LITERALS = {
    "addition",
    "assistant",
    "claude",
    "conversation",
    "deny",
    "interact",
    "pdf",
    "terminal",
    "tool",
    "user",
    "view",
}

MOBILE_DYNAMIC_LOCALIZATION_BOUNDARIES: dict[str, set[str]] = {
    "Sources/ThreadingMobile/MobileRowSwipe.swift": {"title"},
    "Sources/ThreadingMobile/RemoteAttachmentsView.swift": {"message"},
    "Sources/ThreadingMobile/RemoteConversationTimelineViewController.swift": {"title"},
    "Sources/ThreadingMobile/RemoteDiagnostics.swift": {"title"},
    "Sources/ThreadingMobile/RemoteGitReviewView.swift": {"label", "localization.key"},
    "Sources/ThreadingMobile/RemoteNotifications.swift": {"localization.key"},
    "Sources/ThreadingMobile/ThemedDialog.swift": {"title", "$0"},
}


def literal_values(expression: str) -> list[str]:
    """Returns non-interpolated string tokens from a compound Swift expression."""
    result: list[str] = []
    index = 0
    while index < len(expression):
        index = skip_space_and_comments(expression, index)
        end = string_end(expression, index)
        if end is None:
            index += 1
            continue
        value = decode_string_token(expression[index:end])
        if value is not None:
            result.append(value)
        index = end
    return result


def mobile_assignment_findings(source: str, relative_path: str) -> list[Finding]:
    names = (
        "accessibilityHint|accessibilityLabel|accessibilityValue|"
        "placeholder|subtitle|text|title"
    )
    findings: list[Finding] = []
    for match in re.finditer(rf"\.\s*({names})\s*=\s*", source):
        if ignored_on_line(source, match.start()):
            continue
        start = skip_space_and_comments(source, match.end())
        line_end = source.find("\n", start)
        sample_end = len(source) if line_end < 0 else min(len(source), line_end + 240)
        sample = source[start:sample_end]
        if "MobileL10n.string(" in sample or not literal_has_language(sample):
            continue
        findings.append(Finding(
            relative_path,
            line_number(source, start),
            f'presentation property "{match.group(1)}" contains an unlocalized literal',
        ))
    return findings


def remote_localization_keys(root: pathlib.Path) -> set[str]:
    """Keys in the wire contract must also ship in the receiving iPhone's catalog."""
    keys: set[str] = set()
    for relative_path in REMOTE_LOCALIZATION_SOURCES:
        source = (root / relative_path).read_text(encoding="utf-8")
        for call in discover_calls(source):
            for label, expression, _ in call.arguments:
                if label not in {"key", "localizationKey"}:
                    continue
                key = static_string(expression)
                if key:
                    keys.add(key)
    return keys


def audit_mobile(root: pathlib.Path) -> list[Finding]:
    catalog_keys, findings = load_translated_catalog(root, MOBILE_CATALOG_PATH)
    _, info_findings = load_translated_catalog(
        root,
        MOBILE_INFO_CATALOG_PATH,
        source_keys_are_format_strings=False,
    )
    findings.extend(info_findings)
    used_keys = remote_localization_keys(root)

    for path in sorted((root / MOBILE_SOURCE_ROOT).glob("*.swift")):
        source = path.read_text(encoding="utf-8")
        relative_path = path.relative_to(root).as_posix()
        findings.extend(mobile_assignment_findings(source, relative_path))
        for call in discover_calls(source):
            terminal = terminal_call_name(call.name)
            selectors: tuple[str | int, ...] | None = None
            if call.name == "MobileL10n.string":
                selectors = (0,)
            elif terminal in MOBILE_LOCALIZING_CALLS:
                selectors = MOBILE_LOCALIZING_CALLS[terminal]
            elif terminal in MOBILE_SWIFTUI_CALLS:
                selectors = MOBILE_SWIFTUI_CALLS[terminal]
            if selectors is None:
                continue

            for expression, offset in selected_arguments(call, selectors):
                key = static_string(expression)
                if key is not None:
                    if key:
                        used_keys.add(key)
                    continue
                values = literal_values(expression)
                if (
                    call.name == "MobileL10n.string"
                    and not values
                    and expression.strip()
                    not in MOBILE_DYNAMIC_LOCALIZATION_BOUNDARIES.get(relative_path, set())
                ):
                    findings.append(Finding(
                        relative_path,
                        line_number(source, offset),
                        "dynamic MobileL10n key is not covered by an audited localization boundary",
                    ))
                human_values = [
                    value for value in values
                    if re.search(r"[A-Za-zÀ-ÖØ-öø-ÿ]{2,}", value)
                ]
                for value in human_values:
                    if (
                        value
                        and value not in MOBILE_MACHINE_LITERALS
                    ):
                        used_keys.add(value)
                if (
                    terminal in MOBILE_SWIFTUI_CALLS
                    and len(human_values) >= 2
                    and "MobileL10n.string(" not in expression
                ):
                    findings.append(Finding(
                        relative_path,
                        line_number(source, offset),
                        f'computed SwiftUI copy in "{terminal}" must resolve through MobileL10n',
                    ))

    for key in sorted(used_keys - catalog_keys):
        findings.append(Finding(
            MOBILE_CATALOG_PATH,
            1,
            f'missing source key "{key}"',
        ))
    return findings


def javascript_object(source: str, name: str) -> str | None:
    marker = re.search(rf"\n\s{{4}}{re.escape(name)}\s*:\s*\{{", source)
    if marker is None:
        return None
    open_brace = source.find("{", marker.start())
    depth = 1
    index = open_brace + 1
    in_string = False
    escaped = False
    while index < len(source):
        character = source[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
        elif character == '"':
            in_string = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[open_brace + 1:index]
        index += 1
    return None


def javascript_messages(source: str, language: str) -> dict[str, str] | None:
    block = javascript_object(source, language)
    if block is None:
        return None
    pairs = re.finditer(
        r'("(?:\\.|[^"\\])*")\s*:\s*("(?:\\.|[^"\\])*")\s*,?',
        block,
    )
    return {
        json.loads(match.group(1)): json.loads(match.group(2))
        for match in pairs
    }


class RemoteHTMLAudit(html.parser.HTMLParser):
    def __init__(self, relative_path: str) -> None:
        super().__init__(convert_charrefs=True)
        self.relative_path = relative_path
        self.findings: list[Finding] = []
        self.keys: set[str] = set()
        self.localized_stack: list[bool] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        localized = "data-i18n" in values
        self.localized_stack.append(localized or any(self.localized_stack[-1:]))
        for attribute, localization_attribute in (
            ("placeholder", "data-i18n-placeholder"),
            ("aria-label", "data-i18n-aria-label"),
            ("title", "data-i18n-title"),
        ):
            value = values.get(attribute)
            key = values.get(localization_attribute)
            if key:
                self.keys.add(key)
            if value and re.search(r"[A-Za-zÀ-ÖØ-öø-ÿ]{2,}", value) and not key:
                self.findings.append(Finding(
                    self.relative_path,
                    self.getpos()[0],
                    f'HTML attribute "{attribute}" contains unlocalized copy',
                ))
        if values.get("data-i18n"):
            self.keys.add(values["data-i18n"])

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        if self.localized_stack:
            self.localized_stack.pop()

    def handle_data(self, data: str) -> None:
        if (
            re.search(r"[A-Za-zÀ-ÖØ-öø-ÿ]{2,}", data)
            and not any(self.localized_stack[-1:])
        ):
            self.findings.append(Finding(
                self.relative_path,
                self.getpos()[0],
                "HTML text contains unlocalized copy",
            ))


def audit_remote_client(root: pathlib.Path) -> list[Finding]:
    app_path = root / REMOTE_CLIENT_ROOT / "app.js"
    html_path = root / REMOTE_CLIENT_ROOT / "index.html"
    relative_js = app_path.relative_to(root).as_posix()
    relative_html = html_path.relative_to(root).as_posix()
    findings: list[Finding] = []
    try:
        source = app_path.read_text(encoding="utf-8")
        html_source = html_path.read_text(encoding="utf-8")
    except OSError as error:
        return [Finding(REMOTE_CLIENT_ROOT, 1, f"cannot read remote client: {error}")]

    english = javascript_messages(source, "en")
    swedish = javascript_messages(source, "sv")
    if english is None or swedish is None:
        return [Finding(relative_js, 1, "cannot parse English and Swedish message dictionaries")]
    for key in sorted(set(english) - set(swedish)):
        findings.append(Finding(relative_js, 1, f'missing Swedish browser message "{key}"'))
    for key in sorted(set(swedish) - set(english)):
        findings.append(Finding(relative_js, 1, f'Swedish browser message has no English key "{key}"'))
    token_pattern = re.compile(r"\{([A-Za-z0-9_]+)\}")
    for key in sorted(set(english) & set(swedish)):
        if sorted(token_pattern.findall(english[key])) != sorted(token_pattern.findall(swedish[key])):
            findings.append(Finding(
                relative_js,
                1,
                f'placeholder mismatch in Swedish browser message "{key}"',
            ))

    used_keys = set(re.findall(r'\bt\(\s*"([^"]+)"', source))
    html_audit = RemoteHTMLAudit(relative_html)
    html_audit.feed(html_source)
    findings.extend(html_audit.findings)
    used_keys.update(html_audit.keys)
    for key in sorted(used_keys - set(english)):
        findings.append(Finding(relative_js, 1, f'missing browser message "{key}"'))

    presentation_patterns = (
        r'\.textContent\s*=\s*"[^"]*[A-Za-zÀ-ÖØ-öø-ÿ]{2,}',
        r'\b(?:appendNotice|setBadge|setStatus)\(\s*"[^"]*[A-Za-zÀ-ÖØ-öø-ÿ]{2,}',
    )
    for pattern in presentation_patterns:
        for match in re.finditer(pattern, source):
            if ignored_on_line(source, match.start()):
                continue
            findings.append(Finding(
                relative_js,
                line_number(source, match.start()),
                "browser presentation copy bypasses t()",
            ))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo_root", type=pathlib.Path)
    parser.add_argument("--list-keys", action="store_true")
    arguments = parser.parse_args()

    root = arguments.repo_root.resolve()
    used_keys: set[str] = set()
    findings: list[Finding] = []
    for path in swift_files(root):
        keys, file_findings = audit_file(path, root)
        used_keys.update(keys)
        findings.extend(file_findings)

    if arguments.list_keys:
        print(json.dumps(sorted(used_keys), ensure_ascii=False, indent=2))
        return 0

    catalog_keys, catalog_findings = load_catalog(root)
    findings.extend(catalog_findings)
    for key in sorted(used_keys - catalog_keys):
        findings.append(Finding(
            CATALOG_PATH,
            1,
            f'missing source key "{key}"',
        ))
    findings.extend(audit_mobile(root))
    findings.extend(audit_remote_client(root))

    for finding in sorted(set(findings)):
        print(f"{finding.path}:{finding.line}: error: {finding.message}", file=sys.stderr)
    if findings:
        print(
            "\nLocalization boundary failed. Route first-party copy through L10n, or add "
            "// localization-ignore: <reason> for a genuine protocol/technical literal.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
