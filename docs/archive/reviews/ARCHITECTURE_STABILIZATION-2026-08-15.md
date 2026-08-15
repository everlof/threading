# Archived architecture-stabilization record — 15 August 2026

Most Threading code is still one application target, so directory names alone do not enforce
dependency direction. The stable identity kernel now lives in the compiler-isolated
`ThreadingDomain` package. This document names the current product boundary, the intended direction
of knowledge, and the small health ledger used to tell whether structural work has reduced change
amplification.
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

`ThreadingDomain` is the first extracted layer. It owns the typed project, session, terminal,
transcript, and account identities plus their storage-safe encoding behavior. Its Swift package has
no dependencies and `scripts/check_module_boundaries.py` rejects any import other than Foundation.
The application target currently exposes migration aliases so the extraction changes ownership
without forcing a repository-wide import rewrite.

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

- `Core/Remote/RemoteAccessServer.swift` called `AppDelegate.shared` four times for resume, create,
  pin refresh, and surface refresh. Milestone 1 replaced those calls with the injected
  `RemoteSessionCommands` application capability; provider archive events are now adapted at
  the composition root through the same refresh operation.
- `Core/Agent/AgentRuntime.swift` constructs and retains `AgentSessionViewController` and
  `ConversationViewController`.
- `Core/Agent/LimitRecoveryCoordinator.swift` accepts concrete `AgentSessionViewController`
  values in five paths.
- `Core/Agent/SessionContextHandoff.swift` stores a `ConversationViewController` case.
- `Core/Remote/RemoteSessionMirrorRegistry.swift` accepts a `ConversationViewController` when
  building its live projection.
- `Core/Session/ProjectTerminalRuntime.swift` constructs and retains
  `ProjectTerminalViewController`.

These edges are the measured migration queue, not exemptions. The architecture gate now rejects
any Core reference to `AppDelegate` or `MainWindowController`, discovers concrete UI controller
types, and permits only the 19 references in its explicit ratcheted legacy map. Runtime/controller
ownership follows behind an application capability or projection boundary.

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

### Milestone 1 — remote application capability

Measured after introducing `RemoteSessionCommands`:

| Metric | Baseline | Milestone 1 | Change |
|---|---:|---:|---:|
| Threading Swift files / lines | 749 / 322,134 | 750 / 322,177 | +1 / +43 for the explicit contract |
| `AppDelegate.shared` in Core | 4 / 1 file | 0 / 0 files | −4 / −1 file |
| Concrete UI-controller references in Core | 19 / 5 files | 19 / 5 files | unchanged; now ratcheted |
| `MainWindowController` authority | 5,081 / 4 files | 5,070 / 4 files | −11 event-composition lines |
| `ProjectStore.shared` | 345 / 68 files | 345 / 68 files | unchanged in this slice |

The real loopback server's focused suite routes create, resume, metadata refresh, and surface
refresh through a recording capability without constructing `AppDelegate` or a window. A missing
capability fails a dormant resume closed with HTTP 503. `scripts/check_dependency_boundaries.py`
prevents the removed upward edge from returning and makes every remaining controller edge an
explicit debt reduction.

### Milestone 2 — compiler-enforced domain identities

The first stable contracts now compile and test without the application target:

| Metric | Milestone 1 | Milestone 2 | Change |
|---|---:|---:|---:|
| Threading application Swift files / lines | 750 / 322,177 | 750 / 321,993 | 184 identity lines moved out of the app target |
| `ThreadingDomain` Swift files / lines | 0 / 0 | 1 / 197 | one Foundation-only compiler boundary |
| UI-framework imports in Core/Models | 63 / 61 files | 63 / 61 files | unchanged; new domain module has zero |
| Concrete UI-controller references in Core | 19 / 5 files | 19 / 5 files | unchanged; still ratcheted |
| `ProjectStore.shared` | 345 / 68 files | 345 / 68 files | unchanged in this slice |

The package test suite pins the existing single-value Codable shapes, path-component refusal,
terminal history namespaces, and account-handle persistence semantics. Existing application tests
continue through source-compatible aliases. This establishes a compiler boundary without claiming
that persistence, runtime, application, or UI have already been extracted.

### Milestone 3 — application environment and one injected ownership boundary

