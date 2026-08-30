#!/usr/bin/env python3
"""Keep native navigator reads inside the typed fact/option/host boundary."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from collections import Counter
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple


CATALOG = pathlib.PurePosixPath(
    "Sources/Threading/Core/Extensions/HostFactCatalog.swift"
)
MARKERS = pathlib.PurePosixPath("Sources/Threading/UI/Views/NativeSidebarParity.swift")
SESSION_ROW = pathlib.PurePosixPath("Sources/Threading/UI/Views/SessionRowView.swift")
SIDEBAR_NODES = pathlib.PurePosixPath("Sources/Threading/UI/Views/SidebarOutlineNodes.swift")
PROJECT_SIDEBAR = pathlib.PurePosixPath(
    "Sources/Threading/UI/Views/ProjectSidebarViewController.swift"
)
SOURCE_ROOT = pathlib.PurePosixPath("Sources/Threading")

DOMAIN_TYPES = ("AgentSession", "Project", "ProjectTerminal")
SUBJECT_FOR_TYPE = {
    "AgentSession": "session",
    "Project": "project",
    "ProjectTerminal": "terminal",
}
STATIC_PROVIDER_ROOTS = ("GitInfo", "AppSettings")

ENUM_CASE = re.compile(r"^\s*case\s+([^\n]+)$", re.MULTILINE)
PARITY_LIST = re.compile(r"\bparity\s*:\s*\[([^\]]*)\]")
NATIVE_ALIAS_LIST = re.compile(r"\bnativeAliases\s*:\s*\[([^\]]*)\]")
NATIVE_ALIAS_CASE = re.compile(
    r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r'"(AgentSession|Project|ProjectTerminal)\.([A-Za-z_][A-Za-z0-9_]*)"\s*$',
    re.MULTILINE,
)
PROVIDER_ALIAS_LIST = re.compile(r"\bproviderAliases\s*:\s*\[([^\]]*)\]")
PROVIDER_ALIAS_CASE = re.compile(
    r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r'"([A-Z][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)"\s*$',
    re.MULTILINE,
)
SOURCE_ALIAS_CASE = re.compile(
    r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r'"([A-Za-z_][A-Za-z0-9_.]*)"\s*$',
    re.MULTILINE,
)
DOT_TOKEN = re.compile(r"\.([A-Za-z_][A-Za-z0-9_]*)")
RECEIVER_MEMBER_READ = re.compile(
    r"(?<![A-Za-z0-9_$])(\$0|[a-z_][A-Za-z0-9_]*)"
    r"(\s*\[[^\]\n]+\])?\s*[?!]?\s*\.\s*"
    r"([A-Za-z_][A-Za-z0-9_]*)\b"
)
KEYPATH_MEMBER_READ = re.compile(r"\\\.\s*([A-Za-z_][A-Za-z0-9_]*)\b")
MARKER_START = re.compile(r"\bNativeSidebarParity\.(fact|facts|option|host)\s*\(")
SHARED_PROVIDER_READ = re.compile(
    r"\b([A-Z][A-Za-z0-9_]*(?:Store|Runtime|Registry|Provider|ProviderSlot|Discovery|Service|Manager))"
    r"\.shared\s*[?!]?\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\b"
)
PROVIDER_TYPE = (
    r"[A-Z][A-Za-z0-9_]*(?:Store|Runtime|Registry|Provider|ProviderSlot|Discovery|Service|Manager)"
)
SHARED_PROVIDER_ROOT = re.compile(rf"\b({PROVIDER_TYPE})\.shared\b")
STATIC_PROVIDER_READ = re.compile(
    rf"\b({PROVIDER_TYPE})\.([a-z_][A-Za-z0-9_]*)\b"
)
LOCAL_DECLARATION = re.compile(
    r"\b(?:let|var)\s+([a-z_][A-Za-z0-9_]*)"
    r"(?:\s*:\s*([A-Za-z_][A-Za-z0-9_]*))?\s*=\s*"
    r"([^\n;,}]+)"
)
TYPED_PROVIDER_DECLARATION = re.compile(
    rf"\b(?:let|var)\s+([a-z_][A-Za-z0-9_]*)\s*:\s*"
    rf"(?:any\s+|some\s+)?({PROVIDER_TYPE})\s*[?!]?"
)


@dataclass(frozen=True)
class Marker:
    lane: str
    tokens: Tuple[str, ...]
    call_start: int
    value_start: int
    value_end: int

    def contains(self, offset: int) -> bool:
        return self.value_start <= offset < self.value_end


@dataclass(frozen=True)
class LexicalScope:
    start: int
    end: int
    depth: int

    def contains(self, offset: int) -> bool:
        return self.start < offset < self.end


@dataclass(frozen=True)
class ProviderBinding:
    name: str
    offset: int
    scope: LexicalScope
    provider_type: Optional[str]


@dataclass(frozen=True)
class CaptureBindingEvent:
    name: str
    expression: str
    scope: LexicalScope
    name_offset: int
    expression_offset: int
    binding_offset: int


def relative(path: pathlib.Path, repository: pathlib.Path) -> pathlib.PurePosixPath:
    return pathlib.PurePosixPath(path.relative_to(repository).as_posix())


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def mask_comments_and_strings(source: str) -> str:
    """Blank Swift comments/string text while retaining executable interpolations."""

    chars = list(source)
    index = 0
    mode = "code"
    block_depth = 0
    string_delimiter = ""
    string_hashes = 0
    suspended_strings: List[Tuple[str, int]] = []
    interpolation_depths: List[int] = []

    def blank(position: int) -> None:
        if position < len(chars) and chars[position] != "\n":
            chars[position] = " "

    def blank_range(start: int, length: int) -> None:
        for position in range(start, min(start + length, len(chars))):
            blank(position)

    def string_opening(position: int) -> Optional[Tuple[str, int, int]]:
        hashes = 0
        while position + hashes < len(source) and source[position + hashes] == "#":
            hashes += 1
        quote = position + hashes
        if source.startswith('\"\"\"', quote):
            return '\"\"\"', hashes, hashes + 3
        if quote < len(source) and source[quote] == '\"':
            return '\"', hashes, hashes + 1
        return None

    while index < len(source):
        if mode == "line_comment":
            blank(index)
            if source[index] == "\n":
                mode = "code"
            index += 1
            continue

        if mode == "block_comment":
            if source.startswith("/*", index):
                blank_range(index, 2)
                block_depth += 1
                index += 2
            elif source.startswith("*/", index):
                blank_range(index, 2)
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    mode = "code"
            else:
                blank(index)
                index += 1
            continue

        if mode == "string":
            interpolation = "\\" + ("#" * string_hashes) + "("
            closing = string_delimiter + ("#" * string_hashes)
            if source.startswith(interpolation, index):
                blank_range(index, len(interpolation))
                suspended_strings.append((string_delimiter, string_hashes))
                interpolation_depths.append(1)
                mode = "code"
                index += len(interpolation)
                continue
            if source.startswith(closing, index):
                blank_range(index, len(closing))
                mode = "code"
                index += len(closing)
                continue
            if string_hashes == 0 and source[index] == "\\":
                blank(index)
                if index + 1 < len(source):
                    blank(index + 1)
                    index += 2
                else:
                    index += 1
                continue
            blank(index)
            index += 1
            continue

        if source.startswith("//", index):
            blank_range(index, 2)
            mode = "line_comment"
            index += 2
            continue
        if source.startswith("/*", index):
            blank_range(index, 2)
            block_depth = 1
            mode = "block_comment"
            index += 2
            continue

        opening = string_opening(index)
        if opening is not None:
            string_delimiter, string_hashes, length = opening
            blank_range(index, length)
            mode = "string"
            index += length
            continue

        if interpolation_depths:
            if source[index] == "(":
                interpolation_depths[-1] += 1
            elif source[index] == ")":
                interpolation_depths[-1] -= 1
                if interpolation_depths[-1] == 0:
                    blank(index)
                    interpolation_depths.pop()
                    string_delimiter, string_hashes = suspended_strings.pop()
                    mode = "string"
                    index += 1
                    continue
        index += 1

    return "".join(chars)


def matching_delimiter(source: str, opening: int, left: str, right: str) -> Optional[int]:
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == left:
            depth += 1
        elif source[index] == right:
            depth -= 1
            if depth == 0:
                return index
    return None


def declaration_slice(source: str, pattern: str) -> Optional[Tuple[int, int]]:
    masked = mask_comments_and_strings(source)
    match = re.search(pattern, masked, re.MULTILINE)
    if match is None:
        return None
    opening = masked.find("{", match.end())
    if opening < 0:
        return None
    closing = matching_delimiter(masked, opening, "{", "}")
    if closing is None:
        return None
    return match.start(), closing + 1


def declaration(source: str, pattern: str) -> Optional[str]:
    bounds = declaration_slice(source, pattern)
    if bounds is None:
        return None
    return source[bounds[0]:bounds[1]]


def enum_cases(source: str, name: str) -> Tuple[Set[str], List[str]]:
    enum_source = declaration(source, rf"\benum\s+{re.escape(name)}\b")
    if enum_source is None:
        return set(), [f"has no {name} enum"]

    cases: Set[str] = set()
    failures: List[str] = []
    for match in ENUM_CASE.finditer(mask_comments_and_strings(enum_source)):
        for item in match.group(1).split(","):
            parsed = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", item)
            if parsed is None:
                continue
            token = parsed.group(1)
            if token in cases:
                failures.append(f"{name} repeats .{token}")
            cases.add(token)
    if not cases:
        failures.append(f"{name} declares no cases")
    return cases, failures


def host_provider_owners(
    marker_source: str,
    host_dependencies: Set[str],
) -> Tuple[Dict[str, str], List[str]]:
    failures: List[str] = []
    alias_source = declaration(
        marker_source, r"\benum\s+NativeSidebarHostProviderAlias\b"
    )
    aliases: Dict[str, str] = {}
    if alias_source is None:
        return {}, ["has no NativeSidebarHostProviderAlias enum"]
    for token, type_name, member in PROVIDER_ALIAS_CASE.findall(alias_source):
        if token in aliases:
            failures.append(f"NativeSidebarHostProviderAlias repeats .{token}")
            continue
        aliases[token] = f"{type_name}.{member}"
    if not aliases:
        failures.append("NativeSidebarHostProviderAlias declares no literal cases")

    parity = declaration(marker_source, r"\benum\s+NativeSidebarParity\b")
    if parity is None:
        return {}, failures + ["has no NativeSidebarParity enum"]
    masked = mask_comments_and_strings(parity)
    start = re.search(
        r"\bstatic\s+let\s+providerOwnership\s*:\s*\[[^\]]+\]\s*=\s*\[",
        masked,
    )
    if start is None:
        return {}, failures + ["NativeSidebarParity has no providerOwnership inventory"]
    opening = masked.rfind("[", start.start(), start.end())
    closing = matching_delimiter(masked, opening, "[", "]")
    if closing is None:
        return {}, failures + ["NativeSidebarParity.providerOwnership is unterminated"]

    ownership: Dict[str, str] = {}
    mapped_aliases: Counter[str] = Counter()
    for entry in split_top_level(masked[opening + 1:closing]):
        if not entry.strip():
            continue
        match = re.fullmatch(
            r"\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
            r"\.([A-Za-z_][A-Za-z0-9_]*)\s*",
            entry,
        )
        if match is None:
            failures.append("providerOwnership entries must be literal case pairs")
            continue
        alias, dependency = match.groups()
        mapped_aliases[alias] += 1
        provider = aliases.get(alias)
        if provider is None:
            failures.append(f"providerOwnership names unknown alias .{alias}")
            continue
        if dependency not in host_dependencies:
            failures.append(f"providerOwnership names unknown host .{dependency}")
            continue
        if provider in ownership:
            failures.append(f"providerOwnership repeats {provider}")
            continue
        ownership[provider] = dependency

    for alias in sorted(aliases):
        count = mapped_aliases[alias]
        if count == 0:
            failures.append(f"host provider alias .{alias} has no ownership entry")
        elif count > 1:
            failures.append(f"host provider alias .{alias} has {count} ownership entries")
    return ownership, failures


def source_owners(
    source: str,
    alias_enum: str,
    inventory: str,
    dependencies: Set[str],
) -> Tuple[Dict[str, str], List[str]]:
    """Read a compiler-visible source-to-dependency inventory."""

    failures: List[str] = []
    alias_source = declaration(source, rf"\benum\s+{re.escape(alias_enum)}\b")
    aliases: Dict[str, str] = {}
    if alias_source is None:
        return {}, [f"has no {alias_enum} enum"]
    for token, spelling in SOURCE_ALIAS_CASE.findall(alias_source):
        if token in aliases:
            failures.append(f"{alias_enum} repeats .{token}")
            continue
        aliases[token] = spelling
    if not aliases:
        failures.append(f"{alias_enum} declares no literal cases")

    masked = mask_comments_and_strings(source)
    start = re.search(
        rf"\bstatic\s+let\s+{re.escape(inventory)}\s*:\s*\[[^\]]+\]\s*=\s*\[",
        masked,
    )
    if start is None:
        return {}, failures + [f"has no {inventory} inventory"]
    opening = masked.rfind("[", start.start(), start.end())
    closing = matching_delimiter(masked, opening, "[", "]")
    if closing is None:
        return {}, failures + [f"{inventory} is unterminated"]

    ownership: Dict[str, str] = {}
    mapped_aliases: Counter[str] = Counter()
    for entry in split_top_level(masked[opening + 1:closing]):
        if not entry.strip():
            continue
        match = re.fullmatch(
            r"\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
            r"\.([A-Za-z_][A-Za-z0-9_]*)\s*",
            entry,
        )
        if match is None:
            failures.append(f"{inventory} entries must be literal case pairs")
            continue
        alias, dependency = match.groups()
        mapped_aliases[alias] += 1
        spelling = aliases.get(alias)
        if spelling is None:
            failures.append(f"{inventory} names unknown alias .{alias}")
            continue
        if dependency not in dependencies:
            failures.append(f"{inventory} names unknown dependency .{dependency}")
            continue
        if spelling in ownership:
            failures.append(f"{inventory} repeats {spelling}")
            continue
        ownership[spelling] = dependency

    for alias in sorted(aliases):
        count = mapped_aliases[alias]
        if count == 0:
            failures.append(f"{alias_enum} .{alias} has no ownership entry")
        elif count > 1:
            failures.append(f"{alias_enum} .{alias} has {count} ownership entries")
    return ownership, failures


def catalog_owners(
    catalog_source: str,
    members_by_type: Dict[str, Set[str]],
) -> Tuple[Set[str], Dict[Tuple[str, str], Set[str]], List[str]]:
    dependencies, failures = enum_cases(catalog_source, "NativeSidebarFactDependency")
    alias_source = declaration(catalog_source, r"\benum\s+NativeSidebarMemberAlias\b")
    aliases_by_token: Dict[str, Tuple[str, str]] = {}
    if alias_source is None:
        failures.append("has no NativeSidebarMemberAlias enum")
    else:
        for token, type_name, member in NATIVE_ALIAS_CASE.findall(alias_source):
            if token in aliases_by_token:
                failures.append(f"NativeSidebarMemberAlias repeats .{token}")
                continue
            aliases_by_token[token] = (type_name, member)
            if member not in members_by_type.get(type_name, set()):
                failures.append(
                    f"NativeSidebarMemberAlias .{token} names unknown "
                    f"{type_name}.{member}"
                )
        if not aliases_by_token:
            failures.append("NativeSidebarMemberAlias declares no literal cases")

    provider_source = declaration(
        catalog_source, r"\benum\s+NativeSidebarProviderAlias\b"
    )
    providers_by_token: Dict[str, Tuple[str, str]] = {}
    if provider_source is None:
        failures.append("has no NativeSidebarProviderAlias enum")
    else:
        for token, type_name, member in PROVIDER_ALIAS_CASE.findall(provider_source):
            if token in providers_by_token:
                failures.append(f"NativeSidebarProviderAlias repeats .{token}")
                continue
            providers_by_token[token] = (type_name, member)
        if not providers_by_token:
            failures.append("NativeSidebarProviderAlias declares no literal cases")

    catalog = declaration(catalog_source, r"\benum\s+HostFactCatalog\b")
    if catalog is None:
        return dependencies, {}, failures + ["has no HostFactCatalog enum"]

    masked = mask_comments_and_strings(catalog)
    start = re.search(r"\bstatic\s+let\s+all\s*:\s*\[[^\]]+\]\s*=\s*\[", masked)
    if start is None:
        return dependencies, {}, failures + ["HostFactCatalog has no descriptor inventory"]
    opening = masked.rfind("[", start.start(), start.end())
    closing = matching_delimiter(masked, opening, "[", "]")
    if closing is None:
        return dependencies, {}, failures + ["HostFactCatalog.all is unterminated"]

    owners: Counter[str] = Counter()
    semantic_tokens: Dict[Tuple[str, str], Set[str]] = {}
    inventory = masked[opening + 1:closing]
    for descriptor in split_top_level(inventory):
        descriptor_kind = re.match(r"\s*(session|project|terminal)\s*\(", descriptor)
        if descriptor_kind is None:
            continue
        subject = descriptor_kind.group(1)
        tokens = [
            token
            for parity in PARITY_LIST.findall(descriptor)
            for token in DOT_TOKEN.findall(parity)
        ]
        owners.update(tokens)
        projection_members = set(
            re.findall(r"\$0\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\b", descriptor)
        )
        for member in projection_members:
            semantic_tokens.setdefault((subject, member), set()).update(tokens)

        for aliases in NATIVE_ALIAS_LIST.findall(descriptor):
            parsed_aliases = DOT_TOKEN.findall(aliases)
            alias_remainder = DOT_TOKEN.sub("", aliases)
            if not parsed_aliases or re.sub(r"[\s,]", "", alias_remainder):
                failures.append(
                    f"{subject} descriptor has a non-literal nativeAliases case"
                )
            for alias in parsed_aliases:
                resolved = aliases_by_token.get(alias)
                if resolved is None:
                    failures.append(
                        f"{subject} descriptor aliases unknown .{alias}"
                    )
                    continue
                type_name, member = resolved
                semantic_tokens.setdefault(
                    (SUBJECT_FOR_TYPE[type_name], member), set()
                ).update(tokens)

        for aliases in PROVIDER_ALIAS_LIST.findall(descriptor):
            parsed_aliases = DOT_TOKEN.findall(aliases)
            alias_remainder = DOT_TOKEN.sub("", aliases)
            if not parsed_aliases or re.sub(r"[\s,]", "", alias_remainder):
                failures.append(
                    f"{subject} descriptor has a non-literal providerAliases case"
                )
            for alias in parsed_aliases:
                resolved = providers_by_token.get(alias)
                if resolved is None:
                    failures.append(
                        f"{subject} descriptor aliases unknown provider .{alias}"
                    )
                    continue
                type_name, member = resolved
                semantic_tokens.setdefault(
                    ("provider", f"{type_name}.{member}"), set()
                ).update(tokens)

    for token in sorted(set(owners) - dependencies):
        failures.append(f"HostFactCatalog publishes unknown dependency .{token}")
    for token in sorted(dependencies):
        count = owners[token]
        if count == 0:
            failures.append(f".{token} has no public HostFactCatalog descriptor")
        elif count > 1:
            failures.append(f".{token} is owned by {count} public descriptors")
    return dependencies, semantic_tokens, failures


def direct_type_schema(
    masked_declaration: str,
) -> Tuple[Set[str], Dict[str, Tuple[str, bool]]]:
    opening = masked_declaration.find("{")
    if opening < 0:
        return set(), {}
    members: Set[str] = set()
    domain_targets: Dict[str, Tuple[str, bool]] = {}
    depth = 1
    for line in masked_declaration[opening + 1:].splitlines(keepends=True):
        if depth == 1:
            match = re.match(
                r"\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
                r"(?:(?:private|fileprivate|internal|public|package)(?:\(set\))?\s+)?"
                r"(?:static\s+)?(?:let|var|func)\s+([A-Za-z_][A-Za-z0-9_]*)\b",
                line,
            )
            if match:
                members.add(match.group(1))
            target = re.match(
                r"\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
                r"(?:(?:private|fileprivate|internal|public|package)(?:\(set\))?\s+)?"
                r"(?:static\s+)?(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
                r"(\[\s*)?(AgentSession|Project|ProjectTerminal)\b",
                line,
            )
            if target:
                domain_targets[target.group(1)] = (
                    target.group(3),
                    target.group(2) is not None,
                )
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            break
    return members, domain_targets


def model_schema(
    repository: pathlib.Path,
) -> Tuple[Dict[str, Set[str]], Dict[Tuple[str, str], Tuple[str, bool]], List[str]]:
    members: Dict[str, Set[str]] = {type_name: set() for type_name in DOMAIN_TYPES}
    domain_targets: Dict[Tuple[str, str], Tuple[str, bool]] = {}
    failures: List[str] = []
    for path in sorted((repository / SOURCE_ROOT).rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        masked = mask_comments_and_strings(source)
        for target in DOMAIN_TYPES:
            pattern = re.compile(rf"\b(?:struct|class|extension)\s+{target}\b")
            offset = 0
            while match := pattern.search(masked, offset):
                opening = masked.find("{", match.end())
                closing = (
                    matching_delimiter(masked, opening, "{", "}")
                    if opening >= 0
                    else None
                )
                if closing is None:
                    failures.append(
                        f"{relative(path, repository)}:{line_number(source, match.start())}: "
                        f"unterminated {target} declaration"
                    )
                    break
                declaration_members, declaration_targets = direct_type_schema(
                    masked[match.start():closing + 1]
                )
                members[target].update(declaration_members)
                for member, destination in declaration_targets.items():
                    domain_targets[(target, member)] = destination
                offset = closing + 1
    return members, domain_targets, failures


def top_level_comma(source: str, start: int, end: int) -> Optional[int]:
    depths = {"(": 0, "[": 0, "{": 0, "<": 0}
    pairs = {")": "(", "]": "[", "}": "{", ">": "<"}
    for index in range(start, end):
        character = source[index]
        if character in depths:
            depths[character] += 1
        elif character in pairs and depths[pairs[character]] > 0:
            depths[pairs[character]] -= 1
        elif character == "," and all(value == 0 for value in depths.values()):
            return index
    return None


def parse_literal_tokens(lane: str, source: str) -> Optional[Tuple[str, ...]]:
    stripped = source.strip()
    if lane == "facts":
        if not (stripped.startswith("[") and stripped.endswith("]")):
            return None
        tokens = DOT_TOKEN.findall(stripped[1:-1])
        remainder = DOT_TOKEN.sub("", stripped[1:-1])
        if not tokens or re.sub(r"[\s,]", "", remainder):
            return None
        return tuple(tokens)
    match = re.fullmatch(r"\.([A-Za-z_][A-Za-z0-9_]*)", stripped)
    if match is None:
        return None
    return (match.group(1),)


def marker_calls(
    source: str,
    allowed: Dict[str, Set[str]],
    path: pathlib.PurePosixPath,
    line_offset: int = 0,
) -> Tuple[List[Marker], List[str]]:
    masked = mask_comments_and_strings(source)
    found: List[Marker] = []
    failures: List[str] = []
    for match in MARKER_START.finditer(masked):
        lane = match.group(1)
        opening = masked.rfind("(", match.start(), match.end())
        closing = matching_delimiter(masked, opening, "(", ")")
        if closing is None:
            failures.append(
                f"{path}:{line_offset + line_number(source, match.start())}: "
                f"unterminated {lane} marker"
            )
            continue
        comma = top_level_comma(masked, opening + 1, closing)
        if comma is None or top_level_comma(masked, comma + 1, closing) is not None:
            failures.append(
                f"{path}:{line_offset + line_number(source, match.start())}: "
                f"{lane} marker must have "
                "exactly two top-level arguments"
            )
            continue
        tokens = parse_literal_tokens(lane, masked[opening + 1:comma])
        if tokens is None:
            failures.append(
                f"{path}:{line_offset + line_number(source, match.start())}: "
                f"{lane} marker dependency "
                "must be a literal case or literal case array"
            )
            continue
        token_lane = "fact" if lane == "facts" else lane
        for token in tokens:
            if token not in allowed[token_lane]:
                failures.append(
                    f"{path}:{line_offset + line_number(source, match.start())}: "
                    f"{lane} marker names "
                    f"unknown or unpublished .{token}"
                )
        found.append(Marker(lane, tokens, match.start(), comma + 1, closing))
    return found, failures


def innermost_marker(found: Sequence[Marker], offset: int) -> Optional[Marker]:
    containing = [marker for marker in found if marker.contains(offset)]
    if not containing:
        return None
    return min(containing, key=lambda marker: marker.value_end - marker.value_start)


def split_top_level(source: str) -> List[str]:
    parts: List[str] = []
    start = 0
    depths = {"(": 0, "[": 0, "{": 0, "<": 0}
    pairs = {")": "(", "]": "[", "}": "{", ">": "<"}
    for index, character in enumerate(source):
        if character in depths:
            depths[character] += 1
        elif character in pairs and depths[pairs[character]] > 0:
            depths[pairs[character]] -= 1
        elif character == "," and all(value == 0 for value in depths.values()):
            parts.append(source[start:index])
            start = index + 1
    parts.append(source[start:])
    return parts


def function_parameters(function_source: str) -> Set[str]:
    masked = mask_comments_and_strings(function_source)
    match = re.search(r"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*\s*\(", masked)
    if match is None:
        return set()
    opening = masked.find("(", match.start(), match.end())
    closing = matching_delimiter(masked, opening, "(", ")")
    if closing is None:
        return set()
    names: Set[str] = set()
    for parameter in split_top_level(masked[opening + 1:closing]):
        head = parameter.split(":", 1)[0]
        identifiers = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", head)
        if identifiers and identifiers[-1] != "_":
            names.add(identifiers[-1])
    return names


def scalar_domain_parameters(function_source: str) -> Set[str]:
    """Parameters whose model-member semantics are audited by the enclosing declaration."""

    masked = mask_comments_and_strings(function_source)
    match = re.search(r"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*\s*\(", masked)
    if match is None:
        return set()
    opening = masked.find("(", match.start(), match.end())
    closing = matching_delimiter(masked, opening, "(", ")")
    if closing is None:
        return set()
    type_union = "|".join(DOMAIN_TYPES)
    names: Set[str] = set()
    for parameter in split_top_level(masked[opening + 1:closing]):
        typed = re.search(
            rf"\b([a-z_][A-Za-z0-9_]*)\s*:\s*(?:{type_union})\b\s*\??",
            parameter,
        )
        if typed is not None:
            names.add(typed.group(1))
    return names


def inferred_domain_names(
    masked: str,
    domain_targets: Dict[Tuple[str, str], Tuple[str, bool]],
) -> Tuple[Dict[str, Set[str]], Dict[str, Set[str]]]:
    """Conservatively follow typed native model values through ordinary aliases."""

    values: Dict[str, Set[str]] = {}
    collections: Dict[str, Set[str]] = {}
    type_union = "|".join(DOMAIN_TYPES)
    collection_factories = {
        name: type_name
        for name, type_name in re.findall(
            rf"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\b[^{{]*?->\s*\[\s*"
            rf"({type_union})\s*\]",
            masked,
        )
    }
    value_factories = {
        name: type_name
        for name, type_name in re.findall(
            rf"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\b[^{{]*?->\s*"
            rf"({type_union})\b\s*\??",
            masked,
        )
    }
    for match in re.finditer(
        rf"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*({type_union})\b\s*\??",
        masked,
    ):
        values.setdefault(match.group(1), set()).add(match.group(2))
    for match in re.finditer(
        rf"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\[\s*({type_union})\s*\]",
        masked,
    ):
        collections.setdefault(match.group(1), set()).add(match.group(2))
    for match in re.finditer(
        rf"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\[\s*"
        rf"[^:\]\n]+:\s*({type_union})\s*\]",
        masked,
    ):
        collections.setdefault(match.group(1), set()).add(match.group(2))

    def merge(target: Dict[str, Set[str]], name: str, types: Iterable[str]) -> None:
        target.setdefault(name, set()).update(types)

    def infer_expression(expression: str) -> Tuple[Set[str], Set[str]]:
        expression = expression.strip()
        if expression in values:
            return set(values[expression]), set()
        if expression in collections:
            return set(), set(collections[expression])
        member = re.fullmatch(
            r"([A-Za-z_][A-Za-z0-9_]*)\s*[?!]?\s*\.\s*"
            r"([A-Za-z_][A-Za-z0-9_]*)",
            expression,
        )
        if member is None:
            return set(), set()
        result_values: Set[str] = set()
        result_collections: Set[str] = set()
        for source_type in values.get(member.group(1), set()):
            destination = domain_targets.get((source_type, member.group(2)))
            if destination is None:
                continue
            target_type, is_collection = destination
            (result_collections if is_collection else result_values).add(target_type)
        return result_values, result_collections

    changed = True
    while changed:
        before = (
            sum(map(len, values.values())),
            sum(map(len, collections.values())),
        )
        for match in re.finditer(
            r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
            r"([A-Za-z_][A-Za-z0-9_]*)\b",
            masked,
        ):
            target, source = match.group(1), match.group(2)
            tail = masked[match.end():match.end() + 80]
            if source in value_factories and re.match(r"\s*\(", tail):
                merge(values, target, [value_factories[source]])
            if source in collection_factories and re.match(r"\s*\(", tail):
                merge(collections, target, [collection_factories[source]])
            if source in values:
                member = re.match(
                    r"\s*[?!]?\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\b",
                    tail,
                )
                if member is None:
                    merge(values, target, values[source])
                else:
                    for source_type in values[source]:
                        destination = domain_targets.get((source_type, member.group(1)))
                        if destination is None:
                            continue
                        target_type, is_collection = destination
                        merge(
                            collections if is_collection else values,
                            target,
                            [target_type],
                        )
            if source in collections:
                if re.match(
                    r"\s*(?:\[|\.(?:first|last)\b|\.randomElement\s*\()",
                    tail,
                ):
                    merge(values, target, collections[source])
                elif re.match(
                    r"\s*(?:\.(?:filter|sorted|reversed|prefix|suffix|dropFirst|"
                    r"dropLast)\b|(?:\n|[,)}]))",
                    tail,
                ):
                    merge(collections, target, collections[source])

        for match in re.finditer(
            r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
            r"\[([^\[\]\n]*)\]",
            masked,
        ):
            elements = split_top_level(match.group(2))
            dictionary_values: List[str] = []
            is_dictionary = True
            for element in elements:
                depths = {"(": 0, "[": 0, "{": 0, "<": 0}
                pairs = {")": "(", "]": "[", "}": "{", ">": "<"}
                colon: Optional[int] = None
                has_top_level_ternary = False
                for index, character in enumerate(element):
                    if character in depths:
                        depths[character] += 1
                    elif character in pairs and depths[pairs[character]] > 0:
                        depths[pairs[character]] -= 1
                    elif all(value == 0 for value in depths.values()):
                        if character == "?":
                            has_top_level_ternary = True
                        elif character == ":" and not has_top_level_ternary:
                            colon = index
                            break
                if colon is None:
                    is_dictionary = False
                    break
                dictionary_values.append(element[colon + 1:])

            element_types: List[Set[str]] = []
            for element in (dictionary_values if is_dictionary else elements):
                inferred_values, inferred_collections = infer_expression(element)
                if not inferred_values or inferred_collections:
                    element_types = []
                    break
                element_types.append(inferred_values)
            if element_types and all(types == element_types[0] for types in element_types):
                merge(collections, match.group(1), element_types[0])

        marker_pattern = re.compile(
            r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
            r"NativeSidebarParity\.(?:fact|facts|host|option)\s*\("
        )
        for match in marker_pattern.finditer(masked):
            opening = masked.rfind("(", match.start(), match.end())
            closing = matching_delimiter(masked, opening, "(", ")")
            if closing is None:
                continue
            comma = top_level_comma(masked, opening + 1, closing)
            if comma is None:
                continue
            inferred_values, inferred_collections = infer_expression(
                masked[comma + 1:closing]
            )
            merge(values, match.group(1), inferred_values)
            merge(collections, match.group(1), inferred_collections)

        for match in re.finditer(
            r"\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)\b",
            masked,
        ):
            if match.group(2) in collections:
                merge(values, match.group(1), collections[match.group(2)])
        for match in re.finditer(
            r"\bfor\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,[^)]*\)\s+in\s+"
            r"zip\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\b",
            masked,
        ):
            if match.group(2) in collections:
                merge(values, match.group(1), collections[match.group(2)])
        after = (
            sum(map(len, values.values())),
            sum(map(len, collections.values())),
        )
        changed = before != after
    return values, collections


def domain_closure_aliases(
    masked: str,
    collections: Dict[str, Set[str]],
) -> List[Tuple[int, int, Set[str], bool, Set[str]]]:
    """Return element-variable scopes for common collection operations."""

    scopes: List[Tuple[int, int, Set[str], bool, Set[str]]] = []
    operations = (
        "map|compactMap|flatMap|filter|sorted|contains|allSatisfy|firstIndex|"
        "prefix|dropWhile|reduce|forEach"
    )
    pattern = re.compile(
        rf"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*"
        r"(?:(?:lazy\s*\.\s*)|(?:(?:enumerated|reversed)\s*\(\s*\)\s*\.\s*))*"
        rf"(?:{operations})\b"
    )
    for match in pattern.finditer(masked):
        if match.group(1) not in collections:
            continue
        opening = masked.find("{", match.end())
        if opening < 0:
            continue
        call_opening = masked.find("(", match.end(), opening)
        if call_opening >= 0:
            call_closing = matching_delimiter(masked, call_opening, "(", ")")
            if call_closing is not None and call_closing < opening:
                if masked[call_closing + 1:opening].strip():
                    continue
        elif masked[match.end():opening].strip():
            continue
        closing = matching_delimiter(masked, opening, "{", "}")
        if closing is None:
            continue
        header = masked[opening + 1:min(closing, opening + 300)]
        named = re.match(r"\s*([^{}\n]+?)\s+in\b", header)
        if named is None:
            scopes.append(
                (opening + 1, closing, set(), True, set(collections[match.group(1)]))
            )
            continue
        names = set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", named.group(1)))
        if ("reduce" in match.group(0) or "enumerated" in match.group(0)) and len(names) > 1:
            names = {list(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", named.group(1)))[-1]}
        scopes.append(
            (opening + 1, closing, names, False, set(collections[match.group(1)]))
        )
    return scopes


def domain_member_reads(
    masked: str,
    members_by_type: Dict[str, Set[str]],
    domain_targets: Dict[Tuple[str, str], Tuple[str, bool]],
) -> Iterable[Tuple[int, str, str]]:
    values, collections = inferred_domain_names(masked, domain_targets)
    closure_scopes = domain_closure_aliases(masked, collections)
    for match in RECEIVER_MEMBER_READ.finditer(masked):
        receiver, subscript, member = match.group(1), match.group(2), match.group(3)
        receiver_types: Set[str] = set(values.get(receiver, set()))
        if subscript is not None:
            receiver_types.update(collections.get(receiver, set()))
        for start, end, names, implicit, types in closure_scopes:
            if start <= match.start() < end and (
                (implicit and receiver == "$0") or receiver in names
            ):
                receiver_types.update(types)
        for type_name in sorted(receiver_types):
            if member in members_by_type.get(type_name, set()):
                yield match.start(), type_name, f".{member}"

    tuple_slots: Dict[Tuple[str, int], Set[str]] = {}
    for declaration_match in re.finditer(
        r"\b(?:let|var)\s+([a-z_][A-Za-z0-9_]*)\s*=\s*\(([^()\n]*)\)",
        masked,
    ):
        for index, element in enumerate(split_top_level(declaration_match.group(2))):
            element = element.strip()
            if element in values:
                tuple_slots[(declaration_match.group(1), index)] = set(values[element])
    tuple_member_read = re.compile(
        r"(?<![A-Za-z0-9_$])([a-z_][A-Za-z0-9_]*)\s*\.\s*"
        r"([0-9]+)\s*[?!]?\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\b"
    )
    for match in tuple_member_read.finditer(masked):
        for type_name in sorted(
            tuple_slots.get((match.group(1), int(match.group(2))), set())
        ):
            if match.group(3) in members_by_type.get(type_name, set()):
                yield match.start(), type_name, f".{match.group(3)}"

    key_path_subscript = re.compile(
        r"(?<![A-Za-z0-9_$])([a-z_][A-Za-z0-9_]*)"
        r"(\s*\[(?!\s*keyPath\s*:)[^\]\n]+\])?\s*"
        r"\[\s*keyPath\s*:\s*(\\)\s*"
        r"(?:(AgentSession|Project|ProjectTerminal)\s*)?\.\s*"
        r"([A-Za-z_][A-Za-z0-9_]*)\s*\]"
    )
    for match in key_path_subscript.finditer(masked):
        receiver, element_subscript, _, rooted_type, member = match.groups()
        receiver_types = (
            set(collections.get(receiver, set()))
            if element_subscript is not None
            else set(values.get(receiver, set()))
        )
        for type_name in sorted(receiver_types):
            if rooted_type is not None and rooted_type != type_name:
                continue
            if member in members_by_type.get(type_name, set()):
                yield match.start(3), type_name, f".{member}"

    for collection in collections:
        element_read = re.compile(
            rf"\b{re.escape(collection)}\s*\.\s*(?:first|last)\s*[?!]?\s*\.\s*"
            r"([A-Za-z_][A-Za-z0-9_]*)\b"
        )
        for match in element_read.finditer(masked):
            for type_name in sorted(collections[collection]):
                if match.group(1) in members_by_type.get(type_name, set()):
                    yield match.start(), type_name, f".{match.group(1)}"

        key_path = re.compile(
            rf"\b{re.escape(collection)}\s*\.\s*"
            r"(?:map|compactMap|flatMap|filter|sorted|contains|allSatisfy)\s*\(\s*"
            r"\\\.\s*([A-Za-z_][A-Za-z0-9_]*)\b"
        )
        for match in key_path.finditer(masked):
            for type_name in sorted(collections[collection]):
                if match.group(1) in members_by_type.get(type_name, set()):
                    offset = masked.find("\\", match.start(), match.end())
                    yield offset, type_name, f".{match.group(1)}"


def domain_value_escapes(
    masked: str,
    domain_targets: Dict[Tuple[str, str], Tuple[str, bool]],
) -> Iterable[Tuple[int, str, str]]:
    """Find whole model values handed to code outside the audited declaration."""

    values, collections = inferred_domain_names(masked, domain_targets)
    domain_names = set(values) | set(collections)
    internal_functions = set(
        re.findall(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", masked)
    )
    safe_functions = internal_functions | {
        "for",
        "guard",
        "if",
        "return",
        "switch",
        "while",
        "zip",
    }
    call_start = re.compile(
        r"\b([A-Za-z_][A-Za-z0-9_]*(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\("
    )
    for call in call_start.finditer(masked):
        callee_parts = re.split(r"\s*\.\s*", call.group(1))
        callee = callee_parts[-1]
        is_internal_call = callee in safe_functions and (
            len(callee_parts) == 1 or callee_parts[:-1] in (["self"], ["Self"])
        )
        is_local_collection_call = (
            len(callee_parts) == 2
            and callee_parts[0] in collections
            and callee in {"append", "insert"}
        )
        if (
            is_internal_call
            or is_local_collection_call
            or "NativeSidebarParity" in call.group(1)
        ):
            continue
        opening = masked.rfind("(", call.start(), call.end())
        closing = matching_delimiter(masked, opening, "(", ")")
        if closing is None:
            continue
        argument_start = opening + 1
        for argument in split_top_level(masked[argument_start:closing]):
            for name in domain_names:
                name_read = re.compile(
                    rf"(?<![A-Za-z0-9_$.]){re.escape(name)}\b"
                    r"(?!\s*[?!]?\s*(?:\.|\[|:))"
                )
                for match in name_read.finditer(argument):
                    types = values.get(name, set()) | collections.get(name, set())
                    for type_name in sorted(types):
                        yield argument_start + match.start(), type_name, name
            argument_start += len(argument) + 1


def lexical_scopes(masked: str) -> List[LexicalScope]:
    """Return brace scopes without pretending braces in comments/strings are code."""

    pairs: List[Tuple[int, int, int]] = [(-1, len(masked), 0)]
    stack: List[Tuple[int, int]] = []
    for offset, character in enumerate(masked):
        if character == "{":
            stack.append((offset, len(stack) + 1))
        elif character == "}" and stack:
            opening, depth = stack.pop()
            pairs.append((opening, offset, depth))
    return [LexicalScope(*pair) for pair in pairs]


def innermost_scope(scopes: Sequence[LexicalScope], offset: int) -> LexicalScope:
    return max(
        (scope for scope in scopes if scope.contains(offset)),
        key=lambda scope: scope.depth,
    )


def provider_reads(masked: str) -> Iterable[Tuple[int, str]]:
    """Find provider access while respecting Swift's local lexical shadowing."""

    seen: Set[Tuple[int, str]] = set()
    for match in SHARED_PROVIDER_READ.finditer(masked):
        item = (match.start(), f"{match.group(1)}.shared.{match.group(2)}")
        if item not in seen:
            seen.add(item)
            yield item
    for match in STATIC_PROVIDER_READ.finditer(masked):
        if match.group(2) == "shared":
            continue
        item = (match.start(), f"{match.group(1)}.{match.group(2)}")
        if item not in seen:
            seen.add(item)
            yield item

    scopes = lexical_scopes(masked)
    scopes_by_start = {scope.start: scope for scope in scopes}
    bindings: List[ProviderBinding] = []
    declaration_offsets: Set[int] = set()
    propagation_offsets: Set[int] = set()
    shared_initializer_offsets: Set[int] = set()
    local_typealiases = set(
        re.findall(r"\btypealias\s+([A-Z][A-Za-z0-9_]*)\s*=", masked)
    )

    def recognized_provider_type(type_name: str) -> bool:
        return (
            re.fullmatch(PROVIDER_TYPE, type_name) is not None
            and type_name not in local_typealiases
        )

    def visible_binding(name: str, offset: int) -> Optional[ProviderBinding]:
        candidates = [
            binding
            for binding in bindings
            if binding.name == name
            and binding.offset <= offset
            and binding.scope.contains(offset)
        ]
        if not candidates:
            return None
        return max(candidates, key=lambda binding: (binding.scope.depth, binding.offset))

    def provider_type(expression: str, annotation: Optional[str], offset: int) -> Optional[str]:
        expression = expression.strip()
        direct = re.fullmatch(rf"({PROVIDER_TYPE})\.shared\s*[?!]?", expression)
        if direct is not None:
            return direct.group(1)
        if (
            annotation is not None
            and recognized_provider_type(annotation)
            and re.fullmatch(r"\.shared\s*[?!]?", expression)
        ):
            return annotation
        propagation = re.fullmatch(
            r"(?:(?:self|Self)\s*[?!]?\s*\.\s*)?"
            r"([a-z_][A-Za-z0-9_]*)\s*[?!]?",
            expression,
        )
        if propagation is None:
            return None
        source = visible_binding(propagation.group(1), offset)
        return source.provider_type if source is not None else None

    events: List[Tuple[int, str, object]] = []
    initialized_declaration_offsets: Set[int] = set()
    for match in LOCAL_DECLARATION.finditer(masked):
        events.append((match.start(1), "declaration", match))
        initialized_declaration_offsets.add(match.start(1))
    for match in TYPED_PROVIDER_DECLARATION.finditer(masked):
        if (
            match.start(1) not in initialized_declaration_offsets
            and recognized_provider_type(match.group(2))
        ):
            events.append((match.start(1), "typedDeclaration", match))

    # Function parameters belong to the function body, not to the containing type.
    function = re.compile(r"\b(?:func|init|subscript)\b")
    for match in function.finditer(masked):
        opening = masked.find("(", match.end())
        if opening < 0:
            continue
        closing = matching_delimiter(masked, opening, "(", ")")
        if closing is None:
            continue
        body = masked.find("{", closing)
        if body < 0 or body not in scopes_by_start:
            continue
        next_declaration = function.search(masked, closing + 1, body)
        if next_declaration is not None:
            continue
        parameter_offset = opening + 1
        for parameter in split_top_level(masked[opening + 1:closing]):
            typed = re.search(
                r"\b([a-z_][A-Za-z0-9_]*)\s*:\s*"
                r"(?:any\s+|some\s+)?([A-Z][A-Za-z0-9_]*)",
                parameter,
            )
            if typed is not None:
                type_name = (
                    typed.group(2)
                    if recognized_provider_type(typed.group(2))
                    else None
                )
                events.append(
                    (
                        body,
                        "parameter",
                        (
                            typed.group(1),
                            scopes_by_start[body],
                            type_name,
                            parameter_offset + typed.start(1),
                        ),
                    )
                )
            if typed is not None and type_name is not None:
                shared = SHARED_PROVIDER_ROOT.search(parameter)
                if shared is not None:
                    shared_initializer_offsets.add(parameter_offset + shared.start())
            parameter_offset += len(parameter) + 1

    # Capture-list bindings and closure arguments belong only to the closure body.
    for scope in scopes:
        if scope.start < 0:
            continue
        header_end = min(scope.end, scope.start + 500)
        cursor = scope.start + 1
        while cursor < header_end and masked[cursor].isspace():
            cursor += 1
        capture_bounds: Optional[Tuple[int, int]] = None
        if cursor < header_end and masked[cursor] == "[":
            capture_closing = matching_delimiter(masked, cursor, "[", "]")
            if capture_closing is None or capture_closing >= header_end:
                continue
            capture_bounds = (cursor + 1, capture_closing)
            cursor = capture_closing + 1

        if capture_bounds is None:
            closure = re.match(r"\s*([^{}\n]*?)\s+in\b", masked[cursor:header_end])
        else:
            closure = re.match(r"\s*([^{}]*?)\s+in\b", masked[cursor:header_end])
        if closure is None:
            continue
        body_offset = cursor + closure.end()

        if capture_bounds is not None:
            capture_start, capture_end = capture_bounds
            entry_offset = capture_start
            for entry in split_top_level(masked[capture_start:capture_end]):
                parsed = re.fullmatch(
                    r"\s*(?:(?:weak|unowned(?:\(safe\))?)\s+)?"
                    r"([a-z_][A-Za-z0-9_]*)"
                    r"(?:\s*=\s*(.+?))?\s*",
                    entry,
                )
                if parsed is not None and parsed.group(1) not in {"self", "super"}:
                    name = parsed.group(1)
                    expression = parsed.group(2) or name
                    name_offset = entry_offset + parsed.start(1)
                    expression_offset = (
                        entry_offset + parsed.start(2)
                        if parsed.group(2) is not None
                        else name_offset
                    )
                    events.append(
                        (
                            name_offset,
                            "capture",
                            CaptureBindingEvent(
                                name,
                                expression,
                                scope,
                                name_offset,
                                expression_offset,
                                body_offset,
                            ),
                        )
                    )
                entry_offset += len(entry) + 1

        arguments = closure.group(1) or ""
        argument_offset = cursor + closure.start(1)
        for argument in split_top_level(arguments):
            typed = re.search(
                r"\b([a-z_][A-Za-z0-9_]*)\s*:\s*"
                r"(?:any\s+|some\s+)?([A-Z][A-Za-z0-9_]*)",
                argument,
            )
            plain = re.fullmatch(r"\s*([a-z_][A-Za-z0-9_]*)\s*", argument)
            name = typed.group(1) if typed is not None else plain.group(1) if plain else None
            if name is not None:
                type_name = (
                    typed.group(2)
                    if typed is not None and recognized_provider_type(typed.group(2))
                    else None
                )
                name_match = typed if typed is not None else plain
                assert name_match is not None
                events.append(
                    (
                        scope.start,
                        "parameter",
                        (
                            name,
                            scope,
                            type_name,
                            argument_offset + name_match.start(1),
                        ),
                    )
                )
            argument_offset += len(argument) + 1

    assignment = re.compile(
        r"(?<![A-Za-z0-9_$.])([a-z_][A-Za-z0-9_]*)\s*=(?!=)\s*([^\n;,}]+)"
    )
    binding_declaration_offsets = {
        event[0]
        for event in events
        if event[1] in {"declaration", "capture"}
    }
    for match in assignment.finditer(masked):
        if match.start(1) not in binding_declaration_offsets:
            events.append((match.start(1), "assignment", match))

    for offset, kind, payload in sorted(events, key=lambda event: (event[0], event[1])):
        if kind == "parameter":
            name, scope, type_name, name_offset = payload  # type: ignore[misc]
            declaration_offsets.add(name_offset)
            bindings.append(ProviderBinding(name, offset, scope, type_name))
            continue

        if kind == "capture":
            assert isinstance(payload, CaptureBindingEvent)
            resolved_type = provider_type(
                payload.expression,
                None,
                payload.name_offset,
            )
            declaration_offsets.add(payload.name_offset)
            propagation = re.fullmatch(
                r"\s*(?:(?:self|Self)\s*[?!]?\s*\.\s*)?"
                r"([a-z_][A-Za-z0-9_]*)\s*[?!]?\s*",
                payload.expression,
            )
            if propagation is not None and resolved_type is not None:
                propagation_offsets.add(payload.expression_offset)
            if resolved_type is not None:
                shared = SHARED_PROVIDER_ROOT.search(
                    masked,
                    payload.expression_offset,
                    payload.expression_offset + len(payload.expression),
                )
                if shared is not None:
                    shared_initializer_offsets.add(shared.start())
            bindings.append(
                ProviderBinding(
                    payload.name,
                    payload.binding_offset,
                    payload.scope,
                    resolved_type,
                )
            )
            continue

        match = payload
        assert isinstance(match, re.Match)
        name = match.group(1)
        if kind == "typedDeclaration":
            scope = innermost_scope(scopes, offset)
            declaration_offsets.add(offset)
            bindings.append(ProviderBinding(name, offset, scope, match.group(2)))
            continue
        if kind == "declaration":
            annotation = match.group(2)
            expression = match.group(3)
            scope = innermost_scope(scopes, offset)
            declaration_offsets.add(offset)
        else:
            prior = visible_binding(name, offset)
            if prior is None:
                continue
            annotation = None
            expression = match.group(2)
            scope = innermost_scope(scopes, offset)
        resolved_type = provider_type(expression, annotation, offset)
        if resolved_type is not None:
            shared = SHARED_PROVIDER_ROOT.search(masked, match.start(), match.end())
            if shared is not None:
                shared_initializer_offsets.add(shared.start())
        propagation = re.fullmatch(
            r"\s*(?:(?:self|Self)\s*[?!]?\s*\.\s*)?"
            r"([a-z_][A-Za-z0-9_]*)\s*[?!]?\s*",
            expression,
        )
        if propagation is not None and resolved_type is not None:
            source_offset = masked.find(propagation.group(1), match.start(), match.end())
            if source_offset >= 0:
                propagation_offsets.add(source_offset)
        bindings.append(ProviderBinding(name, offset, scope, resolved_type))

    # Constructor/property injection is internal alias propagation, not a use of the provider.
    storage_assignment = re.compile(
        r"(?<![A-Za-z0-9_$.])(?:self|Self)\s*[?!]?\s*\.\s*"
        r"([a-z_][A-Za-z0-9_]*)\s*=(?!=)\s*"
        r"((?:(?:self|Self)\s*[?!]?\s*\.\s*)?"
        r"[a-z_][A-Za-z0-9_]*\s*[?!]?|\.shared\s*[?!]?)"
    )
    for match in storage_assignment.finditer(masked):
        stored = visible_binding(match.group(1), match.start())
        if stored is None or stored.provider_type is None:
            continue
        expression = match.group(2)
        resolved_type = (
            stored.provider_type
            if re.fullmatch(r"\.shared\s*[?!]?", expression.strip())
            else provider_type(expression, None, match.start(2))
        )
        if resolved_type != stored.provider_type:
            continue
        propagation_offsets.add(match.start())
        propagation_offsets.add(match.start(2))

    alias_names = {binding.name for binding in bindings if binding.provider_type is not None}
    member_offsets: Set[int] = set()
    for alias in alias_names:
        member_read = re.compile(
            rf"(?<![A-Za-z0-9_$.])(?:(?:self|Self)\s*[?!]?\s*\.\s*)?"
            rf"{re.escape(alias)}\s*[?!]?\s*\.\s*"
            r"([A-Za-z_][A-Za-z0-9_]*)\b"
        )
        for match in member_read.finditer(masked):
            binding = visible_binding(alias, match.start())
            if binding is None or binding.provider_type is None:
                continue
            member_offsets.add(match.start())
            item = (
                match.start(),
                f"{binding.provider_type}.shared.{match.group(1)}",
            )
            if item not in seen:
                seen.add(item)
                yield item

    for match in SHARED_PROVIDER_ROOT.finditer(masked):
        if match.start() in shared_initializer_offsets:
            continue
        if re.match(r"\s*[?!]?\s*\.", masked[match.end():]):
            continue
        item = (match.start(), f"{match.group(1)}.shared")
        if item not in seen:
            seen.add(item)
            yield item

    for alias in alias_names:
        alias_read = re.compile(
            rf"(?<![A-Za-z0-9_$.])(?:(?:self|Self)\s*[?!]?\s*\.\s*)?"
            rf"{re.escape(alias)}\b"
        )
        for match in alias_read.finditer(masked):
            binding = visible_binding(alias, match.start())
            if binding is None or binding.provider_type is None:
                continue
            if match.start() in (
                declaration_offsets | propagation_offsets | member_offsets
            ):
                continue
            item = (match.start(), f"{binding.provider_type}.shared")
            if item not in seen:
                seen.add(item)
                yield item
    for root in STATIC_PROVIDER_ROOTS:
        shared = r"(?:\s*\.\s*shared)?" if root == "AppSettings" else ""
        pattern = re.compile(
            rf"\b{re.escape(root)}{shared}\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\b"
        )
        for match in pattern.finditer(masked):
            item = (match.start(), f"{root}.{match.group(1)}")
            if item not in seen:
                seen.add(item)
                yield item


