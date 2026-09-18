#!/usr/bin/env python3
"""Turns `sweep-core.sh`'s raw compiler errors into verdicts.

The question this answers is the one `headless.py` could only bound: of the non-UI code, how much
fails on Linux for a *platform* reason, and how much fails only because a sibling file was not
compiled alongside it. The second kind is not a portability problem at all — it is an artifact of
type-checking one file at a time — and conflating the two is how 69% would become a number nobody
should trust.

The rule for telling them apart is not a prefix. Platform symbols here have no common shape
(`Logger`, `SecItemCopyMatching`, `NWConnection`, `UTType`, `SHA256`), so instead every type
Threading declares anywhere in the repository is collected first, and an unresolved symbol counts
as ours if it appears in that set.

    ./classify-core.py [repo-root]
"""
import pathlib
import re
import sys
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent
ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else HERE / "../..").resolve()
ERRORS = HERE / "out" / "core-errors.tsv"

DECLARATION = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|final\s+|@\w+\s+)*"
    r"(?:class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.M,
)
NO_MODULE = re.compile(r"no such module '([A-Za-z_][A-Za-z0-9_]*)'")
MISSING = re.compile(r"cannot find (?:type |protocol )?'([A-Za-z_][A-Za-z0-9_]*)'")
MEMBER = re.compile(r"type '([A-Za-z_][A-Za-z0-9_.]*)' has no member '([A-Za-z_][A-Za-z0-9_]*)'")

# On Linux, URLSession and friends live in a *separate* module — swift-corelibs-foundation splits
# networking out of Foundation. Files that use them are not blocked; they need one more import.
# This is a real porting chore (every such file gains a `#if canImport(FoundationNetworking)`),
# so it is counted and named rather than waved through.
FOUNDATION_NETWORKING = {
    "URLRequest", "URLSession", "URLSessionConfiguration", "URLSessionTask", "URLSessionDataTask",
    "URLSessionDownloadTask", "URLSessionUploadTask", "URLSessionWebSocketTask",
    "URLSessionDelegate", "URLSessionTaskDelegate", "URLSessionDataDelegate", "URLResponse",
    "HTTPURLResponse", "URLCredential", "URLAuthenticationChallenge", "URLProtectionSpace",
    "URLCache", "HTTPCookie", "HTTPCookieStorage", "URLSessionWebSocketDelegate",
}

# Errors that say nothing about portability: a member lookup on `Any` or on a generic placeholder
# is what one-file type-checking produces when the real type lives in a sibling.
NOT_A_SYMBOL = {"Any", "AnyObject", "Self", "T", "Element", "Value", "Key", "Result"}

# A module or C symbol with a real Linux equivalent: a port, not a wall. Kept in step with
# headless.py so the import ceiling and this measurement can be compared line for line.
SUBSTITUTABLE_MODULES = {
    "Darwin": "Glibc",
    "os": "swift-log",
    "OSLog": "swift-log",
    "CryptoKit": "swift-crypto, same API",
    "Network": "SwiftNIO or POSIX sockets",
    "CoreGraphics": "the spike's own geometry, or Cairo/Skia",
    "CoreText": "HarfBuzz + FreeType",
    "ImageIO": "libpng / libjpeg",
    "UniformTypeIdentifiers": "shared-mime-info",
    "Compression": "zlib / liblzma",
    "SQLite3": "system libsqlite3 with a module map",
    "ObjectiveC": "delete",
}
# C symbols that are Apple frameworks reached without an import line.
SUBSTITUTABLE_SYMBOLS = {
    "FSEvent": "inotify",
    "CF": "Foundation's Swift types",
}


def threading_symbols() -> set:
    """Every type name declared anywhere in our own Swift sources."""
    names = set()
    for directory in ["Sources", "Packages"]:
        base = ROOT / directory
        if not base.is_dir():
            continue
        for path in base.rglob("*.swift"):
            if "/.build/" in str(path) or "/checkouts/" in str(path):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            names.update(DECLARATION.findall(text))
    return names


