# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Skalman is a native macOS app for organizing coding-agent sessions, built with **Swift** and **AppKit**, using **SwiftTerm** for terminal emulation. Targets **macOS 13+**.

A single window pairs a project sidebar with the selected session's terminal. Each session
hosts a Claude Code, Codex, or shell process inside a project folder. Sessions outlive their
terminals: when the agent exits, the PTY is torn down but the session record remains so the
conversation can be resumed later by its agent-assigned identifier.

## Build & Run Commands

The project is **Xcode-only** — a single `Skalman.xcodeproj`, no SwiftPM manifest. (SwiftTerm
stays a local Swift package that the Xcode project references; the app's own `Package.swift` was
removed so there is one build system, not two.)

```bash
# Build the app
xcodebuild -project Skalman.xcodeproj -scheme Skalman -configuration Debug build

# Run the tests (SkalmanTests target, hosted in the app)
xcodebuild -project Skalman.xcodeproj -scheme Skalman -destination 'platform=macOS' test

# Run the built app (never the bare binary — build with xcodebuild, then open the bundle)
open "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Skalman-*/Build/Products/Debug/Skalman.app | head -1)"
```

Resources: files under `Sources/` are members of the app target automatically (Xcode 16
synchronized folders). The asset catalogue compiles to `Assets.car`; `Resources/Icons` is marked
an explicit folder so its loose PNGs land under `Contents/Resources/Icons/`, loaded via
`Bundle.main` (`AgentBrandIcon`). Unit tests `@testable import Skalman`, so the test bundle is
hosted in the app; `AppDelegate` skips its real startup under `XCTestCase` so tests spawn no
agents or MCP server.

## Dependencies

- **SwiftTerm** (local fork): Terminal emulation engine handling VT100/xterm, ANSI parsing, PTY communication
  - Location: `./SwiftTerm/` (git submodule)
  - Upstream: https://github.com/migueldeicaza/SwiftTerm
  - **This is our fork** - feel free to modify SwiftTerm source code directly to implement features or fix bugs. The iOS folder is excluded on macOS builds.

## Architecture

### Core Components

- **LocalProcessTerminalView**: SwiftTerm's AppKit view that combines terminal rendering + PTY handling
- **EmojiFixedTerminalView**: Subclass that fixes emoji rendering with proper background compositing
- **TerminalSession**: Manages SwiftTerm view lifecycle, the child process, and session state
- **MainWindowController**: The single window; sidebar, terminal and display panes in an `NSSplitViewController`
- **ProjectSidebarViewController**: Source list of projects and their sessions
- **TerminalContainerViewController**: Swaps the terminal pane to the selected session
- **AgentSessionViewController**: Hosts one session's terminal and drives its launch/exit
- **DisplayPaneController**: The third pane, holding per-session content agents display
- **TerminalProfile**: User preferences for font, colors, shell configuration

### Model & Runtime Split

- **ProjectStore**: Owns projects and sessions; persists to `projects.json`. Knows nothing
  about running processes. Terminal-title updates are coalesced (`scheduleSave`) because
  agents rewrite the title constantly; structural edits save immediately.
- **AppSettings / AccountPreferencesStore**: `UserDefaults`-backed behavioural settings and
  per-account icon/name customisation.
- **AgentRuntime**: Caches live `AgentSessionViewController`s keyed by session id. A session
  with no entry is dormant.
- **AgentLauncher**: Builds the command line for a fresh launch vs. a resume, including
  account routing.
- **CodexSessionDiscovery**: Recovers the session id Codex assigns itself after launch.
- **AgentAccountDiscovery**: Finds agent logins by scanning `~/.claude-*` / `~/.codex-*`.
- **ShellAliasReader**: Labels accounts with the user's own alias name.

### Window Chrome

The window uses `.fullSizeContentView` with a transparent, hidden title bar, so the sidebar
runs the full height and the traffic lights float over it. The window title stays `Skalman`,
since it is only surfaced where macOS names the window (Mission Control, the Window menu).

Chrome is a real `NSToolbar` (`.unifiedCompact` style — the large `.unified` style sizes the
system sidebar toggle for a 15pt window title, dwarfing the quiet 13pt session title beside
it; see `MainWindowToolbar.swift`) rather than a
hand-rolled header. That matters: an earlier custom header had to track the sidebar's collapse
state and shift itself sideways to dodge the traffic lights. The toolbar gets all of that for
free, because its items are positioned relative to the window rather than to either pane.

- `.toggleSidebar` and `.sidebarTrackingSeparator` are **system** items. The first drives the
  split view's first item; the second keeps a divider aligned with the split position.
- `.sessionTitle` is ours, holding `SessionTitleItemView`. It sets `isBordered = false`, or the
  system draws a bezel behind it and it reads as a button.

Nothing may pin to `view.topAnchor` in either pane, or it lands under the toolbar — a bug this
project has already had once, where it hid the terminal's first rows. The terminal, placeholder
and sidebar content all pin to `safeAreaLayoutGuide`, which the toolbar insets for them.

`SidebarSplitViewController` overrides `toggleSidebar(_:)` to set `isCollapsed` directly.
The stock implementation collapses but does not restore here, which left no way back to the
sidebar. Overriding it fixes the toolbar button and the View menu together, since both route
through that one method.

