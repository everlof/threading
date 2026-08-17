# Threading Extensions

Threading extensions are intended to be authored by coding agents from a documented contract,
not by copying application internals. The default extension kind is therefore:

- a Swift WebAssembly command module interpreted outside Threading rather than code loaded into it;
- described by a manifest Threading can inspect before executing it;
- compiled against the Foundation-only `ThreadingExtensionKit`;
- allowed to return semantic UI values, never AppKit or SwiftUI views;
- rendered by Threading through the same theme boundary as built-in UI.

This keeps ordinary extensions isolated and lets the host retain control of themes,
accessibility, focus, motion, component state, and future visual changes.

## Current implementation status

The first vertical slice exists:

- [`ThreadingExtensionKit`](../../Packages/ThreadingExtensionKit) defines manifests, capabilities,
  contributions, and the initial declarative UI nodes.
- [`ThreadingExtensionPolicyPlugin`](../../Packages/ThreadingExtensionKit/Plugins/ThreadingExtensionPolicyPlugin)
  fails the supported safe-extension build when source imports AppKit or SwiftUI.
- [`HelloStatusExtension`](../../Packages/ThreadingExtensionKit/Examples/HelloStatusExtension) is the
  compiling provider reference; [`HelloStatusConsumerExtension`](../../Packages/ThreadingExtensionKit/Examples/HelloStatusConsumerExtension)
  is the matching service consumer.
- [`extension-manifest.schema.json`](schema/extension-manifest.schema.json) is the
  machine-readable manifest schema.
- [`extension-settings.schema.json`](schema/extension-settings.schema.json) defines the
  host-rendered settings form vocabulary.
- [`extension-services.schema.json`](schema/extension-services.schema.json) defines versioned
  service declarations, dependencies, calls, and results.
- [`extension-node.schema.json`](schema/extension-node.schema.json) is the machine-readable UI
  schema.
- [`workspace-navigator.schema.json`](schema/workspace-navigator.schema.json) defines the
  compositional, collection-oriented navigator contribution documented in
  [`WORKSPACE_NAVIGATORS.md`](WORKSPACE_NAVIGATORS.md).
- [`DECLARATIVE_UI.md`](DECLARATIVE_UI.md) documents native value controls, generic semantic
  scenes, correlated action values, surface limits, and the host-rendering architecture.
- [`extension-process.schema.json`](schema/extension-process.schema.json) describes correlated
  settings, service, command, panel/component/navigator-action, and MCP-tool requests and
  responses.
- [`extension-host.schema.json`](schema/extension-host.schema.json) describes atomic component
  patch publications over the independent host channel.
- [`extension-host-data.schema.json`](schema/extension-host-data.schema.json) describes safe
  project, session, provider, and account snapshots plus cursor events.
- [`extension-identity-resolutions.schema.json`](schema/extension-identity-resolutions.schema.json)
  describes atomic provider/account icon resolver publications.
- [`extension-secrets.schema.json`](schema/extension-secrets.schema.json) describes the
  extension-private Keychain broker payloads.
- [`extension-storage.schema.json`](schema/extension-storage.schema.json) describes the
  brokered key-value and cache payloads the host exchanges when it writes an extension's
  private storage on its behalf.
- [`generated/component-catalog.json`](generated/component-catalog.json) and the per-component
  schemas under [`generated/schemas`](generated/schemas) are generated directly from the same
  SDK catalogue Threading's runtime registers.
- [`API_V1.md`](API_V1.md) freezes the supported safe API, its version domains, capability
  set, and compatibility promise.
- Threading links the SDK and renders `ExtensionNode` trees into its own themed AppKit controls,
  including text/search fields, pickers, and generic interactive scenes for data visualizations.
- Extensions may register validated `ui.workspace-navigation` contributions. Users choose one
  under **View → Navigator**; Threading virtualizes its collections, owns project/session routing,
  and restores Native when the selected process generation becomes unavailable.
- The Component Gallery remains a direct development harness: it can choose an extension
  directory, inspect its manifest, supervise a persistent process, validate every JSONL value,
  route button actions, and re-render returned panel state.
- Settings has an Extensions page that imports packages into app-owned storage, persists
  enablement, starts and stops supervised processes, reports runtime state, reloads and reveals
  packages, and moves removed packages into recoverable storage.
- Enabled extensions can contribute complete Settings pages and append sections to stable
  built-in pages. Threading renders toggle, text, choice, and integer fields through its design
  system, owns their durable values, supplies them at launch, and synchronizes accepted changes
  with the running process.
- Enabled command contributions join the same registry as built-in commands. Threading renders
  them at stable top-level Extensions, Project, and View anchors, lists and rebinds them on the
  existing Keyboard settings page, enforces application/project/session scope, and routes
  invocations over the supervised JSONL process. Default shortcuts are suggestions and become
  unbound on a conflict.
- Enabled panel contributions appear beside Threading's built-in Terminal, Browser, Files, Review,
  and Info surfaces in the display pane's `+` menu. Each opens as a normal per-session tab,
  receives opaque project/session context on actions, persists by stable extension/panel ID, and
  shows a recoverable unavailable state across disable, reload, crash, or startup ordering.
