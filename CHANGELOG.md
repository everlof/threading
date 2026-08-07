# Changelog

Release notes for Threading. The section matching the released version is embedded into the
Sparkle appcast as Markdown by `scripts/generate_appcast.sh` and shown in the in-app update
sheet, so write each entry for the person deciding whether to install — what changed for them,
not which file moved. A release cannot ship without its section: the appcast script fails on a
version this file does not describe.

Format: `## [x.y.z]` per release, newest first, matching the git tag `vx.y.z`.

## [Unreleased]

## [0.1.0]

### Added

- First release of Threading: projects and agent sessions in one window, with Claude Code,
  Codex, Grok, and OpenCode running in real terminals — or, experimentally, rendered as
  native conversations.
- Signed in-app software updates powered by Sparkle. Threading checks its GitHub release
  feed at most daily, only with your consent, and shows updates in its own interface:
  release notes rendered natively, download and preparation progress, and an explicit
  install step. Automatic downloads and system profiling are never enabled.
