# Application structure

Most Threading code still compiles in one application target, so directories alone do not enforce
dependency direction. The compiler-isolated `ThreadingDomain` package is the stable identity
kernel; architecture checks ratchet the remaining legacy edges while application capabilities are
extracted one ownership boundary at a time.

`scripts/check_ui_structure.py --report` inventories direct AppKit controller and view/window
subclasses, constraint construction, and drawing references outside `UI/Design`. Its checked-in
ceilings run in the ordinary architecture build phase: 83 direct controllers, 119 platform
views/windows, 2,818 constraint sites, and 96 drawing sites on 2026-09-25. A reduction must
lower the corresponding ceiling. This prevents growth while the semantic structural seam is
built; it does not make the remaining feature-owned sites portable or certify their layout.

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
`Core/Session/AgentSessionRowPresentation.swift`, with macOS preference injection in
`AgentSessionPresentation.swift`; terminal creation's git lookup lives in
`Core/Project/ProjectTerminalCreation.swift`. `RemoteHostRecord.sshDestination` belongs to the
SSH adapter. Read-receipt state is a model; its store and remote participant projection stay in
Core. Outbox capacity is a separate shared default, so scheduled records do not import the live
queue's delivery vocabulary. Durable control actors and scopes live beside grants in
`ControlAuthority.swift`, separate from runtime outcomes in `ControlContract.swift`.

`EnvironmentKeys` is a Foundation-only vocabulary, separate from AppKit terminal constants.
`AgentEnvironment` receives an environment dictionary and explicit tool-path settings; both the
terminal and headless macOS paths use the same inherited-identity filter. The Linux host compiles
that policy unchanged and resolves only its own host environment. Terminal colour/pager claims
remain with the frontend that can state what its terminal renders.

`AgentLaunchPlan` and `ShellCommand` are portable values under `Core/Agent/`. The plan's
`inLoginShell` factory takes an already-resolved shell path and composes the same quoted
`cd && exec` invocation for every host. `AgentLauncher` retains account discovery, remaining
provider flags, permission/default resolution and `launchEnvironment()`; compiling a command plan must
not import those host services or silently replace their policy. `CodexLaunchCommand` composes
the provider's invocation and terminal flags from resolved values; the macOS launcher still owns
model metadata, account/hook setup, permission defaults and resume preflight.
`ClaudeLaunchCommand` likewise composes the portable fresh/resume command pair from resolved
session values and host-supplied integration flags. The macOS remote host and experimental Linux
hosts share it; the macOS local launcher still owns hooks and fork handling. The Linux CLI starts
a fresh standard-account Claude session and records its caller-minted UUID before spawn; the native
Linux window can also resume an exited one after a worker checks the exact transcript path.
`ClaudeTranscriptPath` owns that portable path and project-slug encoding for both hosts, while
account discovery and transcript source selection remain host-owned. The headless CLI does not
yet offer exited-session resume.

`AgentSessionCreation` owns fresh-record assembly and handoff admission independently of the
store and UI. macOS and the Linux host share it; host adapters retain account/model admission,
project/identity checks, fallback branch lookup, persistence and notification delivery. This is
not yet a shared session-creation transaction or runtime coordinator.
The native Linux host prepares a new agent through a zero-recent-row navigation snapshot and one
indexed identity check, then uses the incremental session write. It never decodes the standing
session graph to launch a new child.
`AgentLaunchRecording` applies a terminal plan's durable launch facts before either host hands
it to a process owner. Both hosts mark the attempt launched, stamp activity, clear a previous
exit code and store the plan's resume state; admission and the exact database write remain with
each host. A prior launch failure remains until the runtime survives its startup check.

`AgentSessionRowPresentation` carries typed identity, title precedence and attention precedence
(scheduled, woke, then snoozed). `SessionRowView.configure` assembles it from the existing
`NativeSidebarParity` fact and host reads; a scheduled or wake state avoids evaluating the snooze
clock. Hosts own localization, account resolution, activity, commands and extension composition.
The value does not own persistence or layout: the Mac view owns its constraints, identity badge
and trailing-control reservation. No new extension surface is introduced.