Sidebar rows deliberately leave `NSTableCellView.textField` unset. Assigning it lets the table
restyle the label on selection, which tints an unemphasized source-list row with the accent
colour; the filled selection shape is the only cue wanted. Each row view's `applyTextColors`
owns the colours instead, inverting only for `.emphasized` (selected while the sidebar has
focus).

A session row's trailing edge is one fixed-size slot holding the status indicator and the
`⋯` actions button overlaid, crossfaded on hover via `alphaValue` rather than `isHidden` —
a stack view detaches hidden arranged views, so toggling visibility would re-lay out the row
under the pointer.

### MCP Server

Skalman hosts an MCP server and registers it with each Claude or Codex session it launches,
which is how an agent reaches the GUI it is running inside. The terminal stays the input
surface; the display panel becomes the output surface for anything the terminal renders badly.

The transport is HTTP over a loopback port (`NWListener`, no dependency, no entitlement — the
app is unsandboxed already). stdio was the alternative and is worse here: it spawns a child
that would then have to find its way back to the running app, when the app is already alive
and already owns the routing table.

**Session routing is the whole design.** `MCPSessionRegistry` mints a per-session token and
`AgentLauncher` passes a URL embedding it through Claude's `--mcp-config` file or Codex's
one-run `mcp_servers` overrides, so a tool call arrives already attributed — the URL *is* the
identity. `AgentSession.id` is the key, not
`agentSessionID`, which is nil for Codex until discovery and always nil for shells.

Three deliberate choices in the launch line:

- **The display tool is pre-approved** with `--allowedTools mcp__skalman__*` for Claude and a
  tool-specific `approval_mode="approve"` override for Codex, or every image raises a
  permission prompt and the feature costs more attention than it saves. Other tools are
  unaffected.
- **No `--strict-mcp-config`**, which would suppress the user's own MCP servers for every
  session Skalman launches — a far larger change than adding one.
- **The `instructions` field of the `initialize` response** carries the "you have a panel,
  prefer it over describing a file" guidance. Capability alone does not change behaviour: an
  agent in a terminal has no reason to believe anything it emits can be seen as an image.
  Both clients consume those server instructions, so a separate system-prompt flag is not
  needed.

Tool results are **plain text, never image content blocks**. The app has already drawn the
image, so the result costs a sentence rather than an image's worth of tokens — and it sidesteps
the undocumented question of what Claude Code does with an image returned from a tool.

### Display Panel

`DisplayContent.Body` is an enum, so the panel shows either an `NSImageView` or a `WKWebView`
and the `⋯` menu offers only the actions that fit — an image and a document share almost
nothing worth acting on.

Three things were measured rather than assumed, each having first been wrong:

- **`NSSplitView.setPosition` does nothing** under `NSSplitViewController`, which lays its
  items out with Auto Layout. `setPosition(915, ofDividerAt: 1)` left the pane at its 260pt
  minimum. Width is set with a temporary constraint, released once honoured so the divider
  stays draggable.
- **`NSImageView`'s intrinsic content size is the image's own size**, so left alone it drives
  the split view and a 900px image opens a 900pt panel. Both content priorities are floored.
- **The width observer fired during the uncollapse layout**, recording the transient 260pt
  minimum as the user's width and then restoring *that*. `isRestoringDisplayPaneWidth`
  suppresses recording for the reveal, and the target width is read before uncollapsing.

The web view **allows network** and blocks only navigation. A CSP would be theatre: the agent
already has a shell, so anything it could exfiltrate through a page it could exfiltrate more
easily with `curl`. Blocking link navigation is a usability fix — a 380pt browser with no
back button is a trap — not a security control. Links go to `NSWorkspace` instead.

Documents load with `baseURL: nil`, giving an opaque origin: CDN scripts still load (measured),
but the page cannot read local files or same-origin data. A `color-scheme` meta is prepended
only when the document does not mention one, so unstyled HTML picks up WebKit's dark canvas
beside a dark terminal instead of flashing white.

WKWebView works in the unbundled `swift build` binary — worth knowing, since needing an
`.app` bundle for the web content process would have forced the project to Xcode-only builds.

`MCPServer` calls its handler on the main queue, because neither `ProjectStore`, `AgentRuntime`
nor AppKit is thread-safe. Everything arriving off the network hops before touching them.

The listener must be ready before any launch, since a launch reads the port — so
`AppDelegate` defers `restoreSelectedSession()` to the `start` callback. That callback fires
whether the listener came up or not: a failed server costs sessions their panel, not their
launch (`mcpFlags` returns "" and the command line is unchanged).

### Native Conversations (experimental, Codex only)

A session can be rendered by Skalman instead of shown as a terminal. `AgentSession.usesNativeUI`
picks the surface, fixed at creation — the two drive the CLI in incompatible ways, so switching
mid-conversation would mean killing the process and resuming under a different interface.

The mode is gated behind `AgentKind.supportsNativeUI`, which returns true only for Codex.
Claude is disabled *deliberately*: its streaming mode is `claude -p`, which runs on the user's
subscription, and Anthropic's 2026 terms restrict subscription OAuth to Claude Code and
claude.ai. The implementation remains in the tree but is unreachable. A session still flagged
native for an unsupported kind falls back to its terminal.