- New safe extensions run as WebAssembly in Threading's signed, App Sandboxed interpreter.
  Threading opens the validated module and passes that one file descriptor to the runner; the
  guest receives no filesystem preopens, socket API, subprocess authority, or Keychain API.
  Its only Threading-specific import is the authenticated host broker. Legacy native format-1
  packages remain readable through the deprecated Seatbelt compatibility launcher.
- A manifest can declare namespaced MCP tool metadata. The running process registers the matching
  definitions, Threading routes calls over the existing JSONL process, and each extension appears
  as its own group beside built-in tools in Tools settings.
- Providers can declare versioned JSON services and consumers can request exact provider,
  service, and version dependencies. Threading's generation-bound host token authenticates the
  caller, the broker routes only declared dependencies to a matching running registration, and
  Extensions settings reports provided services plus required/optional availability.
- Extensions declaring `storage.secrets` can store bounded opaque values through the
  generation-bound host broker. Threading scopes them by authenticated extension identity and
  stores them in Keychain; values never enter package files, KV JSON, settings, cache directories,
  or sandbox grants.
- The real sidebar session and project rows now have versioned customization contracts with
  safe title, identity-image, and tooltip properties, additive `after-title` status slots, and
  compact full-content replacement. Machine-readable constraints limit their node vocabulary,
  depth, count, roles, and text length; replacement actions retain extension/target provenance
  while the host keeps selection, activity/count state, drag/drop, accessibility, and row
  actions. Repository and branch headings are deliberately outside the project-row contract.
- The main-window content exposes a semantic around-hook contract. Enabled hooks form a stable
  chain around the existing view through exactly one `.proceed` node, so an extension can place
  host-rendered content beside or over the original without receiving an `NSView`. A separate
  `ui.rendering.metal` capability admits bounded extension shader source in those declared
  positions; Threading still owns the renderer and input lifecycle.
- The `media` node is the only one whose pixels move on their own, and the host draws all of
  them. An extension states which document, whether it is playing, how fast and how it loops, and
  receives a coalesced state report; the decoder, the clock, the transport, the ceilings and the
  pasteboard stay on the host side. `ui.media-documents` gates it, and every surface opts in
  separately (`allowsMedia` defaults to false), so no existing contract gained a player when the
  node shipped.
- A process declaring any implemented host capability receives a per-generation loopback URL
  and bearer token. `ExtensionHostClient` publishes complete patch sets atomically and reads
  separately gated project/session snapshots and cursor events; the host derives source
  identity and ordering from the token, rejects invalid sets without disturbing the last
  accepted state, and removes the generation immediately on disable, reload, crash, uninstall,
  or shutdown. Replacement buttons route back as semantic component actions.
- The Hello Status reference extension queries real entity IDs and uses that production path to
  publish live status to both project and session rows. It also queries provider/account
  presentation snapshots, publishes primitive icon resolutions, and replaces the session
  identity subtree with a host-rendered provider/account HStack. In-memory fixtures remain only
  as deterministic gallery/test inputs.
- The built-in `Extension authoring` MCP group lists and describes those contracts, validates
  complete patch JSON with the runtime validator, and renders a native preview into the display
  panel without installing or publishing the patch.

The next product layers are more documented host component anchors and richer panel node
vocabulary where real extensions require it.
Project/session/provider/account snapshots, primitive identity resolvers, selectable session
identity composition, generated catalogues, authoring tools, and cursor events are implemented;
[`HOST_SURFACES.md`](HOST_SURFACES.md) records that boundary.
[`COMPONENT_CUSTOMIZATION.md`](COMPONENT_CUSTOMIZATION.md) specifies how those contracts fit into
existing AppKit components without requiring a universal base class.

## Extension forms

Extensions do not declare one exclusive `type`. Their form is derived from composable
capabilities, so a small extension can grow without changing package format:

| Profile | Capability | Contribution | Intended surface |
| --- | --- | --- | --- |
| Command extension | `commands` | `ExtensionCommand` | User-triggered actions |
| Panel extension | `panels` | `ExtensionPanel` with semantic `ExtensionNode` UI | Host-rendered custom UI |
| Agent-tool extension | `mcp.tools` | Statically declared and runtime-registered MCP tools | Claude and Codex |
| Settings extension | `settings` | Complete pages and sections appended to stable host pages | Threading Settings |
| Service extension | `services.provide` | Versioned JSON service contracts | Other declared extensions |
| Component extension | `ui.components` | Properties, slots, and constrained content replacement | Documented host components |
| Navigator extension | `ui.workspace-navigation` | Complete semantic navigator documents with virtualizable collections | Leading workspace navigator |
| Metal surface extension | `ui.rendering.metal` + `ui.components` | Bounded fragment surfaces inside declared component hooks | Contracts whose hook vocabulary admits Metal |
| Media extension | `ui.media-documents` | A `media` node — a document handle plus a playback intent, drawn by a host-owned player | Panels, and any surface whose vocabulary admits media |
| Asset-browsing extension | `host.project.files.read` | Bounded, cursor-paged enumeration as opaque content handles | A project's own documents |
| Attachment-preview extension | `attachments.preview` (+ `attachments.file-types`) | A preview body offered for one attachment; ordering decides the winner | The Attachments pane's preview body |
| Identity extension | `appearance.provider-icons`, `appearance.account-icons`, `appearance.session-identity` | Primitive image recipes and constrained composition | Provider/account marks and session identity layout |
| Appearance extension | `appearance.themes`, `appearance.fonts` | App-theme documents and font files carried as package data | Settings ▸ Themes and the chrome/conversation font pickers |
| Hybrid extension | Any combination | Two or more contribution forms | One process sharing state across surfaces |
| Runtime extension | None of the above | No visible contribution yet | Foundation for future capabilities |

