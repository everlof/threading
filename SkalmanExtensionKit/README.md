# SkalmanExtensionKit

The Foundation-only contract between Skalman and safe, out-of-process extensions.

The package contains:

- inspectable extension manifests and capabilities;
- semantic command and panel contributions;
- statically declared and runtime-registered MCP tool contributions;
- statically inspectable, host-rendered Settings pages and built-in-page sections;
- versioned, manifest-declared extension services brokered without shared storage;
- host-scoped persistent key-value and disposable cache storage;
- a tokenized host client for atomic component and primitive identity publications plus safe
  project/session/provider/account snapshots, separately gated session-runtime telemetry, and
  cursor-based change events;
- a Codable `ExtensionNode` UI tree rendered by Skalman;
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
Screen Recording and Accessibility for a directly supervised child to Skalman, so the host
preflights and requests those two grants only when the companion declared their capabilities.

```bash
swift build --package-path SkalmanExtensionKit
swift test --package-path SkalmanExtensionKit
swift run --package-path SkalmanExtensionKit HelloStatusExtensionExample --skalman-register
swift run --package-path SkalmanExtensionKit HelloStatusConsumerExtensionExample --skalman-register
```

Skalman links this package, renders `ExtensionNode` through its own AppKit design system, and
supervises the extension as a persistent JSONL process. `--skalman-register` remains a
one-shot validation path; the live host uses `--skalman-serve`.

Enabled command contributions join Skalman's built-in command registry. Their stable IDs,
application/project/session scope, portable default shortcuts, and stable Extensions,
Project, or View menu placements are host-rendered and globally conflict-checked. An invocation arrives as
`ExtensionCommandRequest`; the process returns the matching `ExtensionCommandResponse`.
Extensions never create `NSMenuItem`s or install keyboard event monitors.
Commands default to ordinary risk. A command declared with `risk: .destructive` is gated by
Skalman's own confirmation before the request is sent; the host owns its wording, buttons,
keyboard defaults, and decision.

Enabled `ExtensionPanel` contributions appear in the selected session's display-pane `+` menu
beside Skalman's built-in surfaces. They open as persistent tabs keyed by extension and panel ID.
Button requests carry opaque project/session context; returned semantic panel state is rendered
by Skalman. Disable, reload, crash, and startup ordering produce a host-owned unavailable state
until the current process generation registers the panel again.

Settings contributions are declared in the manifest under the `settings` capability. Skalman
renders complete pages and sections appended to stable built-in pages using toggle, bounded text,
choice, and stepped integer controls. Effective values arrive through
`ExtensionSettingsEnvironment` before registration and through correlated
`ExtensionSettingsUpdateRequest` values while the process runs. Skalman owns persistence and
rolls back a rejected live change; the settings backing file is never granted to the extension.

Brokered services use `services.provide` plus runtime-registered
`ExtensionServiceDefinition` values on the provider, and `services.consume` plus exact
`ExtensionServiceDependency` values on the consumer. `ExtensionHostClient.callService` sends a
JSON object through Skalman's generation-bound host channel; Skalman authenticates the caller
from its token and forwards an `ExtensionServiceRequest` to the matching running provider
process. The provider never receives the consumer token or access to its package/storage.

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
fragment surface in that tree; Skalman owns the `MTKView`, pipeline wrapper, signals, input
routing and lifecycle. `Examples/RainWindowExtension` is the public-API reference.

`sidebar.project-hover-card@1` uses the same around-hook chain for temporary project
presentations. Extensions may add around `.proceed` or exclusively replace the visual body;
Skalman retains hover timing, popover chrome, placement, dismissal and accessibility. The
reference Hello Status extension adds project status below native SCC details.

`sidebar.session-hover-card@1` is the session-context counterpart. The same reference extension
adds status below the native session details, demonstrating that temporary presentations share
one composition host rather than a project/SCC-specific API.

`toolbar.account-usage-popover@1` repeats the pattern for the active account. Refresh, account
switching and hover survival stay in Skalman's shell; an extension only adds, wraps or replaces
the semantic visual body.