`PTYHostSocket` is the shared Unix connection leaf: it receives a path, deadline and desired
blocking mode, then returns an owned descriptor or a portable `PTYHostClientError`. It does not
import host registration, diagnostics, stores or UI. `PTYHostConnectionBinding` carries shared typed-session admission and attempt-scoped rollback;
hosts synchronize the value rather than putting locks or event delivery into the policy.
`PTYHostHandshake` owns bounded hello-batch retention and compatibility perspective. Hosts inject
control diagnostics and admission effects; handshake I/O, event pumping and write queue ownership
remain above these values in the client.

`PTYHostClient` lives in `Packages/ThreadingPTYClient`, a compiled Darwin/Linux module. Its
journal and typed diagnostic callbacks are injected; `PTYHostClientHost` preserves macOS
EventLog/OSLog defaults and the availability probe. Client bounds
live apart from registration paths. A Linux socket writer owns its descriptor and per-send signal
policy, while the shared client owns queue admission, protocol state and event delivery.

The experimental Linux `WindowHarness --app` connects its project snapshot to that client through
`GraphicalTerminal`. Fresh runtimes are keyed by project and attached runtimes by typed persisted
agent or terminal identity, with an eight-entry combined ceiling. The native window switches
between projects, the selected project's saved-agent or saved-terminal list, and the visible
terminal. Left from a project opens agents; Right opens terminals. Navigation does not create a
new child or detach an existing one. The snapshot keeps at most 512 identities of each
kind per project and the UI mounts only viewport rows. Only the visible terminal requests
rendered frames; store work and terminal processing stay on workers. This remains a host-only diagnostic frontend,
not the shipping Mac sidebar or a public extension surface.

The Linux window's ATK bridge projects those mounted rows into AT-SPI, including durable IDs,
bounded Unicode names, selected state and actions. Actions re-enter SDL's existing project-navigation
events; the bridge neither reads the store nor owns runtime decisions. The terminal currently
exposes a read-only ATK Text projection of its visible, bounded grid, with Unicode offsets,
concealed-cell masking and changed-span notifications. It does not traverse hidden scrollback.
SDL window focus is projected onto the mounted selected row or terminal without moving selection.
The frame, mounted list rows and terminal expose window, screen and parent-coordinate component
bounds from the live SDL window; one row rectangle supplies drawing, pointer hit testing and
AT-SPI publication, and point lookup returns mounted children only. The terminal maps Unicode
offsets to the same fixed cell positions its Pango renderer uses; point queries resolve only
visible cells, not hidden scrollback. The list alone implements ATK's single-child Selection
interface: reads project its selected row, and writes enqueue the same generation-checked
navigation action as the row's accessible `select` action. The host remains the selection owner;
clear and multiselect requests are refused. Bounds-change notifications, comprehensive focus
behavior, terminal text selection and screen-reader inspection remain open accessibility work.

The navigator keeps specimen row chrome and selection geometry, then passes only its mounted
title and row labels to a Linux Pango text leaf over the opaque frame. That leaf validates the
frame and label rectangles, shapes Unicode into one reusable row-sized surface, and clips each
label to its existing row. The host caps labels before encoding; the leaf caps its shared UTF-8
buffer, label count and per-label bytes. Neither the store nor the accessibility bridge owns
glyph rendering, and navigation never shapes offscreen rows.

