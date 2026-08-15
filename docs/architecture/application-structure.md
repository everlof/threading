# Application structure

Most Threading code still compiles in one application target, so directories alone do not enforce
dependency direction. The compiler-isolated `ThreadingDomain` package is the stable identity
kernel; architecture checks ratchet the remaining legacy edges while application capabilities are
extracted one ownership boundary at a time.

The completed stabilization measurements and rationale are preserved in
[`docs/archive/reviews/ARCHITECTURE_STABILIZATION-2026-08-15.md`](../archive/reviews/ARCHITECTURE_STABILIZATION-2026-08-15.md).
Current structural debt lives in the short root [`IMPROVEMENTS.md`](../../IMPROVEMENTS.md). Refresh
its counts with `scripts/report_architecture_health.py` rather than hand-counting with a different
definition.

## Product boundary

Architecture work preserves every current surface. Experimental and beta labels describe support
expectations; they are not permission to remove a surface.

| Classification | Current surfaces | Architectural treatment |
|---|---|---|
| Product kernel | Projects and checkouts; durable sessions; terminal sessions and standalone project terminals; launch, resume, archive and recovery; sidebar/navigation; accounts and provider capabilities; attention, notifications and limits; persistence | Domain policy and durable records flow inward. AppKit owns composition only. These surfaces cannot depend on an experimental presentation. |
| Experimental | Native chat conversations, side chats and subagent presentation; remote access and the iPhone/browser companion | Keep explicit capability and transport seams. An experiment may depend on the kernel; the kernel must not depend on its controllers or views. |
| Product extensions | Display panel, browser automation, execution audit, attachments and media, Git review, managed workspaces, scheduled work, MCP tools, safe extensions, themes and customization | Treat each as an application capability with one owner and bounded inputs. Cross-surface access goes through typed capabilities, not controller lookup. |
| Support infrastructure | Settings and command discovery; onboarding; diagnostics, event logging and support reports; crash recovery; updates and release tooling; component gallery; UI evidence and fixtures | May observe product state through projections. It does not become a second source of truth for product records or policy. |
| Candidate to park or remove | None approved | File size, age, beta status, or low visibility is not sufficient evidence. Removal needs a separate product decision. |

## Dependency direction

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
contracts remain in the Foundation-only `ThreadingRemoteKit` and `ThreadingExtensionKit` packages
rather than being copied into the application layer.

`ThreadingDomain` owns typed project, session, terminal, transcript, and account identities plus
their storage-safe encoding behavior. Its package has no dependencies. The same directory-wide
`scripts/check_module_boundaries.py` rule rejects every Domain import except Foundation and every
Application import except Foundation plus the explicitly approved lower-level contract modules.
The app target exposes migration aliases so contracts can move without a repository-wide
mechanical rewrite.

The application target currently approximates the other layers:

| Location | Authority |
|---|---|
| `Models/` | Provider capabilities and persisted records. Provider, session, workspace, project, and persisted-UI records have separate files; AppKit-bearing theme/profile values remain migration debt. |
| `Core/Session`, `Core/Project`, `Core/Settings`, `Core/Logging` | Legacy persistence and application state. Stores and policies still share directories while injection advances boundary by boundary. |
| `Core/Agent`, `Core/AI`, `Core/MCP`, `Core/Remote`, `Core/Extensions` | Runtime and transport. Core/Remote reaches session lifecycle only through injected `RemoteSessionCommands`; built-in MCP representation comes from one typed descriptor registry. |
| `Application/` | Foundation-only use cases and policies extracted from UI adapters, including browser, session, extension-authoring, remote-session, and window-navigation capabilities. |
| `App/` | Process composition. `AppEnvironment` owns the legacy store/service instances passed into migrated coordinators. |
| `UI/` | AppKit composition and presentation. Feature UI uses `UI/Design`; tool and browser controllers adapt application capabilities to windows and WebKit. |

## Remaining upward dependencies

The architecture gate rejects every Core reference to `AppDelegate` or `MainWindowController` and
permits only the ratcheted concrete-controller edges reported by
`scripts/check_dependency_boundaries.py`:

- `Core/Agent/AgentRuntime.swift` constructs and retains agent-session and conversation view
  controllers.
- `Core/Agent/LimitRecoveryCoordinator.swift` accepts concrete agent-session controllers.
- `Core/Agent/SessionContextHandoff.swift` stores a conversation-controller case.
- `Core/Remote/RemoteSessionMirrorRegistry.swift` accepts a conversation controller while adapting
  its live projection.
- `Core/Session/ProjectTerminalRuntime.swift` constructs and retains a project-terminal controller.

These are a migration queue, not exemptions. Remove one complete ownership edge, add a focused
capability/projection test, and lower the ratchet in the same coherent commit.

## Composition and identity rules

- `AppDelegate` constructs `AppEnvironment`; `MainWindowController` passes it into application
  coordinators. A leaf must not add a new `.shared` lookup for an application-owned service.
- A conversation retains `SessionID` and consumes an injected current-session projection. Durable
  records are values and must not be retained as a substitute for current store state.
- Main-window and tool coordinators keep composition, routing, and presentation. Command policy,
  sequencing, destructive confirmation state, and stale-callback refusal belong in independently
  tested application services.
- Splitting an extension file is not decomposition unless dependencies and authority shrink.
- `Tests/ThreadingTests` is a filesystem-synchronized Xcode group. Add a Swift file below that
  directory; never add per-file project references or Sources-phase entries.

## Authoritative inventories

Inventories are projections of code-owned registries, not Markdown lists updated in parallel.

| Inventory | Source of truth | Projections and proof |
|---|---|---|
| Built-in MCP tools | `MCPBuiltInToolRegistry.descriptors` | MCP `tools/list`, Tools settings, scoped catalogs, and routing derive from descriptors; `MCPWireTests` enforces identity/decoder/schema/annotation/group/binding parity. |
| Settings | `AppSettingDefinitions.all`, projected through `SettingsPages.all`, plus the extension settings registry | Each built-in definition owns its stable identity, current or migration persistence key and value shape, absence/default semantics, validation, notification policy, page/row/search metadata, and remote policy. `AppSettings`, navigation, both search paths, and `list_settings` project from it; definition completeness and anchor-resolution tests prove key, order, and row parity. |
| Commands and shortcuts | `AppCommands.all`, then `CommandRegistry` for extensions, project scripts, and overrides | Menus, Keyboard settings, the command palette, and host command plane consume registry descriptors; shortcut and command-policy tests enumerate them. |
| Public extension components | `ThreadingComponentCatalog.document` | `ThreadingComponentCatalogGenerator` writes committed Markdown, JSON, and schemas under `docs/extensions/generated`; CI runs it with `--check`. |

Add metadata to the owning registry and extend its completeness test. Do not create a second
hand-maintained tool, settings, shortcut, or component inventory.
