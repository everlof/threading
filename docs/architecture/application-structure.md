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
| `Application/` | Foundation-only use cases and policies extracted from UI adapters, including browser, session, extension-authoring, remote-session, window-navigation, and settings-catalogue capabilities. |
| `App/` | Process composition. `AppEnvironment` owns the legacy store/service instances passed into migrated coordinators. |
| `UI/` | AppKit composition and presentation. Feature UI uses `UI/Design`; tool and browser controllers adapt application capabilities to windows and WebKit. |

## Remaining upward dependencies

The architecture gate rejects every Core reference to `AppDelegate` or `MainWindowController` and
permits only the ratcheted concrete-controller edges reported by
`scripts/check_dependency_boundaries.py`:

- `Core/Agent/AgentRuntime.swift` constructs and retains agent-session and conversation view
  controllers.
- `Core/Agent/LimitRecoveryCoordinator.swift` accepts concrete agent-session controllers.
- `Core/Session/ProjectTerminalRuntime.swift` constructs and retains a project-terminal controller.

Session-context routing is no longer in this queue: Core targets the typed
`SessionContextReceiving` capability and resolves it through `SessionContextDestinationQuerying`;
the UI controller is only an adapter. Remote conversation mirroring now follows the same rule:
`RemoteConversationSurface` owns the Foundation-only projection/submission contract and
`ConversationViewController` adapts it, so Core/Remote never receives the controller. The ratchet
now permits 17 references across the three files above, down from 19 across five.

These are a migration queue, not exemptions. Remove one complete ownership edge, add a focused
capability/projection test, and lower the ratchet in the same coherent commit.

## Composition and identity rules

- `AppDelegate` is the only approved source composition root for `AppEnvironment.live`;
  `MainWindowController` and feature controllers require an injected environment or narrower
  capability and never recover a live environment. Main-window tests deliberately consume the
  hosted process's redirected shared store/runtime/settings graph; their composition helper exists
  only on `HostedStoreTestCase`, which makes the store redirect and teardown a compile-time
  prerequisite for every caller. Their UUID-scoped `EventLog` directory has a fixture owner that
  releases the controller and environment before removing it. The architecture gate rejects
  `.live` construction anywhere else and rejects moving that helper back onto `XCTestCase`. A leaf
  must not add a new `.shared` lookup for an application-owned service.
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
| Built-in MCP tools | `MCPTools.authoredDeclarations`; `MCPBuiltInToolRegistry.descriptors` is its fail-closed admitted projection | MCP `tools/list`, Tools settings, scoped catalogs, decoding, and typed execution routing derive from declarations; `MCPWireTests` enforces identity/decoder/schema/annotation/group/binding parity and rejects incomplete declarations. |
| Settings | Closed `AppSettingIdentity` cases and typed `AppSettingDescriptor<Value>` declarations; `AppSettingDefinitions.all` is their type-erased catalogue projection, then `SettingsPages.all` adds page structure and the extension settings registry | Each descriptor owns stable persistence identity, Swift value type and encoding, absence/default semantics, validation/normalization, notification policy, and remote policy. `AppSettings` and authenticated owner mutation use typed descriptors; navigation, both search paths, migrations, audits, and `list_settings` use the one type-erased projection. Completeness, compatibility, production-validation, authorization, and anchor-resolution tests prevent drift. |
| Commands and shortcuts | `AppCommands.all`, then `CommandRegistry` for extensions, project scripts, and overrides | Menus, Keyboard settings, the command palette, and host command plane consume registry descriptors; shortcut and command-policy tests enumerate them. |
| Public extension components | `ThreadingComponentCatalog.document` | `ThreadingComponentCatalogGenerator` writes committed Markdown, JSON, and schemas under `docs/extensions/generated`; CI runs it with `--check`. |

Add metadata to the owning registry and extend its completeness test. Do not create a second
hand-maintained tool, settings, shortcut, or component inventory.

## Current stabilization increment

These measurements are the output of `scripts/report_architecture_health.py` against the truthful
pre-change `HEAD` tree and the current source tree. The settings-catalogue command family moved
from `AgentToolCoordinator` into the Foundation-only `SettingsCatalogueService`; the UI adapter
now only maps and routes. `RemoteAccessCoordinator` also receives `AppSettings` explicitly and
authorizes mutations from descriptor `remotePolicy`. The remote conversation mirror consumes the
typed `RemoteConversationSurface` rather than a view controller. The architecture gate ratchets
these moved ownership edges and the sole `AppEnvironment.live` composition root.

| Metric | Before | Current | Change |
|---|---:|---:|---:|
| Threading Swift files / lines | 793 / 328,643 | 795 / 329,431 | +2 service/capability files / +788 net typed contracts, wiring, fixtures, and proofs |
| `ThreadingDomain` Swift files / lines | 1 / 197 | 1 / 197 | unchanged |
| `static … shared` declarations | 89 / 87 files | 89 / 87 files | unchanged |
| `ProjectStore.shared` | 247 / 63 files | 247 / 63 files | unchanged |
| `AgentRuntime.shared` | 102 / 31 files | 102 / 31 files | unchanged |
| `AppSettings.shared` | 216 / 39 files | 196 / 39 files | −20 references at the remote ownership boundary |
| `EventLog.shared` | 82 / 25 files | 82 / 25 files | unchanged |
| Core `AppDelegate.shared` | 0 / 0 files | 0 / 0 files | unchanged |
| Concrete UI-controller references in Core | 18 / 4 files | 17 / 3 files | −1 complete remote projection edge / −1 file; remains active debt |
| UI-framework imports in Core/Models | 63 / 61 files | 63 / 61 files | unchanged; remains active debt |
| `MainWindowController` authority | 5,107 / 4 files | 5,098 / 4 files | −9 fallback-construction lines |
| `AgentToolCoordinator` authority | 9,005 / 15 files | 8,979 / 15 files | −26 settings-catalogue policy lines |
| Capability extensions | 5,909 / 11 files | 5,882 / 11 files | −27 settings-catalogue policy lines |
| `ThreadingTests` Swift files | 379 | 382 | +3 focused proof files; filesystem synchronized |

The nine-line `MainWindowController` reduction removes a production composition escape hatch; it
is not a controller decomposition. Likewise, moving 26 catalogue-policy lines out of
`AgentToolCoordinator` is one coherent authority edge, not decomposition of the remaining hub.
Both authorities stay in the active debt ledger at their full reported sizes.