def audit_scope(
    path: pathlib.PurePosixPath,
    scope_name: str,
    source: str,
    members_by_type: Dict[str, Set[str]],
    domain_targets: Dict[Tuple[str, str], Tuple[str, bool]],
    allowed: Dict[str, Set[str]],
    semantic_tokens: Dict[Tuple[str, str], Set[str]],
    host_provider_tokens: Dict[str, str],
    fact_input_tokens: Dict[str, str],
    option_source_tokens: Dict[str, str],
    host_input_tokens: Dict[str, str],
    source_usage: Counter[Tuple[str, str]],
    audited_parameters: Iterable[str] = (),
    exempt_entry_parameters: Iterable[str] = (),
    line_offset: int = 0,
    audit_domain: bool = True,
    audit_providers: bool = True,
    report_marker_failures: bool = True,
) -> Tuple[List[str], Counter[Tuple[str, str]]]:
    failures: List[str] = []
    masked = mask_comments_and_strings(source)
    found, marker_failures = marker_calls(source, allowed, path, line_offset)
    if report_marker_failures:
        failures.extend(marker_failures)
    audited: List[Tuple[int, str, str, Optional[str]]] = []

    if audit_domain:
        for offset, type_name, spelling in domain_member_reads(
            masked, members_by_type, domain_targets
        ):
            audited.append((offset, "domain member", spelling, type_name))
        for offset, type_name, spelling in domain_value_escapes(
            masked, domain_targets
        ):
            audited.append((offset, "domain value", spelling, type_name))
    if audit_providers:
        for offset, spelling in provider_reads(masked):
            audited.append((offset, "provider root", spelling, None))

    opening = masked.find("{")
    exempt_entries = set(exempt_entry_parameters)
    for parameter in audited_parameters:
        pattern = re.compile(rf"\b{re.escape(parameter)}\b")
        for match in pattern.finditer(masked, opening + 1):
            suffix = masked[match.end():]
            if re.match(r"\s*:", suffix):
                continue
            audited.append((match.start(), "entry input", parameter, None))

    marker_semantics: Dict[Marker, Set[str]] = {}
    for offset, kind, spelling, type_name in sorted(
        set(audited), key=lambda item: (item[0], item[1], item[2], item[3] or "")
    ):
        diagnostic_line = line_offset + line_number(source, offset)
        marker = innermost_marker(found, offset)
        if marker is None:
            if kind == "domain value":
                failures.append(
                    f"{path}:{diagnostic_line}: whole {type_name} value {spelling} "
                    "escapes outside NativeSidebarParity"
                )
            else:
                failures.append(
                    f"{path}:{diagnostic_line}: {scope_name} reads {kind} "
                    f"{spelling} outside NativeSidebarParity"
                )
            continue
        if kind == "domain value" and not (
            type_name == "AgentSession"
            and marker.lane == "host"
            and marker.tokens == ("hoverContent",)
        ):
            failures.append(
                f"{path}:{diagnostic_line}: whole {type_name} value {spelling} may only "
                "escape through host(.hoverContent)"
            )
        if kind == "domain member":
            required_host: Optional[str] = None
            if spelling == ".id":
                required_host = "entityIdentity"
            elif spelling == ".folderPath":
                required_host = "localRepositoryContext"
            if required_host is not None and not (
                marker.lane == "host" and marker.tokens == (required_host,)
            ):
                failures.append(
                    f"{path}:{diagnostic_line}: domain {spelling} must use "
                    f"host(.{required_host})"
                )
            elif marker.lane in ("host", "option") and required_host is None:
                failures.append(
                    f"{path}:{diagnostic_line}: domain {spelling} cannot use "
                    f"{marker.lane}(.{marker.tokens[0]}); publish a fact"
                )
        if kind == "entry input":
            source_key = f"{scope_name}.{spelling}"
            lane = "fact" if marker.lane == "facts" else marker.lane
            ownership = {
                "fact": fact_input_tokens,
                "option": option_source_tokens,
                "host": host_input_tokens,
            }
            known_lanes = {
                candidate_lane
                for candidate_lane, sources in ownership.items()
                if source_key in sources
            }
            expected = ownership.get(lane, {}).get(source_key)
            if expected is not None:
                source_usage[(lane, source_key)] += 1
            if expected is not None and marker.tokens != (expected,):
                failures.append(
                    f"{path}:{diagnostic_line}: entry input {spelling} must use its "
                    f"owned {lane} dependency (.{expected})"
                )
            elif expected is None and known_lanes:
                choices = ", ".join(sorted(known_lanes))
                failures.append(
                    f"{path}:{diagnostic_line}: entry input {spelling} must use its "
                    f"owned lane ({choices})"
                )
            elif expected is None and spelling not in exempt_entries:
                failures.append(
                    f"{path}:{diagnostic_line}: entry input {spelling} has no typed "
                    "ownership inventory"
                )
        if spelling.startswith("AppSettings."):
            expected_option = option_source_tokens.get(spelling)
            if expected_option is not None:
                source_usage[("option", spelling)] += 1
            if expected_option is None:
                failures.append(
                    f"{path}:{diagnostic_line}: {spelling} has no typed option-source owner"
                )
            elif marker.lane != "option":
                failures.append(
                    f"{path}:{diagnostic_line}: {spelling} must use the option lane"
                )
            elif marker.tokens != (expected_option,):
                failures.append(
                    f"{path}:{diagnostic_line}: {spelling} must use its owned option "
                    f"dependency (.{expected_option})"
                )
        elif spelling.startswith("GitInfo."):
            expected_host = host_input_tokens.get(spelling)
            if expected_host is not None:
                source_usage[("host", spelling)] += 1
            if expected_host is None:
                failures.append(
                    f"{path}:{diagnostic_line}: {spelling} has no typed host-source owner"
                )
            elif marker.lane != "host" or marker.tokens != (expected_host,):
                failures.append(
                    f"{path}:{diagnostic_line}: {spelling} must use its owned host "
                    f"dependency (.{expected_host})"
                )
        elif kind == "provider root":
            provider_key = spelling.replace(".shared.", ".")
            expected_host = host_provider_tokens.get(provider_key)
            if marker.lane == "host" and expected_host is None:
                failures.append(
                    f"{path}:{diagnostic_line}: {spelling} must publish a fact"
                )
            elif marker.lane == "host" and marker.tokens != (expected_host,):
                failures.append(
                    f"{path}:{diagnostic_line}: {spelling} must use its host-owned "
                    f"dependency (.{expected_host})"
                )
            elif marker.lane not in ("fact", "facts", "host"):
                failures.append(
                    f"{path}:{diagnostic_line}: {spelling} must publish a fact"
                )

        semantic_member = spelling.rsplit(".", 1)[-1]
        if type_name is not None:
            semantic_key: Optional[Tuple[str, str]] = (
                SUBJECT_FOR_TYPE[type_name], semantic_member
            )
        elif kind == "provider root":
            semantic_key = ("provider", spelling.replace(".shared.", "."))
        else:
            semantic_key = None
        expected = semantic_tokens.get(semantic_key, set())
        if kind == "domain member" and expected:
            marker_semantics.setdefault(marker, set()).update(expected)
        if kind in ("domain member", "provider root") and marker.lane in (
            "fact",
            "facts",
        ):
            if not expected:
                failures.append(
                    f"{path}:{diagnostic_line}: {spelling} has no catalog-owned "
                    "fact dependency"
                )
            elif expected.isdisjoint(marker.tokens):
                choices = ", ".join(f".{token}" for token in sorted(expected))
                failures.append(
                    f"{path}:{diagnostic_line}: {spelling} must use its catalog-owned "
                    f"fact dependency ({choices})"
                )

    for marker in found:
        if (
            marker.lane not in ("fact", "facts")
            or not audit_domain
            or marker not in marker_semantics
        ):
            continue
        owned = marker_semantics.get(marker, set())
        for token in marker.tokens:
            if token not in owned:
                failures.append(
                    f"{path}:{line_offset + line_number(source, marker.call_start)}: "
                    f"{marker.lane} marker includes .{token}, which no enclosed domain read owns"
                )
        for token in sorted(owned - set(marker.tokens)):
            failures.append(
                f"{path}:{line_offset + line_number(source, marker.call_start)}: "
                f"{marker.lane} marker omits catalog-owned .{token}"
            )

    usage: Counter[Tuple[str, str]] = Counter()
    for marker in found:
        lane = "fact" if marker.lane == "facts" else marker.lane
        usage.update((lane, token) for token in marker.tokens)
    return failures, usage


