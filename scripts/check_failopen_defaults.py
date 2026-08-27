#!/usr/bin/env python3
"""Reject an unrecognised raw value that silently becomes a specific, permissive case.

`Enum(rawValue: x) ?? .something` answers "I do not know what this is" with "then it is
this" — and the case picked is nearly always the permissive one, because it is the one the
author had in mind while writing the happy path.  `docs/architecture/reliability-and-type-safety.md`
already says permission and capability lookups default to refusal and that an invalid value
must not accidentally become a permissive or destructive default; this is what enforces it.

The repository owns two correct idioms, and an offending site should move to one of them:

* an explicit `unknown(String)` (or `.unknown`) case, the way `RemoteLosslessStringToken` in
  `Packages/ThreadingRemoteKit/.../RemoteWireVocabulary.swift` does — the unrecognised value
  stays unrecognised and every consumer has to say what it does about that; or
* an exhaustive `switch` with no `default:`, so adding a case upstream is a compile error at
  the projection rather than a silent downgrade.

**What is rejected.**  `Type(rawValue: …) ?? .case`, `Self(rawValue: …) ?? .case`,
`.init(rawValue: …) ?? .case`, and the qualified `?? Type.case` spelling of the same thing.
The `??` may sit on a following line, and comments and string literals are masked before the
scan so neither can hide a site or invent one.

**Scope.**  `Sources/Threading/`, `Sources/ThreadingMobile/`, and the first-party
`Packages/Threading*/Sources/` trees.  Deliberately excluded:

* `Packages/Vendor/` — our forks of third-party code (SwiftTerm and the rest).  We modify
  those directly, but their vocabulary is upstream's and a lint of ours does not govern it.
* `Packages/*/Examples/` — extension-author templates, which are read as sample code and are
  not part of the app's trust boundary.

**Allowlisting.**  An entry is keyed by repository-relative path plus enclosing declaration
path — never a line number, which rots on the next edit above it — and carries a written
reason a reviewer can evaluate.  A missing or perfunctory reason is refused, because an
unjustified suppression is precisely the thing this check exists to prevent, and an entry that
no longer matches a real site is refused too, so the list cannot outlive what it excused.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


# The call: `Foo(rawValue:`, `Foo.Bar(rawValue:`, `Self(rawValue:`, `.init(rawValue:`. The
# argument may start on the next line, so the whitespace classes are deliberately permissive.
RAW_VALUE_CALL = re.compile(
    r"(?:\.init|\b[A-Z][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*\(\s*rawValue\s*:"
)

# The fallback, allowed to sit on a later line. Both spellings of a fixed case are caught: the
# implicit-member `.case` and the qualified `Type.case`, which is the same decision written out.
#
# A fallback followed by `(` is deliberately not one of them, because it is not a fixed case. It
# is either a derivation — `?? UpdateChannelSubscription.standard(for: AppInfo.buildChannel)`
# resolves an unset update channel against the running build — or a case that carries the raw
# value forward, `?? .unknown(raw)`, which is the idiom this check exists to push people towards.
CASE_FALLBACK = re.compile(
    r"\s*\?\?\s*"
    r"(?P<fallback>\.[A-Za-z_][A-Za-z0-9_]*|[A-Z][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)"
    # No `\s*` before this: with one, the name itself backtracks a character at a time until the
    # lookahead is happy, and `?? .standard(…)` matches as `.standar`.
    r"(?![A-Za-z0-9_(])"
)

# Enough of a Swift declaration to name the site. Only used for the allowlist key, so it names
# the innermost enclosing type/member rather than attempting to parse the language.
DECLARATION = re.compile(
    r"^(?P<indent>[ \t]*)"
    r"(?P<modifiers>(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|public|internal|fileprivate"
    r"|private|open|static|class|final|lazy|weak|unowned|override|convenience|required"
    r"|indirect|nonisolated|dynamic|mutating|nonmutating)[ \t]+)*)"
    r"(?P<keyword>enum|struct|class|actor|extension|protocol|func|init|subscript|deinit|var|let)"
    r"\b[ \t]*(?P<name>[A-Za-z_][A-Za-z0-9_]*)?"
)

# A `var` or `let` only *encloses* code when it opens a brace: a computed property, a `lazy`
# initializer closure, a property observer. `let parameters: NWParameters` and
# `let control = ThemedSegmentedControl()` are local bindings that happen to sit above the site,
# and naming an allowlist entry after one of those would key it on a temporary.
OPENS_A_BODY = re.compile(r"\{[ \t]*$")

SOURCE_ROOTS = ("Sources/Threading", "Sources/ThreadingMobile")
PACKAGE_ROOT_GLOB = "Packages/Threading*/Sources"
EXCLUDED_PATH_MARKERS = ("Packages/Vendor/", "/Examples/")

MINIMUM_REASON_LENGTH = 40

# Path + enclosing declaration -> why this one unrecognised value may become this one case.
#
# Every entry here is a case where the fallback is either unreachable given a stated invariant,
# or is itself the refusing answer. "It has always been like that" is not a reason; neither is
# "the value comes from us", because the point of a raw value is that it came from somewhere
# else.
ALLOWLIST = {
    (
        "Packages/ThreadingRemoteKit/Sources/ThreadingRemoteKit/RemoteWireDTO.swift",
        "RemoteHostConnectionPolicy.init",
    ): (
        "Fails closed, which is the whole design of the field: `privateOnly` is the most "
        "restrictive of the three policies, so a phone sending vocabulary this build has no "
        "case for can only narrow what the host will do, never widen it. The type comment "
        "states the same contract for the installed base decoding it from the other side."
    ),
    (
        "Packages/ThreadingPeerTransport/Sources/ThreadingPeerTransport/WebRTCPeerTransport.swift",
        "WebRTCPeerTransport.candidateKind",
    ): (
        "This is the correct idiom rather than an exception to it: `PeerCandidateKind.unknown` "
        "is an explicit case for a candidate type WebRTC reported and we do not model, and it "
        "reaches diagnostics as unknown rather than as a plausible-looking route. The value is "
        "descriptive telemetry and gates nothing."
    ),
    (
        "Sources/ThreadingMobile/SessionDashboard.swift",
        "SessionDashboard.organization",
    ): (
        "A stored UI preference, not an external message: an `@AppStorage` string that predates "
        "the current cases, or was written by a build with a case this one lacks, legitimately "
        "falls back to the shipped default grouping. Nothing is permitted or refused by it — the "
        "worst outcome is that the list is grouped the way a fresh install groups it."
    ),
    (
        "Sources/ThreadingMobile/SessionDashboard.swift",
        "SessionDashboard.typeDirection",
    ): (
        "The same stored-preference fallback as `organization`, one line above: an unreadable "
        "`@AppStorage` sort direction becomes the shipped default ordering. It decides which end "
        "of a list chats appear at and gates no capability."
    ),
    (
        "Sources/Threading/UI/Views/BrowserComparisonViewController.swift",
        "BrowserComparisonViewController.viewPicker",
    ): (
        "The index is bounded by the control that produces it. `ThemedSegmentedControl.choose` "
        "guards `segmentViews.indices.contains(index)` before calling `onSelect`, and "
        "`applyContent` configures the picker with at most the two titles that `View` has cases "
        "for, so the fallback is unreachable. It also names the same display the single-title "
        "configuration selects, so a third segment added without a case would show the pair, not "
        "grant anything."
    ),
}


def blank_span(characters: list, start: int, end: int) -> None:
    """Replace a span with spaces, keeping every newline so line numbers do not move."""

    for index in range(start, end):
        if characters[index] != "\n":
            characters[index] = " "


def masked_source(source: str) -> str:
    """Return the file with comment and string-literal bodies blanked out.

    Offsets and line numbers are preserved, so the scan below can count parentheses without
    a `//` in a URL, a `??` in a doc comment, or a parenthesis in a message ending the call
    it is quoting. The notes explaining this seam have to be able to spell the pattern they
    are refusing, and after masking they can.
    """

    characters = list(source)
    length = len(source)
    index = 0

    while index < length:
        character = source[index]

        if source.startswith("//", index):
            end = source.find("\n", index)
            end = length if end < 0 else end
            blank_span(characters, index, end)
            index = end
            continue

        if source.startswith("/*", index):
            depth = 1
            end = index + 2
            while end < length and depth:
                if source.startswith("/*", end):
                    depth += 1
                    end += 2
                elif source.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            blank_span(characters, index, end)
            index = end
            continue

        if character in ('"', "#"):
            hashes = 0
            quote = index
            while quote < length and source[quote] == "#":
                hashes += 1
                quote += 1
            if quote >= length or source[quote] != '"':
                index += 1
                continue

            pounds = "#" * hashes
            if source.startswith('"""', quote):
                terminator = '"""' + pounds
                cursor = quote + 3
            else:
                terminator = '"' + pounds
                cursor = quote + 1
            escape = "\\" + pounds

            while cursor < length:
                if source.startswith(escape, cursor):
                    cursor += len(escape) + 1
                    continue
                if source.startswith(terminator, cursor):
                    cursor += len(terminator)
                    break
                cursor += 1

            blank_span(characters, quote, min(cursor, length))
            index = cursor
            continue

        index += 1

    return "".join(characters)


