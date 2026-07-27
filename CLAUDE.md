# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**This file is an index.** The reasoning behind each subsystem — what was measured, what was
wrong first, and which rules are load-bearing — lives in `docs/architecture/`. Those notes are
not recoverable from the code, so **read the relevant file before changing a subsystem**; the
table under [Subsystems](#subsystems) says which one.

## Project Overview

Skalman is a native macOS app for organizing coding-agent sessions, built with **Swift** and **AppKit**, using **SwiftTerm** for terminal emulation. Targets **macOS 13+**.

A single window pairs a project sidebar with the selected session's terminal. Each session
hosts a Claude Code or Codex process inside a project folder, with a shell available under it
on demand. Sessions outlive their
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

**`Tests/SkalmanTests` is *not* a synchronized folder** — a new test file must be registered
in `project.pbxproj` by hand (PBXFileReference, PBXBuildFile, the Tests group, and the test
target's Sources phase; follow the `A1000000…1`/`…2` id convention already there). The failure
mode is silent: an unregistered test file builds nothing and `xcodebuild test` reports
"Executed 0 tests" for it. `scripts/add_test_file.py` does the four edits.

## Dependencies

Three local Swift packages, each a git submodule referenced as an `XCLocalSwiftPackageReference`.
**All three are our forks — modify their source directly** rather than working around them.

| | Location / upstream | What it draws |
|---|---|---|
| **SwiftTerm** | `./SwiftTerm/` — [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal emulation: VT100/xterm, ANSI parsing, PTY. The iOS folder is excluded on macOS builds. |
| **ThinkingOrbs** | `./ThinkingOrbs/` — [everlof/thinking-orbs-swift](https://github.com/everlof/thinking-orbs-swift) | The dotted "working" orb beside the conversation status. AppKit `ThinkingOrbView` only; the app stays AppKit-only. |
| **LabelMorph** | `./LabelMorph/` — [everlof/LabelMorph](https://github.com/everlof/LabelMorph) | The label that morphs a name character by character — every session, project and checkout name. |

Each has a seam that is ours (ThinkingOrbs' `tint`, LabelMorph's truncation) plus the theme
wrapper that drives it: see [`docs/architecture/dependencies.md`](docs/architecture/dependencies.md).

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
- **AgentRuntime**: Caches live `AgentSessionViewController`s keyed by session id. A session
  with no entry is dormant.
- **AgentLauncher**: Builds the command line for a fresh launch vs. a resume, including
  account routing.
- **CodexSessionDiscovery**: Recovers the session id Codex assigns itself after launch.
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
`PATH`, and the agent CLIs live in `~/.local/bin` or a Node prefix. Claude accepts
`--session-id <uuid>`, so its id is minted up front; Codex has no equivalent, so its id is read
back from the rollout it writes (or, better, reported by its `SessionStart` hook).

## Subsystems

Each file states the decisions and the measurements behind one area. Read the one you are about
to change — most of these rules were arrived at by getting the obvious thing wrong first.

| Read before you touch | File |
|---|---|
| The toolbar, the pane header strips, the sidebar's silhouette, split-item behaviour, anything pinning to `topAnchor` | [`window-chrome.md`](docs/architecture/window-chrome.md) |
| The MCP server, tool routing by session token, launch flags, the display panel and its web view | [`mcp-and-display.md`](docs/architecture/mcp-and-display.md) |
| The live browser an agent drives: origin grants, the accessibility snapshot, refs and semantic locators, the browser tools | [`agent-browser.md`](docs/architecture/agent-browser.md) |
| Natively rendered conversations: the Claude/Codex stream transports, permission brokering, transcript replay, the timeline model, tool rows, diffs, the turn rail | [`native-conversations.md`](docs/architecture/native-conversations.md) |
| Session state (`dormant`/`idle`/`working`/`needsAttention`), lifecycle hooks for both CLIs, `hooks.json`, the shell-command policy | [`session-activity.md`](docs/architecture/session-activity.md) |
| Reading git metadata (worktrees, submodules, identities), the Git Review pane, staging, the commit graph, diff syntax highlighting | [`git.md`](docs/architecture/git.md) |
| Side chats and forking, the shell drawer, session naming, launching, resuming, importing outside conversations | [`sessions.md`](docs/architecture/sessions.md) |
| Terminal themes, app themes, the three assignment scopes, the MCP theme tools, glow and clipping | [`themes.md`](docs/architecture/themes.md) |
| Agent marks, account chips, project icons, icon discovery and research | [`icons.md`](docs/architecture/icons.md) |
| Multiple logins per CLI, discovery and naming, migrating a conversation between accounts, usage readings | [`accounts.md`](docs/architecture/accounts.md) |
| The SQLite store, quarantine, `EventLog`/`SkalmanLogger`, composer drafts | [`persistence.md`](docs/architecture/persistence.md) |
| Reclaimable build output, the two deletion gates, `scc` code stats | [`storage-and-stats.md`](docs/architecture/storage-and-stats.md) |
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
- A new component includes behavior, accessibility, live-theme-switch and rendered-state tests.

`scripts/check_theme_boundaries.sh` is an error-producing build lint. Do not silence it with a
directory exclusion; fix the call site or add the smallest justified exception to
`config/theme-boundary.json`.

`Design.swift` holds every measurement, weight and surface colour. Reach for a token rather
than a number — a literal in a view is how the language erodes. The scale is deliberately
small (`Spacing` is 2/4/6/10/12/20/32); a value between two steps is nearly always a mistake.

The vocabulary — flat over bezelled, quiet until relevant, content leads, system colours only,
`.continuous` corners, aligned by ink — the component table, and the bug behind each rule are in
[`docs/architecture/design-system.md`](docs/architecture/design-system.md). **Read it before
building any new UI**: a screen assembled from stock `NSPopUpButton`, `NSBox` and bezelled
buttons will not match anything else in the app, and will fail the build lint.

## Extension Authoring

Safe extensions are machine-authored, out-of-process executables built against the
Foundation-only `SkalmanExtensionKit`. Before creating or changing one, read
`docs/extensions/AGENT_AUTHORING.md` completely and use
`SkalmanExtensionKit/Examples/HelloStatusExtension` as the source template. Do not infer the
extension API from application internals, remove `SkalmanExtensionPolicyPlugin`, or import
AppKit/SwiftUI in a safe extension. If the semantic UI model cannot express a requested
interface, report the missing node as an SDK requirement rather than bypassing the host
renderer.

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
│   ├── Logging/            # SkalmanLogger (os_log), EventLog (durable journal)
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

**A fixture window is built, never shown.** `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`
is `true`, which is right for the app and a trap for the test host: a window ordered on screen
and then released queues that decision, and AppKit acts on it the next time *anything* spins the
run loop. The host then exits cleanly inside a later, unrelated test — no crash report, no failing
assertion, and `xcodebuild` reporting "unexpected exit" against whichever test happened to pump.
Found by a menu test that ran the run loop for a second, which made a latent version of this
land in `SessionImportBelongingTests`. An unshown window still lays out, still draws through
`cacheDisplay`, and still takes a first responder, which is everything these tests need.

**Rendered-state tests are how appearance is reviewed here.** `ConversationRenderTests`,
`GitReviewRenderTests`, `ThemeSettingsRenderTests`, `CodeStatsRenderTests` and
`ToolbarChromeRenderTests` draw real fixtures to PNGs, light and dark (`SKALMAN_RENDER_OUT`
redirects the output). Several bugs in this codebase were visible in a picture and in no
assertion anyone would have written.

## Documentation

### `docs/architecture/`

One file per subsystem — see [Subsystems](#subsystems). **When a decision in one of those areas
changes, update its file rather than this one**; CLAUDE.md keeps only what is true across the
whole project. A new subsystem earns a new file plus one row in the table.

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