`AppDelegate` now owns an `AppEnvironment` and passes it through `MainWindowController` to the
`SessionCoordinator` family. The live environment is the only new composition point that names the
legacy `ProjectStore`, `AgentRuntime`, `AppSettings`, and `EventLog` singletons. The coordinator's
session creation, archive, scheduled-message, limit-escape, and developer-report paths use the
injected instances instead. The sidebar receives only the two runtime-backed availability
projections it needs for menu construction, rather than locating the runtime itself through this
new boundary.

| Metric | Milestone 2 | Milestone 3 | Change |
|---|---:|---:|---:|
| Threading application Swift files / lines | 750 / 321,993 | 751 / 322,070 | +1 environment file / +77 net wiring and test-support lines |
| `ProjectStore.shared` | 345 / 68 files | 299 / 64 files | −46 / −4 files |
| `AgentRuntime.shared` | 130 / 34 files | 116 / 32 files | −14 / −2 files |
| `AppSettings.shared` | 230 / 43 files | 223 / 40 files | −7 / −3 files |
| `EventLog.shared` | 112 / 31 files | 94 / 27 files | −18 / −4 files |
| `static … shared` declarations | 87 / 85 files | 87 / 85 files | unchanged; the environment is not another singleton |
| `MainWindowController` authority | 5,070 / 4 files | 5,098 / 4 files | +28 composition lines for explicit wiring |

`SessionCoordinatorTests` constructs all four services independently and proves that the
coordinator and its sidebar retain the injected instances. The architecture gate rejects future
singleton lookups anywhere in the four `SessionCoordinator` files. This is intentionally one
ownership-boundary migration; remaining leaf consumers stay in the measured queue rather than
being rewritten mechanically.

### Milestone 4 — filesystem-synchronized unit tests

`Tests/ThreadingTests` is now a `PBXFileSystemSynchronizedRootGroup` owned by the unit-test target.
The conversion removed 357 file references, 357 build-file objects, 357 group children, and 357
Sources-phase entries. The obsolete registration helper and checker were removed from local, CI,
UI, and app-build paths; test membership now has one source of truth: the filesystem.

| Metric | Milestone 3 | Milestone 4 | Change |
|---|---:|---:|---:|
| `ThreadingTests` Swift files | 357 manually registered | 358 filesystem synchronized | +1 architecture proof test; −1,428 synchronized project entries |
| `ThreadingTests` Sources-phase entries | 357 | 0 | compiler discovers the synchronized group |

`FilesystemSynchronizedTestTargetTests.swift` is intentionally absent from `project.pbxproj` and
executes through the focused Xcode test plan. It also asserts that its own name remains absent,
so restoring per-file registration would fail the proof rather than quietly reintroducing a
second list.

### Milestone 5 — authoritative registries and subsystem ownership

Built-in MCP tools now enter the runtime through one admitted `MCPBuiltInToolDescriptor` per
typed identity. A descriptor carries argument decoding, schema, behavior annotations, catalog
group and presentation, and its application execution binding. Advertised definitions, enabled
names, scoped definitions, catalog rows, completeness checks, and execution routing all consume
`MCPBuiltInToolRegistry.descriptors`; an incomplete or disagreeing declaration is rejected rather
than forming a partial second catalog. `MCPWireTests` prove descriptor parity for every closed
`MCPBuiltInTool` case.

The settings and command paths already had the intended authoritative catalogs, so this milestone
kept and verified them instead of adding competing registries. `SettingsPages.all` feeds Settings
navigation, both search paths, and the read-only `list_settings` MCP tool. `AppCommands.all` feeds
`CommandRegistry`, whose descriptors project into menus, the command palette, shortcuts,
extensions, and the host command plane.

Typed event transport moved to `Core/Events`, each event declaration moved beside its owning
project, session, settings, stats, disk, or theme subsystem, and nonvisual AppKit lifetime helpers
moved to `UI/Infrastructure`. Agent and MCP defaults likewise moved to `Core/Agent` and `Core/MCP`.
The architecture
gate rejects returning those declarations to `TerminalConstants.swift`.