def call_end(masked: str, opening_parenthesis: int) -> int:
    """Return the offset just past the call's closing parenthesis, or -1 if unbalanced."""

    depth = 0
    index = opening_parenthesis
    while index < len(masked):
        if masked[index] == "(":
            depth += 1
        elif masked[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return -1


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def declaration_path(lines: list, target_line: int) -> str:
    """Name the innermost enclosing type/member of a 1-based line, as a dotted path.

    Takes the *masked* lines, so a brace inside a comment or a string does not read as a
    declaration opening a body.
    """

    target_text = lines[target_line - 1]
    target_indent = len(target_text) - len(target_text.lstrip())
    stack = []

    for text in lines[: target_line - 1]:
        match = DECLARATION.match(text)
        if match is None:
            continue
        name = match.group("name")
        keyword = match.group("keyword")
        if keyword == "init":
            name = "init"
        elif keyword == "deinit":
            name = "deinit"
        elif keyword == "subscript":
            name = "subscript"
        if not name:
            continue
        if keyword in ("var", "let") and not OPENS_A_BODY.search(text):
            continue
        indent = len(match.group("indent").expandtabs(4))
        while stack and stack[-1][0] >= indent:
            stack.pop()
        stack.append((indent, name))

    while stack and stack[-1][0] >= target_indent:
        stack.pop()
    return ".".join(name for _, name in stack) or "<file scope>"


def in_scope_files(repository: pathlib.Path) -> list:
    roots = [repository / relative for relative in SOURCE_ROOTS]
    roots.extend(sorted(repository.glob(PACKAGE_ROOT_GLOB)))

    paths = []
    for root in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.swift")):
            posix = "/" + path.relative_to(repository).as_posix()
            if any(marker in posix for marker in EXCLUDED_PATH_MARKERS):
                continue
            paths.append(path)
    return paths


def sites(repository: pathlib.Path) -> list:
    """Every `(rawValue:) ?? case` site in scope, as (relative path, line, symbol, text)."""

    found = []
    for path in in_scope_files(repository):
        source = path.read_text(encoding="utf-8")
        # Masking walks the file a character at a time, and almost no file mentions `rawValue:`
        # at all. Masking cannot *create* a match, only suppress one, so a file with no match in
        # the raw text has none in the masked text either and can be skipped outright. This is
        # the difference between the gate costing two seconds of every build and costing ten.
        if not RAW_VALUE_CALL.search(source):
            continue
        masked = masked_source(source)
        lines = masked.splitlines()
        relative = path.relative_to(repository).as_posix()

        for match in RAW_VALUE_CALL.finditer(masked):
            opening = masked.find("(", match.start(), match.end())
            end = call_end(masked, opening)
            if end < 0:
                continue
            fallback = CASE_FALLBACK.match(masked, end)
            if fallback is None:
                continue
            line = line_number(source, match.start())
            found.append((
                relative,
                line,
                declaration_path(lines, line),
                " ".join(source[match.start():fallback.end()].split()),
            ))
    return found


def allowlist_failures(repository: pathlib.Path, found: list) -> list:
    failures = []
    for (path, symbol), reason in sorted(ALLOWLIST.items()):
        if len(reason.strip()) < MINIMUM_REASON_LENGTH:
            failures.append(
                f"failopen-default: the allowlist entry for {path} ({symbol}) has no reason a "
                "reviewer can evaluate; say why an unrecognised value may become this case"
            )

    # Only audited against a tree that actually contains these files. The regression tests run
    # the checker over a temporary fixture repository, where no allowlisted file exists and a
    # staleness report would be noise rather than a finding.
    present = {
        (path, symbol)
        for path, symbol in ALLOWLIST
        if (repository / path).is_file()
    }
    if not present:
        return failures

    matched = {(path, symbol) for path, _, symbol, _ in found}
    for path, symbol in sorted(ALLOWLIST):
        if (path, symbol) in matched:
            continue
        if (path, symbol) in present:
            failures.append(
                f"failopen-default: the allowlist entry for {path} ({symbol}) no longer matches "
                "a site; delete it rather than leaving an excuse behind"
            )
        else:
            failures.append(
                f"failopen-default: the allowlist entry for {path} names a file that no longer "
                "exists; delete it rather than leaving an excuse behind"
            )
    return failures


def check(repository: pathlib.Path) -> list:
    found = sites(repository)
    failures = [
        f"{path}:{line}: unrecognised raw value defaults to a case — {text}  "
        f"[allowlist key: (\"{path}\", \"{symbol}\")]"
        for path, line, symbol, text in found
        if (path, symbol) not in ALLOWLIST
    ]
    return failures + allowlist_failures(repository, found)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "repository",
        nargs="?",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent,
    )
    args = parser.parse_args()

    failures = check(args.repository.resolve())
    if failures:
        print("\n".join(failures))
        print(
            "failopen-default: an unrecognised raw value must not become a specific case — give "
            "the type an explicit unknown case, or project it with an exhaustive switch that has "
            "no default, so a value nobody modelled cannot arrive as a permission; allowlist a "
            "site in scripts/check_failopen_defaults.py only with a reason that says why it is "
            "safe",
            file=sys.stderr,
        )
        return 1

    print("failopen-default: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
