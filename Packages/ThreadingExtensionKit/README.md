# ThreadingExtensionKit

The Foundation-only contract between Threading and safe, out-of-process extensions.

The package contains:

- inspectable extension manifests and capabilities;
- semantic command and panel contributions;
- semantic workspace navigator contributions with virtualizable collection snapshots;
- statically declared and runtime-registered MCP tool contributions;
- statically inspectable, host-rendered Settings pages and built-in-page sections;
- versioned, manifest-declared extension services brokered without shared storage;
- versioned, domain-keyed fact providers with bounded atomic publication;
- host-scoped persistent key-value and disposable cache storage;
- a tokenized host client for atomic component and primitive identity publications plus safe
  project/session/provider/account snapshots, separately gated session-runtime telemetry, and
  cursor-based change events;
- a Codable `ExtensionNode` UI tree, including native value controls and bounded semantic
  visualization scenes, rendered by Threading;
- versioned component contracts and property, slot, and full-content patch values;
- correlated Codable request/response values for commands, persistent actions, and MCP calls;
- validation with machine-readable field paths;
- optional advanced-companion declarations with OS-facing capabilities kept independent from
  the WebAssembly core's host-data authority;
- a SwiftPM build-tool plugin that rejects AppKit and SwiftUI imports;
- a compiling reference extension.

It deliberately contains no AppKit or SwiftUI dependency. Read
[`docs/extensions/AGENT_AUTHORING.md`](../docs/extensions/AGENT_AUTHORING.md) before generating
an extension.

Advanced packages remain a strict superset: their Wasm core uses this same API for settings,
commands, hooks, panels, tools, storage, and services. An optional nested macOS companion is a
separately identified worker for OS authority, never a source of AppKit views or implicit host
access. The current host inspects the nested signature, sandbox entitlements, and reviewed
authority, pins its designated code requirement, and supervises a generation-bound
`ExtensionCompanionHello`/shutdown lifecycle. Declared operations are relayed through the host
with `ExtensionHostClient.callCompanion`, correlated request/response envelopes, and on-demand
activation. The worker receives no Wasm broker authority. Remote surfaces are implemented;
distribution author identity remains a later layer.

The companion's signature and entitlements own its App Sandbox boundary. macOS attributes
Screen Recording and Accessibility for a directly supervised child to Threading, so the host
preflights and requests those two grants only when the companion declared their capabilities.

```bash
# From the ThreadingExtensionKit package directory, wherever the SDK snapshot lives:
swift build
swift test
swift run HelloStatusExtensionExample --threading-register
swift run HelloStatusConsumerExtensionExample --threading-register
swift run GitLabStateExtensionExample --threading-register
swift run ActivityInboxExtensionExample --threading-register
```

Threading links this package, renders `ExtensionNode` through its own AppKit design system, and
supervises the extension as a persistent JSONL process. `--threading-register` remains a
one-shot validation path; the live host uses `--threading-serve`.

Enabled command contributions join Threading's built-in command registry. Their stable IDs,
application/project/session scope, portable default shortcuts, and stable Extensions,
Project, or View menu placements are host-rendered and globally conflict-checked. An invocation arrives as
`ExtensionCommandRequest`; the process returns the matching `ExtensionCommandResponse`.
Extensions never create `NSMenuItem`s or install keyboard event monitors.
Commands default to ordinary risk. A command declared with `risk: .destructive` is gated by
Threading's own confirmation before the request is sent; the host owns its wording, buttons,
keyboard defaults, and decision.

Enabled `ExtensionPanel` contributions appear in the selected session's display-pane `+` menu
beside Threading's built-in surfaces. They open as persistent tabs keyed by extension and panel ID.
Buttons, text/search inputs, pickers, and interactive scene marks raise correlated action
requests with opaque project/session context; returned semantic panel state is rendered by
Threading. A generic scene supplies normalized semantic marks for treemaps, heatmaps, charts,
timelines, and similar native visualizations without accepting extension drawing code or HTML.
See [`docs/extensions/DECLARATIVE_UI.md`](../docs/extensions/DECLARATIVE_UI.md). Disable, reload,
crash, and startup ordering produce a host-owned unavailable state until the current process
generation registers the panel again.

`ExtensionWorkspaceNavigator` replaces the complete interior of the host-owned leading navigator.
Its root composes ordinary semantic content with virtualized list, outline, and grid snapshots
carrying stable IDs and host project/session destinations. Users select a live navigator under
**View → Navigator**; Threading persists the identity, routes value-bearing actions through the
owning process, atomically installs returned snapshots, preserves collection presentation state,
and falls back to Native if that process generation disappears or cannot render. Actionable grid
items supply an `accessibilityLabel` for the host-owned cell. A navigator may declare up to 16
localized `ExtensionWorkspaceNavigatorOption` toggle or choice values. Their complete declaration
is immutable within one process generation and fits within a 30-entry extension-owned menu budget;
the v1 renderer keeps these controls hidden until the host-evaluated v2 transform consumes them. See
[`docs/extensions/WORKSPACE_NAVIGATORS.md`](../docs/extensions/WORKSPACE_NAVIGATORS.md).