def check(repository: pathlib.Path) -> List[str]:
    failures: List[str] = []
    for path in (CATALOG, MARKERS, SESSION_ROW, SIDEBAR_NODES, PROJECT_SIDEBAR):
        if not (repository / path).is_file():
            failures.append(f"{path}: required navigator parity source is missing")
    if failures:
        return failures

    members_by_type, domain_targets, model_failures = model_schema(repository)
    failures.extend(model_failures)

    catalog_source = (repository / CATALOG).read_text(encoding="utf-8")
    facts, semantic_tokens, catalog_failures = catalog_owners(
        catalog_source, members_by_type
    )
    failures.extend(f"{CATALOG}: {failure}" for failure in catalog_failures)
    fact_input_tokens, fact_input_failures = source_owners(
        catalog_source,
        "NativeSidebarFactInputAlias",
        "nativeInputOwnership",
        facts,
    )
    failures.extend(f"{CATALOG}: {failure}" for failure in fact_input_failures)

    marker_source = (repository / MARKERS).read_text(encoding="utf-8")
    options, option_failures = enum_cases(
        marker_source, "NativeSidebarOptionDependency"
    )
    hosts, host_failures = enum_cases(marker_source, "NativeSidebarHostDependency")
    failures.extend(f"{MARKERS}: {failure}" for failure in option_failures + host_failures)
    host_provider_tokens, host_provider_failures = host_provider_owners(
        marker_source, hosts
    )
    failures.extend(f"{MARKERS}: {failure}" for failure in host_provider_failures)
    option_source_tokens, option_source_failures = source_owners(
        marker_source,
        "NativeSidebarOptionSourceAlias",
        "optionSourceOwnership",
        options,
    )
    host_input_tokens, host_input_failures = source_owners(
        marker_source,
        "NativeSidebarHostInputAlias",
        "hostInputOwnership",
        hosts,
    )
    failures.extend(
        f"{MARKERS}: {failure}"
        for failure in option_source_failures + host_input_failures
    )
    allowed = {"fact": facts, "option": options, "host": hosts}

    all_usage: Counter[Tuple[str, str]] = Counter()
    all_source_usage: Counter[Tuple[str, str]] = Counter()

    row_source = (repository / SESSION_ROW).read_text(encoding="utf-8")
    row_bounds = declaration_slice(row_source, r"\bfinal\s+class\s+SessionRowView\b")
    if row_bounds is None:
        failures.append(f"{SESSION_ROW}: has no SessionRowView class")
    else:
        row_class = row_source[row_bounds[0]:row_bounds[1]]
        row_line_offset = line_number(row_source, row_bounds[0]) - 1
        scope_failures, usage = audit_scope(
            SESSION_ROW,
            "SessionRowView",
            row_class,
            members_by_type,
            domain_targets,
            allowed,
            semantic_tokens,
            host_provider_tokens,
            fact_input_tokens,
            option_source_tokens,
            host_input_tokens,
            all_source_usage,
            line_offset=row_line_offset,
        )
        failures.extend(scope_failures)
        all_usage.update(usage)

    configure_bounds = declaration_slice(row_source, r"\bfunc\s+configure\s*\(")
    if configure_bounds is None:
        failures.append(f"{SESSION_ROW}: has no SessionRowView.configure")
    else:
        configure = row_source[configure_bounds[0]:configure_bounds[1]]
        configure_line_offset = line_number(row_source, configure_bounds[0]) - 1
        scope_failures, _ = audit_scope(
            SESSION_ROW,
            "SessionRowView.configure",
            configure,
            {},
            domain_targets,
            allowed,
            semantic_tokens,
            host_provider_tokens,
            fact_input_tokens,
            option_source_tokens,
            host_input_tokens,
            all_source_usage,
            function_parameters(configure),
            scalar_domain_parameters(configure),
            line_offset=configure_line_offset,
            audit_domain=False,
            report_marker_failures=False,
        )
        failures.extend(scope_failures)

    nodes_source = (repository / SIDEBAR_NODES).read_text(encoding="utf-8")
    builder_bounds = declaration_slice(nodes_source, r"\benum\s+SidebarTreeBuilder\b")
    if builder_bounds is None:
        failures.append(f"{SIDEBAR_NODES}: has no SidebarTreeBuilder")
    else:
        builder = nodes_source[builder_bounds[0]:builder_bounds[1]]
        builder_line_offset = line_number(nodes_source, builder_bounds[0]) - 1
        scope_failures, usage = audit_scope(
            SIDEBAR_NODES,
            "SidebarTreeBuilder",
            builder,
            members_by_type,
            domain_targets,
            allowed,
            semantic_tokens,
            host_provider_tokens,
            fact_input_tokens,
            option_source_tokens,
            host_input_tokens,
            all_source_usage,
            line_offset=builder_line_offset,
        )
        failures.extend(scope_failures)
        all_usage.update(usage)

        for entrypoint in ("rootNodes", "projectNode"):
            function_bounds = declaration_slice(
                builder,
                rf"\bstatic\s+func\s+{entrypoint}\s*\(",
            )
            if function_bounds is None:
                failures.append(f"{SIDEBAR_NODES}: has no SidebarTreeBuilder.{entrypoint}")
                continue
            function = builder[function_bounds[0]:function_bounds[1]]
            function_line_offset = (
                builder_line_offset + line_number(builder, function_bounds[0]) - 1
            )
            entry_failures, _ = audit_scope(
                SIDEBAR_NODES,
                f"SidebarTreeBuilder.{entrypoint}",
                function,
                {},
                domain_targets,
                allowed,
                semantic_tokens,
                host_provider_tokens,
                fact_input_tokens,
                option_source_tokens,
                host_input_tokens,
                all_source_usage,
                function_parameters(function),
                scalar_domain_parameters(function),
                line_offset=function_line_offset,
                audit_domain=False,
                audit_providers=False,
                report_marker_failures=False,
            )
            failures.extend(entry_failures)

    project_sidebar_source = (repository / PROJECT_SIDEBAR).read_text(encoding="utf-8")
    density_bounds = declaration_slice(
        project_sidebar_source,
        r"\bfunc\s+applyTreeDensity\s*\(",
    )
    if density_bounds is None:
        failures.append(
            f"{PROJECT_SIDEBAR}: has no ProjectSidebarViewController.applyTreeDensity"
        )
    else:
        density = project_sidebar_source[density_bounds[0]:density_bounds[1]]
        density_line_offset = line_number(project_sidebar_source, density_bounds[0]) - 1
        density_failures, usage = audit_scope(
            PROJECT_SIDEBAR,
            "ProjectSidebarViewController.applyTreeDensity",
            density,
            {},
            domain_targets,
            allowed,
            semantic_tokens,
            host_provider_tokens,
            fact_input_tokens,
            option_source_tokens,
            host_input_tokens,
            all_source_usage,
            line_offset=density_line_offset,
            audit_domain=False,
        )
        failures.extend(density_failures)
        all_usage.update(usage)

    for lane, sources in (
        ("fact", fact_input_tokens),
        ("option", option_source_tokens),
        ("host", host_input_tokens),
    ):
        for source_key in sorted(sources):
            if all_source_usage[(lane, source_key)] == 0:
                failures.append(
                    f"{MARKERS if lane != 'fact' else CATALOG}: {lane} source "
                    f"{source_key} has no audited native occurrence"
                )

    for lane, tokens in (("option", options), ("host", hosts)):
        for token in sorted(tokens):
            if all_usage[(lane, token)] == 0:
                failures.append(
                    f"{MARKERS}: {lane} dependency .{token} has no protected native read"
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
    failures = check(parser.parse_args().repository.resolve())
    if failures:
        for failure in failures:
            print(f"navigator-fact-parity: {failure}", file=sys.stderr)
        return 1
    print("navigator-fact-parity: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