```
                    ConversationStreamSession
                              │
            ┌─────────────────┴─────────────────┐
            ▼                                   ▼
 CodexStreamSession                    ClaudeStreamSession
 one child per turn                    persistent stream (disabled)
 codex exec --json                     claude --print --stream-json
            │
            ▼
 ConversationViewController
```

`codex exec --json` is one-shot, not a persistent input stream. `CodexStreamSession` is
therefore a **logical** long-lived session: `start()` makes it ready, `send()` launches a child,
and a normal child exit makes it ready again. The first child creates a thread; the
`thread.started` event supplies the id persisted in `AgentSession.agentSessionID`, and each
later plan becomes `codex exec resume <id> --json -`. Plans are rebuilt per turn from the latest
`ProjectStore` record so the newly adopted id is never trapped in the controller's old snapshot.

`CodexStreamEvent` maps provider-specific JSONL onto the existing `[StreamEvent]` rendering
model. `agent_message` items become markdown, command/MCP/search/file items become the same
collapsible tool rows as Claude calls, and `turn.completed` returns the composer to Ready.
Codex does not emit agent-message deltas through `exec --json`, so its messages land complete;
the streaming placeholder remains useful only to the disabled Claude transport.

The disabled Claude transport was measured around four constraints before it was written:

- **The process survives multiple turns.** One instance serves a whole conversation; it is not
  respawned per message.
- **Token-level streaming exists** (`content_block_delta`), so this is not just transcript
  tailing with extra steps.
- **There is no interactive permission prompt.** A headless run silently *blocks* tools it
  would otherwise ask about — the third turn of the probe tried to write a file and was
  refused outright.
- **A `PreToolUse` hook can broker it.** The hook receives `tool_name`/`tool_input`, blocks
  synchronously while the app asks, and its `permissionDecision` is honoured.

That last point made the Claude mode viable rather than a choice between useless and unsafe.
The hook is a bare `curl` reading stdin and writing stdout, which is exactly the command-hook
contract — no helper script to install or keep in step with the app. It posts to the *existing*
MCP listener, and `session_id` routing was already solved, because for Claude sessions that
identifier is the UUID Skalman minted.

For that disabled Claude transport, the request is shown **inline in the conversation that
raised it**, as a `PermissionRequestView` card (`ConversationViewController.presentPermission`),
not a window-modal sheet. A sheet was the wrong shape: it seized the whole window for a decision
belonging to one session and gave no clue which session asked when several were running. The card
sits in the thread, keeps its place as a record of what was chosen after it is answered, and
carries the edit diff for edits. The modal sheet survives only as a fallback for the impossible
case — a request with no live conversation.

Claude requests are shown **one at a time**: an agent can fire several tool calls in a turn, but
a stack of cards is answered out of context, so they queue and the next appears only once the
current one is decided (`permissionQueue` / `activePermissionCard`, `showNextPermissionIfIdle`).

A pending Claude request in an **off-screen** session raises the sidebar's attention dot: a
native session reports `activity` through `AgentRuntime` alongside terminal sessions, returning
`.needsAttention` when anything is waiting and the session is not visible (`isVisible`, set by
`setVisibleSession`). On screen the card is the cue, so no dot. `terminate()` denies the active
card and every queued request, so a session that goes away does not leave the CLI blocked on the
hook's timeout.

`PermissionPolicy` decides which Claude tools are worth interrupting for, in Swift rather than
in the hook's matcher: the hook fires for every tool and the app filters. The read-only set is a short
**allowlist**, so a tool added in a future release prompts rather than slipping through unasked.

Claude's two views come from the CLI: `stream_event` deltas while tokens arrive, and complete
`assistant`/`user` messages once each finishes. The finished message is authoritative — the
streaming label is thrown away and replaced when it lands, rather than reconstructing state
from deltas.

**Resuming replays the transcript.** Neither agent streams old context into a new process, so
without `TranscriptReplay` the agent remembers a conversation the screen does not show. The
terminal never needed this: its scrollback *was* the record. Drawing the conversation ourselves
means rebuilding it.

Replay emits `[StreamEvent]` rather than a parallel model, so replayed and live content share
one rendering path. Claude reuses its content-block parser; Codex reads the clean `event_msg`
user/agent records from its rollout and deliberately ignores duplicate `response_item`
messages. `.userMessage` exists only for replay: a live turn is echoed locally as it is sent,
so producing it from the stream too would draw it twice.

Three Claude record kinds are skipped, and each would otherwise read as nonsense: `isMeta` (text the
CLI injected on the user's behalf, never typed), `isSidechain` (subagent threads, which belong
to a Task run rather than this conversation), and everything that is not `user`/`assistant`
(mode changes, titles, file snapshots). The cap is a *rolling window* keeping the newest turns
— what matters about a conversation being resumed is how it ended.

### Conversation Rendering

The chat surface follows the shape of a modern chat client, not a log: the user's turns are
right-aligned bubbles (`appendUserBubble`), the agent's are left-aligned markdown
(`appendAssistant` → `MarkdownView`). A bubble suits a short instruction; flowing text suits a
long answer, and forcing either into the other's shape is what made the first pass read as a
debug dump.