For a host-evaluated navigator, set `pipeline`, put that complete navigator in the manifest's
static `workspaceNavigators` list, and repeat the exact raw base-language declaration in the live
registration. Threading checks parity before localizing it and exposes only the matched running
generation; materialized v1 navigators remain runtime-only. `Examples/ActivityInboxExtension` is
the public reference: it requests only `ui.workspace-navigation`, while Threading owns its search,
Priority/relative-date sections, sorting, working indicator updates, row realization, and
source-session activation.

Settings contributions are declared in the manifest under the `settings` capability. Threading
renders complete pages and sections appended to stable built-in pages using toggle, bounded text,
choice, and stepped integer controls. Effective values arrive through
`ExtensionSettingsEnvironment` before registration and through correlated
`ExtensionSettingsUpdateRequest` values while the process runs. Threading owns persistence and
rolls back a rejected live change; the settings backing file is never granted to the extension.

Brokered services use `services.provide` plus runtime-registered
`ExtensionServiceDefinition` values on the provider, and `services.consume` plus exact
`ExtensionServiceDependency` values on the consumer. `ExtensionHostClient.callService` sends a
JSON object through Threading's generation-bound host channel; Threading authenticates the caller
from its token and forwards an `ExtensionServiceRequest` to the matching running provider
process. The provider never receives the consumer token or access to its package/storage.

Fact providers use `facts.provide` and repeat their manifest's `factDefinitions` in the live
registration. `ExtensionHostClient.publishFacts(_:replacing:)` atomically replaces values for
explicit repository or repository-branch subjects. The bearer supplies provider identity and
process generation; no opaque project or session identifier is accepted by this capability.
`Examples/GitLabStateExtension` is the data-only reference: it discovers public GitLab merge
request state through an exact `gitlab.com` brokered-network grant and publishes
`gitlab.mr.state@1` on canonical repository-branch subjects. It declares no navigator, component,
session, settings, or storage capability. Its stable 32-repository admission set, four-request
concurrency ceiling, two-page repository limit, and 128-fact repository limit bound both remote
work and retained generation state. Authoritative refreshes replace complete repository scopes;
transient or truncated refreshes preserve the last observation so the host, not the provider,
decides when it is stale.

Component customization is connected end to end. A process declaring `ui.components` receives a
short-lived host URL and bearer token, then uses `ExtensionHostClient` to atomically replace its
accepted patches. The production `sidebar.session-row` and `sidebar.project-row` components
expose safe properties, status-only additive slots, and constrained full-content replacement
inside host-owned behavior shells. Disable, reload, crash, or app shutdown revokes the process
generation and restores native content. The implemented contract, transport, conflict,
validation, action, and fallback rules are tracked in
[`docs/extensions/COMPONENT_CUSTOMIZATION.md`](../docs/extensions/COMPONENT_CUSTOMIZATION.md).

`application.main-window@1` additionally exposes a composable around-hook seam. A hook is an
`ExtensionNode` tree with exactly one `.proceed`, representing the next hook and ultimately the
existing AppKit content. This gives extensions controlled wrapper composition without view
handles or runtime swizzling. The optional `ui.rendering.metal` capability admits a bounded
fragment surface in that tree; Threading owns the `MTKView`, pipeline wrapper, signals, input
routing and lifecycle. `Examples/RainWindowExtension` is the public-API reference.

`sidebar.project-hover-card@1` uses the same around-hook chain for temporary project
presentations. Extensions may add around `.proceed` or exclusively replace the visual body;
Threading retains hover timing, popover chrome, placement, dismissal and accessibility. The
reference Hello Status extension adds project status below native SCC details.

`sidebar.session-hover-card@1` is the session-context counterpart. The same reference extension
adds status below the native session details, demonstrating that temporary presentations share
one composition host rather than a project/SCC-specific API.

`toolbar.account-usage-popover@1` repeats the pattern for the active account. Refresh, account
switching and hover survival stay in Threading's shell; an extension only adds, wraps or replaces
the semantic visual body.

`composer.session-start@1` and `composer.conversation-reply@1` expose the deliberately narrower
composer form. A hook is one horizontal stack containing exactly one `.proceed`, with compact
status, text, image, spacer, and button nodes before or after it. Replacement and overlay are
not allowed: Threading keeps the actual `PromptView`, submission, keyboard routing, drafts,
stream availability, permission state, and accessibility. The first target has project context;
the second has session context.