def main() -> None:
    if not ERRORS.exists():
        print(f"missing {ERRORS} — run ./sweep-core.sh first", file=sys.stderr)
        raise SystemExit(1)

    ours = threading_symbols()
    our_modules = {path.name for path in (ROOT / "Packages").iterdir() if path.is_dir()}
    our_modules |= {"Threading", "ThreadingMobile", "SwiftTerm", "TimberLineParser"}
    # Ours, but fetched rather than vendored: NativeDiffCore comes from everlof/NativeDiffKit and
    # is referenced as a `.product(name:)`, which the target scan below does not see.
    our_modules |= {"NativeDiffCore"}
    # Targets declared *inside* our packages count too — NativeDiffCore lives in ThreadingDesignKit,
    # and a directory-name-only set reported it as a platform blocker.
    target = re.compile(r'\.(?:target|library|executableTarget)\(\s*name:\s*"([A-Za-z_][A-Za-z0-9_]*)"')
    for manifest in (ROOT / "Packages").rglob("Package.swift"):
        if "/.build/" in str(manifest) or "/checkouts/" in str(manifest):
            continue
        our_modules.update(target.findall(manifest.read_text(encoding="utf-8", errors="replace")))
    print(f"{len(ours)} type names declared in our own sources\n")

    verdicts = Counter()
    modules = Counter()
    platform_symbols = Counter()
    blocked_files = []
    needs_networking = []

    # Split on "\n" explicitly, never `splitlines()`: the errors are escaped onto one line with
    # "\v", and `splitlines()` treats a vertical tab as a line break — which silently turned 636
    # files into 1,810 and reported 97% success from the first twenty-six rows.
    rows = [
        line.split("\t", 1)
        for line in ERRORS.read_text().split("\n")
        if line.strip()
    ]
    for row in rows:
        name = row[0]
        blob = (row[1] if len(row) > 1 else "").replace("\v", "\n")

        if not blob.strip():
            verdicts["compiles standalone"] += 1
            continue

        missing_modules = set(NO_MODULE.findall(blob))
        # Our own packages are not a portability problem — they are simply not on the search path
        # for a one-file type-check, exactly like a sibling type that was not compiled alongside.
        foreign_modules = missing_modules - our_modules
        if foreign_modules:
            for module in foreign_modules:
                modules[module] += 1
            verdicts["blocked: missing module"] += 1
            blocked_files.append((name, sorted(foreign_modules)))
            continue
        if missing_modules:
            verdicts["needs only our own siblings"] += 1
            continue

        unresolved = set(MISSING.findall(blob))
        members = {
            f"{base}.{member}"
            for base, member in MEMBER.findall(blob)
            if base not in NOT_A_SYMBOL and base not in ours
        }
        foreign = {symbol for symbol in unresolved if symbol not in ours and symbol not in NOT_A_SYMBOL}
        foreign |= members

        networking = {symbol for symbol in foreign if symbol.split(".")[0] in FOUNDATION_NETWORKING}
        foreign -= networking
        if networking:
            needs_networking.append(name)

        if foreign:
            for symbol in foreign:
                platform_symbols[symbol] += 1
            verdicts["blocked: platform symbol"] += 1
            blocked_files.append((name, sorted(foreign)[:6]))
        elif networking:
            verdicts["needs import FoundationNetworking"] += 1
        else:
            verdicts["needs only our own siblings"] += 1

    total = len(rows)
    print(f"{total} files type-checked on Linux against Foundation alone\n")
    order = [
        "compiles standalone",
        "needs only our own siblings",
        "needs import FoundationNetworking",
        "blocked: missing module",
        "blocked: platform symbol",
    ]
    for key in order:
        count = verdicts.get(key, 0)
        print(f"  {count:4d}  ({count * 100 // total:2d}%)  {key}")

    portable = (
        verdicts.get("compiles standalone", 0)
        + verdicts.get("needs only our own siblings", 0)
        + verdicts.get("needs import FoundationNetworking", 0)
    )
    print(f"\n  {portable:4d}  ({portable * 100 // total:2d}%)  nothing platform-specific in the way")

    def note(name):
        head = name.split(".")[0]
        if head in SUBSTITUTABLE_MODULES:
            return SUBSTITUTABLE_MODULES[head]
        for prefix, replacement in SUBSTITUTABLE_SYMBOLS.items():
            if head.startswith(prefix) or head.startswith("k" + prefix):
                return replacement
        return None

    everything = modules + platform_symbols
    soft = [(k, v) for k, v in everything.most_common() if note(k)]
    hard = [(k, v) for k, v in everything.most_common() if not note(k)]

    print("\nblocked, but a known Linux equivalent exists (a port, not a wall):")
    for name, count in soft:
        print(f"  {count:4d}  {name:26s} {note(name)}")

    print("\nblocked with no Linux story yet:")
    for name, count in hard[:25]:
        print(f"  {count:4d}  {name}")

    listing = HERE / "out" / "core-blocked.txt"
    with listing.open("w") as handle:
        for name, reasons in blocked_files:
            handle.write(f"{name}\t{','.join(reasons)}\n")
    print(f"\nblocked files listed in {listing.relative_to(HERE)}")


if __name__ == "__main__":
    main()
