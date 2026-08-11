#!/usr/bin/env python3
"""Enforce the source-level privacy contract for Threading's unified logs."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


LOGGER_CALL = re.compile(
    r"(?:ThreadingLogger\.[A-Za-z][A-Za-z0-9_]*|mobileDiagnosticLogger)\."
    r"(?:debug|info|notice|warning|error|critical|fault)\s*\("
)
INTERPOLATION = "\\("
RAW_INTERPOLATION = re.compile(r"\\#+\(")
PRIVACY_ARGUMENT = re.compile(r",\s*privacy\s*:\s*\.(public|private)\b")
DIRECT_LOGGER = re.compile(r"\bLogger\s*\(\s*subsystem\s*:")
DIRECT_OS_LOG = re.compile(r"\bos_log\s*\(")
LOGGER_DEFINITIONS = {
    pathlib.PurePosixPath("Sources/Threading/Core/Logging/Logger.swift"),
    pathlib.PurePosixPath("Sources/ThreadingMobile/RemoteDiagnostics.swift"),
}
PUBLIC_SENSITIVE = re.compile(
    r"(?:"
    r"\blocalizedDescription\b|"
    r"\babsoluteString\b|"
    r"\b(?:prompt|systemPrompt|userMessage|content|response|message|detail|output)\b|"
    r"\b(?:handle|accountID|sourceName|fileName|destination|projectPath|folderPath|codexHome|email)\b|"
    r"\.path\b|\.lastPathComponent\b"
    r")"
)
PUBLIC_AGGREGATE = re.compile(r"(?:\.count|\.utf8\.count)\s*(?:\?\?\s*\d+)?\s*$")
NEVER_LOG = re.compile(
    r"(?:"
    r"^\s*token\s*$|"
    r"\b(?:accessToken|refreshToken|invitationToken|pairingBootstrapToken|"
    r"password|bearer|apiKey|privateKey)\b"
    r")"
)


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def call_end(source: str, opening_parenthesis: int) -> int | None:
    """Return the byte after a logger call's closing parenthesis.

    Parentheses inside Swift string literals do not delimit the call. This deliberately treats
    an interpolation as string content too: its closing parenthesis is paired inside the literal,
    and only the parenthesis after the closing quote ends the logger call.
    """

    depth = 0
    index = opening_parenthesis
    string_delimiter: str | None = None
    escaped = False

    while index < len(source):
        if string_delimiter is not None:
            if string_delimiter == '"""':
                if source.startswith(string_delimiter, index):
                    string_delimiter = None
                    index += len('"""')
                    continue
            elif escaped:
                escaped = False
            elif source[index] == "\\":
                escaped = True
            elif source[index] == '"':
                string_delimiter = None
        elif source.startswith('"""', index):
            string_delimiter = '"""'
            index += len('"""')
            continue
        elif source[index] == '"':
            string_delimiter = '"'
        elif source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1

    return None


def interpolation_end(text: str, opening_parenthesis: int) -> int | None:
    """Return the closing parenthesis for one Swift string interpolation."""

    depth = 1
    index = opening_parenthesis + 1
    string_delimiter: str | None = None
    escaped = False

    while index < len(text):
        if string_delimiter is not None:
            if string_delimiter == '"""':
                if text.startswith(string_delimiter, index):
                    string_delimiter = None
                    index += len('"""')
                    continue
            elif escaped:
                escaped = False
            elif text[index] == "\\":
                escaped = True
            elif text[index] == '"':
                string_delimiter = None
        elif text.startswith('"""', index):
            string_delimiter = '"""'
            index += len('"""')
            continue
        elif text[index] == '"':
            string_delimiter = '"'
        elif text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index
        index += 1

    return None


