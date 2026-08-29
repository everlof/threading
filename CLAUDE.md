# CLAUDE.md

This is the canonical repository guidance for every coding agent. The filename is historical; the
rules are not specific to one tool.

**This file is an index.** The reasoning behind each subsystem — what was measured, what was
wrong first, and which rules are load-bearing — lives in `docs/architecture/`. Those notes are
not recoverable from the code, so **read the relevant file before changing a subsystem**; the
table under [Subsystems](#subsystems) says which one.

## Project Overview

Threading is a native macOS app for organizing coding-agent sessions, built with **Swift** and **AppKit**, using **SwiftTerm** for terminal emulation. Targets **macOS 13+ on Apple silicon** — the app is
`arm64` only; see [`releasing.md`](docs/architecture/releasing.md#apple-silicon-only).

A single window pairs a project sidebar with the selected session's terminal. Each session
hosts a Claude Code, Codex, Grok, or OpenCode process inside a project folder, with a shell available under it
on demand. Sessions outlive their
terminals: when the agent exits, the PTY is torn down but the session record remains so the
conversation can be resumed later by its agent-assigned identifier.

## Build & Run Commands

The project is **Xcode-only** — a single `Threading.xcodeproj`, no SwiftPM manifest. (SwiftTerm
stays a local Swift package that the Xcode project references; the app's own `Package.swift` was
removed so there is one build system, not two.)

```bash
# Build the app
xcodebuild -project Threading.xcodeproj -scheme Threading -configuration Debug build

# Run the tests — see "Test levels" below for which one to pick
scripts/test.sh          # fast: everything except the tests that put a window on screen
scripts/test.sh all      # the whole ThreadingTests target
scripts/test.sh ui       # app-level XCUITest scenarios in an isolated Cocoa home
scripts/test-connectivity.sh software  # focused Mac + iOS Simulator connectivity contracts
scripts/test-connectivity.sh hardware --device <name-or-UDID> --scenario automatic --non-interactive  # unattended device lifecycle lane

# Run the built app (never the bare binary — build with xcodebuild, then open the bundle)
open "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Threading-*/Build/Products/Debug/Threading.app | head -1)"

# Opt-in macOS + iOS Simulator InjectionNext hot reload. Quit Threading and Xcode first.
scripts/injection_next.sh xcode
```

**Agent shorthand:** when the user says **“injection mode”**, run
`scripts/injection_next.sh xcode` without asking them to restate the workflow. Tell them when the
supervised Xcode is ready so they can quit Threading and press Run. If Xcode or InjectionNext is
already open, report that prerequisite instead of quitting either app without permission.

`scripts/injection_next.sh` is the only InjectionNext path. It downloads one pinned, signed and
notarized release to the user's cache, prepares cache-local macOS and iOS Simulator clients,
applies `scripts/config/injection-next.xcconfig` to that supervised Xcode's Debug app builds
through `XCODE_XCCONFIG_FILE`, and has InjectionNext launch that Xcode so it can observe compiler
commands and source saves. To keep both apps live, open the project in two windows inside that one
Xcode process, then Run `Threading` on My Mac in one and `ThreadingMobile` on an iOS Simulator in
the other. Do not accept any offer to patch the project or compiler. The wrapper does not enable
file-watcher mode and does not modify `Threading.xcodeproj`. Xcode and InjectionNext must both be
quit before running the wrapper, and every Threading must be quit before pressing Run because the
experiment uses ordinary app state. Ordinary Xcode, command-line builds, tests, profiling, CI,
Release and physical-device builds do not link or start InjectionNext; use those ordinary paths
for every completion check. Injection replaces function bodies, not type layout: adding stored
properties, changing signatures, adding or renaming source files, and changing already-initialized
stored constants still require a normal rebuild. The two model-effort pickers deliberately keep
their tweakable local metrics as computed accessors and invalidate/re-evaluate on InjectionNext's
completion notification, so an already-open picker visibly refreshes after a save. Never use an
injection build for tests, performance evidence or shipping verification.

**A commit on master starts a background build.** `scripts/install_git_hooks.sh` installs
post-commit and post-merge hooks that rebuild master's tip in a separate clone and install it over
`/Applications/Threading.app`, cancelling and restarting when a newer commit lands. It never quits
or moves the running app: a ready build waits until Threading quits before installing.
`scripts/autoinstall.sh status` says what it is doing and `off` pauses it; see
[`releasing.md`](docs/architecture/releasing.md).

Resources: files under `Sources/` are members of the app target automatically (Xcode 16
synchronized folders). The asset catalogue compiles to `Assets.car`; `Resources/Icons` is marked
an explicit folder so its loose PNGs land under `Contents/Resources/Icons/`, loaded via
`Bundle.main` (`AgentBrandIcon`). Unit tests `@testable import Threading`, so the test bundle is
hosted in the app; `AppDelegate` skips its real startup under `XCTestCase` so tests spawn no
agents or MCP server.

`Tests/ThreadingTests` and `Tests/ThreadingUITests` are filesystem-synchronized Xcode groups.
A new Swift file under either directory is compiled by its owning target automatically; do not
add per-file `PBXFileReference`, `PBXBuildFile`, group, or Sources-phase entries. UI tests launch
the shipping executable against a disposable `CFFIXED_USER_HOME`; read
[`ui-scenario-testing.md`](docs/architecture/ui-scenario-testing.md) before adding a scenario or
recording provider traffic.

## Dependencies

Four local Swift packages are referenced as `XCLocalSwiftPackageReference`s. ThinkingOrbs,
LabelMorph and BorderBeamKit are git submodules; SwiftTerm is vendored directly in this
repository. **All four are our forks — modify their source directly** rather than working
around them.

| | Location / upstream | What it draws |
|---|---|---|
| **SwiftTerm** | `./Packages/Vendor/SwiftTerm/` — [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal emulation: VT100/xterm, ANSI parsing, PTY. The iOS folder is excluded on macOS builds. |
| **ThinkingOrbs** | `./Packages/Vendor/ThinkingOrbs/` — [everlof/thinking-orbs-swift](https://github.com/everlof/thinking-orbs-swift) | The dotted "working" orb beside the conversation status. AppKit `ThinkingOrbView` only; the app stays AppKit-only. |
| **LabelMorph** | `./Packages/Vendor/LabelMorph/` — [everlof/LabelMorph](https://github.com/everlof/LabelMorph) | The AppKit/UIKit label that morphs a name character by character — every session, project and checkout name. |
| **BorderBeamKit** | `./Packages/Vendor/BorderBeamKit/` — [Jakubantalik/border-beam](https://github.com/Jakubantalik/border-beam) (its `ports/ios` tree, extracted) | The breathing agent-activity ring over the composer and around the sidebar's selected working row. AppKit `BorderBeamHostView` only; the SwiftUI + Metal half stays inside the package. |

Each has a seam that is ours (ThinkingOrbs' `tint`, LabelMorph's truncation, BorderBeamKit's
AppKit host) plus the theme wrapper that drives it: see
[`docs/architecture/dependencies.md`](docs/architecture/dependencies.md).

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

- **ProjectStore**: Owns projects and sessions; persists to SQLite. Knows nothing
  about running processes. Terminal-title updates are coalesced (`scheduleSave`) because
  agents rewrite the title constantly; structural edits save immediately.
- **AppSettings / AccountPreferencesStore**: `UserDefaults`-backed behavioural settings and
  per-account icon/name customisation.
- **AgentKind.capabilities**: The one place a runtime is named to decide what the host may do
  with it. Everything else asks `kind.supports(_:)`;
  `scripts/check_architecture_boundaries.sh` fails the build on a `kind == .claude`-shaped
  comparison outside `Models/Project.swift`. See [`sessions.md`](docs/architecture/sessions.md).
- **AgentRuntime**: Caches live `AgentSessionViewController`s keyed by session id. A session
  with no entry is dormant.
- **AgentLauncher**: Builds the command line for a fresh launch vs. a resume, including
  account routing.
- **CodexSessionDiscovery**: Recovers the session id Codex assigns itself after launch.
- **OpenCodeSessionDiscovery**: Recovers OpenCode's provider-assigned `ses_…` id through its
  public JSON session listing.
- **AgentAccountDiscovery**: Finds agent logins by scanning `~/.claude-*` / `~/.codex-*`.
- **ShellAliasReader**: Labels accounts with the user's own alias name.

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

### Launching

Launches go through a **login shell** because a GUI app does not inherit the user's interactive
`PATH`, and the agent CLIs live in `~/.local/bin` or a Node prefix. Claude and Grok accept
`--session-id <uuid>`, so their ids are minted up front. `GrokSessionDiscovery` confirms the Grok
record through `grok sessions list` before marking it resumable, because quitting first-login
authentication creates no session. Codex has no equivalent, so its id is read back from the
rollout it writes (or, better, reported by its `SessionStart` hook). OpenCode also assigns its own
id; `OpenCodeSessionDiscovery` reads it through `opencode session list --format json`, never
through a private database schema.

## Subsystems

Each file states the decisions and the measurements behind one area. Read the one you are about
to change — most of these rules were arrived at by getting the obvious thing wrong first.

| Read before you touch | File |
|---|---|
| The toolbar, the pane header strips, the sidebar's silhouette, split-item behaviour, anything pinning to `topAnchor` | [`window-chrome.md`](docs/architecture/window-chrome.md) |
| The MCP server, tool routing by session token, launch flags, the display panel and its web view | [`mcp-and-display.md`](docs/architecture/mcp-and-display.md) |
| The opt-in paired-iPhone evidence path, automatic error screenshots, bounded Mac cache and iOS checkup tools | [`ios-local-diagnostics.md`](docs/architecture/ios-local-diagnostics.md) |
| The session-owned in-panel iOS Simulator, CoreSimulator lifecycle, direct framebuffer/input helper, leases and agent route | [`simulator-pane.md`](docs/architecture/simulator-pane.md) |
| The live browser an agent drives: origin grants, the accessibility snapshot, refs and semantic locators, the browser tools | [`agent-browser.md`](docs/architecture/agent-browser.md) |
| Natively rendered conversations: the Claude/Codex stream transports, permission brokering, transcript replay, the timeline model, tool rows, diffs, the turn rail | [`native-conversations.md`](docs/architecture/native-conversations.md) |
| The exact agent-execution ledger: provider-native adapters, redaction, hash-linked storage, filters and the live browser split | [`execution-audit.md`](docs/architecture/execution-audit.md) |
| Session state (`dormant`/`idle`/`working`/`needsAttention`/`limitReached`), Claude/Codex lifecycle hooks, provider-neutral output inference, `hooks.json`, the shell-command policy | [`session-activity.md`](docs/architecture/session-activity.md) |
| Reading git metadata (worktrees, submodules, identities), the Git Review pane, staging, the commit graph, diff syntax highlighting | [`git.md`](docs/architecture/git.md) |
| The draft opt-in for a session-owned detached worktree, execution-directory routing, finish handshake, local merge and disposal | [`managed-workspaces.md`](docs/architecture/managed-workspaces.md) |
| Documents that vary over time: the `media` node, the host-owned player and its renderer registry, the Lottie and movie engines, bounded project-file handles, the attachments preview seam | [`media-documents.md`](docs/architecture/media-documents.md) |
| The runtime capability matrix, side chats and forking, the shell drawer, session naming, launching, resuming, importing outside conversations | [`sessions.md`](docs/architecture/sessions.md) |
| A session's PTY outliving the app: the `threading-ptyd` wire contract, its framing and frames, the version gate, the ring and the exact rejoin, the launchd registration and the retire-on-upgrade rule | [`pty-host.md`](docs/architecture/pty-host.md) |
| Writing a message now and sending it later: the record, the store, the clock, waking a dormant session, the usage-reset presets | [`scheduled-messages.md`](docs/architecture/scheduled-messages.md) |
| A session refused over a rate limit: the transcript signal, the limit chooser, recovery policies, the parked state, the scheduled continuation | [`limit-recovery.md`](docs/architecture/limit-recovery.md) |
| A scheduled end for a session: the deadline and its three moments, the wind-down message, the hold at every seam, bounded interrupts and the stop-agent escalation, quiet hours, receipts | [`curfew.md`](docs/architecture/curfew.md) |
| An agent that would not start: the captured failure record, the launch-failure surface, the transcript preflight, and repairing a broken conversation with an agent | [`launch-failure.md`](docs/architecture/launch-failure.md) |
| The typed session control plane: actor/scope/refusal contract, cross-session messaging (`list_sessions`/`send_to_session`), delivery per surface, provenance | [`control-plane.md`](docs/architecture/control-plane.md) |
| The first-launch walkthrough: window deferral and the terminate trap, the completed flag, the global conversation scan, the notifications opt-in | [`onboarding.md`](docs/architecture/onboarding.md) |
| Terminal themes, app themes, the three assignment scopes, the MCP theme tools, glow and clipping | [`themes.md`](docs/architecture/themes.md) |
| Agent marks, account chips, project icons, icon discovery and research | [`icons.md`](docs/architecture/icons.md) |
| Opening a checkout or a file in another app: the registry, LaunchServices detection, line numbers, the header's split control | [`external-apps.md`](docs/architecture/external-apps.md) |
| Multiple logins per CLI, discovery and naming, migrating a conversation between accounts, usage readings, the usage-window poke | [`accounts.md`](docs/architecture/accounts.md) |
| Local transcript cost/token reporting, runtime/billing provenance, scan caching, durable limit/reset history and the Usage dashboard | [`usage-dashboard.md`](docs/architecture/usage-dashboard.md) |
| The source-control provider boundary, GitHub pull requests, GitLab merge requests, remote detection, forge capabilities and managed publication safety | [`source-control.md`](docs/architecture/source-control.md) |
| Repository-root `.threading.json`, bounded project-script discovery, active-checkout routing, registry/palette refresh and explicit visible-terminal execution | [`project-scripts.md`](docs/architecture/project-scripts.md) |
| The GitHub credential chain (app connection, `gh`, credential helper), the device-flow sign-in, filing issues from the inspector and Help ▸ Report a Problem, the `network.brokered` extension fetch and its grant rules | [`github.md`](docs/architecture/github.md) |
| The SQLite store, quarantine, `EventLog`/`ThreadingLogger`, composer drafts, the scratchpad's folder, where state lives on disk and the Advanced page's resets | [`persistence.md`](docs/architecture/persistence.md) |
| A launch that did not come back: the marker, the launch ledger and its two-step open, the crash-loop policy, held-back restoration, Recovery Mode and its one-shot launch flags | [`crash-recovery.md`](docs/architecture/crash-recovery.md) |
| Performance spans, main-thread stalls, MetricKit payloads, `sample`/`xctrace`, and the full/full+ sweep | [`performance.md`](docs/architecture/performance.md) |
| Entitlements, the TCC grants and who inherits them, the Privacy settings page, Info.plist usage strings | [`permissions.md`](docs/architecture/permissions.md) |
| Developer ID signing, notarization, `scripts/release.sh`, and the Sparkle automatic-update plan | [`releasing.md`](docs/architecture/releasing.md) |
| Reclaimable build output, the two deletion gates, bundled project composition and Git activity | [`storage-and-stats.md`](docs/architecture/storage-and-stats.md) |
| Persistence/wire failure semantics, dependency direction, strict concurrency, bounded work, CI and release gates | [`reliability-and-type-safety.md`](docs/architecture/reliability-and-type-safety.md) |
| Product-scope classification, application layers, upward dependencies, authoritative registries/projections and architecture health metrics | [`application-structure.md`](docs/architecture/application-structure.md) |
| Application-level XCUITest journeys, recorded provider traffic and deterministic fixture agents | [`ui-scenario-testing.md`](docs/architecture/ui-scenario-testing.md) |
| Any new or materially changed user-facing surface, popover, sidebar/composer/conversation component, or public extension seam | [`CUSTOMIZATION_SURFACE_AUDIT.md`](docs/extensions/CUSTOMIZATION_SURFACE_AUDIT.md) |
| Any UI at all: the component vocabulary, themed controls, tabs, the composer, motion previews | [`design-system.md`](docs/architecture/design-system.md) |
| The three forked packages and the seams that are ours | [`dependencies.md`](docs/architecture/dependencies.md) |

## Design System

### Required AppKit theme boundary

Before changing UI, read and follow [`docs/THEME_BOUNDARY.md`](docs/THEME_BOUNDARY.md). It is
the canonical policy for both humans and agents.

- Feature code never constructs or subclasses an AppKit control or chrome-drawing surface.
- Use `UI/Design/`; if the needed component does not exist, add the boundary there first.
- `UI/Design/` is not exempt: composite components use the lower-level themed components too.
- Structural AppKit types are allowed only when they choose no visible styling.
- System chrome is contained behind a named wrapper and a narrow, documented policy exception.
- Colours come from semantic `Design` roles, and theme colours never become unrecorded layer
  `CGColor`s.
- A view says what it tells the pointer by declaring `PointerClaiming`; `addCursorRect` and
  `NSCursor.…set()` are lint errors outside that seam. Claiming nothing is not claiming the
  arrow — cursor rectangles are a *window's* list, so a view that registers none inherits the
  I-beam of whatever is behind it.
- A new component includes behavior, accessibility, live-theme-switch and rendered-state tests.

`scripts/check_theme_boundaries.sh` is an error-producing build lint. Do not silence it with a
directory exclusion; fix the call site or add the smallest justified exception to
`scripts/config/theme-boundary.json`.

It runs from the **Enforce Repository Boundaries** build phase, together with
`scripts/check_architecture_boundaries.sh` (structural invariants the type checker cannot
express across files, including the provider-capability rule) and, through the theme script's
own chained lines, `scripts/check_mobile_theme_boundaries.py` and
`scripts/check_localization_boundaries.sh`. All therefore fail an ordinary
`xcodebuild`, which is the point: the push gate runs tests only, and this repository has no
remote for it to gate. `scripts/ci.sh` runs the same set for CI and release preflight.

The iPhone app has its own half of the boundary, because SwiftUI fails differently: a `List`
supplies its own row plate and a sheet is a hosting scene that inherits neither the palette nor
the presentation values read from it. Row chrome has one owner
(`Sources/ThreadingMobile/MobileSettingsChrome.swift`) and the theme crosses a presentation
boundary one way (`mobileTheme(_:)`). See
[`docs/IOS_THEMED_DIALOGS.md`](docs/IOS_THEMED_DIALOGS.md).

`Design.swift` holds every measurement, weight and surface colour. Reach for a token rather
than a number — a literal in a view is how the language erodes. The scale is deliberately
small (`Spacing` is 2/4/6/10/12/20/32); a value between two steps is nearly always a mistake.

The vocabulary — flat over bezelled, quiet until relevant, content leads, system colours only,
`.continuous` corners, aligned by ink — the component table, and the bug behind each rule are in
[`docs/architecture/design-system.md`](docs/architecture/design-system.md). **Read it before
building any new UI**: a screen assembled from stock `NSPopUpButton`, `NSBox` and bezelled
buttons will not match anything else in the app, and will fail the build lint.

## Performance Is a Product Requirement

Threading should feel immediate with real working sets, not only with an empty project or a short
conversation. Responsiveness, stable scrolling, bounded memory, and launch time are product
behavior. The person implementing a feature owns those properties from design through
verification; performance is not a cleanup phase after the UI works.

This does not mean speculative micro-optimization. It means naming the scaling contract before
coding and using measurements whenever work may be user-visible or data-dependent. Our usual
workflow is:

1. **State the contract.** Record expected and stress cardinalities, event frequency, the bounded
   unit of rendering, and the interaction that must remain exact (for example a line jump, scroll
   momentum, bottom position, selection, or reconnect). Apply the [Scaling Gate](#scaling-gate)
   whenever data size or callback frequency is not a small fixed constant.
2. **Reproduce the real path deterministically.** Add an opt-in stress fixture that drives the
   production model and presentation code with generated data or a sanitized replay. Preserve the
   shape that made the client slow: many rich rows, one enormous row, rapid updates, deep jumps,
   cold caches, or simultaneous retained surfaces. Add coarse phase spans around actionable
   owners, never per-row instrumentation in a hot loop.
3. **Take a matched baseline.** Measure the isolated action more than once with the same build,
   configuration, fixture, and initial state. Report a median plus tail/max behavior where it
   matters, along with live-view count and footprint when those can grow. Time fixture manufacture,
   process/framework bootstrap, and test-host creation separately from the production operation;
   otherwise a harness cost can masquerade as an app regression. Use Release builds for shipping
   launch conclusions; Debug measurements are useful for iteration but are not a substitute.
4. **Attribute before changing code.** Semantic spans identify the slow product phase; stack
   samples and command-line `xctrace` identify the CPU, layout, allocation, I/O, or concurrency
   owner. Separate background preparation from main-thread mount, mutation, layout, and draw so a
   faster aggregate does not hide a worse interaction.
5. **Fix the owner structurally.** Prefer removing work, moving discovery off-main, caching stable
   results, virtualizing at the repeating unit, preserving stable identities, and coalescing only
   genuinely redundant events. A debounce, spinner, hidden eager subtree, or lower-quality result
   does not make an unbounded operation fast. Do not trade away exact navigation, accessibility,
   scroll momentum, bottom correctness, or fresh data to improve a number.
6. **Run the matched after case and leave a regression boundary.** Re-run the identical fixture,
   record before/after results and the reason in
   [`docs/architecture/performance.md`](docs/architecture/performance.md), and keep the focused
   stress test. Run `scripts/profile_threading.sh full` when shared interaction infrastructure
   changed; reserve `full+` for release or investigation sweeps whose specialist extremes are
   intentionally expensive. Document flat or reverted experiments too, so the next person does
   not repeat them.

The complete self-profiling design, existing workloads, privacy limits, artifact locations, and
CLI-only `sample`/`xctrace` commands are in
[`docs/architecture/performance.md`](docs/architecture/performance.md). Interactive Instruments is
not required.

## Scaling Gate

Apply this before implementing a UI or callback whose cardinality or frequency comes from outside
a small fixed schema: files, transcripts, git changes, sessions, accounts, extensions, processes,
browser data, provider responses, or streamed events. If the bound is uncertain, treat it as
unbounded. Read the full rationale and current audit in
[`docs/architecture/performance.md`](docs/architecture/performance.md#implementation-time-scaling-gate).

- Write down the expected and stress cardinalities, the mutation frequency, and which operations
  must be O(visible), O(changed), or O(1). A protocol/file-size cap is not automatically a safe UI
  bound, and a per-item cap is not an aggregate bound.
- Keep externally sized content as value models. Tables/collections/outlines own only viewport
  views; do not put an unbounded stack or recursive subtree inside one virtual row.
- Collapse, paginate, and cap **before** constructing views, attributed documents, images, or
  constraints. Hiding a subtree after it was built saves pixels, not construction, layout, or
  memory.
- **A cap on output is not a cap on work.** A bound stated in bytes, rows or items *returned* says
  nothing about how much was examined to produce them, and the two diverge exactly when the content
  is sparse. Bound the scan, not just the result.
- A local disclosure, toggle, append, or status change updates the affected stable identities. It
  does not clear and rebuild a whole externally sized page or timeline.
- Layout, resize, scroll, pointer, and stream callbacks do no filesystem/process work and no work
  proportional to total content. Preserve a trackpad gesture's routing through its momentum tail;
  a nested component must not silently consume vertical scrolling.
- Discovery, parsing, filesystem reads, image decoding, and child processes stay off the main
  actor unless a measured, documented bound makes them frame-cheap. Debouncing repeated calls is
  useful only after one call is itself bounded.
- Add an opt-in deterministic stress fixture when the surface can grow or the callback is
  high-frequency. Measure background preparation, main-thread mount/mutation, layout, scroll or
  resize tails, live view count, correctness of exact jumps/bottom position, and footprint as
  applicable.

A small fixed form may still use a retained stack and wholesale rebuild. The review question is
not whether code contains `NSStackView` or `removeFromSuperview`; it is whether externally sized
content or a high-frequency event can reach that path. Cell reuse and controller replacement are
normal lifecycle work, not violations.

## Extension Authoring

Safe extensions are machine-authored, out-of-process executables built against the
Foundation-only `ThreadingExtensionKit`. Before creating or changing one, read
`docs/extensions/AGENT_AUTHORING.md` completely and use
`Packages/ThreadingExtensionKit/Examples/HelloStatusExtension` as the source template. Do not infer the
extension API from application internals, remove `ThreadingExtensionPolicyPlugin`, or import
AppKit/SwiftUI in a safe extension. If the semantic UI model cannot express a requested
interface, report the missing node as an SDK requirement rather than bypassing the host
renderer.

## Code Style Guidelines

**Fix the root cause each time, no band-aids.**

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
Sources/Threading/
├── App/                    # App entry point, AppDelegate
├── Core/
│   ├── Constants/          # Genuinely cross-cutting terminal, window, and shared UI constants
│   ├── Agent/              # AgentLauncher, AgentRuntime, session discovery, GitInfo
│   ├── MCP/                # MCPServer, MCPConnection, MCPSessionRegistry, MCPTools
│   ├── Logging/            # ThreadingLogger (os_log), EventLog (durable journal)
│   └── Session/            # TerminalSession, ProjectStore, StateManager, DraftStore
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

### Test levels

Three levels, one entry point — `scripts/test.sh <level>`. **Run `fast` while iterating and
`all` before you commit or push.** Never run `all` in a loop: it steals focus.

| Level | Command | Covers | Cost |
|---|---|---|---|
| **fast** | `scripts/test.sh` | `Threading-Fast` test plan — the whole `ThreadingTests` target minus the cases that must order a window on screen | default; nothing appears on screen |
| **all** | `scripts/test.sh all` | `Threading-All` test plan — the entire Mac target — then the complete `ThreadingMobileTests` target in an iOS Simulator | adds ~14 live-WKWebView tests that flash real windows and load real pages, plus one simulator run |
| **e2e** | `scripts/test.sh e2e` | `ThreadingNotificationE2E` scheme — real APNs delivery; `--claude` also spawns a real Claude | needs the four `THREADING_APNS_*` credentials; exits 2 without them, so it never fires by accident |

The plans live in `TestPlans/` and are attached to the `Threading` scheme, so Xcode's test-plan
picker offers the same choice. `-only-testing:` still works through the script for a single class.

Connectivity has a focused cross-platform runner outside these three ordinary levels:
`scripts/test-connectivity.sh software|topology|all` runs the Mac contracts plus the matching
subset of `ThreadingMobileTests` in an iOS Simulator. `simulator-chaos` repeatedly terminates the
real iOS app against an isolated real server, while `hardware --device <name-or-UDID>` owns physical
faults and topology. Both process lanes verify recovery from the app's share-safe diagnostic
journal rather than from timed UI observations. Their scope, evidence and the still-unautomated
two-shipping-app chaos lane are documented in
[`docs/CONNECTIVITY_TESTING.md`](docs/CONNECTIVITY_TESTING.md).

**`all` is enforced on push.** `scripts/install_git_hooks.sh` installs the gate; run it once per
clone. `core.hooksPath` points at a shared `~/.git-hooks` whose `pre-commit` already delegates to
an optional `.git/hooks/pre-commit.local`, so the installer teaches `pre-push` the same trick
rather than shadowing the global hooks and having to reimplement Git LFS. The shim under `.git/`
is one line; the logic is `scripts/pre_push.sh`, which is versioned and reviewable. Deletion-only
pushes skip the gate. Bypass deliberately with `THREADING_SKIP_TESTS=1 git push` — prefer it over
`--no-verify`, which also skips Git LFS.

The canonical non-interactive CI/release gate builds `ThreadingMobile` for a generic iOS Simulator
destination and then runs its complete test target through `scripts/test-mobile.sh`. That runner
and the `all` push gate share the host-wide CoreSimulator lock. Override its concrete destination
with `THREADING_MOBILE_TEST_DESTINATION` when the default iPhone simulator is unavailable.
All CI Xcode lanes share a fresh DerivedData directory and ratchet compiler warnings per source
file, with a separate ceiling for diagnostics that become errors in Swift 6 language mode. See the
[shipping contract](docs/architecture/reliability-and-type-safety.md#shipping-contract) before
changing `scripts/swift_warning_baseline.json`.

The same hook runs `scripts/check_secrets.sh` over the range being pushed first, and that half
is **not** covered by `THREADING_SKIP_TESTS`: it costs under a second, and it is the only gate
whose failure cannot be repaired by a later commit, because a credential pushed to a public
remote stays addressable by sha. See
[`reliability-and-type-safety.md`](docs/architecture/reliability-and-type-safety.md#the-secret-scan-is-the-one-gate-that-fails-closed-forever).

**Never run `git push` to try something out.** `submodule.recurse` is true, so a push recurses
into `Packages/Vendor/LabelMorph` and `Packages/Vendor/ThinkingOrbs` and publishes them to their real GitHub
remotes — even when the outer push targets a local throwaway path, and even though the main repo
has no remote configured. To exercise the hook, pipe fabricated ref lines into
`scripts/pre_push.sh` directly. The sole scripted publication exception is
`scripts/publish_local_release.sh`: it names the tested commit's outer `master` and one annotated
tag as explicit refspecs and disables recursion in both configuration and the push option. Do not generalize its
push primitive into a convenience command. Before either ref moves it runs both `scripts/test.sh
all` and `scripts/ci.sh`, then proves the clean checkout still points at the commit those gates
tested; the locally invoked publisher skips only that duplicate quality-gate run.

**Fast is defined by "orders a window on screen", not by "is UI".** Almost every UI test here —
all the `*RenderTests`, the themed component tests, the pane header/footer tests — builds an
*unshown* window and `cacheDisplay`s it, which draws nothing on screen and stays in `fast`. Only
the following cases genuinely need to be visible, and they are skipped by name in
`Threading-Fast.xctestplan`:

- `BrowserAgentBridgeIntegrationTests` (the whole class) — WKWebView will not load or render
  offscreen, so each test calls `orderFront`. Note the sibling class in the same file,
  `BrowserAgentBridgeTests`, needs no window and stays in `fast`.
- `BrowserOffScreenCaptureTests` (the whole class) — measures what an agent can still capture
  from a browser whose window is miniaturized, moved off the visible frame, or fully occluded,
  which needs a real window ordered on screen to *stop* being visible in each of those ways. It
  is a platform tripwire rather than a behaviour test: `browser_screenshot` and the remote
  workspace preview both go through `WKSnapshotConfiguration.afterScreenUpdates = true`, and
  the detached-browser-window work rests on that still returning pixels. Today it does in all
  three conditions; the class exists so a macOS update changing that is a failing test rather
  than an agent quietly reading blank pages.
- `BrowserCaptureGeometryTests` (the whole class) — the same platform question asked of a
  window's geometry rather than its capture, and it needs the window server to answer for the
  same reason.
- `SidebarRevealFocusTests` (the whole class) — proves that revealing the native sidebar moves
  keyboard ownership into its selected row. AppKit exposes no key window while the test host is
  inactive, so the fixture must activate the host and order its main window or key panel on
  screen; an unshown-window responder assertion would not prove where keystrokes go.
- `ThemedControlTests/testPromptCanTakeFocusAndShowsItOnTheWholeSurface()` and
  `testOnScreenTextFieldContainsOnlyItsNamedPrivateEditorBoundary()` — both assert on first
  responder, which requires a key window.
- `ThemedPresentationTests/testPopoverEscapeClosesOnceAndReturnsFocus()`,
  `testAlertEscapeEndsTheSheetAndReturnsFocus()`,
  `testAlertDismissEndsTheSheetWithoutAButtonAnswer()` and
  `testPopoverWithAnInitialResponderTakesKeyStatusAndGivesItBack()` — the four that share
  `testWindow()`, a titled 420×260 fixture at (120,120) with `makeKeyAndOrderFront`. They
  present a real popover panel and real sheets and assert who holds the keyboard afterwards,
  which is AppKit's presentation machinery rather than ours. They were flashing a window three
  times per `fast` run, which is the lane an agent re-runs all day; they still run in `all`, so
  the push gate is unchanged.

**Adding a test that needs a real window?** Add it to `skippedTests` in
`TestPlans/Threading-Fast.xctestplan` and say why here. Anything that can be asserted against an
unshown window belongs in `fast` — reach for `orderFront` only when the framework forces it.

**A window can be ordered on screen and still be invisible, but only if it is borderless.**
`GitReviewRenderTests` and `ExecutionAuditRenderTests` park their fixture at
`NSPoint(x: -10_000, y: -10_000)` before `orderFront`, so WebKit and Core Animation treat it as a
real window while nothing appears on any display. That works because both are `.borderless`: a
`.titled` window is pulled back by `NSWindow.constrainFrameRect(_:to:)`, and a probe of this
machine put one asking for (-10,000, -10,000) at (0,0) instead — on screen, top left, exactly
where you would notice it. Overriding `constrainFrameRect(_:to:)` to return the proposed rect
keeps a titled window parked. So a fixture that needs a real window does not automatically need a
*visible* one: check whether it can be borderless or unconstrained first, and skip it from `fast`
only when it genuinely has to be somewhere a person could see.

**Parking answers "is this drawn", not "where do the keystrokes go" — and neither does ordering
front.** The trick above buys a real window for rendering and for WebKit; it does not buy key
status, because the window server does not hand the keyboard to a window sitting on no display.
`ThemedPresentationTests/testPopoverWithAnInitialResponderTakesKeyStatusAndGivesItBack()` was
tried on exactly that fixture — titled, `constrainFrameRect(_:to:)` overridden, parked at
(-10,000, -10,000), `makeKeyAndOrderFront` — and came up with `isKeyWindow` false.

Moving it to the visible `testWindow()` did not fix it either, and the reason is one level up:
**`NSApp.keyWindow` is `nil` for the whole of an inactive application.** A suite started by
`scripts/test.sh` runs with the terminal frontmost, and since macOS 14 `activate(ignoringOtherApps:)`
cannot take the front from an app that has not yielded it — so no window in the host holds key,
`makeKeyAndOrderFront` merely records the intent, and every key-status assertion fails while the
code under test is working. Diagnosing this by adding assertions for `NSApp.isActive` and
`NSApp.keyWindow` beside the failing one took a minute and saved changing the popover.

So a test that asserts `isKeyWindow` belongs in the skip list above **and** has to ask for the
front itself. `activateHost()` in that file does it, and `XCTSkipUnless`es when the front does not
come, so a run that structurally cannot observe focus says so instead of blaming the component.
Expect that test to report as skipped in an ordinary command-line `all` run; it verifies for real
when the host is frontmost.

**A fast fixture window is built, never shown, and has bounded ownership.** An unshown window still
lays out, draws through `cacheDisplay`, and takes a first responder, which is everything these
tests need. `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false` in a
hosted XCTest process, but that does not make `close()` a universal teardown: AppKit can retain
private autoreleased tracking, animation, or view state until XCTest drains the current case, and
closing the window in that same pool is a reproducible `objc_release` crash. A local unshown
fixture may simply leave scope; a shown fixture is ordered out first. If a controller or other
owner retains repeated fixtures, it must either close them at a component-defined safe point or
reuse a bounded host. The Motion menu tests take the latter path: they dismiss menu tracking
synchronously and reuse one unshown window with fresh per-test controllers. Never solve a
lifetime race by accumulating one ordered-out window per test, and never mechanically replace
`orderOut` with `close` without a lifecycle-sequence test.

**A hosted test writes to the developer's own preferences.** The bundle is hosted in the app, so
`UserDefaults.standard` inside a test is the real app's `UserDefaults` — a test that records a
choice there changes what the app the developer is running launches into next. This shipped as
"the theme selection doesn't persist between app launches": three test classes apply a theme in
`setUp` and one put it back, so the last test to run decided. Anything that stores a **user's
choice** goes through `PreferenceStore`, which redirects to a scratch suite under a test bundle;
behavioural settings stay on `.standard` because tests set those deliberately and assert the app
read them. See [`themes.md`](docs/architecture/themes.md) for the line between the two.

**A hosted test also wrote to the developer's own projects and chats, and deleted them.** The
same hosting that hands a test `UserDefaults.standard` handed it `StateManager.shared`, so
`ProjectStore.shared` in a test opened the real `threading.db`. `ProjectDatabase.save(_:)`
reconciles the whole graph — `DELETE FROM project WHERE id NOT IN (…)`, with sessions following
through `ON DELETE CASCADE` — and the test host never reaches `SingleInstanceLock`, because
`applicationDidFinishLaunching` returns on `NSClassFromString("XCTestCase")` first. So a fixture's
`addProject` wrote the test's project list over the user's, deleting every project added since
that test process loaded. Real projects and their chats were lost this way; fixture rows for
`/var/folders/…/T/sound-scope-…` were still sitting in the live database afterwards.
`StateManager` now redirects to a per-pid scratch directory under a test bundle, the reconcile
refuses when the store's generation has moved beneath it, and **a test that touches
`ProjectStore.shared` inherits `HostedStoreTestCase`**, which proves the redirect still holds and
erases the scratch store in teardown. See [`persistence.md`](docs/architecture/persistence.md).

**A component tested outside the container it ships in can pass while being unusable.** A sidebar
row's buttons were asserted on a row held in a plain `NSView`, so two rounds of fixes landed
against a button that no click could reach in the app — `NSOutlineView` was swallowing it (see
[`design-system.md`](docs/architecture/design-system.md)). When a component's behaviour depends on
its host, put the host in the fixture, and assert the host's own answer beside ours.

**Focus is not `makeFirstResponder`'s return value.** On a window that is merely visible rather
than key, `makeFirstResponder` returns `true`, installs the field editor, and leaves
`currentEditor()` non-nil — while every keystroke goes on reaching the key window somewhere else.
So the assertions anyone would reach for all pass on a surface that cannot be typed into, which is
how ⌘J's file search shipped with a search field the keyboard never reached. A test about focus
asserts `isKeyWindow` (or `NSApp.keyWindow`) beside the responder. A borderless
`.nonactivatingPanel` can hold key status while the host application is inactive, so this needs no
window on screen and no activation — it stays in `fast`.

**A detached fixture with a frame constrains nothing.** `NSView(frame:)` outside a window pins no
width, so Auto Layout lays the subtree out at the width it would *prefer* and a child may come out
wider than the view holding it — with no "unable to simultaneously satisfy" to say so, because
nothing was violated. Two tests measured a control row that way and reported it overflowing a pane
it had never been asked to fit; the compression they were accusing it of skipping worked the whole
time, and one of them had been passing on a fixture that proved nothing. A fixture standing in for
a pane states its size the way a split view does — `widthAnchor`/`heightAnchor` constraints — and
insets its content, since a control aligned by ink reaches past the margin its glyph sits on.

**Rendered-state tests are how appearance is reviewed here.** `ConversationRenderTests`,
`GitReviewRenderTests`, `ThemeSettingsRenderTests`, `CodeStatsRenderTests`,
`ToolbarChromeRenderTests`, `AccountLimitsSectionTests/testRendersTheLimitsSectionToImages`,
`CustomLimitShowTests/testRendersTheCappedBarToImages` and
`SessionAttachmentComparisonTests/testRendersTheDropAffordance`
draw real fixtures to PNGs, light and dark (`THREADING_RENDER_OUT` redirects the output). Several
bugs in this codebase were visible in a picture and in no assertion anyone would have written —
including a drop affordance whose every assertion passed while it drew a saturated plate over the
row it was naming, louder than the window's own selection, and a settings section whose cards sat
at a third of the pane while every assertion about its width passed, because a vertical
`NSStackView` aligned `.leading` gives each arranged view its *fitting* width. **What a render
finds becomes an assertion**: both are now tested for directly, so the picture is where a defect
is *noticed* rather than where it is remembered.

## Documentation

### `docs/architecture/`

One file per subsystem — see [Subsystems](#subsystems). **When a decision in one of those areas
changes, update its file rather than this one**; CLAUDE.md keeps only what is true across the
whole project. A new subsystem earns a new file plus one row in the table.

### `docs/decisions/` and `docs/feature-drafts/`

Two parking places, told apart by whether somebody intends to build the thing.
[`docs/feature-drafts/`](docs/feature-drafts/README.md) holds researched proposals awaiting
implementation. [`docs/decisions/`](docs/decisions/README.md) holds ideas investigated to a
**recommendation** — build now, prototype, wait for demand, or reject — each with the evidence that
should reopen it. **Before proposing a feature, check whether it already has a record**: five
deferred ideas from the t3code research are answered there, three of them because Threading already
has the machinery. Neither directory is a second source of truth; when an approved slice ships, its
durable decisions move into `docs/architecture/` and a pointer stays behind.

### IMPROVEMENTS.md

The short active architecture-health ledger. It contains only current structural debt and points
to the measurement command and closing rules. Completed reviews live under `docs/archive/reviews`;
their findings are evidence, not current instructions. Load-bearing rules such as persistence
quarantine, actor isolation, and typed IDs live in the owning `docs/architecture` file.

### Agent-guidance feedback

Run `scripts/audit_agent_feedback.py` when deciding whether past Claude/Codex behavior justifies
new guidance. It writes a private, ignored report under `.build/agent-feedback/`. Promote only
repeated, future-actionable behavior: cross-cutting rules belong here, subsystem rules belong in
their owning architecture document, and enforceable rules should become code, tests or gates.
Never commit transcript excerpts or add historical change narration to agent guidance.

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