`Markdown` is a hand-written CommonMark subset — headings, paragraphs, fenced code, simple
lists, inline emphasis and code spans — because the project depends only on SwiftTerm and this
is a hundred lines of scanning rather than a package to track. Parsing is a **reader table**:
each block kind is a function that either consumes its block or returns nil for the next reader
to try, which keeps `parse` a flat loop rather than a branching tower. Fenced code is read
first and verbatim, so a `*` in a shell glob is never mistaken for emphasis. Code blocks draw
on their own scrollable monospace surface; everything else is a selectable label, so wrapping
and selection come free.

Tool calls render through `ToolCallView`: a fixed-width **glyph column** (`$` bash, `→` read,
`←` write, `✱` grep/glob, `◈` search — the vocabulary a terminal user already knows), the
tool, its one-line subject, and a size once the result lands. Collapsed by default and clicked
open, because a directory listing is longer than everything said around it. The glyph and the
whole surface aren't inspiration taken loosely from opencode's TUI — they are its exact idea,
expressed in AppKit and system colours instead of a hardcoded palette, per this file's
design-system rule.

Streaming stays plain text replaced by rendered markdown when the message finishes: rendering
markdown per token would reflow the whole block on every keystroke, and the finished message is
authoritative anyway. This is the same "finished message wins" rule the live/replay split
already depends on.

An **edit tool renders a diff**, not raw output. `EditDiff` builds `[DiffLine]` from the call's
own arguments — `Edit` gives old/new text, `Write` a whole new file (all added), `MultiEdit` a
list of hunks — so the diff is known *before the tool runs* and the result only confirms it
landed. The alignment is a line-level LCS walk, skipped past `alignmentCap` lines for a plain
removed-then-added rendering rather than paying for a huge table. `DiffView` draws one
full-width coloured row per line (the width is what reads as a diff, so it is rows, not an
attributed string) with a `+`/`−` gutter; long lines wrap because the pane is narrow and hiding
half a change off the right edge is worse. The same `DiffView` is the approval sheet's
accessory: an edit is approved on *what* it changes, which the sheet now shows, not merely which
file. This is opencode's diff-viewer idea in AppKit and system colours.

`JSONLReader` and `ClaudeTranscript` were extracted rather than copied: `SessionImporter`
already read these files, and the transcript path was already derived in two places. The
reader's correctness notes — never cap a record, let the caller decide when to stop — now live
in one place instead of being rediscovered per caller.

### Git Layouts

`GitInfo` reads git metadata from disk rather than shelling out. Three layouts matter, and
only the first has a `.git` *directory*:

| Layout | `.git` | Metadata lives at |
|---|---|---|
| Ordinary checkout | directory | `<root>/.git` |
| Linked worktree | file | `<repo>/.git/worktrees/<name>` |
| Submodule | file | `<super>/.git/modules/<name>` |

Worktrees and submodules store a **file** containing `gitdir: <path>`, so reading
`<root>/.git/HEAD` finds nothing — worktrees showed no branch at all until `gitDirectory(for:)`
started following that pointer. A git *subtree* needs no handling: it is merged content, and
looks exactly like an ordinary subdirectory.

`worktreeLocation(for:)` resolves a path once into both identities, and the accessors
(`worktreeIdentity`, `repositoryIdentity`, `worktreeName`) read from it. The two identities are
the `git-dir` / `git-common-dir` distinction: `worktreeIdentity` is the checkout's own git
directory (`<repo>/.git/worktrees/<name>`, or `<repo>/.git` for the main tree) and is stable
per checkout — it does not change when the branch does; `repositoryIdentity` trims the
`/worktrees/<name>` suffix so every checkout of a repo shares one identity, which is the
sidebar's grouping key. **`worktreeIdentity` is the durable key for "which checkout"; the
branch is only ever a display value.** A submodule keeps its own identity under `/modules/`,
correctly — it is a separate repository that happens to live inside another.

The sidebar groups **only when a repository has more than one checkout added**, so the common
single-checkout case keeps the flatter two-level layout. Grouped checkouts are labelled by
branch, since the repository name is already shown above them.

A branch belongs to a *checkout*, not to a repository: two worktrees of one repo are on
different branches simultaneously. It is re-read when a session stops working, which is when
an agent is most likely to have just switched, rather than by polling.

A *session*, though, carries its own branch record (`AgentSession.branch`): captured at
creation, re-read by `ProjectStore.refreshBranch` at the same stopped-working moment, and
frozen while dormant — a conversation happened on whatever was checked out at the time, and
that stays true after the checkout moves on. It drives the sidebar's **branch grouping**
(`SidebarTreeBuilder`, `BranchGroupNode`): inside a project, sessions sharing a branch gather
under a heading, but **only when that branch has more than one session** — the same
earns-its-level rule as repository grouping, applied one level down. Sessions on lone
branches or with no recorded branch stay directly under the project, and a group takes its
first session's position so the list keeps its order. Toggleable via
`AppSettings.groupsSessionsByBranch` (on by default; Settings > General), and also from where
the grouping is *seen*: a checked menu item in the project-row and branch-heading context
menus, and a gear that fades into a branch heading's trailing slot on hover (the session
rows' `⋯` crossfade mechanism, reused) opening the toggle plus an "All Settings…" door.
Branch headings are not selectable, collapse like projects (state kept in-memory only — the
groups themselves are transient), and the hover popover prefers the session's recorded branch
over the checkout's current one for the same reason the record exists.

