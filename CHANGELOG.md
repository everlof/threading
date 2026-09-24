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

## [0.4.0]

### Added

- **Test a notification from the chat that sent it.** Push Test shows the latest request and its
  result, lets you edit the title, message, recipient and destination, and sends a test through the
  same delivery checks used by an agent. Find it from the display panel, View menu, command
  palette or Remote Access settings. An agent's notification updates an open test tab without
  taking focus or replacing a draft you are editing.
- **Record and present the adopted Simulator.** Save a recording with visible taps and swipes, or
  capture a full-resolution Simulator video. Choose the touch colour, size and trail, and open a
  separate presenter window for screen sharing. The pane and presenter both accept scrolling and
  device controls.
- Native conversations now name Threading tool calls, and browser annotations include the page
  element path so an agent can identify the marked control more precisely.

### Changed

- Recently viewed chats remain ready to reopen under the idle-agent limit without changing which
  chats resume at launch. Terminal attachment scanning now performs its buffer read and path
  resolution off the main queue, reducing work while large terminals are active.
- A missing worktree stays grouped under its repository in the sidebar, where its recovery action
  remains available.

### Fixed

- **Install and Relaunch** proceeds through Threading's shutdown after you approve the update,
  without asking you to confirm quitting a second time. If installation is still waiting for the
  app to quit, Check for Updates offers a retry instead of leaving an Installing sheet on screen.
- Used Share Chat invitations now explain that the link has already been accepted rather than
  showing a misleading generic failure. Live notification routing on iPhone also follows the
  current connection after a reconnect.
- Simulator recordings keep the right orientation when touches are shown, and themed alert
  borders retain their corners when attached as sheets.

## [0.3.0]

### Added

- **Run a project's Claude terminal chats on a Linux host.** Add the machine once in Settings,
  choose it on the project, and Threading installs verified, version-matched host components over
  SSH. The chat keeps its hooks and Threading tools through the tunnel, its transcript is mirrored
  back to the Mac, Usage is charged to the remote host, and Git Review reads that checkout without
  copying the repository home. Dropped tunnels reconnect, existing remote sessions can be taken
  back after a relaunch, and an old daemon cannot quietly return at boot.
- **Approve an agent's browser request from a paired iPhone.** The pending request appears with the
  browser workspace it belongs to, remains bound to that exact request while the phone refreshes,
  and disappears everywhere as soon as it is answered. An approval grants only the browser action
  being requested; it does not widen the chat's other permissions.
- **Stop a chat before an account's allowance runs out.** A session curfew can now be stated as a
  usage percentage as well as a time, with the same choice available when composing the chat and
  while it is running.
- Projects can be hidden from the sidebar and restored from Settings. Sidebar panel actions are
  also available as commands, so the same destinations can be reached without hunting for their
  buttons.

### Changed

- The Mac sidebar and iPhone now use the same project ordering, show a compact preview for up to
  five chats under each project, and keep a remote worktree beside the checkout it grew from.
- Remote Access keeps Hosted Direct connected more reliably, explains when a sleeping Mac is the
  reason it cannot be reached, and collects remote-machine configuration in Settings.
- iPhone Usage charts do less work while scrolling, Compose keeps a freshly typed draft when Back
  is pressed immediately, and terminal input now carries permanent latency measurements for
  diagnosing slow echo without recording what was typed.

### Fixed

- A failed worktree move no longer lets the chat resume in an ambiguous checkout after launch.
  Threading keeps the refusal visible and offers an explicit retry or cancel instead.
- A remote chat whose host says it is no longer running stops redialling forever, while one whose
  tunnel merely dropped reconnects without allowing an older daemon or connection to take over.
- Remote transcripts, usage totals and Git status now come from the machine that actually ran the
  chat rather than being mixed with the Mac's checkout or account.
- Repeated Remote Access listener restarts keep the configured port when Network.framework has
  finished cancelling the previous listener, while a real port collision still uses the normal
  fallback range.

## [0.2.0]

### Added

- Threading can now start a chat by itself when something happens outside it. A **trigger** names
  the project, the instructions to open with, and how far the agent may go; a source reports the
  events. The first source is Sonda's review-required feed. Every run starts read-only in the
  provider's own conversation, with the event's text kept separate from your instructions — it is
  evidence the agent reads, never configuration it obeys. A run can be allowed one further turn to
  make a local fix, and that is where the grant stops: a trigger cannot push, deploy, open a change
  request or write back to the source. Agents may draft triggers and propose one, but only you
  activate it, and activation names one exact revision. Triggers, Activity and Sources are in the
  sidebar; the configured time limit becomes the session's curfew.
