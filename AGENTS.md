# AGENTS.md

**Read [`CLAUDE.md`](CLAUDE.md) first.** It is this repository's agent guidance and it applies
to you in full — it is named for the tool that wrote it, not for a single agent. This file
exists only because Codex looks for it. Keeping a second copy of the guidance here is what let
the two drift (919 lines apart, and a global "Claude Code" → "Codex" substitution had corrupted
half the sentences it touched), so there is no second copy.

`CLAUDE.md` is an index: the project overview, build and test commands, code style and the
subsystem table. The reasoning behind each subsystem — what was measured, what was wrong first,
and which rules are load-bearing — lives in [`docs/architecture/`](docs/architecture/). Read the
file for the area you are about to change; those notes are not recoverable from the code.

Three rules that are cheapest to learn before you start:

- **Before changing any UI, read [`docs/THEME_BOUNDARY.md`](docs/THEME_BOUNDARY.md) and
  [`docs/architecture/design-system.md`](docs/architecture/design-system.md).** Feature code
  never constructs or subclasses an AppKit control or chrome-drawing surface; new UI is built
  from `Sources/Skalman/UI/Design/`. `scripts/check_theme_boundaries.sh` fails the build
  otherwise.
- **A new test file must be registered in `project.pbxproj` by hand**
  (`scripts/add_test_file.py` does it). `Tests/SkalmanTests` is not a synchronized folder, and
  an unregistered file fails silently — it builds nothing and reports "Executed 0 tests".
- **Before creating or changing an extension**, read `docs/extensions/AGENT_AUTHORING.md`
  completely rather than inferring the API from application internals.