`ExtensionManifest.profile` and `contributionKinds` derive these labels; they are not additional
wire fields. Settings shows both the derived profile and the concrete surfaces an installed
extension provides. Code generators should choose the smallest capability set that covers the
requested behavior, and use a hybrid only when the contributions genuinely share one lifecycle
or state model.

**Appearance contributions are data, not code.** `themes` entries name package-relative JSON
documents written in the host's own app-theme vocabulary — the same document Threading stores for
a custom theme — and `fonts` entries name `.otf`/`.ttf`/`.ttc` files. Both are read, bounded,
and validated by the inspector before any extension code runs: a theme faces the same contrast
and material gates a custom theme faces, its library id is namespaced by the host
(`ext.<extension>.<theme id>`), and a font must parse to at least one face. While the extension
is enabled, its themes appear in Settings ▸ Themes labelled by the extension's name, and its
fonts are registered process-scoped, which makes them appear in the font pickers and resolvable
by any theme document that names their family — including the extension's own, which is how a
theme pack styles the whole app with its own face. Disabling the extension removes both; a
theme that was active falls back to the stock Threading default, and a named-but-gone family
degrades one resolution rung exactly like an uninstalled font. Font licensing is the package author's responsibility,
and the install disclosure names every theme and font family before anything is copied.

**Localization is package-owned presentation data.** A manifest's `localizations` entries pair
a BCP-47 language tag with a bounded package-relative JSON file. Each file is a flat mapping
from readable base-language strings to translated strings. Threading negotiates the closest
catalogue from the app's preferred language list, then applies it to the extension name,
commands, panels and every semantic node, Settings pages/sections/fields/options/placeholders,
services and MCP metadata, companion operations and remote-surface accessibility labels, and
contributed theme names. IDs, resource paths, values, schemas, routing, and capabilities are
never translated. A missing key falls back to its base string.

The same negotiated locale, preferred languages, selected catalogue, and string table are
placed in the extension launch environment. Runtime code uses `ExtensionLocalizer` so action
messages and other dynamic copy agree with what the host already rendered. Settings search
indexes the localized extension metadata. Catalogues are inspected before code runs, must
preserve each key's ordered printf placeholders, and are bounded by file size, entry count, and
string length.

Command, panel, settings, service, agent-tool, identity, appearance, and component extensions
are connected to their product surfaces end to end. Component Gallery remains the direct unpacked-directory
harness and semantic rendering fixture rather than the only place panels can run.
The derived profiles make that distinction visible without pretending there are separate
extension runtimes.

## Data and communication pipeline

Extensions will need durable preferences, cached discovery, and controlled access to host data.
These are separate authorities rather than one shared writable directory:

1. **Private KV storage — implemented.** Declare `storage.kv` and use
   `ExtensionKeyValueStore`. Mutations are atomic, capped at 2,048 keys and 1 MiB, and retained
   across disable, reload, and app launches. How the state reaches disk depends on the launcher
   and the API does not: under the experimental `sandbox-exec` launcher Threading allocates a
   per-extension directory outside the package and the extension writes it; under the supported
   runner the extension has no writable path and the host writes it on the extension's behalf,
   enforcing the same limits. Use `init(environment:)` and the difference stays Threading's.
2. **Private cache storage — implemented.** Declare `storage.cache` and use
   `ExtensionCacheStore`: `data(forName:)`, `setData(_:forName:)`, `removeData(forName:)`,
   `names()`. Threading may clear any entry at any time, so a miss is an ordinary answer rather
   than an error. Entries are capped at 4 MiB each and 100 MiB in total, and a name is one path
   component — no separators, no `..`, no control characters. Downloaded assets and serialized
   indexes belong here, never in the installed package. `ExtensionCache.directoryURL()` still
   returns the raw directory under the experimental launcher and reports `unavailable` under
   the runner, which grants no writable path; `ExtensionCacheStore` works under both.
3. **User settings — implemented.** Declare `settings` and a static form in the manifest.
   Threading owns and validates the values separately from extension KV, supplies effective values
   at launch, and sends correlated updates to a running process. The process cannot open the
   host-owned settings file.
4. **Secrets — implemented.** Declare `storage.secrets` and use
   `ExtensionHostClient.secret(forKey:)`, `setSecret(_:forKey:)`, or the opaque-data variants.
   Threading stores at most 256 names per extension and 64 KiB per value in Keychain. Listing
   returns sorted names only; values are fetched individually.
5. **Host data APIs — implemented for projects, sessions, session runtime, providers, and
   account presentation.** `host.projects.read`, `host.sessions.read`,
   `host.sessions.runtime.read`, `host.repositories.read`, `host.providers.read`,
   `host.accounts.presentation.read`, and `host.events` gate versioned snapshots and a bounded
   cursor feed. `host.project.files.read` is separate and implied by none of them: it returns
   opaque, generation-bound content **handles** plus bounded filesystem metadata — name,
   project-relative path, byte size, modification date, and the host's content hint — and never
   bytes or an absolute path. See
   [`media-documents.md`](../architecture/media-documents.md). The runtime broker accepts an exact stable session ID and returns only
   Threading-attributed agent/shell process groups and listening-port metadata; it is not a raw
   process-table or arbitrary-PID API. One reading is capped at 256 processes and 128 ports.
   Extensions receive stable values, not paths to
   `projects.json`, transcripts, account configs, checkout directories, complete remote URLs,
   login email, internal databases, process arguments, environments, or open files.