def privacy_failures(path: pathlib.Path, source: str) -> list[str]:
    failures: list[str] = []
    offset = 0

    while match := LOGGER_CALL.search(source, offset):
        opening_parenthesis = source.find("(", match.start(), match.end())
        end = call_end(source, opening_parenthesis)
        if end is None:
            failures.append(
                f"{path}:{line_number(source, match.start())}: unterminated ThreadingLogger call"
            )
            break

        call = source[match.start():end]
        for raw in RAW_INTERPOLATION.finditer(call):
            failures.append(
                f"{path}:{line_number(source, match.start() + raw.start())}: "
                "raw-string logger interpolation is not supported by the privacy checker; "
                "use a standard OSLog string literal"
            )
        interpolation_offset = 0
        while True:
            marker = call.find(INTERPOLATION, interpolation_offset)
            if marker < 0:
                break

            closing = interpolation_end(call, marker + 1)
            if closing is None:
                failures.append(
                    f"{path}:{line_number(source, match.start() + marker)}: "
                    "unterminated logger interpolation"
                )
                break

            expression = call[marker + len(INTERPOLATION):closing]
            privacy = PRIVACY_ARGUMENT.search(expression)
            if privacy is None:
                summary = " ".join(expression.split())
                failures.append(
                    f"{path}:{line_number(source, match.start() + marker)}: "
                    f"logger interpolation has no explicit privacy marker: \\({summary})"
                )
            else:
                value = expression[:privacy.start()].strip()
                if NEVER_LOG.search(value):
                    summary = " ".join(value.split())
                    failures.append(
                        f"{path}:{line_number(source, match.start() + marker)}: "
                        f"credential-like value must never be logged: \\({summary})"
                    )
                elif privacy.group(1) == "public":
                    if PUBLIC_SENSITIVE.search(value) and not PUBLIC_AGGREGATE.search(value):
                        summary = " ".join(value.split())
                        failures.append(
                            f"{path}:{line_number(source, match.start() + marker)}: "
                            f"potentially sensitive logger value is public: \\({summary})"
                        )
            interpolation_offset = closing + 1

        offset = end

    return failures


def bypass_failures(repository: pathlib.Path, path: pathlib.Path, source: str) -> list[str]:
    relative = path.relative_to(repository)
    if pathlib.PurePosixPath(relative.as_posix()) in LOGGER_DEFINITIONS:
        return []

    failures: list[str] = []
    for pattern, description in (
        (DIRECT_LOGGER, "constructs an OSLog Logger outside ThreadingLogger"),
        (DIRECT_OS_LOG, "calls os_log directly instead of ThreadingLogger"),
    ):
        for match in pattern.finditer(source):
            failures.append(
                f"{relative}:{line_number(source, match.start())}: {description}"
            )
    return failures


def check(repository: pathlib.Path) -> list[str]:
    failures: list[str] = []
    source_roots = (
        repository / "Sources" / "Threading",
        repository / "Sources" / "ThreadingMobile",
    )
    for source_root in source_roots:
        for path in sorted(source_root.rglob("*.swift")):
            source = path.read_text(encoding="utf-8")
            relative = path.relative_to(repository)
            failures.extend(privacy_failures(relative, source))
            failures.extend(bypass_failures(repository, path, source))
    return failures


def checker_self_test() -> list[str]:
    """Keep the build gate from silently accepting the patterns it exists to reject."""

    cases = (
        ('ThreadingLogger.app.info("count=\\(items.count, privacy: .public)")', 0),
        ('ThreadingLogger.app.info("path=\\(url.path, privacy: .private(mask: .hash))")', 0),
        ('ThreadingLogger.app.info("value=\\(value)")', 1),
        ('ThreadingLogger.app.info("path=\\(url.path, privacy: .public)")', 1),
        ('ThreadingLogger.app.info("token=\\(token, privacy: .private)")', 1),
        ('ThreadingLogger.app.info(#"path=\\#(url.path)"#)', 1),
    )
    failures: list[str] = []
    fixture = pathlib.Path("logging-boundary-self-test.swift")
    for source, expected in cases:
        actual = len(privacy_failures(fixture, source))
        if actual != expected:
            failures.append(
                f"logging-boundary checker self-test expected {expected} failure(s), "
                f"found {actual}: {source}"
            )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "repository",
        nargs="?",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent,
    )
    args = parser.parse_args()

    failures = checker_self_test() + check(args.repository.resolve())
    if failures:
        print("\n".join(failures))
        print(
            "logging-boundary: every interpolated value must choose privacy: .public or "
            ".private; paths, content, account labels and arbitrary diagnostics cannot be "
            "public; use ThreadingLogger rather than constructing a parallel logger",
            file=sys.stderr,
        )
        return 1

    print("logging-boundary: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