- **Search across everything, from either device.** One field reaches your projects, chats,
  transcripts and files, on the Mac and on the iPhone.
- **Plugins you sign and allow.** Alongside the sandboxed extension tier, Threading can load a
  native code bundle into its own process — full AppKit, its own pane, and the ability to hand the
  agent tools of its own. You decide which ones may run; there is no privileged list of ours, and
  the first party has no powers the third party lacks. A plugin receives the app's whole theme and
  the real design-system components, so it looks like the rest of the window rather than
  approximating it.
- **Workspace navigators.** An extension can contribute a navigator beside the sidebar, built from
  bounded facts the host publishes and options you set, updating live as those facts change. Ships
  with reference navigators, including an Activity Inbox and a GitLab one.
- **The adopted Simulator is yours to drive.** Home, Lock, Side and Volume buttons, press-and-hold,
  panning that follows your finger continuously instead of lurching between round-trips, and a
  light/dark toggle. Your consent to control it is remembered across launches.
- **An agent can ask you a question inline** — a real question with named options, answered in the
  conversation on the Mac or on your phone, rather than guessed at or resolved by a timer.
- **Share a chat with someone who does not have Threading**, through a universal link, with the
  browser reachable directly.
- **Annotate a live page for an agent.** Pin a spot in the browser, write what it should notice,
  and the agent reads the pins with the page.
- A paired iPhone's or a Simulator's **log stream, in a pane of its own** — including an app whose
  log format Threading has never seen before. It ships as a plugin rather than as built-in chrome.
- A theme can now put a gradient or a picture under the app's panes — the display panel, the
  browser, Git Review, the audit and the settings subpages — beneath any dot or grid pattern it
  already draws there. Agents set it with the theme tools as `material.backdrop`; a wash has to
  keep the theme's text readable, and a picture is stored with the theme like a sidebar image.
- An extension can put a picture or a live shader beneath the sidebar's rows
  (`sidebar.backdrop@1`). Threading keeps it below 60% opacity, at or under 30 frames a second,
  paused while the window is hidden and frozen under Reduce Motion, and nothing in it can be
  clicked. Shader surfaces can now follow the app's workload and the time of day as well as the
  active account's remaining usage.
- Codex banked usage resets can now be reviewed and used from Mac Usage, `/usage`, a limit-recovery
  strip, or the owner-only iPhone Usage sheet. Threading always confirms the exact account and
  credit, reads the result back from Codex, and only then releases existing chats that were already
  waiting to continue on that account.
- A **Rosé Moon** terminal palette, and Pure now follows the system's appearance.

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
- **Attachments are grouped by the turn they belong to**, and keep their place while they are still
  being queued or sent. Movies preview in the chat, on the phone too, and an attachment's full
  timestamp is available rather than an abbreviation.
- **The sidebar says more with less.** Every repository has a root row and no longer repeats its
  branch on every line, uninteresting rows fold away instead of disappearing — so a search or a
  selected range still has something to land on — and a collapsed sidebar comes back on an edge
  hover.
- **A chat can follow its agent into another checkout**, and a chat you continue on a different
  agent can be started from a paired iPhone.

### Fixed

- A chat Threading followed into a sibling worktree can no longer be pulled straight back by the
  hook report that fired the move. The Stop hook's own working directory was being read after the
  checkout had changed, naming the checkout the chat had just left, and the earlier relaunch let
  the exiting processes be sampled there too. Both readings are now discarded, and a refused
  reversal is written to the diagnostics log so an audit can count them.
- Granting a running chat the Manager role now makes its extra tools usable without relaunching
  it. A provider is told which tools exist when it starts, so promoting it afterwards left those
  tools permanently invisible to that chat even though the grant was live.
- Notifications no longer announce a turn that is not over, and a notification whose reason has
  passed is taken back. A chat that left a shell or a background task running stays marked as
  working until its result actually arrives.
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
- A terminal opened again after a reconnect no longer draws its cursor in the wrong place, and
  the phone's terminal settles its height properly after the keyboard moves.
- Launching a chat in a project folder that has gone missing is refused with an explanation
  instead of failing obscurely, and an idle chat's processes are no longer retained indefinitely.

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