6. **Extension services — implemented.** Exact provider/service/version dependencies are
   declared in the consumer manifest and namespaced calls are brokered by Threading. One
   extension never reads another extension's KV or cache directly; the provider chooses what its
   public service returns and Threading can display and revoke the relationship.

Disable leaves private data and user settings intact. Removal moves durable values, settings,
and cache data into a `.storage` recovery directory beside the recoverable package.
Keychain-backed secrets remain in the extension's isolated Keychain namespace so a recoverable
removal does not silently destroy credentials.

The host supplies storage locations only for capabilities declared in the manifest, and the
process sandbox enforces those exact directory grants. Writing mutable state into an installed
package is denied. An extension cannot directly inspect another extension's storage or arbitrary
user files.

## Extension-contributed commands

Declare `commands`, then return `ExtensionCommand` values from `ExtensionRegistration`. A
command has a local stable ID, title, optional description, scope, risk, optional portable
default shortcut, and host-defined menu placements:

```swift
ExtensionCommand(
    id: "open-build",
    title: "Open Build",
    description: "Open the current CI build.",
    scope: .project,
    defaultShortcut: .init(
        key: "b",
        modifiers: [.option, .command]
    ),
    menuPlacements: [.extensions, .project]
)
```

Threading qualifies the local ID under the owning extension, registers it beside built-in
commands, and removes it atomically when the extension stops. `.application` commands are
always available; `.project` and `.session` commands enable only when that context exists.
The stable menu contracts are `.extensions` for the top-level Extensions menu, `.project`
or `.view` for a host-owned Extensions group at the end of those existing menus, and
`.sessionRow` or `.projectRow` for a host-owned Extensions group in a sidebar row's `⋯` and
right-click menus — there the invocation context carries the row's own identity rather than
the selection, and the row's native actions stay host-owned. Extensions
never receive or construct an `NSMenu`, never name indexes, and cannot splice items between
built-in commands. A command may appear in several placements; its first declared *menu-bar*
placement is canonical and is the only copy that displays and dispatches the shortcut — row
menus never display key equivalents, and a row-only command dispatches a user-bound shortcut
through a hidden menu-bar carrier. An empty placement
array leaves the command available only through a user-bound shortcut.

The default shortcut is a suggestion. Threading validates it, resolves it through the same
`ShortcutOverrideStore` as built-ins, and suppresses it when another active command owns the
chord. Keyboard settings lists extension commands under Extensions and stores overrides by the
fully qualified ID, so disable/re-enable does not forget the user's choice.

Risk defaults to `.ordinary`. Set `risk: .destructive` when the command can make a change that
is difficult or impossible to undo:

```swift
ExtensionCommand(
    id: "reset-build-cache",
    title: "Reset build cache",
    scope: .project,
    risk: .destructive,
    menuPlacements: [.project]
)
```

Threading then asks for confirmation before sending the command request, whether invocation came
from a menu or a shortcut. The extension supplies only the semantic risk classification. Threading
owns the alert, warning copy, button roles, keyboard defaults, and final decision; the command
description and response message never become confirmation wording.

Invocation sends `ExtensionCommandRequest` with the local `commandID` and an opaque context.
Project/session IDs do not grant snapshot access; the corresponding host-data capabilities are
still required. Return exactly one `ExtensionCommandResponse` echoing both `requestID` and
`commandID`. A response may carry a short success `message`, an `error`, or neither when the
command communicates by publishing component state.

## Extension-contributed panels

Declare `panels`, then register one or more `ExtensionPanel` values. A panel is a stable local ID,
a user-facing title, an `ExtensionNode` root, and optionally a `loadActionID`. Threading owns the
tab, scrolling, layout, controls, theme, accessibility, focus, and action routing. Registration
accepts at most 32 panels; each tree is capped at 24 levels, 500 nodes, and 10,000 characters per
text value. Button and load-action IDs use the same contribution-identifier rules as commands
and actions.

Running panels are listed after Threading's built-in surfaces in the selected session's display
pane `+` menu. Opening one creates at most one tab for that extension/panel pair in the session.
The persisted tab stores only the owning extension ID, panel ID, and last title—not a process,
view, or trusted copy of runtime state. It can therefore restore before extension startup and
automatically reconnect to the current process generation. Disable, reload, crash, or a removed
runtime registration replaces the content with a host-owned unavailable state; it never leaves
stale interactive UI behind.

When `loadActionID` is present, the registered root is rendered immediately as loading/fallback
content and Threading invokes that action once when the tab connects to each running process
generation. The request includes the tab's project/session context. Return a replacement panel
to render context-dependent initial content. A replacement may retain the same `loadActionID`;
it does not recursively load. Disable/re-enable, reload, or crash recovery creates a new process
generation and loads again. Ordinary tab selection and rendering do not.

A button sends `ExtensionActionRequest` with `panelID`, `actionID`, and the same opaque
`projectID`/`sessionID` context used for commands. Those IDs do not grant snapshot access.
Return `ExtensionActionResponse` with the matching request ID and optionally:

- a replacement panel with the same panel ID;
- a short success `message`;
- both; or
- an `error`, mutually exclusive with success values.

The replacement belongs only to that tab and current process generation. Package-relative images
are resolved inside the installed extension directory; system symbols are supported. Host assets
remain scoped to documented component contracts rather than becoming an implicit private-image
API for standalone panels.

## Extension-contributed Settings

Declare the `settings` capability and a static `settings` contribution in the manifest. The
declaration is inspectable before code runs and may contain:

- up to eight complete pages in the Settings sidebar; and
- sections appended after Threading's own content on a stable built-in page.

The stable built-in IDs are `general`, `accounts`, `profiles`, `themes`, `motion`, `extensions`,
`tools`, `keyboard`, `usage`, `storage`, and `archived`. Target these IDs through
`ExtensionHostSettingsPage`; never target a translated title, sidebar index, or AppKit view.
The first contract is deliberately append-only.

Fields use globally unique local IDs across the extension and one of four semantic controls:
`toggle`, bounded `text`, enumerated `choice`, or stepped `integer`. Threading renders the controls
through its current theme, accessibility, focus, and validation behavior. Extensions do not
create Settings views.

Threading stores only valid overrides in host-owned storage. Defaults remain in the manifest.
Before registration, the extension can decode the effective values with
`ExtensionSettingsEnvironment.values()`. While it is running, a user change arrives as an
`ExtensionSettingsUpdateRequest`; validate it against the declared contribution, apply the
complete `values` patch, and return an `ExtensionSettingsUpdateResponse` with the same
`requestID` and sorted `settingIDs`. If the process rejects or fails the update, Threading restores
the previous value. A disabled extension receives its latest effective values the next time it
starts.

Settings are not `storage.kv`: the user and host own Settings values, while the extension owns
its private operational state. The extension cannot access the Settings backing file, even when
it declares `storage.kv`.

## Brokered extension services

A provider declares `services.provide` and static `services` definitions. Each definition has a
local ID, exact integer version, title, description, object-rooted input schema, and output
schema. The running provider repeats the same definitions in `ExtensionRegistration`; an
undeclared or broadened runtime service never becomes available.

A consumer declares `services.consume` and one `serviceDependencies` entry per exact
provider/service/version it may call. `required` affects the availability warning shown in
Extensions settings; it does not prevent the consumer process from starting, so providers may
be enabled or restarted in either order.

```swift
let value = try await ExtensionHostClient().callService(
    providerIdentifier: "com.example.ci",
    serviceID: "status",
    version: 2,
    arguments: .object(["projectID": .string(projectID)])
)
```

Caller identity comes from the generation's bearer token and cannot be spoofed in the call.
Threading rejects undeclared dependencies and self-calls, caps the body at 1 MiB, and returns
unavailable as soon as the provider is disabled, reloaded, crashes, or stops registering the
contract. The provider receives `ExtensionServiceRequest` on its existing JSONL stream and
returns one matching `ExtensionServiceResponse`. It sees the verified caller extension ID, but
never the caller's token, package, KV, cache, settings file, or process.

The schemas describe the typed contract for authors and code generation. In protocol v1 the
broker validates the envelope and exact registration/dependency relationship; providers remain
responsible for semantic validation of arguments and consumers for decoding the returned value.

## Extension-contributed MCP tools

Tool metadata is declared in `threading-extension.json` under `mcpTools` with the `mcp.tools`
capability. This lets Threading inspect the name, description, and JSON input schema without
executing code. Global MCP names are generated as
`ext__<reverse-DNS namespace>__<local tool id>`, with dots encoded as double underscores.

The process repeats the definitions in `ExtensionRegistration`. Runtime definitions must match
the manifest exactly; a process cannot silently broaden an inspected schema after the user
enables it. Declared tools appear under the extension's own group in Tools settings. They are
advertised only while both the extension and its tool group are enabled, and calls succeed only
while the process has registered the matching definition.

Calls arrive as `ExtensionMCPToolRequest` values carrying opaque `sessionID`, local `toolID`, and
JSON-object `arguments`. The extension returns one correlated `ExtensionMCPToolResponse`.
Results are plain text in the first protocol version, matching Threading's built-in tools.

### Host separation

The MCP server does not import `ThreadingExtensionKit` or know about `ExtensionManager`. Its only
optional integration point is the host-owned `MCPExternalToolProvider`, installed at the app
composition root. That provider supplies groups, schemas, availability, and invocation using
MCP-owned values. `ExtensionMCPToolProvider` is the adapter that translates those values to the
extension SDK and process manager.

With no provider installed, the same MCP catalogue, wire decoder, dispatcher, and Tools settings
page continue to operate with built-in tools only. Removing the extension experiment therefore
means removing its adapter and composition-root installation rather than unwinding extension
types from the MCP core. A boundary test rejects direct `ThreadingExtensionKit`,
`ExtensionManager`, or `ExtensionJSONValue` references under `Core/MCP`.

## Package and installation lifecycle

An installed package is a directory with the `.threadingextension` suffix. Threading also accepts an
unpacked development directory through the import panel.

Extensions settings has two deliberately separate sources:

- **From Threading** is a small catalogue compiled into the app. Its installable packages are
  resources inside `Threading.app`, covered by the app's code signature, and opening Settings
  performs no discovery request. At launch this catalogue contains Storm.
- **Import…** accepts a package or unpacked development directory chosen by the user and records
  it as a local unsigned import.

A catalogue item's HTTPS Git URL is an inspectable project/source link, not a delivery
mechanism. Threading never clones, builds, or executes repository contents. Adding or updating a
first-party item therefore requires a new app build containing the reviewed prebuilt package;
there is no remotely mutable launch repository or marketplace feed.

```text
BuildWatch.threadingextension/
├── threading-extension.json
├── bin/
│   └── build-watch.wasm
├── Source/                      # expected for distributable packages
│   ├── Package.swift
│   ├── Sources/
│   └── Vendor/ThreadingExtensionKit/
├── Resources/
├── Web/                         # reserved for a future custom web panel
├── README.md
└── LICENSE
```

Set `"runtime": "webAssembly"` and name a `.wasm` module in `executable`. The module is an
ordinary read-only package file and does not need an executable bit. A manifest with no
`runtime` decodes as `"native"` only to keep existing experimental packages usable.

WebAssembly packages require both the prebuilt module and a rebuildable Swift project. The
inspector verifies `Source/Package.swift` plus at least one Swift file under `Source/Sources/`
without compiling on the user's machine. `ExtensionPackager` copies an authoring project there
and excludes local `.build`, `.git`, `.swiftpm`, `DerivedData`, and `.DS_Store` state.
Source-only packages remain a developer workflow: normal installation never depends on a
compatible Swift toolchain.

An outside project consumes a **vendored, versioned snapshot** of `ThreadingExtensionKit` through
`.package(path: "Vendor/ThreadingExtensionKit")`. `Packages/ThreadingExtensionKit/SDK_VERSION` identifies the
snapshot. This avoids an absolute path into the Threading checkout, a floating dependency, and a
network fetch during rebuild. Every app build embeds the filtered snapshot at
`Contents/Resources/ExtensionSDK/ThreadingExtensionKit` and the matching public authoring contract
at `Contents/Resources/ExtensionSDK/docs/extensions`. The scaffold flow preserves that sibling
layout under `Vendor/`, making the SDK README links valid and retaining the complete docs,
schemas, generated component catalogue, and checklist inside packaged `Source/`. Local `.build`
and `Build` artifacts are excluded from the app snapshot.

`Packages/docs` is intentionally a symlink to the repository's root `docs` directory. It keeps
the SDK README's `../docs/extensions` links valid in all three supported layouts: this checkout,
the app bundle's `ExtensionSDK`, and a scaffolded project's `Vendor` directory. Do not flatten or
rewrite those package-relative links without changing all three layouts together.

Installation from either source follows a strict sequence:

1. inspect the manifest without executing code;
2. reject unsupported capabilities, escaping executables, symbolic links, oversized packages,
   and excessive entry counts;
3. show whether the package is an app-included copy or a local unsigned import, name its runtime,
   source availability, and full capability set, then require the user to choose
   **Install Disabled**;
4. copy into a staging sibling under Application Support;
5. inspect the copied package again;
6. atomically move the complete package into
   `~/Library/Application Support/Threading/Extensions/Packages/`;
7. leave it disabled until the user explicitly enables it.

Enablement is stored separately in `Extensions/state.json`. This keeps packages immutable and
lets Threading discover them without trusting their contents to remember whether they should run.
Removing an extension stops its process, clears enablement, and moves the package under
`Extensions/Removed/` rather than destroying it. Settings, KV, cache, committed `dataVersion`,
and host-authored provenance move into matching recovery files. Keychain secrets deliberately
remain under the extension identifier for an intentional reinstall; the removal confirmation
states this, and an extension should delete secrets before removal when retention is unwanted.
A reinstall does not silently restore filesystem state from `Removed/`.

An identifier collision never overwrites an installed package. Updating is a separate,
version-aware operation: Threading stages the candidate, shows its capability delta, binds
approval to the staged content digest, stops the running generation and atomically swaps the
approved tree into place.

`dataVersion` is a monotonic extension-owned storage schema. Threading passes the previously
committed and target versions to the process, commits the target only after successful
registration, and retries an interrupted migration on the next launch. Updates and launches
which would decrease it are refused.

Provenance is host-authored and shown in Extensions settings as either local/unsigned or
“From Threading · included copy”, followed by a SHA-256 prefix and the vendored SDK version when
present. Format 2 adds the first-party origin and safe HTTPS repository URL while continuing to
read format-1 local records. It records source and integrity; it never changes containment,
capability approval, or disabled-by-default behavior. There is no package-author signing
hierarchy and therefore no “trust anyway” escape hatch.

## Two extension tiers

### Safe extensions

The default. They compile to WebAssembly, run in Threading's signed interpreter process, and use
`ThreadingExtensionKit`. Their UI is an `ExtensionNode` tree rendered by the host. The extension
cannot inject an `NSView`, inspect the hierarchy, or call AppKit. It can wrap a documented
component when that contract exposes an around-hook seam: `.proceed` stands for the next
host-owned view, while stacks, overlays, and capability-gated custom surfaces remain
host-instantiated.

