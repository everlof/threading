#!/usr/bin/env python3
"""Remove phased rollout metadata without changing other feed bytes. Re-sign before publishing."""

from __future__ import annotations

import argparse
from pathlib import Path
import xml.parsers.expat as expat


PHASE_ELEMENT = "http://www.andymatuschak.org/xml-namespaces/sparkle}phasedRolloutInterval"


def remove_rollouts(source: bytes) -> tuple[bytes, int]:
    # Expat's byte offsets let us preserve enclosure signatures, CDATA release notes, dates,
    # namespace prefixes and formatting exactly. A text replacement could alter a release note
    # that merely quotes the same XML tag.
    parser = expat.ParserCreate(namespace_separator="}")
    stack: list[str] = []
    ranges: list[tuple[int, int]] = []
    start = None

    def begin(name, attributes):
        nonlocal start
        if name == PHASE_ELEMENT:
            if not stack or stack[-1] != "item" or start is not None:
                raise ValueError("phased rollout metadata must be a direct child of an RSS item")
            if attributes:
                raise ValueError("unexpected attributes on phased rollout metadata")
            start = parser.CurrentByteIndex
        stack.append(name)

    def end(name):
        nonlocal start
        if name == PHASE_ELEMENT:
            opening_end = source.index(b">", start) + 1
            if source[start:opening_end].rstrip().endswith(b"/>"):
                stop = opening_end
            else:
                stop = source.index(b">", parser.CurrentByteIndex) + 1
            ranges.append((start, stop))
            start = None
        stack.pop()

    def reject_doctype(*_):
        raise ValueError("appcast must not contain a DOCTYPE")

    parser.StartElementHandler = begin
    parser.EndElementHandler = end
    parser.StartDoctypeDeclHandler = reject_doctype
    parser.Parse(source, True)
    for start, stop in reversed(ranges):
        source = source[:start] + source[stop:]
    return source, len(ranges)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appcast", type=Path)
    parser.add_argument("--check", action="store_true", help="refuse rollout metadata without modifying the feed")
    args = parser.parse_args()
    original = args.appcast.read_bytes()
    updated, count = remove_rollouts(original)
    if args.check:
        if count:
            raise SystemExit(f"Appcast still contains {count} phased rollout interval(s).")
        return
    if count:
        args.appcast.write_bytes(updated)
    print(f"Removed {count} phased rollout interval(s); the feed must be signed before publication.")


if __name__ == "__main__":
    main()