| Metric | Milestone 4 | Milestone 5 | Change |
|---|---:|---:|---:|
| Threading application Swift files / lines | 751 / 322,070 | 762 / 322,261 | +11 ownership files / +191 net contract and guard lines |
| `TerminalConstants.swift` lines | 1,323 | 542 | −781 shared-grab-bag lines |
| `ProjectStore.shared` | 299 / 64 files | 299 / 64 files | unchanged in this slice |
| Concrete UI-controller references in Core | 19 / 5 files | 19 / 5 files | unchanged; still ratcheted |
| `ThreadingTests` Sources-phase entries | 0 | 0 | filesystem remains the only test-membership list |

This milestone changes authoritative representation and ownership, not product behavior. Focused
MCP, event, scheduling, persistence, theme, agent-launch, hook, and registry suites cover the moved
boundaries; the full test plan is the milestone gate.

### Milestone 6 — decomposition by authority

This milestone moved use cases and state machines, rather than merely moving extensions between
files:

- `ConversationViewController` retains a `SessionID` and reads an injected current-session
  projection, so a replacement record cannot leave the conversation holding stale value state.
- Browser download lifecycle, navigation lifecycle, agent form-navigation policy, and destructive
  storage sequencing are Foundation-only application objects with direct tests. AppKit/WebKit code
  adapts page leases, presentation, and the actual browser operation.
- Agent session commands and extension-authoring commands are injected application services; the
  tool coordinator maps MCP transport values into those capabilities.
- Window back/forward history belongs to `WindowNavigationCoordinator`; the window controller
  composes it with current selection and presentation.
- The 2,515-line project-model aggregate was split into provider capabilities, session records,
  workspace records, project records, and persisted UI documents. `Project.swift` now contains
  256 lines of the aggregate root and compatibility surface.
- Deterministic component-gallery stories moved beside the Design components they demonstrate;
  the gallery controller retains catalog assembly and interactive presentation.

| Metric | Milestone 5 | Milestone 6 | Change |
|---|---:|---:|---:|
| Threading application Swift files / lines | 762 / 322,261 | 778 / 322,696 | +16 authority and testable policy files / +435 net lines |
| `ProjectStore.shared` | 299 / 64 files | 295 / 64 files | −4 stale-session lookups |
| `MainWindowController` authority | 5,098 / 4 files | 5,075 / 4 files | −23 navigation-policy lines |
| `AgentToolCoordinator` authority | 9,558 / 15 files | 9,349 / 15 files | −209 use-case lines |
| `AgentToolCoordinator+…` capability extensions | 6,130 / 11 files | 5,903 / 11 files | −227 use-case lines |
| `BrowserViewController.swift` | 4,248 | 4,077 | −171 lifecycle and policy lines |
| `Project.swift` | 2,515 | 256 | −2,259 lines reassigned by model authority |
| `ComponentGalleryWindowController.swift` | 5,476 | 5,290 | −186 deterministic fixture lines |

The architecture gate prevents the extracted policy from returning to adapters and keeps the new
browser services Foundation-only. Focused unit and real-WebKit race tests cover each browser
boundary; coordinator, project-record, gallery-catalog, and conversation-projection suites cover
the other ownership moves.

## Live inventories

Inventories are projections of code-owned registries, not Markdown tables that must be updated in
parallel:

| Inventory | Authoritative code | Generated/visible projection | Drift proof |
|---|---|---|---|
| Built-in MCP tools | `MCPBuiltInToolRegistry.descriptors` | MCP `tools/list`, Tools settings, scoped catalogs and execution routing | `MCPWireTests` checks identity, decoding, schema, annotations, grouping and binding parity. |
| Settings | `SettingsPages.all` plus extension settings registry | Settings navigation, both search paths and `list_settings` | `SettingsAnchorResolutionTests` builds indexed pages and resolves row anchors. |
| Commands and shortcuts | `AppCommands.all`, then `CommandRegistry` for extension/project additions and overrides | Menus, Keyboard settings, command palette and host command plane | `KeyboardShortcutTests`, `TabCyclingCommandTests`, and command-policy tests enumerate the registry. |
| Public extension components | `ThreadingComponentCatalog.document` | Committed Markdown, JSON and per-component schemas in `docs/extensions/generated` | `ThreadingComponentCatalogGenerator --check` runs in CI. |

Do not add a hand-maintained tool, settings, shortcut, or component list to architecture docs. Add
metadata to its registry and extend the relevant completeness test; every consumer should see the
same projection.