Native conversation rows are four separate contracts:
`conversation.user-message@1`, `conversation.assistant-message@1`,
`conversation.tool-call@1`, and `conversation.permission-card@1`. Each accepts a bounded
vertical annotation hook around exactly one `.proceed`, never replacement or overlay. The
target's optional `entityID` is the session ID, so an extension can specialize a row kind for a
known session without receiving transcript content. User/assistant text, tool arguments and
results, and permission details are not component-context values. Permission-card hooks are
display-only; Threading's native card remains the only source of approval controls.

Display-pane chrome has two deliberately asymmetric contracts. `display.pane-header@1`
provides a compact command/status hook immediately before Threading's `+` button.
`display.tab-header@1` provides one display-only `after-title` status slot inside each native
tab belonging to the targeted session. Tab identity, selection, close, order, overflow, active
state, persistence, pane visibility, and the new-tab menu remain host-owned. Targets use the
sanitized session ID; internal tab UUIDs are not part of the public API.

Host data is connected through the same per-generation token but independently capability-gated:
`host.projects.read`, `host.sessions.read`, `host.repositories.read`, `host.providers.read`,
`host.accounts.presentation.read`, and `host.events`.
`ExtensionHostClient` returns versioned snapshots and an atomic cursor; extensions poll changes
after that cursor and re-read the changed entity. Project paths, transcript paths, prompts,
complete remote URLs, and repository credentials are not exposed.

Primitive provider/account identity resolution is connected end to end through
`appearance.provider-icons` and `appearance.account-icons`. An extension publishes host assets,
system symbols, or safe package-relative image resources; Threading resolves them synchronously in
the existing provider/account layers and restores native imagery on invalidation or process exit.

Complete session identity composition uses `appearance.session-identity` and the same component
patch transport. The constrained `sidebar.session-identity` contract lets an extension arrange
the already-resolved provider/account assets in a compact HStack while Threading retains the row,
activity opacity, conflict selection, and native fallback.

`ThreadingComponentCatalog` exposes all current contracts in the SDK. The
`ThreadingComponentCatalogGenerator` executable writes their committed Markdown, catalogue JSON,
and contract-specific schemas; Threading's Extension authoring MCP group serves the same values
and validator to coding agents at runtime.

Advanced companion packages keep that same WebAssembly core and may additionally declare
bounded `ExtensionRemoteSurface` values under `ui.remote-surfaces`. An ordinary
`ExtensionPanel.remoteSurface` reference selects one. Threading owns the view, accessibility
fallback, viewport, visibility, and normalized input; the companion reads the inherited
`THREADING_COMPANION_SURFACE_FD` with `ExtensionRemoteSurfaceWire` and supplies only bounded
premultiplied BGRA8 frames with explicit acknowledgements.

`Examples/SimulatorRelayExtension` is the end-to-end advanced reference. Its Wasm core exposes
an ordinary remote-surface panel while a separately signed companion captures and controls the
Simulator window using only the generic process, capture, input, and remote-surface
capabilities. Its package script builds both artifacts and retains rebuildable source.

Importable directories are copied into Threading's Application Support storage and remain
disabled until the user enables them on the Extensions settings page. See
[`docs/extensions/README.md`](../docs/extensions/README.md) for the `.threadingextension`
layout, installation limits, source-retention direction, and removal/recovery behavior.

New safe extensions set `runtime: webAssembly` and compile to a `.wasm` command module. Threading
runs that module in its signed App Sandboxed interpreter with no filesystem preopens, sockets,
subprocesses, or direct Keychain API. The guest's sole Threading import forwards authenticated
requests to the host broker. The SDK describes authorities; the host owns and enforces them.
`runtime` is required, and manifests that omit it are refused. Legacy native packages must
select `runtime: native` explicitly.

`storage.secrets` grants only the host broker, not Keychain APIs or a directory. Use
`ExtensionHostClient` to set, fetch, list the names of, and remove extension-private secrets.
Threading derives the Keychain namespace from the generation-bound bearer identity.

`SDK_VERSION` is the version of the complete source snapshot. Outside extension projects vendor
that snapshot under `Vendor/ThreadingExtensionKit` and use a relative SwiftPM path dependency.
Distributable packages retain the complete project, including that vendor directory, under
`Source/`; the prebuilt `.wasm` remains the deterministic installation artifact.

Use `ExtensionDataMigrationContext` before registration when `dataVersion` increases. Threading
commits the target only after registration succeeds, so every migration step must be idempotent
and should use atomic key-value mutations.

Safe extension API v1 and its compatibility promise are frozen in
[`docs/extensions/API_V1.md`](../docs/extensions/API_V1.md). `network.client` is retained only
in the legacy native capability vocabulary; it is not available to safe WebAssembly v1 guests.