`sidebar.project-hover-card@1` applies the same composition to the native project-metrics card.
Threading retains hover timing, popover placement, dismissal, width, insets, theme and
accessibility. A hook can place extension content before or after `.proceed`; a replacement can
own the entire visual body. The card opens when either native metrics or an accepted
extension contribution exists, so an extension may introduce project hover information before
the host has produced a reading.

`sidebar.session-hover-card@1` applies that identical presentation mechanism to a session's
identity, checkout and activity card. Its context and entity key are session-specific, but its
layout vocabulary, provenance routing, extension-only fallback and host-owned popover lifecycle
are the same. Hello Status uses both contracts, which keeps these APIs exercised by one ordinary
extension rather than by host-only fixtures.

`toolbar.account-usage-popover@1` is the same mechanism with account context. Threading keeps
usage refresh, active-account selection, popover chrome and the pointer-tracking bridge that
keeps the hover presentation alive. Those behaviors remain intact even when an extension
replaces the complete visual body.

Those three are cards Threading already shows, which an extension may compose into. The reverse
— an extension's *own* row revealing a card — is `ExtensionNode.disclosure`: the extension gives
a summary and the level behind it, and Threading gives the reveal. The dwell, the surface, its
placement, how far it grows before it scrolls, the pointer bridge into it, and the dismissal are
all host-owned, presented through the named `extension.node-detail` popover. A contract states
the revealed level's vocabulary separately from the row's (`disclosureDetail`), which is how the
corner card keeps controls out of its compact line while allowing them one level in.

The two composer contracts are intentionally more constrained:
`composer.session-start@1` targets a project and `composer.conversation-reply@1` targets a
session. Each accepts compact controls before or after one `.proceed` in a horizontal stack,
but no replacement or overlay. `.proceed` is the existing native prompt, so extension controls
cannot erase text input, send behavior, keyboard routing, draft persistence, streaming or
permission state. The Hello Status example publishes one accessory for each composer using the
same public component transport as every other patch.

Conversation rendering continues that pattern with one contract per security and lifecycle
shape: `conversation.user-message@1`, `conversation.assistant-message@1`,
`conversation.tool-call@1`, and `conversation.permission-card@1`. A vertical hook can add
bounded annotation UI before or after `.proceed`; it cannot replace or overlay the native row.
Targets are family-wide or scoped to a session ID already available from the sanitized session
snapshot. Component lookup never sends transcript text, tool input/output, or approval details
to the extension.

The original AppKit object remains alive inside `.proceed`. A late tool result therefore still
updates the same collapsible `ToolCallView`, and a permission request still settles through the
same `PermissionRequestView` after an extension reload or disable. Permission annotations allow
only display nodes, not buttons, so they cannot imitate Allow, Allow for Session, or Deny.

Display-pane chrome is extensible without making the tab model public.
`display.pane-header@1` is a compact horizontal command/status hook in the accessory region
before the host-owned new-tab button. Its `.proceed` is a zero-sized composition anchor, not
the tab strip. `display.tab-header@1` is narrower still: it accepts one display-only
`after-title` status node inside each native tab for the targeted session. Extensions do not
receive internal tab UUIDs and cannot own selection, close, ordering, overflow, persistence,
active state, pane visibility, or the `+` menu.

The build plugin is correctness enforcement for generated source, not a security boundary.
Running out of process contains crashes and the value-only protocol prevents view injection.
`WasmLaunchPolicy` passes the inspected module on descriptor 4 to
`Contents/Helpers/threading-wasm-extension-runner`. That runner has only the App Sandbox
entitlement and needs no package path: the guest receives WASI stdio, no filesystem preopens,
and the one `threading.host_exchange` import. Serve mode forwards that import to the
generation-bound broker on descriptor 3; registration mode deliberately has no broker.
Guest memory, table growth, module size, and each broker request/response are bounded.

`network.client` is not available to WebAssembly guests yet. A future network service must be
host-brokered and capability checked; no socket entitlement will be added to the runner.

Existing manifests without `runtime` remain native for compatibility and use
`SandboxExecLaunchPolicy`. That launcher is deprecated and is not the authoring target for new
safe extensions. The two older App Sandbox helpers remain adversarial test harnesses: arbitrary
native code can deliberately raise a legacy login-Keychain ACL prompt, which is why they were
not promoted to the product path.
[`SANDBOX_RUNNER.md`](SANDBOX_RUNNER.md) has the design, the measurements, and the two denial
probes that motivated the WebAssembly boundary.

### Advanced companion extensions

The power tier is a superset of the safe model, not a second UI API. An advanced package
keeps its Wasm core and all ordinary semantic contributions, then optionally declares separately
identified macOS companion apps for OS-level work. Companion capabilities are granular and
independent from host-data capabilities. UI returns through semantic nodes or a bounded remote
surface rather than an in-process `NSViewController`; a sandboxed web/canvas body remains a
future middle tier.

Manifest inspection, signed entitlement matching, install/update disclosure, launch-time pinned
requirement validation, supervised lifecycle, and declared operation relay are present.
`whileExtensionEnabled` workers auto-start, `onDemand` workers start on the first authorized
operation or surface, and every worker is torn down with its core generation. Remote surfaces
carry bounded premultiplied BGRA8 frames into host-owned views and normalized declared input back
over a private inherited socket, with one outstanding frame per presentation. The host
authenticates the Wasm caller, resolves only that extension's declarations, and keeps the core's
bearer out of the worker process. Distribution author identity remains in the implementation
checklist in `HANDOFF.md`.