Graphical restoration across app restarts is available through explicit
`--attach STORE SOCKET TERMINAL_UUID` and through selection
in the project browser. A saved agent session has the same terminal renderer through explicit
`--attach-agent STORE SOCKET SESSION_UUID` or the project's saved-agent picker; the host validates
the agent record and keeps its typed daemon identity. The project-targeted launcher also attempts
attach-only restoration of the saved selected agent when it belongs to that project, has launched,
is unarchived and has no recorded exit. If it falls outside the recent window, one indexed read
puts it in the picker without increasing the 512-row cap. Opening a different agent
updates the selected ID on a worker before entering its terminal; opening a shell or saved terminal
clears it on a writable store. Startup restoration never starts a child, and automatic terminal
restoration remains missing. Explicit Codex picker selection can still resume a departed agent.
Attach validates store membership on a worker, adopts the daemon grid without resizing the child,
suppresses query responses for the announced replay byte prefix and marks cut history. Input and
frames remain gated until replay completes; old or invalid peers fail explicitly under an attach
deadline.
An explicit native clipboard gesture forwards at most 64 KiB of valid UTF-8 on the same ordered
terminal worker, with the emulator's live bracketed-paste mode deciding the framing. The host
keeps shortcut routing and clipboard refusal. Local selection and explicit copy work there.
For the native terminal, SDL text-editing events carry bounded, uncommitted IME text to a
Pango-drawn preview by the emulator cursor; committed text-input events enter the ordered PTY queue.
The X11/IBus Pinyin smoke verifies that the child receives no preedit bytes and receives the
committed UTF-8 once. This is one platform/input-method path, not general Linux IME parity.
An integrated terminal failure stops only its client and remains navigable as a failed entry;
returning to projects preserves other runtimes. Revisiting does not silently retry. The failed
view waits on native events and bounds its diagnostic text before drawing. The standalone
terminal diagnostic still exits nonzero on failure.
`WindowHarness --app-codex` adds an explicit absolute Codex executable to the project window.
Ctrl+Shift+A creates a fresh selected-project Codex record on the terminal worker through the
same `AgentSessionCreation`, `CodexLaunchCommand` and `AgentLaunchPlan` policies the CLI host
uses, then sends an `agentSession` spawn with the window's actual initial grid. Store membership,
nonblocking lock ownership, record persistence and launch admission remain host-owned; the UI
publishes the new identity into its bounded saved-agent snapshot only after persistence.
Linux launch paths use the production database's exact project/session mutations rather than a
whole-graph save. A first Codex session and its newly imported project commit together; an
existing-project session and its selection commit together; rollout discovery writes only the
standing session. The project terminal remains embedded in its owning project row, so that row
still grows with the number of terminals in that project.
Selected agent attach, rollout discovery and resume read one indexed session and its validated
owning project instead of decoding the full archive again. The initial project-window snapshot
reads project rows, indexed session counts and at most 512 recent session payloads per project on
a worker. The targeted launcher reads one selected agent by primary key when it falls outside
that recent window; an eligible agent replaces one picker slot without expanding the 512-row cap.
It does not decode other dormant sessions outside the window. Project terminal records still
live in each project payload, so terminal identity lookup searches those embedded records.
The visible experiment has a bounded Codex login chooser (Ctrl+Shift+I), but no provider or model
picker. A worker discovers up to 31 legacy marker-backed homes once per window, alongside the
standard home. `THREADING_LINUX_CODEX_ACCOUNT=codex-work` sets the initial new-session choice;
the window can change it without changing saved sessions. The stored handle sends later resumes
back to that exact `HOME/.codex-work` after login-marker, rollout-ID and mixed-ordinal checks.
Without the variable, new sessions use `HOME/.codex`.
Registered keyring locations and other providers are still unsupported on Linux. A source-tree
Linux launcher can import an existing project into the same durable store without a daemon,
then start or reuse the daemon before opening this window with the requested project selected.
The import and worker-built startup snapshot use the same canonical project-directory identity
as macOS, so a symlink spelling does not create or select a second project. Selecting a project
alone does not start another child.
Explicit replacement is a separate project action. Once a spawn send is attempted, the runtime
assumes a child may exist until a matching exit or definitive refusal proves otherwise. A missing
reply, disconnect, write failure or `alreadyExists` refusal cannot authorize a replacement. The
host creates a fresh durable record only after admission and preserves prior record counts while
replacing one cache entry; it never kills a child as a side effect of this action.

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
