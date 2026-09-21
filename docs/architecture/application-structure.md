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
contracts remain in the Foundation-only `ThreadingRemoteKit`, `ThreadingExtensionKit` and
`ThreadingPTYHostKit` packages rather than being copied into the application layer. The last of
those is linked by a process that is not the app at all, so its allowed imports are `Foundation`
and `ThreadingDomain` and nothing else; `scripts/check_module_boundaries.py` holds that floor.

`ThreadingDomain` owns typed project, session, terminal, transcript, and account identities plus
their storage-safe encoding behavior. Persisted account appearance values also live here;
`ThreadingRemoteKit` keeps public aliases while local preferences depend directly on Domain,
so storing presentation choices cannot pull in the remote transport's TLS adapters. Domain has
no dependencies. The same directory-wide
`scripts/check_module_boundaries.py` rule rejects every Domain import except Foundation and every
Application import except Foundation plus the explicitly approved lower-level contract modules.
The app target exposes migration aliases so contracts can move without a repository-wide
mechanical rewrite.

Persisted records do not own runtime discovery or presentation policy. Launch environment
policy lives in `Core/Agent/AgentEnvironment.swift`, with process/preference resolution in
`AgentEnvironmentHost.swift`; session title policy lives in
`Core/Session/AgentSessionPresentation.swift`; terminal creation's git lookup lives in
`Core/Project/ProjectTerminalCreation.swift`. `RemoteHostRecord.sshDestination` belongs to the
SSH adapter. Read-receipt state is a model; its store and remote participant projection stay in
Core. Outbox capacity is a separate shared default, so scheduled records do not import the live
queue's delivery vocabulary. Durable control actors and scopes live beside grants in
`ControlAuthority.swift`, separate from runtime outcomes in `ControlContract.swift`.

`EnvironmentKeys` is a Foundation-only vocabulary, separate from AppKit terminal constants.
`AgentEnvironment` receives an environment dictionary and explicit tool-path settings; both the
terminal and headless macOS paths use the same inherited-identity filter. Terminal colour/pager claims
remain with the frontend that can state what its terminal renders.

`AgentLaunchPlan` and `ShellCommand` are portable values under `Core/Agent/`. The plan's
`inLoginShell` factory takes an already-resolved shell path and composes the same quoted
`cd && exec` invocation for every host. `AgentLauncher` retains account discovery, provider
flags, permission/default resolution and `launchEnvironment()`; compiling a command plan must
not import those host services or silently replace their policy. `CodexLaunchCommand` composes
the provider's invocation and terminal flags from resolved values; the macOS launcher still owns
model metadata, account/hook setup, permission defaults and resume preflight.

`AgentSessionCreation` owns fresh-record assembly and handoff admission independently of the
store and UI. Host adapters retain account/model admission,
project/identity checks, fallback branch lookup, persistence and notification delivery. This is
not yet a shared session-creation transaction or runtime coordinator.

`PTYHostSocket` is the shared Unix connection leaf: it receives a path, deadline and desired
blocking mode, then returns an owned descriptor or a portable `PTYHostClientError`. It does not
import host registration, diagnostics, stores or UI. `PTYHostConnectionBinding` carries shared typed-session admission and attempt-scoped rollback;
hosts synchronize the value rather than putting locks or event delivery into the policy.
`PTYHostHandshake` owns bounded hello-batch retention and compatibility perspective. Hosts inject
control diagnostics and admission effects; handshake I/O, event pumping and write queue ownership
remain above these values in the client.

`PTYHostClient` itself now compiles on Darwin and Linux. Its journal callback is injected;
`PTYHostClientHost` preserves macOS EventLog defaults and the availability probe. Client bounds
live apart from registration paths. A Linux socket writer owns its descriptor and per-send signal
policy, while the shared client owns queue admission, protocol state and event delivery.