The nested signature is the companion's App Sandbox boundary. Screen Recording and
Accessibility have an additional macOS rule: a directly supervised child is attributed to its
responsible parent, Threading. Before spawning a companion that declared `screen.capture` or
`input.control`, Threading therefore performs the corresponding host-owned preflight/prompt and
fails the companion status closed if the user has not granted it. This does not give the worker
any Threading host-data authority.

## Design rules

1. A contribution describes meaning. Threading chooses pixels.
2. Capabilities are declared before the extension runs.
3. Manifests and wire values remain inspectable when they contain a capability newer than the
   host.
4. Stable extension API is smaller than Threading's internal design system.
5. The reference example and schemas are normative. Prose explains them but does not override
   them.
6. New UI vocabulary is added only for a real extension that cannot express its interface with
   existing nodes.

## Repository layout

```text
Packages/ThreadingExtensionKit/
├── Package.swift
├── Sources/ThreadingExtensionKit/
├── Plugins/ThreadingExtensionPolicyPlugin/
├── Examples/HelloStatusExtension/
├── Examples/HelloStatusConsumerExtension/
├── Examples/SimulatorRelayExtension/
└── Tests/ThreadingExtensionKitTests/

docs/extensions/
├── README.md
├── AGENT_AUTHORING.md
├── AUTHORING_FLOW.md
├── HOST_SURFACES.md
├── COMPONENT_CUSTOMIZATION.md
├── CUSTOMIZATION_SURFACE_AUDIT.md
├── SANDBOX_RUNNER.md
├── HANDOFF.md
├── generated/
│   ├── component-catalog.json
│   ├── component-catalog.md
│   └── schemas/
└── schema/
    ├── extension-manifest.schema.json
    ├── extension-settings.schema.json
    ├── extension-services.schema.json
    ├── extension-node.schema.json
    ├── workspace-navigator.schema.json
    ├── extension-host.schema.json
    ├── extension-host-data.schema.json
    ├── extension-identity-resolutions.schema.json
    ├── extension-secrets.schema.json
    ├── extension-storage.schema.json
    └── extension-process.schema.json
```

## Validation

From the repository root:

```bash
swift build --package-path Packages/ThreadingExtensionKit
swift test --package-path Packages/ThreadingExtensionKit
swift run --package-path Packages/ThreadingExtensionKit HelloStatusExtensionExample --threading-register
swift run --package-path Packages/ThreadingExtensionKit HelloStatusConsumerExtensionExample --threading-register
swift run --package-path Packages/ThreadingExtensionKit SessionInfoExtensionExample --threading-register
swift run --package-path Packages/ThreadingExtensionKit ThreadingComponentCatalogGenerator \
  docs/extensions/generated
```

The example target uses the same policy plugin generated extensions must use.
Run the catalogue generator with `--check` in verification to detect stale committed docs.
`--threading-register` is a finite diagnostic handshake. Threading uses `--threading-serve` to keep
the process alive and exchange action messages.

## Try the real host path

The supported artifact is built with a Swift.org toolchain and the official Swift WebAssembly
SDK. Xcode's Apple toolchain may not contain the WebAssembly backend even when `swift` reports
the same language version. Verify that the selected Swift.org binary can see an installed SDK:

```bash
SWIFT_ORG=/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift
"$SWIFT_ORG" sdk list
"$SWIFT_ORG" build --disable-sandbox \
  --package-path Packages/ThreadingExtensionKit \
  --swift-sdk swift-6.3.2-RELEASE_wasm \
  --product HelloStatusExtensionExample
```

Use the exact SDK identifier printed by `sdk list`; it is intentionally not inferred. Then
assemble the directory the manifest describes:

```bash
WASM_BIN=Packages/ThreadingExtensionKit/.build/wasm32-unknown-wasip1/debug
mkdir -p /tmp/HelloStatusExtension/bin
cp Packages/ThreadingExtensionKit/Examples/HelloStatusExtension/threading-extension.json \
  /tmp/HelloStatusExtension/
cp "$WASM_BIN/HelloStatusExtensionExample.wasm" \
  /tmp/HelloStatusExtension/bin/hello-status.wasm
mkdir -p /tmp/HelloStatusExtension/Source
rsync -a --exclude .build --exclude .git --exclude .swiftpm \
  Packages/ThreadingExtensionKit/ /tmp/HelloStatusExtension/Source/
```

For a direct development run, open **Component Gallery**, find **Extension rendering**, choose
**Load Extension Directory…**, and select `/tmp/HelloStatusExtension`. Threading runs the
manifest → persistent process → validation → native-rendering harness without installing it.
Press **Refresh**: the extension returns a new semantic panel and the status advances from
“Ready” to “Refreshed 1 time”.

For the product path, import the same directory under **Settings → Extensions**, enable it,
select a session, open the display pane, and choose **+ → Status** under Hello Status. The panel
is now a persistent session tab. The same refresh command also appears under
**Extensions → Hello Status** and **Project → Extensions → Hello Status**, uses `⌥⌘R` from its
canonical first placement when that chord is free, and is listed with built-ins on the Keyboard
settings page.
Its **Presentation** page appears in the Settings sidebar, while its **Startup** section is
appended to General; changes update the running row publications and survive disable/re-enable.
