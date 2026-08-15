# Contributing to Threading

## Before you change a subsystem

This codebase keeps its reasoning in [`docs/architecture/`](docs/architecture/) — one file per
subsystem, recording what was measured and which rules are load-bearing. **Read the relevant
file before changing that area**; the index and the table of what maps where is
[`CLAUDE.md`](CLAUDE.md). Most of those rules were arrived at by getting the obvious thing
wrong first, and a change that contradicts one without updating it will not land.

Three boundary lints run inside every ordinary `xcodebuild` and will fail the build outright:
architecture boundaries, the AppKit theme boundary (`docs/THEME_BOUNDARY.md` — feature code
never constructs stock controls), and localization coverage.

## Building and testing

```bash
xcodebuild -project Threading.xcodeproj -scheme Threading -configuration Debug build

scripts/test.sh          # fast — run while iterating; no window is ordered on screen
scripts/test.sh all      # the whole suite — run before proposing changes
```

Test source folders are filesystem synchronized. Add a Swift file below the appropriate test
directory and Xcode compiles it automatically; do not add per-file project entries.

## The contributor license agreement

Threading's repository is GPLv3, but the iOS companion is also distributed on the App Store —
under Apple's terms, which the GPL does not permit. That build is only lawful because the
copyright holder licenses their own code both ways. For your contribution to be includable in
it, we need the same latitude from you: [`CLA.md`](CLA.md) grants the maintainer a
non-exclusive license to distribute your contribution under other terms too. You keep the
copyright to your work, and it remains in the repository under GPLv3 like everything else.

This is the same arrangement projects like Blink Shell use, for the same reason. Agreement is
collected when you open your first pull request; a PR whose author has not agreed cannot be
merged, however good the code, so it is worth reading `CLA.md` first — it is short.
