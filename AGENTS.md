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

Seven rules that are cheapest to learn before you start:

- **Fix the root cause each time, no band-aids.**

- **Before changing any UI, read [`docs/THEME_BOUNDARY.md`](docs/THEME_BOUNDARY.md) and
  [`docs/architecture/design-system.md`](docs/architecture/design-system.md).** Feature code
  never constructs or subclasses an AppKit control or chrome-drawing surface; new UI is built
  from `Sources/Threading/UI/Design/`. `scripts/check_theme_boundaries.sh` fails the build
  otherwise.
- **Performance is a product requirement, not a cleanup pass.** Follow the measured workflow in
  [`CLAUDE.md`](CLAUDE.md#performance-is-a-product-requirement). Before implementing a surface or
  callback whose size or frequency comes from files, transcripts, extensions, accounts, sessions,
  processes, or provider data, apply its [scaling gate](CLAUDE.md#scaling-gate). Collapsed or
  hidden content is not lazy if its views were already built; the detailed rules and current audit
  live in [`performance.md`](docs/architecture/performance.md#implementation-time-scaling-gate).
- **Test sources are filesystem synchronized.** A new Swift file below `Tests/ThreadingTests`
  or `Tests/ThreadingUITests` is compiled automatically; do not add per-file entries to
  `project.pbxproj`.
- **Before creating or changing an extension**, read `docs/extensions/AGENT_AUTHORING.md`
  completely rather than inferring the API from application internals.
- **Before adding or materially changing a durable user-facing surface**, apply the
  [customization-surface gate](docs/extensions/CUSTOMIZATION_SURFACE_AUDIT.md#gate-for-every-new-surface).
  Decide whether the surface is a public extension component or deliberately host-only, and state
  which behavior Threading keeps host-owned when presentation is customizable.
- **Before reporting a change complete**, re-read the request item by item, verify the shipping
  path at the relevant test level, and state anything that remains unverified. Appearance and
  layout work requires inspected rendered evidence from the real product shell; compilation and
  structural assertions alone are not visual verification.
