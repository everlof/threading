#!/usr/bin/env python3
"""Reject the two ways an unmodelled provider value can quietly change what the user sees.

A value nobody wrote a case for can fail in two directions, and both end at the same place —
the person reading the window is shown something the agent never said.  This file refuses
both.

**By substitution.**  `Enum(rawValue: x) ?? .something` answers "I do not know what this is"
with "then it is this" — and the case picked is nearly always the permissive one, because it
is the one the author had in mind while writing the happy path.
`docs/architecture/reliability-and-type-safety.md`
already says permission and capability lookups default to refusal and that an invalid value
must not accidentally become a permissive or destructive default; this is what enforces it.

**By omission.**  The same unrecognised value handed to a *failable* initializer removes the
row instead of downgrading it, and an absent row is invisible in exactly the way a wrong one
is not.  The second rule below refuses that shape.  Both are the same defect wearing
different clothes, which is why they share a file.

The repository owns two correct idioms, and an offending site should move to one of them:

* an explicit `unknown(String)` (or `.unknown`) case, the way `RemoteLosslessStringToken` in
  `Packages/ThreadingRemoteKit/.../RemoteWireVocabulary.swift` does — the unrecognised value
  stays unrecognised and every consumer has to say what it does about that; or
* an exhaustive `switch` with no `default:`, so adding a case upstream is a compile error at
  the projection rather than a silent downgrade.

**What the substitution rule rejects.**  `Type(rawValue: …) ?? .case`,
`Self(rawValue: …) ?? .case`, `.init(rawValue: …) ?? .case`, and the qualified `?? Type.case`
spelling of the same thing.  The `??` may sit on a following line, and comments and string
literals are masked before the scan so neither can hide a site or invent one.

**What the omission rule rejects, and why it is this narrow.**  Only the conjunction of three
things, because each one alone is everywhere and almost always fine:

1. *A closed vocabulary of ours.*  The initializer belongs to an `enum` declared in this
   repository and is a hand-written `init?` whose first parameter is a `String`.  That is the
   authorial statement "this is one of a fixed set of names somebody else chose".
   `URL(string:)`, `UUID(uuidString:)` and `NSImage(data:)` are not declared here and a
   struct's failable initializer is a *format* parser: its `nil` means "this is not an X at
   all", not "this is an X I have no case for".  `init?(rawValue:)`, `init?(stringValue:)`,
   `init?(intValue:)` and `init?(coder:)` are excluded because `RawRepresentable`, `CodingKey`
   and `NSCoding` require them to be failable — banning them would ban the conformance.
2. *A value straight off the wire.*  The argument was bound in the same `guard`/`if`
   condition by `as? String` or by a `JSONValue` accessor, so it demonstrably came out of an
   untyped payload rather than out of our own store or another typed value.
3. *A row that disappears.*  The failure branch drops **one element while the rest are
   kept** — `return nil` inside a `compactMap` closure, or `continue` inside a `for … in`
   loop.  That is the invisible outcome: a plan with a step missing looks like a plan.

**What the omission rule deliberately does not catch.**  All of these were measured against
this tree and rejected as too noisy for a rule that fails everyone's build:

* `Enum(rawValue: wireString)` in the same dropping position.  A `String`-raw enum is used for
  our own persisted and internal vocabulary at least as often as for a provider's, and nothing
  at the call site tells the two apart: including it flagged nine sites, of which two were
  wire vocabulary and seven were stored preferences, theme roles and internal identifiers.
* *Withdrawing the whole collection* — `return nil`/`return []` from the function building it
  rather than skipping one element.  That is lossy, but it is fail-closed and legible: the
  user sees no plan rather than a plan with a step quietly missing.  Two sites in this tree do
  exactly that on purpose and say so in a comment.
* A failable initializer over `Any` (`JSONValue(foundationValue:)`), which is total over
  anything `JSONSerialization` can produce and so never actually drops a row.
* `if let x = T(providerValue: …) { … }` with no `else` — the drop is real but has no text to
  match on.
* An initializer taking more than one argument, and any conversion written as a `switch` or a
  static function rather than an initializer.

The rule therefore trades recall for the right to fail a build.  It is calibrated so that the
shape it fires on is the one this repository already fixed once by hand: `planSteps` in
`ACPWireAdapter.swift` before commit `2536faf9` read
`entries.compactMap { … guard let status = RunProgress.Step.Status(providerValue: rawStatus)
else { return nil } … }`, and a plan entry whose status ACP added later vanished from the run
indicator.  The fix was an `unknown(String)` case, so the omission became a named branch at
the projection instead of a failed initializer three types away.

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


# MARK: - The omission rule


# `enum Foo`, with the modifiers that may precede it. Used to answer one question only: is the
# type this initializer belongs to a closed vocabulary we declare, or somebody else's parser.
ENUM_DECLARATION = re.compile(
    r"^[ \t]*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|public|internal|fileprivate|private"
    r"|open|final|indirect|nonisolated)[ \t]+)*enum[ \t]+(?P<name>[A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)

# A hand-written failable initializer whose *first* parameter is a `String` or `String?`. The
# external label may be `_`, and an internal name may follow it. Requiring `String` is what
# keeps `init?(foundationValue: Any)`, `init?(kind: AgentKind)` and `init?(stored: Stored)`
# out: those take a value that has already been modelled, so their `nil` is not "a name I do
# not know".
FAILABLE_STRING_INITIALIZER = re.compile(
    r"\binit\?[ \t]*\([ \t\n]*"
    r"(?P<label>_|[A-Za-z_][A-Za-z0-9_]*)"
    r"(?:[ \t]+[A-Za-z_][A-Za-z0-9_]*)?"
    r"[ \t]*:[ \t]*String\??[ \t]*[,)]"
)

# Failable because a protocol says so. `RawRepresentable`, `CodingKey` and `NSCoding` all
# require the initializer to be failable, so an enum conforming to one of them cannot write the
# non-failable version this rule would otherwise ask for.
PROTOCOL_INITIALIZER_LABELS = ("rawValue", "stringValue", "intValue", "coder")

# `let name = <anything> as? String` or `let name = <anything>.stringValue` — the value came out
# of an untyped payload in this very condition, which is the provenance half of the rule.
WIRE_BINDING = re.compile(
    r"\blet[ \t]+(?P<name>[A-Za-z_][A-Za-z0-9_]*)[ \t]*=[^,\n]*?"
    r"(?:\bas\?[ \t]*String\b|\.stringValue\b)"
)

# `let x = Vocabulary(label: value)` with exactly one argument. A second argument means the
# initializer is deciding something else as well, and the rule stays out of it.
VOCABULARY_BINDING = re.compile(
    r"\blet[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t\n]*"
    r"(?:[A-Za-z_][A-Za-z0-9_]*\.)*(?P<type>[A-Z][A-Za-z0-9_]*)[ \t]*\([ \t\n]*"
    r"(?:(?P<label>[A-Za-z_][A-Za-z0-9_]*)[ \t]*:[ \t\n]*)?"
    r"(?P<argument>[A-Za-z_][A-Za-z0-9_]*)[?!]*[ \t\n]*\)"
)

# `guard <conditions> else {` and `if <conditions> else {`. A `{` inside the condition means a
# closure is in there and the span is not a condition list any more, so those are skipped.
CONDITIONAL_BINDING = re.compile(r"\b(?:guard|if)\b(?P<condition>[^{]*?)\belse\b[ \t\n]*\{")

# The whole else-body has to be one of these and nothing else. A branch that logs, records a
# diagnostic, or substitutes something is making a decision the reader can find; this rule is
# about the branch that says nothing at all.
ELEMENT_DROP = re.compile(r"^(?:return[ \t]+nil|return[ \t]*\[[ \t]*\]|return|continue)$")

# The two block openers that make a `nil`/`continue` skip one element and keep the rest.
COMPACT_MAP_CLOSURE = re.compile(r"\.compactMap[ \t]*\{")
FOR_IN_LOOP = re.compile(r"\bfor\b[^\n]*\bin\b[^\n]*\{")

# Path + enclosing declaration -> why an unrecognised name may remove this row and leave the
# rest of the collection standing.
#
# Empty on purpose. Every site in this tree either withdraws the whole collection (which the
# rule does not ask about) or converts through a vocabulary with an explicit `unknown` case. An
# entry here has to say why the *absence* of a row is the honest answer, which is a harder
# thing to argue than a fail-closed default and should stay that way.
DROPPED_ELEMENT_ALLOWLIST = {}


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


def allowlist_failures(
    repository: pathlib.Path,
    found: list,
    allowlist: dict = None,
    rule: str = "failopen-default",
    consequence: str = "become this case",
) -> list:
    allowlist = ALLOWLIST if allowlist is None else allowlist
    failures = []
    for (path, symbol), reason in sorted(allowlist.items()):
        if len(reason.strip()) < MINIMUM_REASON_LENGTH:
            failures.append(
                f"{rule}: the allowlist entry for {path} ({symbol}) has no reason a "
                f"reviewer can evaluate; say why an unrecognised value may {consequence}"
            )

    # Only audited against a tree that actually contains these files. The regression tests run
    # the checker over a temporary fixture repository, where no allowlisted file exists and a
    # staleness report would be noise rather than a finding.
    present = {
        (path, symbol)
        for path, symbol in allowlist
        if (repository / path).is_file()
    }
    if not present:
        return failures

    matched = {(path, symbol) for path, _, symbol, _ in found}
    for path, symbol in sorted(allowlist):
        if (path, symbol) in matched:
            continue
        if (path, symbol) in present:
            failures.append(
                f"{rule}: the allowlist entry for {path} ({symbol}) no longer matches "
                "a site; delete it rather than leaving an excuse behind"
            )
        else:
            failures.append(
                f"{rule}: the allowlist entry for {path} names a file that no longer "
                "exists; delete it rather than leaving an excuse behind"
            )
    return failures


# MARK: - The omission rule's scan


def enclosing_type(lines: list, target_line: int):
    """The innermost type-like declaration around a 1-based line, as (name, keyword).

    Takes the *masked* lines for the same reason `declaration_path` does: a brace in a comment
    or a string must not read as a declaration opening a body.
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
        if keyword in ("init", "deinit", "subscript"):
            name = keyword
        if not name:
            continue
        if keyword in ("var", "let") and not OPENS_A_BODY.search(text):
            continue
        indent = len(match.group("indent").expandtabs(4))
        while stack and stack[-1][0] >= indent:
            stack.pop()
        stack.append((indent, name, keyword))

    while stack and stack[-1][0] >= target_indent:
        stack.pop()
    for _, name, keyword in reversed(stack):
        if keyword in ("enum", "struct", "class", "actor", "extension", "protocol"):
            return name, keyword
    return None


