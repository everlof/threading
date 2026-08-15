# Application structure and health

Threading is still one application target, so directory names alone do not enforce dependency
direction. This document names the current product boundary, the intended direction of knowledge,
and the small health ledger used to tell whether structural work has reduced change amplification.
Run `scripts/report_architecture_health.py` to refresh the measurements; do not hand-count a new
baseline with a different definition.

## Product-scope matrix

Architecture work preserves every current surface. Experimental and beta labels describe support
expectations; they are not permission to remove a surface.

| Classification | Current surfaces | Architectural treatment |
|---|---|---|
| Product kernel | Projects and checkouts; durable sessions; terminal sessions and standalone project terminals; launch, resume, archive and recovery; sidebar/navigation; accounts and provider capabilities; attention, notifications and limits; persistence | Domain policy and durable records flow inward. AppKit owns composition only. These surfaces cannot depend on an experimental presentation. |
| Experimental | Native chat conversations, side chats and subagent presentation (documented as experimental); remote access and the iPhone/browser companion (documented as beta) | Keep explicit capability and transport seams. An experiment may depend on the kernel; the kernel must not depend on its controllers or views. |
| Product extensions | Display panel, browser automation, execution audit, attachments and media, Git review, managed workspaces, scheduled work, MCP tools, safe extensions, themes and customization | Treat each as an application capability with one owner and bounded inputs. Cross-surface access goes through typed capabilities, not controller lookup. |
| Support infrastructure | Settings and command discovery; onboarding; diagnostics, event logging and support reports; crash recovery; updates and release tooling; component gallery; UI evidence and test fixtures | May observe product state through projections. It does not become a second source of truth for product records or policy. |
| Candidate to park or remove | None approved | File size, age, beta status, or low visibility is not sufficient evidence. Any future candidate needs a separate product decision before code or documentation is deleted. |

## Dependency direction

The intended dependency graph is deliberately small:

```text
ThreadingDomain       Foundation-only IDs, records, capabilities, outcomes
        ↓
ThreadingPersistence  databases, migrations, recoverable durable stores
        ↓
ThreadingRuntime      agent processes, transcripts, session runtime
        ↓
ThreadingApplication  use cases, policies, coordinators
        ↓
ThreadingUI           AppKit composition and Design components
```

Composition roots may construct a higher layer from lower-layer implementations. A lower layer
never locates an application delegate, window, or concrete view controller. Cross-cutting wire
contracts remain in the existing Foundation-only `ThreadingRemoteKit` and
`ThreadingExtensionKit` packages rather than being copied into an application layer.

The current source tree only approximates these responsibilities:

| Current location | Predominant responsibility | Known mixing to unwind |
|---|---|---|
| `Models/` | IDs, provider capability policy, persisted records, UI documents | `Project.swift` combines several domain authorities; terminal theme/profile values import AppKit. |
| `Core/Session`, `Core/Project`, `Core/Settings`, `Core/Logging` | Persistence and application state | Stores, notifications, AppKit adapters, schedulers and policies share directories; leaf code frequently locates `.shared`. |
| `Core/Agent`, `Core/AI`, `Core/MCP`, `Core/Remote`, `Core/Extensions` | Runtime, transport and application use cases | Runtime caches own view controllers; remote routing reaches the app composition root; MCP declarations are split across identity, catalog and schema owners. |
| `App/` | Process and application composition | `AppDelegate` is both composition root and a session/window command relay. |
| `UI/` | AppKit composition, presentation and the Design boundary | Large controllers also own application commands and runtime policy. Extension files reduce navigation cost without reducing authority. |

## Current upward dependencies

The inventory reports executable references, excluding comments. At the 15 August 2026 baseline:

- `Core/Remote/RemoteAccessServer.swift` calls `AppDelegate.shared` four times for resume, create,
  archive/pin refresh, and surface refresh.
- `Core/Agent/AgentRuntime.swift` constructs and retains `AgentSessionViewController` and
  `ConversationViewController`.
- `Core/Agent/LimitRecoveryCoordinator.swift` accepts concrete `AgentSessionViewController`
  values in five paths.
- `Core/Agent/SessionContextHandoff.swift` stores a `ConversationViewController` case.
- `Core/Remote/RemoteSessionMirrorRegistry.swift` accepts a `ConversationViewController` when
  building its live projection.
- `Core/Session/ProjectTerminalRuntime.swift` constructs and retains
  `ProjectTerminalViewController`.

These edges are the measured migration queue, not exemptions. The first enforced slice is the
remote server's dependency on `AppDelegate`; runtime/controller ownership follows behind an
application capability or projection boundary.

## Health ledger

Baseline from commit `01da0d8f` on 15 August 2026, with a clean worktree:

| Metric | Baseline | Desired movement |
|---|---:|---|
| Threading Swift files / lines | 749 / 322,134 | Informational; smaller is not itself a goal. |
| `static … shared` declarations | 87 | Down as application-owned services enter the composition root. |
| `ProjectStore.shared` | 345 references across 68 files | Down one ownership boundary at a time. |
| `AppDelegate.shared` in Core | 4 references in one file | Zero, enforced by the architecture gate. |
| Concrete UI-controller references in Core | 19 references across 5 files | Zero as runtime and projections stop owning presentation. |
| UI-framework imports in Core/Models | 63 imports across 61 files | Down as stable contracts move into compiler-enforced modules. |
| `MainWindowController` authority | 5,081 lines across 4 files | Composition, navigation and window lifecycle only. |
| `AgentToolCoordinator` authority | 9,558 lines across 15 files | Browser, extension, storage and session use cases move to application services. |
| `AgentToolCoordinator+…` capability extensions | 6,130 lines across 11 files | Down with authority, not by renaming files. |
| `Tests/ThreadingTests` Swift files | 357 manually registered files | Filesystem synchronized; zero per-file project registrations. |

Every structural milestone records the same metrics here. Counts may rise temporarily when an
explicit seam replaces implicit coupling; the report must explain the authority that moved and
the gate or test that prevents regression.