The branch is **not shown on the project row** — it lived there once as a subtitle, which read
as though the project *were* that branch, when a checkout's branch changes and one repo can
have several checkouts at once. It surfaces instead in the **session rows' hover popover**
(`SessionInfoPopoverViewController`) — sessions are what get selected and what run inside the
checkout — alongside the session's full title, its agent and account, the folder path, and,
when the checkout is a linked worktree, `GitInfo.worktreeName`. The one place the branch still
names a row is a *grouped checkout*, where it is the row's identity — the repository name is
already above it, so the branch is what tells the checkouts apart. The popover opens after a
short hover dwell so it does not flash while the pointer crosses rows, and it survives the
constant reconfigures of a working session's row, dismissing only on exit or reuse for a
different session.

### Session Activity

`SessionActivityTracker` derives `dormant` / `idle` / `working` / `needsAttention` from PTY
output, because an idle agent writes nothing at all — measured at zero bytes over 19s while
sitting at its prompt. This works for any program rather than one specific agent.

Four guards keep it honest:

- A **byte threshold** (`workingByteThreshold`), so the terminal echoing typed characters is
  not mistaken for work.
- A **quiet interval**, so gaps within a burst of output do not flicker the state.
- A **resize quiet period** (`noteTerminalResized`). Resizing sends `SIGWINCH` and full-screen
  terminal apps answer by repainting everything, which is a large burst of output that we
  caused. Suppression blocks a session *entering* `working`, but deliberately keeps an
  already-working session's timer alive — otherwise resizing mid-task would report it as
  finished.