The session record's runtime handoff helpers live in `Core/Agent/ConversationHandoffRuntime.swift`.
Its stored provenance and validation remain in `Models/AgentSession.swift`, so compiling those
records does not pull in live account discovery and model-catalogue lookup. Other model/runtime
couplings remain migration debt; this is not yet a separately compiled persistence module.

The application target currently approximates the other layers:

| Location | Authority |
|---|---|
| `Models/` | Provider capabilities and persisted records. Provider, session, workspace, project, and persisted-UI records have separate files; AppKit-bearing theme/profile values remain migration debt. |
| `Core/Session`, `Core/Project`, `Core/Settings`, `Core/Logging` | Legacy persistence and application state. Stores and policies still share directories while injection advances boundary by boundary. |
| `Core/Agent`, `Core/AI`, `Core/MCP`, `Core/Remote`, `Core/Extensions` | Runtime and transport. Core/Remote reaches session lifecycle through injected `RemoteSessionCommands` and agent-terminal runtime through injected `RemoteTerminalApplicationCapability`; built-in MCP representation comes from one typed descriptor registry. |
| `Application/` | Foundation-only use cases and policies extracted from UI adapters, including browser, session, extension-authoring, remote-session, window-navigation, and settings-catalogue capabilities. |
| `App/` | Process composition. `AppEnvironment` owns the legacy store/service instances passed into migrated coordinators. |
| `UI/` | AppKit composition and presentation. Feature UI uses `UI/Design`; tool and browser controllers adapt application capabilities to windows and WebKit. |

## Upward dependency invariant

The architecture gate rejects every Core reference to `AppDelegate`, `MainWindowController`, or a
concrete UI controller. UI constructs both native-conversation and project-terminal controllers,
then registers their typed runtime surfaces with Core. `AgentRuntime` and
`ProjectTerminalRuntime` retain only those capabilities; neither can construct, return, or recover
the UI adapter behind one.

Session-context routing is no longer in this queue: Core targets the typed
`SessionContextReceiving` capability and resolves it through `SessionContextDestinationQuerying`;
the UI controller is only an adapter. Remote conversation mirroring now follows the same rule:
`RemoteConversationSurface` owns the Foundation-only projection/submission contract and
`ConversationViewController` adapts it, so Core/Remote never receives the controller. Native
conversation lifecycle crosses `AgentConversationRuntimeSurface`, while standalone-terminal
lifecycle crosses `ProjectTerminalRuntimeSurface`; construction and presentation stay in UI.
Remote terminal mirroring crosses the injected Foundation-only
`RemoteTerminalApplicationCapability`;
its live implementation receives `AgentRuntime` from `AppEnvironment` and has no route-time
global lookup. Context handoff and message delivery consume `AgentTerminalInputSurface`; limit
recovery consumes `AgentTerminalLimitRecoverySurface`; extension process inspection receives only
a scalar process-root projection. None of those Core owners can acquire the UI adapter. The
ratchet is zero references across zero Core files, down from 8 references across the final two
owners. It also rejects inferred controller-returning lookups so a differently named accessor
cannot recreate the dependency.

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
- `AppEnvironment` constructs `RemoteTerminalApplicationCapability` from its injected
  `AgentRuntime`; `AppDelegate` installs that same instance into the mirror registry exactly once,
  before remote access starts. The live capability never discovers a runtime, window, or
  controller internally.
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

These measurements are the output of `scripts/report_architecture_health.py` against commit
`746400ac`, immediately before the last two concrete-controller ownership edges moved, and commit
`b4053b80`, which removed them. UI now creates both adapters and Core retains typed runtime
surfaces. The architecture checker was lowered to zero in the same change and rejects inferred
controller-returning lookups as well as direct type references.