def vocabulary_enums(paths: list) -> set:
    """Names of first-party enums entered through a hand-written failable `String` initializer.

    Only the last component of a nested name is kept: a call site writes
    `RunProgress.Step.Status(…)` or `Step.Status(…)` or `Status(…)` for the same type, and the
    other two conditions are what make the match mean something.

    Masking is the expensive part of this file, so it is spent only where it can change an
    answer. A file with no `init?( … : String` in its *raw* text cannot have one after masking,
    and the enum names needed to resolve an `extension` body are looked up only for the handful
    of extension names that actually host such an initializer.
    """

    vocabulary = set()
    extended = set()
    for path in paths:
        source = path.read_text(encoding="utf-8")
        if not FAILABLE_STRING_INITIALIZER.search(source):
            continue
        masked = masked_source(source)
        lines = masked.splitlines()
        for match in FAILABLE_STRING_INITIALIZER.finditer(masked):
            if match.group("label") in PROTOCOL_INITIALIZER_LABELS:
                continue
            enclosing = enclosing_type(lines, masked.count("\n", 0, match.start()) + 1)
            if enclosing is None:
                continue
            name, keyword = enclosing
            base = name.split(".")[-1]
            if keyword == "enum":
                vocabulary.add(base)
            elif keyword == "extension":
                extended.add(base)

    # One pass for every unresolved extension name at once. Most of them are extensions on
    # `Data`, `NSColor` and the like, which are not enums and are not ours, and looking each one
    # up separately means walking the tree once per name for nothing.
    pending = extended - vocabulary
    if pending:
        declaration = re.compile(
            r"\benum[ \t]+(?:" + "|".join(re.escape(name) for name in sorted(pending)) + r")\b"
        )
        for path in paths:
            source = path.read_text(encoding="utf-8")
            if not declaration.search(source):
                continue
            declared = pending & set(ENUM_DECLARATION.findall(masked_source(source)))
            vocabulary |= declared
            pending -= declared
            if not pending:
                break
    return vocabulary


