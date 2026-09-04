# Changelog

Release notes for Threading. The section matching the released version is embedded into the
Sparkle appcast as Markdown by `scripts/generate_appcast.sh` and shown in the in-app update
sheet, so write each entry for the person deciding whether to install — what changed for them,
not which file moved. A release cannot ship without its section: the appcast script fails on a
version this file does not describe.

Format: `## [x.y.z]` per release, newest first, matching the git tag `vx.y.z`.

A beta has a section of its own, under the version it ships as rather than the one it is a beta
of. Its tag is `beta-vx.y.z`, and its version sits strictly below the stable it precedes — a
beta of the upcoming 0.2.0 goes out as 0.1.90 — because Sparkle compares one dotted number and
equal is not newer, so a beta sharing 0.2.0's version would never be offered 0.2.0 itself. Write
it for the tester: what to try, and what is known to be rough. When the stable release lands, its
own section describes the whole change, not the difference since the last beta; nobody on stable
saw the betas.

## [Unreleased]

### Changed

- On iPhone, the account button in a new session's navigation bar now opens one small panel
  holding both choices: the agents as a row of their own marks, and each login as a row led by
  its own disc, ringed by how much of its allowance is used and spelling that reading out
  underneath. Choosing an agent leaves the panel open so the logins beneath can follow it, and
  choosing a login closes it — where the old menu was a single scrolling list that closed after
  the first choice, so picking an agent and then a login meant opening it twice. Your keyboard
  stays up while you choose.

## [0.1.0]

### Added

- First release of Threading: projects and agent sessions in one window, with Claude Code,
  Codex, Grok, and OpenCode running in real terminals — or, experimentally, rendered as
  native conversations.
- Report a Problem, from the Help menu or the inspector. A report carries your description
  and a bounded set of content-free diagnostics, and nothing else: no terminal output, no
  prompts, no file paths, no credentials. A screenshot is included only if you opt in, and
  only as the small preview shown to you. Reports are kept privately for 30 days and then
  deleted.
- Signed in-app software updates powered by Sparkle. Threading checks its GitHub release
  feed at most daily, only with your consent, and shows updates in its own interface:
  release notes rendered natively, download and preparation progress, and an explicit
  install step. Automatic downloads and system profiling are never enabled.