- A **scroll quiet period** (`noteScrollForwarded`). When a program tracks the mouse, wheel
  events are forwarded to it (see the fork's `MacTerminalView.scrollWheel`) and it answers
  each one by repainting its content — the same we-caused-it output as a resize, extended by
  every event so a momentum gesture stays covered.

`needsAttention` is only raised when work finishes in a session that is *not* on screen;
`AgentRuntime.setVisibleSession` tracks which that is. A terminal bell raises it directly.

Output arrives on the main queue (`LocalProcess` defaults its dispatch queue to
`DispatchQueue.main`), which is what lets the tracker use `Timer` safely.

### Session Names

A session carries three names, resolved by `displayTitle`:

1. `customTitle` — an explicit rename, which wins and stops following the terminal
2. `terminalTitle` — the live title the agent reports, retained after it exits
3. `title` — the name assigned at creation

`launchName` deliberately excludes `terminalTitle`, so the agent's own output is never fed
back into the next launch's `--name`.

Terminal titles are stripped of their leading decorative glyph on the way in
(`ProjectStore.strippingDecoration`). Claude Code reports titles like `✻ testings`; that marker
identifies the agent in a plain terminal tab, but the sidebar already draws a status dot and an
agent icon, so keeping it would put a third symbol before every name. A title consisting only of
symbols is left intact rather than reduced to nothing.

### Icons

Two kinds of icon, resolved differently on purpose.

**Agent marks** (`AgentBrandIcons`): sessions on a default account show the agent's own
favicon — Claude's coral starburst, OpenAI's knot — instead of an SF Symbol. Loose PNGs under
`Resources/Icons`, loaded via `Bundle.main` (the folder is an explicit-folder resource, so it
lands under `Contents/Resources/Icons/`), *not* the asset catalogue. The OpenAI knot is monochrome by design, so it
ships as a **template image** and tints with its context like the symbols beside it — which
is what makes it work in dark mode and dim for dormancy. Claude's mark keeps its brand
colour; tinting cannot dim a non-template image, so dormancy dims it through the view's
alpha instead (`SessionRowView.applyAgentIcon`). An account emoji still beats the mark —
the icon slot's job is telling sessions apart, and the account is the bigger difference.

**Project icons** (`ProjectIcon` on `Project`; files owned by `ProjectIconStore`): the
project row shows the project's own mark, else a folder symbol. Every stored icon is
normalised through ImageIO — largest frame (`.ico` carries several), capped at 64px,
re-encoded PNG — so the sidebar never holds a 1024px app icon per row, and an HTML error
page served with a 200 fails the same decode gate that admits real images.

`ProjectIconDiscovery` fills empty slots free of any agent, and **probes known paths rather
than walking the tree**: a recursive scan would surface `node_modules/<lib>/favicon.ico` as
the project's mark. Only the `AppIcon.appiconset` search enumerates, bounded and skipping
dependency directories. Then the GitHub owner avatar (read from the *shared* git config via
`GitInfo.remoteOriginURL` — remotes belong to the repository, not a checkout), then the
favicon of the `package.json` homepage; the network sources only contact hosts the project
itself points at, plus one GitHub API call gating the avatar. Automatic discovery only ever
fills an **empty** slot; a user's explicit choice (`.custom`) is never displaced.

The avatar is admitted **only for organisation owners** (`isOrganization`, via
`api.github.com/users/<owner>`): a person's avatar puts the same face on every repo they
own, which distinguishes nothing — and any doubt (API error, rate limit) refuses rather
than guesses, because the failure mode of guessing is a face on every project. A project
with no discovered mark renders `GeneratedProjectIcon` at *draw time* — its initial on a
colour from a stable djb2 hash of the name (`hashValue` is process-salted and would
recolour the sidebar per launch) — never persisted, so the slot stays genuinely empty for
later discovery.

`SingleInstanceLock` (`flock`, held for the process lifetime) refuses a second instance at
launch, before anything touches the stores: two live instances share `projects.json`
last-writer-wins, and even *instantiating* `ProjectStore` writes it once — a relaunch
handoff between overlapping instances is how three projects lost their icon records. The
losing instance's quit path skips store teardown for the same reason.

The sidebar draws the *composed* rendition (`ProjectIconStore.displayImage`): rounded-rect
clipped, and set on a small **backplate** of the opposing tone when the icon's own
alpha-weighted mean luminance would vanish against the current appearance — a dark mark on
the dark sidebar gets a light plate, measured from the icon's pixels rather than guessed
from its source. The plate colours are fixed neutrals *on purpose*, an exception to the
system-colours rule: a plate exists to oppose the appearance, and every system colour
follows it. Rows retain the `ProjectIcon` and re-compose on
`viewDidChangeEffectiveAppearance`, since the decision is per-appearance.

`ProjectIconResearch` asks Codex to identify the mark — headless `codex exec`, read-only
sandbox, low reasoning effort, default account. Codex-only for the same reason as
`supportsNativeUI` (Claude's headless mode runs subscription OAuth outside Claude Code),
and **manual-only** because it spends the user's own usage: each run is one explicit
"Research Icon with Codex" menu click, never a background default. A file path in its
answer is admitted only from inside the project's own folder — the run is sandboxed, but
our read of its answer is not.

**A headless child is invisible by construction, so every run leaves a record**: the
child's stdout and stderr — merged into one pipe, so a single reader can never deadlock
and the record holds the whole story — land in `IconResearch/<projectID>.jsonl` under
Application Support, written *before* the verdict so failed runs are exactly the ones
whose record survives. Stages log through `SkalmanLogger.agent`, and the sidebar exposes
the record as "Open Last Research Log". This observability exists because the first real
run failed silently and nothing could say where.

Agents can set the icon from inside a session via the `set_project_icon` MCP tool, its own
group on the Tools page.

**Account avatars** (`AccountAvatarStore`): a session's icon slot resolves emoji →
discovered avatar → letter badge → brand mark. The avatar comes from the account's login
email — Claude's `.claude.json` `oauthAccount.emailAddress`, the `email` claim of Codex's
`id_token` (decoded locally; the token itself is never used) — probed against Gravatar
(SHA-256, `d=404` so a miss is a status code) and then GitHub's public-email user search.
The person-avatar ban on project rows *inverts* here on purpose: an account is a person,
and different logins carry different faces, so the avatar distinguishes. It outranks even
the default account's brand mark — a resolved face identifies harder than a logo, and the
per-account emoji still overrides. Hits land in `AccountAvatars/` and refresh the sidebar
through the same notification an emoji edit posts; behind
`AppSettings.discoversAccountAvatars`, which is the only thing that lets an email hash
leave the machine.

### Accounts

Both CLIs support multiple logins via `CLAUDE_CONFIG_DIR` / `CODEX_HOME`. Accounts are
discovered from the filesystem, not from aliases, so they are found regardless of shell setup;
aliases are read only to supply a friendly label.

Admission requires proof of a real login (`.claude.json`/`settings.json` for Claude,
`auth.json` for Codex). Two things are deliberately excluded: Claude Science data roots
(`~/.claude-science`, or any root carrying `install-id` + `runtime/` + `orgs/`), which hold
Claude-shaped state but are not login slots; and aliases that set no config directory.

Two invariants matter:

- **The account sticks to the session.** Conversations are stored per account, so a resume
  must route to the same account or the id will not be found.
- **The default account launches with `env -u`**, not a bare command. A login shell may export
  an override, which would otherwise silently route to the wrong account.

In the sidebar an alternate account is identified entirely by the session's icon slot — its
chosen emoji, else a letter badge (`c.circle.fill`) from its name — with the full name in the
tooltip. Rows carry no account text line, which keeps every session a single-line row.

This mirrors the logic in `~/repo/claudex` (`CredentialStore`, `HandoffLauncher`).

**Moving a conversation between accounts** (`SessionMigration`) exploits that a transcript is a
client-side file the CLI replays each turn, not server state bound to the originating account.
*Verified empirically*: a Claude transcript copied into another account's config dir resumed
with full context under that account. So a move is: copy the transcript into the target
account's directory and re-point `accountHandle`. The destination is the source path with its
**account-directory prefix swapped** — the layout under a config dir (`projects/<slug>/` for
Claude, dated `sessions/` for Codex) is identical between accounts, so one prefix swap serves
both agents. It is **non-destructive** (the original stays, so a move reverses), stops any live
process first (it belongs to the old account and is still writing the file), and Skalman never
touches a token — the official CLI authenticates under whichever account, so this is
portability, not credential reuse.

Same agent only. Cross-agent (Claude ↔ Codex) is *not* a resume — the transcript formats and
resume paths differ — so it is deliberately not offered here; the honest cross-agent operation
is a re-seed (replay the normalized `[StreamEvent]` into a new session on the other agent),
which is a separate, lossy feature.

### Account Usage

The toolbar's trailing pill (`AccountUsageItemView`) shows the selected session's account
rate-limit pressure: a ring gauging the peak window beside every window's own value
(`5h 43% · 7d 73%` — Claude's own status-line vocabulary), monochrome until 75%, orange then
red past 92%, each value tinted by its own window's severity; clicking opens per-window bars
with reset countdowns. `AccountUsageService` caches
per account and keeps the last good reading through failed refreshes. The credential posture
mirrors `~/repo/claudex`: read the short-lived tokens the official CLIs already keep, never
refresh them, and **never read the Keychain** — its `Claude Code-credentials` items do not
say which config directory they belong to, and an unbundled binary re-prompts every rebuild.

Sources, per provider:

- **Codex** — `auth.json` (`tokens.access_token` + `tokens.account_id`) against
  `chatgpt.com/backend-api/wham/usage`, with the `ChatGPT-Account-ID` and `originator`
  headers the backend gates on. Primary/secondary windows are *positions*, not timeframes —
  each is named from its own `limit_window_seconds`.
- **Claude** — `<config>/.credentials.json` against `api.anthropic.com/api/oauth/usage`
  when the file exists. On this machine it does not (macOS keeps the token in the Keychain),
  so the working source is **Claudex's status-line cache**:
  `~/Library/Application Support/Claudex/ClaudeStatus/<profileID>.json`, where `profileID`
  is the lowercase-hex SHA-256 of the standardized, symlink-resolved config-dir path
  (Claudex's own recipe, verified against the real cache files). Claude Code pushes
  `rate_limits` into that feed on every turn, so it is fresher than any polling — and reads
  as `source: .localCache`, which shortens the re-read interval from 300s to 30s.

A window whose `resets_at` has passed keeps its identity but not its percentage — the stale
value describes the *previous* window, so it renders as `—`, never as pressure. The pill
hides entirely for accounts with no usage source (shells always; Claude without either
source): a control with nothing to say is noise in the always-visible corner.

```
Select session → AgentLauncher.plan() → login shell → cd <project> && exec <agent>
                                                              ↓
                          agent exits → PTY torn down → session marked dormant
                                                              ↓
                  row stays in sidebar → select again → resume by agent session id
```

Launches go through a **login shell** because a GUI app does not inherit the user's
interactive `PATH`, and the agent CLIs live in `~/.local/bin` or a Node prefix.

Claude accepts `--session-id <uuid>`, so the id is minted up front. Codex has no equivalent,
so its id is read back from the `session_meta` record at the head of the rollout file it
writes under `~/.codex/sessions/`.

### Session Import

`SessionImporter` discovers conversations started outside Skalman by reading the transcripts
the CLIs already keep, so a session can be adopted into a project and resumed by id.

Reading these files has two traps, both of which cost real coverage before they were fixed:

- **Never cap a record read at a fixed byte count.** A Codex `session_meta` line carries the
  project's instructions, so it runs to tens of kilobytes and grows with `AGENTS.md` — a 16 KB
  cap silently skipped 62% of rollouts, because a truncated line is not parseable JSON. Read
  until the record ends, and bound the *scan*, not the record.
- **The opening turn is not near the top.** Codex writes telemetry (`token_count`,
  `agent_reasoning`) ahead of the conversation, and compaction pushes the first user turn
  further still — past 500 KB in ordinary sessions. `forEachRecord` therefore streams and lets
  the caller stop, so the usual file costs one chunk while a buried turn is still found.

Titles come from the record that holds only what the user typed: Claude's `ai-title`, and
Codex's `event_msg`/`user_message` — *not* the `user`-role messages, which replay the CLI's
own instruction blocks. A transcript with no user turn is not offered at all: Codex writes a
rollout for its approval reviewer against the same project directory, and those are machine
turns nobody can meaningfully reopen.

**A chat is attributed by which worktree it ran in, not by a raw path.** Every transcript
records the directory it launched in — Codex's `session_meta.cwd`, and Claude's per-record
`cwd` (the project-slug directory name is a *lossy* encoding, since two different paths can
slug alike, so the recorded path is the authority). `belongs(cwd:folder:worktree:)` resolves
that path to its worktree via `GitInfo.worktreeIdentity` and admits it only when it is the
project's folder, or a subdirectory *of the same checkout*. This is what keeps a worktree
nested inside the folder — the common `<repo>/.git`-adjacent layout, e.g.
`sonda/.claude-worktrees/SONDA-348` — *out* of the parent project: it is a separate checkout
with its own git directory, on its own branch. The equal-path case, which is almost every
rollout, is settled without touching disk. This mirrors how opencode anchors a session
(`rev-parse --git-dir` vs `--git-common-dir`), read off disk rather than by shelling out.

Verify against disk rather than by eye — `~/.codex/sessions/**/*.jsonl` and
`<claude config>/projects/<slug>/` are the ground truth, and both are cheap to count. The
worktree rules resist real data (no subdirectory-launched chats exist here) so they are proven
against a built layout — main + nested + sibling worktrees — rather than only observed.

### Data Flow

```
User Input → LocalProcessTerminalView → PTY → Agent Process
                       ↓
Agent Output ← LocalProcessTerminalView ← PTY
                       ↓
             (SwiftTerm handles parsing internally)
```

### Key Protocols (SwiftTerm)

- `LocalProcessTerminalViewDelegate`: Receives process lifecycle events
- `TerminalViewDelegate`: Receives terminal state changes (title, size, etc.)

## Design System

**New UI is built from `Sources/Skalman/UI/Design/`, not from stock AppKit controls.** This is
the default, not a preference: a screen assembled from `NSPopUpButton`, `NSBox` and bezelled
buttons will not match anything else in the app.

`Design.swift` holds every measurement, weight and surface colour. Reach for a token rather
than a number — a literal in a view is how the language erodes. The scale is deliberately
small (`Spacing` is 2/4/6/10/12/20/32); a value between two steps is nearly always a mistake.

Components so far:

| | |
|---|---|
| `ChipView` | A flat pill that opens a menu. The standard way to offer a choice. |
| `PromptView` | A rounded container holding a text field and its submit control, as one input. |

The vocabulary these encode, which new work should follow:

- **Flat over bezelled.** Pills and panels with a subtle fill. Stock bezels are heavier than
  anything here and pull attention away from content.
- **Quiet until relevant.** Surfaces rest below full opacity and lift on hover. A control
  offering a single option *hides* rather than showing a dead menu — the composer's account
  and model chips both do this.
- **Content leads.** One element per view carries emphasis, usually what is being typed into
  or read. Everything else is secondary or tertiary label colour.
- **System colours only.** Every surface derives from a system colour, so light and dark both
  work and the accent is the user's own. No hardcoded RGB.
- **`.continuous` corners.** The default circular curve looks subtly wrong beside system
  controls at these radii; `applySurface(fill:radius:border:)` handles this.

`SessionComposerViewController` is the reference implementation — heading, chips, prompt,
anchored above centre and capped at `Design.Size.readableWidth`.

Preferences still use stock AppKit via `PreferencesFormBuilder`. That is deliberate: a
settings window is one place where matching the platform beats matching the app.

## Code Style Guidelines

### Constants & Configuration

All magic numbers and string literals must be defined as constants:

```swift
enum TerminalDefaults {
    static let columns = 80
    static let rows = 24
    static let scrollbackLines = 10_000
    static let defaultShell = "/bin/bash"
    static let defaultFont = "SF Mono"
    static let defaultFontSize: CGFloat = 13
}

enum WindowDefaults {
    static let minWidth: CGFloat = 400
    static let minHeight: CGFloat = 300
}
```

### Naming Conventions

- Types: `PascalCase` (e.g., `TerminalSession`, `CursorStyle`)
- Properties/Methods: `camelCase` (e.g., `currentDirectory`, `startShell()`)
- Constants: `camelCase` within enum namespaces
- File names match primary type name

### Structure Organization

```swift
// MARK: - Properties (public, then private)
// MARK: - Initialization
// MARK: - Public Methods
// MARK: - Private Methods
// MARK: - Protocol Conformance (each protocol gets its own extension)
```

### DRY Principles

- Extract repeated logic into well-named helper methods
- Use protocol extensions for shared behavior
- Centralize color/theme definitions in a single source
- No hardcoded literals - use constants

### Error Handling

```swift
enum TerminalError: LocalizedError {
    case shellNotFound(path: String)
    case sessionCreationFailed

    var errorDescription: String? { /* ... */ }
}
```

## File Organization

```
Sources/Skalman/
├── App/                    # App entry point, AppDelegate
├── Core/
│   ├── Constants/          # TerminalConstants.swift
│   ├── Agent/              # AgentLauncher, AgentRuntime, CodexSessionDiscovery, GitInfo
│   ├── MCP/                # MCPServer, MCPConnection, MCPSessionRegistry, MCPTools
│   └── Session/            # TerminalSession, ProjectStore, StateManager
├── UI/
│   ├── Design/             # Design.swift tokens, ChipView, PromptView
│   ├── Windows/            # MainWindowController
│   ├── Views/              # Sidebar, terminal container, custom NSViews
│   └── Preferences/        # Settings UI
├── Models/                 # Project, AgentSession, TerminalProfile, TerminalTheme
├── Extensions/             # NSColor+Terminal, etc.
└── Resources/              # Assets, fonts
```

## Testing

- Unit tests for `TerminalSession` state management
- Unit tests for `TerminalProfile` serialization
- Integration tests for shell spawning
- UI tests for keyboard input handling

## Documentation

### IMPROVEMENTS.md

The prioritized reliability/type-safety roadmap from the July 2026 architectural review,
kept as a working checklist. When fixing anything it lists, check the item off there; when
touching a subsystem it covers, read its entry first — several items (persistence
quarantine, `@MainActor` adoption, typed IDs) change the rules new code should follow.

### USER_GUIDE.md

The `USER_GUIDE.md` file documents all user-facing features, keyboard shortcuts, and behaviors. **Keep it in sync** when:

- Adding new menu items or keyboard shortcuts
- Adding/removing/changing user-visible features
- Modifying preferences or settings
- Changing state persistence behavior
- Adding new UI components (find bar, process tree, AI mode, etc.)

The guide is organized by feature area with a comprehensive keyboard shortcuts reference at the end.

## Important Notes

- **No App Sandbox**: PTY operations require sandbox to be disabled
- **Hardened Runtime**: Enable with exceptions for PTY
- **SwiftTerm handles**: Escape sequence parsing, screen buffer, cursor management, Unicode