def block_body(masked: str, opening_brace: int):
    """The text between a `{` and its match, or None when the file is unbalanced."""

    depth = 0
    for index in range(opening_brace, len(masked)):
        if masked[index] == "{":
            depth += 1
        elif masked[index] == "}":
            depth -= 1
            if depth == 0:
                return masked[opening_brace + 1:index]
    return None


def enclosing_openers(masked: str, offsets: list) -> dict:
    """For each offset, the text of every block-opening line still on the brace stack."""

    stack = []
    wanted = sorted(offsets)
    position = 0
    snapshots = {}
    for index, character in enumerate(masked):
        while position < len(wanted) and wanted[position] == index:
            snapshots[index] = [
                masked[masked.rfind("\n", 0, brace) + 1:masked.find("\n", brace)]
                for brace in stack
            ]
            position += 1
        if character == "{":
            stack.append(index)
        elif character == "}" and stack:
            stack.pop()
    return snapshots


def dropped_element_sites(repository: pathlib.Path) -> list:
    """Every "one row silently disappears" site, as (relative path, line, symbol, text)."""

    paths = in_scope_files(repository)
    vocabulary = vocabulary_enums(paths)
    if not vocabulary:
        return []

    found = []
    for path in paths:
        source = path.read_text(encoding="utf-8")
        # Same argument the substitution rule makes: masking can only suppress a match, so a
        # file that never names one of these types, or never reads a string out of an untyped
        # payload, cannot satisfy the conjunction however it is masked. Both halves are
        # required, which is what keeps the scan off nearly every file in the tree.
        if "as? String" not in source and ".stringValue" not in source:
            continue
        if not any(name + "(" in source for name in vocabulary):
            continue
        masked = masked_source(source)
        lines = masked.splitlines()
        relative = path.relative_to(repository).as_posix()

        candidates = []
        for conditional in CONDITIONAL_BINDING.finditer(masked):
            condition = conditional.group("condition")
            bound = {match.group("name") for match in WIRE_BINDING.finditer(condition)}
            if not bound:
                continue
            for binding in VOCABULARY_BINDING.finditer(condition):
                if binding.group("type") not in vocabulary:
                    continue
                if binding.group("argument") not in bound:
                    continue
                body = block_body(masked, conditional.end() - 1)
                if body is None:
                    continue
                statements = [text.strip() for text in body.strip().splitlines() if text.strip()]
                if not statements or not all(ELEMENT_DROP.match(text) for text in statements):
                    continue
                candidates.append((conditional.start(), binding, statements))
                break

        if not candidates:
            continue

        snapshots = enclosing_openers(masked, [offset for offset, _, _ in candidates])
        for offset, binding, statements in candidates:
            innermost = None
            for text in snapshots.get(offset, []):
                if COMPACT_MAP_CLOSURE.search(text) or FOR_IN_LOOP.search(text):
                    innermost = text
            if innermost is None:
                continue
            # `return nil` skips one element of a `compactMap` and keeps the rest. Inside a
            # `for` loop the same words abandon the whole collection instead, which is the
            # legible outcome this rule stays out of; there, `continue` is the per-element
            # drop. A closure nested in the loop is read as the loop's, not the map's, because
            # `innermost` is the last opener on the stack either way.
            if COMPACT_MAP_CLOSURE.search(innermost):
                drops_one_row = True
            else:
                drops_one_row = statements == ["continue"]
            if not drops_one_row:
                continue
            line = line_number(source, offset)
            found.append((
                relative,
                line,
                declaration_path(lines, line),
                " ".join(binding.group(0).split()),
            ))
    return found


