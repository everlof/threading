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

### Added

- A theme can now put a gradient or a picture under the app's panes — the display panel, the
  browser, Git Review, the audit and the settings subpages — beneath any dot or grid pattern it
  already draws there. Agents set it with the theme tools as `material.backdrop`; a wash has to
  keep the theme's text readable, and a picture is stored with the theme like a sidebar image.
- An extension can put a picture or a live shader beneath the sidebar's rows
  (`sidebar.backdrop@1`). Threading keeps it below 60% opacity, at or under 30 frames a second,
  paused while the window is hidden and frozen under Reduce Motion, and nothing in it can be
  clicked. Shader surfaces can now follow the app's workload and the time of day as well as the
  active account's remaining usage.

### Fixed

- A chat Threading followed into a sibling worktree can no longer be pulled straight back by the
  hook report that fired the move. The Stop hook's own working directory was being read after the
  checkout had changed, naming the checkout the chat had just left, and the earlier relaunch let
  the exiting processes be sampled there too. Both readings are now discarded, and a refused
  reversal is written to the diagnostics log so an audit can count them.
- The iPhone's session list no longer downloads the whole catalogue every time it comes back on
  screen or the app returns to the foreground. While the live connection is delivering changes,
  coming back asks nothing; returning to the app asks the Mac one question on the route that
  worked last — "is it still this edition?" — and receives a one-line yes instead of every row.
  A Mac restart, a pull to refresh, or a structural change still fetches everything.
- The Mac answers that catalogue request without holding up everything else it is doing: the
  rows are encoded and compressed off its main queue, kept until the catalogue changes, and sent
  compressed. On a slow cellular link a 78-session list that took several seconds to arrive is
  now a fraction of the bytes.
- Attachment thumbnails and previews on the iPhone no longer stay blank after a dropped
  connection. A request whose connection was cut under it is retried once on a fresh one,
  downloads are queued a few at a time instead of all at once, the Mac keeps the connection open
  between thumbnails, and a thumbnail lost while the phone was moving between networks is asked
  for again once the new route is in use.
- The iPhone stops knocking on a Mac address that keeps refusing it. Two of one Mac's Tailscale
  addresses refused every one of 758 attempts in a day while its other addresses answered; an
  address that refuses three times running now sits out the route race for five minutes,
  doubling to an hour, and is tried once more when that rest ends. A refusal also records
  whether the phone held a pin for that address and what the handshake said, so the next report
  can tell a phone-side registration gap from a Mac-side listener fault.
- Reopened chats on the iPhone reuse their warm connection more often: the pool keeps five
  connections for two minutes instead of three for one. Its counters now travel in the phone's
  diagnostics capture, and the Mac records how long it spent attaching each terminal socket.

### Added

- Codex banked usage resets can now be reviewed and used from Mac Usage, `/usage`, a limit-recovery
  strip, or the owner-only iPhone Usage sheet. Threading always confirms the exact account and
  credit, reads the result back from Codex, and only then releases existing chats that were already
  waiting to continue on that account.

### Changed

- On iPhone, the account button in a new session's navigation bar now opens one small panel
  holding both choices: the agents as a row of their own marks, and each login as a row led by
  its own disc, ringed by how much of its allowance is used and spelling that reading out
  underneath. Choosing an agent leaves the panel open so the logins beneath can follow it, and
  choosing a login closes it — where the old menu was a single scrolling list that closed after
  the first choice, so picking an agent and then a login meant opening it twice. Your keyboard
  stays up while you choose.
- Both rows in that panel now answer a press and drag: hold anywhere in the agents or the
  accounts and slide, and the choice follows your finger with a tick at each one, taking effect
  where you lift. Tapping still works exactly as before. The whole cell is the target as well,
  so the space around an agent's mark and name no longer swallows a tap that clearly meant it.

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