`composer.session-start@1` and `composer.conversation-reply@1` expose the deliberately narrower
composer form. A hook is one horizontal stack containing exactly one `.proceed`, with compact
status, text, image, spacer, and button nodes before or after it. Replacement and overlay are
not allowed: Skalman keeps the actual `PromptView`, submission, keyboard routing, drafts,
stream availability, permission state, and accessibility. The first target has project context;
the second has session context.

Native conversation rows are four separate contracts:
`conversation.user-message@1`, `conversation.assistant-message@1`,
`conversation.tool-call@1`, and `conversation.permission-card@1`. Each accepts a bounded
vertical annotation hook around exactly one `.proceed`, never replacement or overlay. The
target's optional `entityID` is the session ID, so an extension can specialize a row kind for a
known session without receiving transcript content. User/assistant text, tool arguments and
results, and permission details are not component-context values. Permission-card hooks are
display-only; Skalman's native card remains the only source of approval controls.

Display-pane chrome has two deliberately asymmetric contracts. `display.pane-header@1`
provides a compact command/status hook immediately before Skalman's `+` button.
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
system symbols, or safe package-relative image resources; Skalman resolves them synchronously in
the existing provider/account layers and restores native imagery on invalidation or process exit.

Complete session identity composition uses `appearance.session-identity` and the same component
patch transport. The constrained `sidebar.session-identity` contract lets an extension arrange
the already-resolved provider/account assets in a compact HStack while Skalman retains the row,
activity opacity, conflict selection, and native fallback.

`SkalmanComponentCatalog` exposes all current contracts in the SDK. The
`SkalmanComponentCatalogGenerator` executable writes their committed Markdown, catalogue JSON,
and contract-specific schemas; Skalman's Extension authoring MCP group serves the same values
and validator to coding agents at runtime.

Advanced companion packages keep that same WebAssembly core and may additionally declare
bounded `ExtensionRemoteSurface` values under `ui.remote-surfaces`. An ordinary
`ExtensionPanel.remoteSurface` reference selects one. Skalman owns the view, accessibility
fallback, viewport, visibility, and normalized input; the companion reads the inherited
`SKALMAN_COMPANION_SURFACE_FD` with `ExtensionRemoteSurfaceWire` and supplies only bounded
premultiplied BGRA8 frames with explicit acknowledgements.

`Examples/SimulatorRelayExtension` is the end-to-end advanced reference. Its Wasm core exposes
an ordinary remote-surface panel while a separately signed companion captures and controls the
Simulator window using only the generic process, capture, input, and remote-surface
capabilities. Its package script builds both artifacts and retains rebuildable source.

Importable directories are copied into Skalman's Application Support storage and remain
disabled until the user enables them on the Extensions settings page. See
[`docs/extensions/README.md`](../docs/extensions/README.md) for the `.skalmanextension`
layout, installation limits, source-retention direction, and removal/recovery behavior.

New safe extensions set `runtime: webAssembly` and compile to a `.wasm` command module. Skalman
runs that module in its signed App Sandboxed interpreter with no filesystem preopens, sockets,
subprocesses, or direct Keychain API. The guest's sole Skalman import forwards authenticated
requests to the host broker. The SDK describes authorities; the host owns and enforces them.
Manifests which omit `runtime` remain legacy native packages for compatibility.

`storage.secrets` grants only the host broker, not Keychain APIs or a directory. Use
`ExtensionHostClient` to set, fetch, list the names of, and remove extension-private secrets.
Skalman derives the Keychain namespace from the generation-bound bearer identity.

`SDK_VERSION` is the version of the complete source snapshot. Outside extension projects vendor
that snapshot under `Vendor/SkalmanExtensionKit` and use a relative SwiftPM path dependency.
Distributable packages retain the complete project, including that vendor directory, under
`Source/`; the prebuilt `.wasm` remains the deterministic installation artifact.

Use `ExtensionDataMigrationContext` before registration when `dataVersion` increases. Skalman
commits the target only after registration succeeds, so every migration step must be idempotent
and should use atomic key-value mutations.

Safe extension API v1 and its compatibility promise are frozen in
[`docs/extensions/API_V1.md`](../docs/extensions/API_V1.md). `network.client` is retained only
in the legacy native capability vocabulary; it is not available to safe WebAssembly v1 guests.