def check(repository: pathlib.Path) -> list:
    found = sites(repository)
    failures = [
        f"{path}:{line}: unrecognised raw value defaults to a case — {text}  "
        f"[allowlist key: (\"{path}\", \"{symbol}\")]"
        for path, line, symbol, text in found
        if (path, symbol) not in ALLOWLIST
    ]
    failures += allowlist_failures(repository, found)

    dropped = dropped_element_sites(repository)
    failures += [
        f"{path}:{line}: unrecognised wire value drops this row — {text}  "
        f"[allowlist key: (\"{path}\", \"{symbol}\")]"
        for path, line, symbol, text in dropped
        if (path, symbol) not in DROPPED_ELEMENT_ALLOWLIST
    ]
    failures += allowlist_failures(
        repository,
        dropped,
        allowlist=DROPPED_ELEMENT_ALLOWLIST,
        rule="dropped-vocabulary",
        consequence="remove this row and leave the rest standing",
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

    failures = check(args.repository.resolve())
    if failures:
        print("\n".join(failures))
        if any("dropped-vocabulary" in failure or "drops this row" in failure
               for failure in failures):
            print(
                "dropped-vocabulary: an unrecognised wire value must not remove a row while the "
                "rest of the collection is kept — an absent row cannot be noticed, so give the "
                "vocabulary an explicit unknown case and decide about it at the projection, "
                "where the omission is a branch somebody can read; allowlist a site in "
                "scripts/check_failopen_defaults.py only with a reason that says why the missing "
                "row is the honest answer",
                file=sys.stderr,
            )
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
    print("dropped-vocabulary: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