| Metric | Before | After | Change |
|---|---:|---:|---:|
| Threading Swift files / lines | 910 / 381,645 | 910 / 381,756 | +111 net typed contracts, wiring, and runtime adaptation |
| `ThreadingDomain` Swift files / lines | 1 / 197 | 1 / 197 | unchanged |
| `static … shared` declarations | 105 / 103 files | 105 / 103 files | unchanged |
| `ProjectStore.shared` | 295 / 74 files | 295 / 74 files | unchanged |
| `AgentRuntime.shared` | 108 / 37 files | 108 / 37 files | unchanged |
| `AppSettings.shared` | 207 / 42 files | 207 / 42 files | unchanged |
| `EventLog.shared` | 110 / 28 files | 110 / 28 files | unchanged |
| Core `AppDelegate.shared` | 0 / 0 files | 0 / 0 files | unchanged |
| Concrete UI-controller references in Core | 8 / 2 files | 0 / 0 files | −8 / −2 files; the exception is closed |
| UI-framework imports in Core/Models | 69 / 66 files | 69 / 66 files | unchanged; remains active debt |
| `MainWindowController` authority | 5,909 / 5 files | 5,909 / 5 files | unchanged; remains active debt |
| `AgentToolCoordinator` authority | 8,967 / 18 files | 8,967 / 18 files | unchanged; remains active debt |
| Capability extensions | 5,900 / 14 files | 5,900 / 14 files | unchanged |
| `ThreadingTests` Swift files | 488 | 488 | unchanged; existing boundary tests carry the zero ratchet |

The current source-tree report still measures zero concrete-controller references in Core (with
911 Threading Swift files and 383,474 lines). The main-window and tool-coordinator authorities stay
in the active debt ledger at their full current sizes; removing this dependency did not decompose
either hub.

The `AgentToolCoordinator` figure above is that increment's measurement, not a running total. The
enforced ratchet in `scripts/check_architecture_boundaries.sh` moved to **9,063 across 19 files**
when the adopted-Simulator tools landed, because a new built-in tool family reaches its
implementation through `MCPBuiltInToolExecuting`, which only the coordinator conforms to. The
family still keeps its policy out of the hub: `SimulatorAgentCommandService` validates the
arguments and shapes the results, and the counted adapter decodes, reveals the pane, and maps a
result. The debt is that the hub is the only door, not that this family walked through it, and the
ledger entry stays open until the dispatch seam lets a service answer for its own tools.

### Transcript authority — 6 September 2026

The missing continuation offer after a checkout move exposed another split in ownership: Claude
kept writing its original file while features read the copy at the new checkout slug. The first
fix recorded the live hook path, but three callers still chose independently between that path
and a computed slot, and background replay/search could bypass the live selection altogether.

| Boundary in this increment | Before | After |
|---|---:|---:|
| Owners of live-path versus checkout-fallback selection | 3 | 1 (`SessionTranscript`) |
| Replay/search paths bypassing live source selection | 2 | 0 |
| Terminal caches retaining the first Claude URL for a launch | 1 | 0 (cache account discovery only) |
| Feature readers allowed to compute a Claude storage slot | unrestricted | 0 (resolver and two destination owners only) |

`ReadRequest` transfers an immutable source to a worker without moving Codex discovery onto the
main actor. Runtime registration owns the authority of an outstanding observation, and the shared
fact reader owns invalidation of work crossing a copy/reset. The gate in
`scripts/check_transcript_boundaries.py` rejects direct location-state access outside the runtime
and resolver, and storage-slot calls outside the resolver and migration/checkout destination owners.
Its regression tests deliberately introduce those dependencies. Source-agreement and deterministic
worker-race tests hold the behavior; the broader singleton counts above are historical measurements,
not numbers this local change claims to have reduced.

Verification on 6 September: 299 focused tests passed, then the full `scripts/test.sh` run passed
with 8,692 passing cases, 65 skips and no failures. Both architecture and theme gates passed.
The 1,000-session location stress case (10 repeated hooks per session, lookup and discard) took
0.127 seconds. These are hosted/file regression results; a new real Claude limit event in an
installed build was not exercised during this increment.
