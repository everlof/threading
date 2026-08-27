# Agent Contract: Authoring a Safe Threading Extension

This document is written for an AI creating or changing a Threading extension. Follow it
literally. Do not infer APIs from Threading's application source.

## Before writing code

1. Read this complete document.
2. Read [`API_V1.md`](API_V1.md).
3. Read [`schema/extension-manifest.schema.json`](schema/extension-manifest.schema.json).
4. Read [`schema/extension-settings.schema.json`](schema/extension-settings.schema.json) when
   contributing Settings.
5. Read [`schema/extension-services.schema.json`](schema/extension-services.schema.json) when
   providing or consuming extension services.
6. Read [`schema/extension-node.schema.json`](schema/extension-node.schema.json) when contributing
   other UI.
7. Read [`schema/extension-process.schema.json`](schema/extension-process.schema.json) when
   handling commands, settings updates, or actions.
8. Read [`schema/extension-host-data.schema.json`](schema/extension-host-data.schema.json) when
   reading host snapshots or events.
9. Use
   [`Packages/ThreadingExtensionKit/Examples/HelloStatusExtension`](../../Packages/ThreadingExtensionKit/Examples/HelloStatusExtension)
   as the provider template and
   [`HelloStatusConsumerExtension`](../../Packages/ThreadingExtensionKit/Examples/HelloStatusConsumerExtension)
   as the consumer template.
10. Do not copy types from `Sources/Threading`.

## Development and installed layouts

```text
MyExtension/                         # editable development project
├── Package.swift
├── threading-extension.json
├── Sources/MyExtension/main.swift
├── Scripts/package.sh
├── Vendor/ThreadingExtensionKit/      # exact SDK snapshot; see SDK_VERSION
├── Vendor/docs/extensions/          # exact offline authoring contract + schemas
└── Resources/

MyExtension.threadingextension/        # importable package
├── threading-extension.json
├── bin/my-extension.wasm
├── Source/                          # complete project, including Vendor/
├── Resources/
├── README.md
└── LICENSE
```

Do not place SwiftPM's whole build directory in the package. The importable directory contains
the prebuilt `.wasm` module named by the manifest plus the source and resources required to
understand, fork, and rebuild it. Threading copies imports into its own Application Support
directory and leaves them disabled; never write mutable state back into the installed package.

The supported dependency shape is a **vendored SDK snapshot**, not a path into Threading's source
checkout and not a floating remote branch:

```swift
dependencies: [
    .package(path: "Vendor/ThreadingExtensionKit")
]
```

Copy the complete `ThreadingExtensionKit` package at one known `SDK_VERSION`, excluding its local
`.build` directory, into `Vendor/ThreadingExtensionKit`. Keep that snapshot unchanged while
developing a release. This makes an extension project outside the Threading repository buildable
offline and makes the retained `Source/` tree state exactly which SDK it used. Updating the SDK
is an explicit source and package update, not something SwiftPM does behind the user's back.
The scaffold also copies the matching public contract to `Vendor/docs/extensions`; keep it with
the SDK so a future agent can discover the API, schemas, examples, and completion checklist from
the project or packaged `Source/` without needing the Threading repository or network access.

The manifest is read before the executable starts:

```json
{
  "formatVersion": 1,
  "identifier": "com.example.my-extension",
  "name": "My Extension",
  "version": "0.1.0",
  "dataVersion": 1,
  "runtime": "webAssembly",
  "executable": "bin/my-extension.wasm",
  "capabilities": [
    "commands",
    "panels",
    "mcp.tools",
    "settings",
    "services.provide",
    "ui.components",
    "host.projects.read",
    "host.sessions.read",
    "host.events",
    "storage.kv",
    "storage.cache",
    "storage.secrets"
  ],
  "mcpTools": [
    {
      "id": "read-status",
      "title": "Read status",
      "description": "Return the extension's current status.",
      "inputSchema": {
        "type": "object",
        "properties": {}
      }
    }
  ],
  "settings": {
    "pages": [
      {
        "id": "presentation",
        "title": "Presentation",
        "symbol": "lightbulb",
        "sections": [
          {
            "id": "status",
            "fields": [
              {
                "id": "show-status",
                "title": "Show status",
                "control": {
                  "type": "toggle",
                  "defaultValue": true
                }
              }
            ]
          }
        ]
      }
    ],
    "sections": []
  },
  "services": [],
  "serviceDependencies": [],
  "localizations": [
    {
      "locale": "sv",
      "resource": "Resources/Localizations/sv.json"
    }
  ]
}
```

Rules:

- `identifier` is lowercase reverse DNS with at least two components.
- `dataVersion` is the monotonic schema version of settings/KV/cache interpretation. Omission
  means 1. Never decrease it, including on an app-version rollback.
- `runtime` is required. New safe extensions use `"runtime": "webAssembly"`. Threading refuses
  manifests that omit the execution boundary; legacy native packages must opt in explicitly
  with `"runtime": "native"`.
- `executable` is relative to the installed extension directory.
- A WebAssembly executable ends in `.wasm` and does not need a POSIX executable bit.
- The runtime admits at most 256 MiB of module bytes. That ceiling is checked on the opened stream,
  not only from package metadata, so replacing or growing a module during launch cannot enlarge the
  runner's allocation.
- `executable` must not contain `.` or `..` path components.
- Do not request `network.client` for WebAssembly. Direct sockets are absent; outbound HTTPS
  goes through the host broker instead: declare `network.brokered` plus explicit
  `networkGrants`, and call `ExtensionHostClient.brokeredFetch`.
- A distributable WebAssembly package must retain a rebuildable Swift project. Threading checks
  for `Package.swift` and at least one `.swift` file under `Sources/` without compiling it.
- The packager copies that project under `Source/` and omits `.build`, `.git`, `.swiftpm`,
  `DerivedData`, and `.DS_Store`. Do not put required source in those locations.
- Localization resources are flat JSON objects mapping the readable base-language string to
  its translation. Threading negotiates `localizations` against the user's preferred languages,
  applies the selected table to host-rendered manifest Settings and runtime contributions, and
  passes that same table to the process. Missing keys fall back to the base string. Translations
  must preserve every printf placeholder (`%@`, `%lld`, and so on) in the same order as the key;
  package inspection rejects a catalogue that would make dynamic formatting unsafe.

For dynamic copy, construct `ExtensionLocalizer` before registration:

```swift
let localizer = ExtensionLocalizer()
let title = localizer.string("Open Build")
let receipt = localizer.format("Opened build %@", buildNumber)
```

`localizer.localeIdentifier`, `preferredLanguages`, and `selectedLanguage` are available when
formatting dates, numbers, or language-sensitive data. Do not inspect the parent process
environment directly; these values and the selected bounded string table are the complete
presentation context.

## Advanced companions

Use a companion only when the extension genuinely needs macOS work that the WebAssembly core
cannot perform. The companion is a separately signed, sandboxed `.app`; it does not replace the
core and does not receive the core's Threading host-data authority.

```json
{
  "runtime": "webAssembly",
  "capabilities": ["companions.invoke"],
  "companions": [
    {
      "id": "worker",
      "platform": "macOS",
      "bundlePath": "Companions/Worker.app",
      "activation": "onDemand",
      "capabilities": [
        "process.spawn",
        "screen.capture",
        "input.control",
        "ui.remote-surfaces"
      ],
      "operations": [
        {
          "id": "device-status",
          "title": "Device Status",
          "description": "Returns the current simulator device state.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "device": { "type": "string" }
            }
          },
          "outputSchema": {
            "type": "object",
            "properties": {
              "state": { "type": "string" }
            }
          }
        }
      ],
      "surfaces": [
        {
          "id": "device",
          "title": "Device",
          "accessibilityLabel": "Live simulated device display",
          "maximumWidth": 1280,
          "maximumHeight": 800,
          "acceptsPointer": true,
          "acceptsKeyboard": true
        }
      ]
    }
  ]
}
```

Rules:

- Request each OS-facing capability explicitly. There is no `advanced.full-access`.
- Prefer `onDemand`; `whileExtensionEnabled` is additional background authority shown during
  install and update review.
- The app bundle identifier is derived as
  `<extension-identifier>.companion.<companion-id>` and must match its code-signing identifier.
- Sign with the hardened runtime and App Sandbox. Network, user-selected-file, and Apple Events
  entitlements must exactly match the declared capabilities; unknown sandbox entitlements are
  rejected.
- Treat App Sandbox authority and interactive macOS privacy grants as separate layers. The
  signed companion owns its sandbox entitlements, but macOS attributes Screen Recording and
  Accessibility to Threading while Threading directly supervises it. Threading's capability-gated
  permission broker requests those grants before spawn. The companion should still preflight
  the grant and fail with an actionable diagnostic if it disappears; it should not attempt to
  manufacture its own prompt.
- Supply one built `.app` for every declared companion when assembling the package. The
  packager refuses missing workers and undeclared extras, copies each app to its exact
  `bundlePath`, then re-runs signature, hardened-runtime, sandbox, identity, and entitlement
  inspection on the staged package.
- Continue declaring commands, settings, MCP tools, host-data reads, storage, services, and UI
  contributions on the WebAssembly core. Companion capabilities never imply them.
- Declare every callable worker operation in that companion's `operations` array and add
  `companions.invoke` to the core capabilities. From the core, call it through
  `ExtensionHostClient.callCompanion`; never invent a socket, shared token, or arbitrary command
  relay.
- On launch, write one `ExtensionCompanionHello` JSON value followed by a newline to stdout.
  Copy the companion ID and generation from `ExtensionCompanionEnvironment`; Threading refuses a
  mismatched or stale generation.
- Keep stdout reserved for the versioned control protocol. Read newline-delimited
  `ExtensionCompanionOperationRequest` values from stdin and answer each with exactly one
  `ExtensionCompanionOperationResponse` carrying the same request ID, generation, and operation
  ID. Also accept `ExtensionCompanionHostMessage` and exit on `.shutdown`.
- The host supervises startup, crashes, disable/reload, on-demand activation, operation timeouts,
  correlation, capability-scoped OS prompting, and remote-surface teardown. The companion
  receives no Wasm host bearer, broker descriptor, undeclared host snapshots, or storage paths.

### Companion remote surfaces

A remote surface is pixels from a companion inside a Threading-owned view, not an AppKit object
owned by the extension. Declare it in `companions[].surfaces`, request `ui.remote-surfaces` on
that companion, and let the WebAssembly core reference it from an ordinary panel registration:

```swift
ExtensionPanel(
    id: "device",
    title: "Device",
    root: .status("Device display unavailable", role: .neutral),
    remoteSurface: .init(companionID: "worker", surfaceID: "device")
)
```

`root` is required. Threading uses it immediately while loading and as the accessible/unavailable
fallback if the companion cannot supply pixels.

When a declared surface is needed, the companion receives
`THREADING_COMPANION_SURFACE_FD`. Interpret its value as an inherited full-duplex file descriptor
and use `ExtensionRemoteSurfaceWire.read`/`write` with a `FileHandle`. The host sends:

- `.open` once per presentation, with a host-generated presentation ID, the declared surface ID,
  viewport, visibility, and the panel's optional project/session IDs;
- `.viewport` whenever size, backing scale, or visibility changes;
- normalized top-left-origin `.input` values only for the input kinds the surface declared;
- `.acknowledgement` after every accepted or dropped frame; and
- `.close` when that presentation goes away.

The companion sends only `.frame` packets. Frames are premultiplied BGRA8, must fit both the
surface's declared dimensions and the 32 MiB packet limit, and must use a strictly increasing
sequence per presentation. There may be only one unacknowledged frame per presentation. Wait for
its acknowledgement before reusing that presentation's buffer budget; stop rendering while
`isVisible` is false. One declared surface may have several simultaneous presentation IDs, so
keep state per presentation rather than per surface.

The socket is the authority and is inherited only by that supervised generation. Disable,
reload, update, core failure, companion failure, and panel close tear it down. Never pass view,
layer, Metal, IOSurface, accessibility, or system-event objects across this boundary.

See `Packages/ThreadingExtensionKit/Examples/SimulatorRelayExtension` for a complete source-bundled
reference. It uses no Simulator-specific host API: the core declares a panel and the companion
composes generic process launch, window capture, normalized input, and remote frames.

Core-side call:

```swift
let result = try await ExtensionHostClient().callCompanion(
    "worker",
    operation: "device-status",
    arguments: .object(["device": .string("iPhone 18")])
)
```

## Data migrations

At process startup read:

```swift
let migration = ExtensionDataMigrationContext()
if migration.isRequired {
    // Apply every step from migration.previousVersion to migration.targetVersion.
    // Use atomic KV mutations and make each step safe to repeat.
}
```

Run migration before writing the registration line. Threading records `targetVersion` only after
registration succeeds. A crash, timeout, invalid registration, or rejected startup leaves the
old committed value and the transition is presented again on the next launch. Migrations must
therefore be idempotent. The host refuses a package or stored-state launch that would decrease
`dataVersion`.

Settings, KV, cache, and secrets keep their existing public APIs; `dataVersion` says how your
extension interprets them, not how Threading's own files are encoded.

## Provenance and removal

Threading records local import provenance outside the immutable package: source filename, package
SHA-256, SDK version when present, and install/update timestamps. It is shown as **local import,
unsigned**. This is identity/integrity information only; it never grants capabilities or
weakens the WebAssembly boundary.

On update, package, settings, KV, cache, secrets, and the committed `dataVersion` are retained.
On Remove:

- package, settings, KV, cache, committed data version, and provenance move under `Removed/`;
- Keychain secrets remain in their identifier namespace so an intentional reinstall can reuse
  credentials;
- a reinstall does not silently restore the filesystem state from `Removed/`.

If secrets should not survive removal, delete them through `ExtensionSecrets` before uninstall.
Deleting a recovery directory later deletes only what is in that directory, never Keychain
items.
- Declare `commands` before registering commands.
- Declare `panels` before registering panels.
- Declare `mcp.tools` and static `mcpTools` metadata before registering MCP tools.
- Declare `settings` before adding a static `settings` form to the manifest.
- Declare `services.provide` and static `services` metadata before registering services.
- Declare `services.consume` and every exact `serviceDependencies` authority before calling
  another extension.
- Declare `ui.components` before constructing `ExtensionHostClient` or publishing component
  patches.
- Declare `ui.workspace-navigation` before registering workspace navigators. This capability
  grants no project or session data by itself; request the applicable host-read capabilities
  separately.
- Declare `host.projects.read` before calling `projects()` or `project(id:)`.
- Declare `host.project.files.read` before calling `projectFiles(_:)`. It is **not** implied by
  `host.projects.read`: that authority returns a sanitized snapshot with no filesystem in it, and
  this one returns names, project-relative paths, byte sizes and modification dates. The answer
  carries opaque handles, never bytes and never an absolute path; a handle is only usable by
  naming it as an `ExtensionMediaSource.fileHandle` for a host renderer to resolve.
- Declare `ui.media-documents` before putting a `media` node in any contribution. The surface must
  also admit it — `allowsMedia` is false in every published contract unless its constraints say
  otherwise.
- Declare `attachments.preview` before answering an `ExtensionAttachmentPreviewRequest`, and
  `attachments.file-types` before registering `previewableFileTypes`. A registration may not claim
  an extension Threading already classifies (`json`, `png`, `pdf`, `html`, `zip`, …).
- Declare `host.sessions.read` before calling `sessions()` or `session(id:)`.
- Declare `host.sessions.runtime.read` before calling `sessionRuntime(id:)`. Pass only a stable
  session ID received from host context or a session snapshot. The result is already filtered
  to that session's agent/shell roots; there is no arbitrary PID or process-table operation.
- Declare `host.repositories.read` in addition to `host.projects.read` only when repository
  host/path, branch, or HEAD revision is needed.
- Declare `host.events` before calling `events(after:limit:)`.
- Declare `storage.kv` before constructing `ExtensionKeyValueStore`.
- Declare `storage.cache` before using `ExtensionCacheStore`.
- Declare `storage.secrets` before using any `ExtensionHostClient` secret method.
- Declare `network.brokered` **and** a `networkGrants` entry for every origin before calling
  `ExtensionHostClient.brokeredFetch`. Grants are exact https hosts with `GET`/`HEAD` only;
  the install dialog shows the user that exact list. A grant may name a credential provider
  the host knows (`"github"`), in which case Threading attaches the user's best connected
  credential itself and the response reports which tier answered — the extension never
  receives a token. Do not combine a credentialed grant with a companion holding
  `network.client`; inspection refuses the pairing.
- Do not declare `network.client` for a safe WebAssembly v1 extension. It is reserved in the
  legacy native vocabulary; brokered fetches replace it.
- Unknown capabilities are not permission.
- Use contribution identifiers beginning with a lowercase letter and containing only lowercase
  letters, digits, `-`, or `.`.

### Choose a contribution form

There is no manifest `type` field. Select capabilities by the surfaces the extension contributes:

- `commands` for user-triggered actions;
- `panels` for semantic UI rendered by Threading;
- `mcp.tools` for tools callable by Claude or Codex;
- `settings` for complete Settings pages or sections appended to built-in pages;
- `services.provide` for versioned JSON APIs consumed by other extensions;
- `ui.components` for safe property, slot, or content patches to documented host components;
- `ui.workspace-navigation` for a user-selectable complete leading-navigator interior;
- any combination for a hybrid sharing one process and state model.

Threading derives `ExtensionManifest.profile` and `contributionKinds` from that set. Do not add an
extra type discriminator to generated manifests, and do not request a capability merely because
another example does. An MCP-only extension should not register an empty panel; a panel-only
extension should not declare `mcp.tools`.

Panel registration is bounded to 32 panels. Each semantic tree is limited to 24 levels, 500
nodes, 1,000 aggregate rendered elements, and 10,000 characters per text value; titles are
non-empty and at most 120 characters.
Use valid contribution identifiers for every button, input, and picker and for every scene mark
action so its returned action can pass the same wire validation. A panel accepts at most 100
options per picker and 500 marks per scene. Every text input and picker also requires a localized
`accessibilityLabel`; a placeholder or selected option is not an accessible field name.

Workspace navigator registration is bounded to eight contributions. Read
[`WORKSPACE_NAVIGATORS.md`](WORKSPACE_NAVIGATORS.md) before authoring one. Navigator collection
items are snapshots with stable IDs and bounded row content, not eagerly nested stacks. The
user chooses a live contribution under **View → Navigator**. Threading virtualizes its rows,
routes project/session destinations through the native navigation coordinator, and returns to
Native if the owning process generation stops or its document cannot be rendered.

For a context-dependent panel, set `loadActionID`. Treat `root` as the immediate loading and
fallback state. Threading sends that action once when the tab connects to each extension process
generation, using the same opaque project/session context as a button. Return a replacement
panel with the same panel ID. Keep `loadActionID` on replacement values for clarity; the host
tracks the generation and will not recursively invoke it. Make the load action idempotent
because reload and crash recovery intentionally run it again.

The semantic `root` is also the portable panel contract for a paired iPhone. A notification can
deep-link to the panel; the extension keeps running on the Mac, iPhone renders the same validated
tree with native controls, and input, picker, button, and scene actions return to the owning Mac
process generation. Use package `extensionResource` images when the semantic panel needs imagery;
the host serves only validated package-relative resources. A companion `remoteSurface` is not
pixel-streamed to iPhone, so make `root` useful rather than a placeholder. An isolated
`customSurface` remains Mac-only and gets an explicit unavailable state on iPhone.

A context-dependent workspace navigator uses the same pattern: set its `loadActionID`, handle
`ExtensionWorkspaceNavigatorActionRequest`, and return an
`ExtensionWorkspaceNavigatorActionResponse` naming the same `navigatorID`. Navigator refreshes
also run after project-store changes, so keep the load action cheap and idempotent. Returned
navigators are complete atomic snapshots; retain stable collection and item IDs so the host can
restore selection, expansion, scroll position, and focus. Collection `.action` activations carry
the item ID as `value`; semantic inputs carry their native string or choice value. Every
actionable grid item requires a localized `accessibilityLabel`, because the complete cell is its
host-owned activation surface.

## Required package policy

The executable target must use `ThreadingExtensionPolicyPlugin`. Do not remove it to make a build
pass.

```swift
.executableTarget(
    name: "MyExtension",
    dependencies: [
        .product(
            name: "ThreadingExtensionKit",
            package: "ThreadingExtensionKit"
        )
    ],
    plugins: [
        .plugin(
            name: "ThreadingExtensionPolicyPlugin",
            package: "ThreadingExtensionKit"
        )
    ]
)
```

## Forbidden in a safe extension

Do not:

- import AppKit;
- import SwiftUI;
- construct `NSView`, `NSViewController`, `View`, or platform controls;
- access Threading application internals;
- assume a theme colour, font, size, radius, or animation duration in *node UI* — panels and
  component patches describe meaning and the host chooses pixels. Stating appearance is done
  through the sanctioned data plane instead: an `appearance.themes` document or an
  `appearance.fonts` file, which the host validates and applies on its own terms;
- encode raw HTML as a substitute for an unsupported UI node;
- add a capability merely to silence validation;
- remove validation or the policy plugin.

If a requested interface cannot be expressed, report the missing semantic component. That is
an SDK design input, not permission to bypass the host renderer.

## Giving a theme its own app icon

A theme declared under `appearance.themes` may name an `iconMark` beside its `resource`:

```json
"themes": [
  { "id": "storm", "resource": "themes/storm.json", "iconMark": "icons/storm.png" }
]
```

While that theme is the selected app theme, Threading's Dock icon and its ⌘-Tab entry wear that
mark. Four rules, and the first is the one that decides the shape of your asset:

- **Ship a mark, not an icon.** The host draws the plate from your theme's own `ground` role and
  composites your artwork on top, so one asset serves both light and dark. A PNG whose edges are
  opaque is a *tile*, and the package is **refused at inspection** — before it can be enabled,
  with an error naming the file. This is not a style preference: the plate stays the host's so
  that no extension can make Threading's icon look like a different application's.
- **Transparent background, square canvas, up to 1024².** Anything larger is downsampled rather
  than refused. Aspect ratio is preserved and the mark is inset from the plate's edge, so do not
  add your own margin on top.
- **Your mark keeps its own colours.** The host does not tint it. You authored the theme and the
  mark together, so the pairing is yours to get right — check it against your theme's `ground`
  in both variants if your theme is adaptive.
- **It is optional, and the fallback is good.** A theme with no `iconMark` gets Threading's own
  mark drawn in your theme's `accent` on your `ground`, with your `material.glow` behind it —
  the same treatment every built-in style gets. Declare a mark only when your theme's identity is
  genuinely a *different glyph*, not merely different colours.

`Examples/StormThemeExtension` is a complete, minimal package doing exactly this — manifest,
theme document, and a mark drawn by a committed script so the asset is reviewable rather than an
opaque binary. It is also the smallest possible `appearance.themes` extension: its executable
does nothing, because themes and marks are data the host reads at inspection.

macOS only. iOS cannot generate or supply an app icon at runtime, so the phone app is unaffected
by any theme, contributed or built in.

## Dressing the sidebar from a theme

A theme document may give any variant a `sidebar` block — a gradient and/or image behind the
project list, a custom logo in place of the Threading mark, and the wordmark's text, family,
size and weight. Nothing new appears in the manifest: the block is part of the same app-theme
vocabulary your `resource` document already speaks, so it travels with the theme.

```json
"variants": {
  "dark": {
    "roles": { "...": "..." },
    "sidebar": {
      "background": {
        "gradient": { "angleDegrees": 165, "stops": [
          { "color": "#0B1020", "position": 0 },
          { "color": "#1A2340", "position": 1 }
        ]},
        "image": { "asset": "art/rain.png", "mode": "tile", "opacity": 0.35 }
      },
      "brand": {
        "logo": { "asset": "art/storm-logo.png" },
        "title": { "text": "Storm", "fontFamily": "Avenir Next", "weight": "semibold" }
      }
    }
  }
}
```

Asset values are package-relative paths; the host reads and normalises every referenced image
at inspection, before your code runs, and a missing or unreadable file fails the whole package
so you see it. Gradient stops must keep the theme's `label` readable at 3:1 — the sidebar is
where the user finds every session. Image legibility is yours: check a background against your
rows in both variants, and wash photographs well below 0.4 opacity. Everything is optional;
state only what your theme's identity actually claims.

## Theme data reloads live

While your extension is enabled, the host watches its package and re-reads your theme
documents (and the images they reference) whenever they change on disk — through the same
validation as install. Two things this makes possible:

- **Iterating.** Edit your theme JSON with Threading open and wearing it; the window follows
  each save. A half-saved or invalid document is skipped and the last good version stays in
  force, so a broken save never costs you your theme — check the host log if an edit refuses
  to land.
- **A chrome that follows something.** Your executable may rewrite the theme documents in its
  own package — a palette tracking the weather, the time of day, a build's state. Write the
  whole document atomically (write-then-rename), keep every variant valid, and change it at a
  human pace: each accepted write repaints the app, and nobody wants their window strobing.

Only theme *data* reloads this way. A manifest change — new capabilities, new contributions —
is still an update, with the re-disclosure an update owes.

## Registering commands

Register user-triggered work as an `ExtensionCommand`, not as a menu item or a keyboard event
monitor:

```swift
let command = ExtensionCommand(
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

let registration = ExtensionRegistration(commands: [command])
```

Choose `.application`, `.project`, or `.session` from the minimum context the command needs.
The stable placements are `.extensions` for Threading's top-level Extensions menu, `.project`
or `.view` for a host-owned Extensions group at the end of those existing menus, and
`.sessionRow` or `.projectRow` for a host-owned Extensions group in a sidebar row's actions
and context menus. A command may name several placements. The first declared placement is
canonical and owns the displayed key equivalent among the menu-bar placements; row menus never
display key equivalents, and a row invocation's context carries *that row's* session or
project rather than the current selection. A session-scoped command cannot declare
`.projectRow` — a project row names no session to supply. The other copies invoke the same
command without duplicating shortcut dispatch. An empty placement array makes a command
shortcut-only after the user binds it in Keyboard settings.

The default shortcut is only a suggestion. It needs command, control, or option; Threading
suppresses it on a conflict and lets the user resolve bindings globally. Never listen for keys
inside the extension.

Commands default to `risk: .ordinary`. Mark a command `risk: .destructive` if it can make a
change that is difficult or impossible to undo. Threading will present its own confirmation before
the request reaches the extension, for both menu and shortcut invocation. Do not try to encode
confirmation instructions in `description`: extensions cannot choose alert copy, buttons,
keyboard defaults, or the user's decision.

## Contributing Settings

Settings UI is static manifest metadata, not a runtime view. Use
`ExtensionSettingsContribution` with complete pages, host-page sections, or both:

```swift
let settings = ExtensionSettingsContribution(
    pages: [
        ExtensionSettingsPage(
            id: "presentation",
            title: "Presentation",
            symbol: "lightbulb",
            sections: [
                ExtensionSettingsSection(
                    id: "status",
                    fields: [
                        ExtensionSettingField(
                            id: "show-status",
                            title: "Show status",
                            control: .toggle(defaultValue: true)
                        ),
                        ExtensionSettingField(
                            id: "tone",
                            title: "Tone",
                            control: .choice(
                                defaultValue: "positive",
                                options: [
                                    .init(id: "positive", title: "Positive"),
                                    .init(id: "warning", title: "Warning")
                                ]
                            )
                        )
                    ]
                )
            ]
        )
    ],
    sections: [
        ExtensionHostSettingsSection(
            id: "startup",
            page: .general,
            title: "Startup",
            fields: [
                ExtensionSettingField(
                    id: "refresh-on-start",
                    title: "Refresh on launch",
                    control: .toggle(defaultValue: false)
                )
            ]
        )
    ]
)
```

The supported controls are `.toggle`, bounded `.text`, enumerated `.choice`, and stepped
`.integer`. Field IDs must be unique across every page and host section in the extension.
Page and section IDs must also be stable: changing one creates a different contribution.

Use only `ExtensionHostSettingsPage` values when appending to a built-in page. The stable IDs
are `general`, `accounts`, `profiles`, `themes`, `motion`, `extensions`, `tools`, `keyboard`,
`usage`, `storage`, and `archived`. Threading appends contributed sections after native sections.
Do not depend on order among different extensions.

At process start:

```swift
var values = settings.effectiveValues(
    overriding: try ExtensionSettingsEnvironment.values()
)
```

Decode `ExtensionSettingsUpdateRequest` before other requests in the serve loop, validate it
with `validate(against:)`, merge its `values`, apply the new behavior, and return exactly one
`ExtensionSettingsUpdateResponse` echoing the `requestID` and sorted changed `settingIDs`.
Threading rolls the UI and persisted value back when the process returns an error or the request
fails. Settings values belong to the user and remain inaccessible as files; use `storage.kv`
for extension-owned state instead.

## Constructing UI

Return meaning through `ExtensionNode`:

```swift
let root = ExtensionNode.stack(
    axis: .vertical,
    spacing: .medium,
    children: [
        .text("Deployment", role: .heading),
        .status("Ready", role: .positive),
        .button(
            id: "deploy",
            title: "Deploy",
            role: .primary,
            isEnabled: true
        )
    ]
)
```

Threading decides how heading text, positive status, primary actions, spacing, focus,
accessibility, and live theme changes render.

For editable values, single choices, and broad native visualizations, use `.textInput`,
`.picker`, and `.scene`. Their interactions use the same action request as a button, with the
field value, stable option value, or activated scene-item ID in `ExtensionActionRequest.value`.
The scene is generic normalized geometry rather than a chart or domain-specific widget, so it can
express treemaps, heatmaps, bars, timelines, scatter plots, and bubbles without requiring one host
view per extension idea. See [`DECLARATIVE_UI.md`](DECLARATIVE_UI.md) for the complete contract,
examples, limits, and architecture diagram.

When those marks form one nested map, declare
`hierarchy: ExtensionSceneHierarchy(rootID: "...")` and give every non-root item a `parentID`.
Threading owns branch zoom, breadcrumbs, keyboard and accessibility navigation on Mac and iPhone;
leaf `actionID` values still return to the extension. All marks remain inside the same 500-mark
scene budget. Circular hierarchy marks are a true packing: child circles stay inside their parent
and sibling circles do not intersect. Flat scenes may still overlap marks for scatter and bubble
plots.

These richer nodes are available in full panels. Compact component surfaces disallow them unless
their published constraint vocabulary explicitly opts in. Read the contract rather than assuming
that a node legal in a panel is legal in a sidebar row, toolbar, or annotation.

### A document that varies over time

`.media` is the only node whose pixels move on their own, and **Threading draws all of them**. The
extension states which document, whether it is playing, how fast and how it loops; the host carries
the decoder, the clock, the transport, the ceilings, the theme, the accessibility and the
pasteboard, and answers with a coalesced `ExtensionMediaStateReport` on `stateActionID`.

```swift
.media(ExtensionMediaDocument(
    id: "hero",                              // stable id: playback survives a panel replacement
    source: .fileHandle(handle.id),          // opaque; never a path, never bytes
    format: .lottie,
    playback: ExtensionMediaPlayback(isPlaying: true, loop: .loop, speed: 1),
    allowsFrameCopy: true,                   // the host owns the pasteboard action
    accessibilityLabel: "Hero animation",
    stateActionID: "playback-state"
))
```

Three rules worth internalizing:

- **Keep `id` stable.** Replacing the panel to update a label must not restart the animation; a
  changed id is what resets it.
- **Do not draw a scrubber.** `transport: .hostOwned` gives you one. A scrubber made of extension
  nodes would be a display-rate callback over a JSONL round trip.
- **Reports are coalesced.** `ready`, `completed`, `failed`, play/pause and scrub end — never per
  frame. Read them with `ExtensionMediaStateReport(actionValue:)`.

`Examples/LottieViewerExtension` is the reference: it enumerates a project's animations as handles,
plays one, and offers a preview body for a Lottie an attachment carries.

### A summary with a second level

Compact surfaces have room for one reading. When there is more behind it — seven check runs
behind "3 pending checks" — say so with `disclosure` rather than trying to fit the list into the
row or dropping the detail entirely:

```swift
.disclosure(
    id: "ci-checks",
    summary: .stack(
        axis: .horizontal,
        spacing: .small,
        children: [
            .text("Checks", role: .compactDetail),
            .flexibleSpacer,
            .status("3 pending", role: .warning)
        ]
    ),
    detail: [
        .stack(
            axis: .horizontal,
            spacing: .small,
            children: [
                .text("build-ananke", role: .compactBody),
                .flexibleSpacer,
                .status("Running", role: .warning)
            ]
        ),
        .divider,
        .button(id: "open-checks", title: "Open on GitHub", role: .standard, isEnabled: true)
    ]
)
```

You state *what* is behind the summary. Threading owns the reveal itself — the dwell before it
opens, the surface it opens on, where that surface goes, how far it grows before it scrolls, and
what closes it. There is no way to ask for a placement, an animation, or an open state, and no
event is delivered when a reader opens one.

The two levels have **separate vocabularies**, and the second one is usually wider: a contract
that forbids buttons in its compact row may still allow them behind a disclosure, because a
control on a surface the reader just opened fights nothing. Read the vocabulary from the
contract rather than assuming — `disclosureDetail` in the component catalogue is the machine-
readable answer, and `nil` there means summaries on that surface have no second level at all.
The revealed level has a node budget of its own; it is a reading, not a page.

## Providing and consuming services

Providers declare and register the exact same definition:

```swift
let statusService = ExtensionServiceDefinition(
    id: "status",
    version: 1,
    title: "Status",
    description: "Returns the provider's current status.",
    outputSchema: .object(["type": .string("object")])
)

let manifest = ExtensionManifest(
    identifier: "com.example.provider",
    name: "Provider",
    version: "1.0.0",
    executable: "bin/provider",
    capabilities: [.servicesProvide],
    services: [statusService]
)
let registration = ExtensionRegistration(services: [statusService])
```

Decode `ExtensionServiceRequest` before general action requests. Validate it, dispatch by both
`serviceID` and `serviceVersion`, and return one `ExtensionServiceResponse` echoing all three
correlation fields. The `callerExtensionIdentifier` was derived from Threading's bearer token and
is safe to use for provider policy; do not accept a caller ID through service arguments.

Consumers declare an exact dependency:

```swift
let dependency = ExtensionServiceDependency(
    providerIdentifier: "com.example.provider",
    serviceID: "status",
    version: 1,
    required: true
)

let value = try await ExtensionHostClient().callService(
    providerIdentifier: dependency.providerIdentifier,
    serviceID: dependency.serviceID,
    version: dependency.version
)
```

`required` produces a stronger unavailable warning in Extensions settings but deliberately does
not block process startup; extensions can start in any order and providers can be reloaded.
Handle `ExtensionHostClientError.rejected` as a normal unavailable/provider error. Never read
another extension's package or storage, and never create a second loopback protocol.

## Process protocol

Threading supports two executable modes:

- `--threading-register` writes one JSON-encoded `ExtensionRegistration` line and exits. Keep
  this mode for validation and diagnostics.
- `--threading-serve` writes the same registration as its first line, stays alive, reads
  `ExtensionSettingsUpdateRequest`, `ExtensionServiceRequest`, `ExtensionCommandRequest`,
  `ExtensionActionRequest`, `ExtensionComponentActionRequest`,
  `ExtensionWorkspaceNavigatorActionRequest`, or `ExtensionMCPToolRequest` lines from stdin,
  and writes the corresponding correlated response to stdout.

The persistent sequence is:

1. Threading reads and validates `threading-extension.json` without running code.
2. Threading starts the declared executable with `--threading-serve`.
3. The extension writes one compact `ExtensionRegistration` JSON line.
4. For a selected menu item or resolved shortcut, Threading writes an
   `ExtensionCommandRequest`. The extension returns one `ExtensionCommandResponse` echoing its
   `requestID` and `commandID`.
5. When a registered panel has `loadActionID`, Threading writes one
   `ExtensionActionRequest` as the tab connects to each process generation. A rendered button,
   text input, picker, or interactive scene mark uses the same request type. Value controls and
   marks include their correlated semantic value in the optional `value` field.
6. The extension copies its `requestID` into exactly one `ExtensionActionResponse`.
7. A returned panel must have the same ID as the panel that raised the action. Threading validates
   the value and renders it through its own controls.
8. A selected navigator's load action, semantic control, or collection action produces an
   `ExtensionWorkspaceNavigatorActionRequest`. Return one
   `ExtensionWorkspaceNavigatorActionResponse` with the same request ID and navigator ID.
9. For a contributed MCP tool, Threading writes an `ExtensionMCPToolRequest`; the extension copies
   its `requestID` into one `ExtensionMCPToolResponse`.
10. For a user settings change, Threading writes an `ExtensionSettingsUpdateRequest`; the extension
   applies it and returns one `ExtensionSettingsUpdateResponse` with the same `requestID`.
11. For a brokered call, Threading writes an `ExtensionServiceRequest` to the declared provider;
    it returns one `ExtensionServiceResponse` matching request ID, service ID, and version.

Component state does not share that sequential stream. A process with `ui.components` receives
`THREADING_EXTENSION_HOST_TOKEN` plus **either** `THREADING_EXTENSION_HOST_FD` (an inherited socket)
or `THREADING_EXTENSION_HOST_URL` (a loopback port), and can construct:

```swift
let host = try ExtensionHostClient()
try await host.publishComponentPatches([
    ExtensionComponentPatch(
        id: "ci-session-status",
        target: .init(
            component: "sidebar.session-row",
            contractVersion: 1,
            entityID: sessionID
        ),
        slots: [
            .init(
                slot: "after-title",
                children: [.status("Passed", role: .positive)]
            )
        ]
    )
])
```

Each call is a complete atomic publication. It replaces every patch from the current process
generation; pass an empty array to clear them. Threading validates the entire publication before
changing visible state. Do not cache or share the host token. It is revoked on disable, reload,
crash, uninstall, and app shutdown.

### Brokered network fetches

Declare the capability and every origin, then fetch through the client:

```json
"capabilities": ["network.brokered"],
"networkGrants": [
  { "host": "api.github.com", "methods": ["GET"], "credential": "github" }
]
```

```swift
let response = try await ExtensionHostClient().brokeredFetch(
    ExtensionBrokeredFetchRequest(
        method: "GET",
        url: "https://api.github.com/repos/owner/name/commits/abc/check-runs",
        headers: ["Accept": "application/vnd.github+json"]
    )
)
// response.status is GitHub's own answer — a 404 is data, not an error.
// response.credentialTier says which credential served it; hint "connect GitHub in
// Threading's Settings" only when it is .anonymous.
```

A completed HTTP exchange always returns, whatever its status; interpreting statuses is the
extension's business. `ExtensionBrokeredFetchFailure` is thrown only for transport failure,
and `ExtensionHostClientError.rejected` means the request fell outside the declared grants.
Responses are capped at 4 MiB; `Authorization`, `Cookie`, and `Host` request headers belong
to the broker and are refused. HTTPS redirects are followed only when they keep the exact
approved host, method, and no-port/no-user-info shape. A redirect outside that authority returns
its original 3xx and `Location`; submit the target as a new brokered request so its grant is
checked independently. `response.finalURL` names the URL that actually answered after any
same-host redirects (and is optional when decoding a response from an older host).

### Reading host snapshots and events

Use the same `ExtensionHostClient`; each operation is independently capability-gated:

```swift
let host = try ExtensionHostClient()
let initial = try await host.sessions()

for session in initial.sessions {
    // Use session.id as an entityID in a documented component target.
}

var cursor = initial.cursor
while !Task.isCancelled {
    let page = try await host.events(after: cursor)
    for event in page.events where event.kind == .sessionChanged {
        let latest = try await host.session(id: event.entityID)
        // Recompute and atomically publish the complete patch set.
        _ = latest.session
    }
    cursor = page.nextCursor
    if !page.hasMore {
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
}
```

Always take an initial snapshot and begin events at the cursor returned with it. This makes
snapshot-plus-events race-free. When the client receives HTTP 410, its cursor fell outside the
bounded journal: discard derived host state, request fresh snapshots, and resume from their
cursor.

Project snapshots contain only opaque ID and display name. `repository` is omitted unless both
`host.projects.read` and `host.repositories.read` are granted; even then it contains only a
sanitized remote host/repository path, branch, and HEAD revision. Session snapshots contain
opaque IDs, provider/account IDs, display title, activity, branch, side-chat/archive flags, and
surface mode. Folder paths, git directories, complete remote URLs, credentials, prompts,
transcript IDs/paths, and login email are never returned.

### Resolving provider and account images

Primitive identity extensions use two independent contribution/read pairs:

```text
appearance.provider-icons       + host.providers.read
appearance.account-icons        + host.accounts.presentation.read
```

Read the safe snapshots, then atomically publish image recipes:

```swift
let providers = try await host.providers()
let accounts = try await host.accounts()

try await host.publishIdentityResolutions(
    providerIcons: providers.providers.map {
        ExtensionProviderIconResolution(
            providerID: $0.id,
            image: $0.id == "codex" ? .systemSymbol("terminal.fill") : $0.image
        )
    },
    accountIcons: accounts.accounts.compactMap {
        guard !$0.hasUserSelectedImage else { return nil }
        return ExtensionAccountIconResolution(
            accountID: $0.id,
            image: $0.image ?? .systemSymbol("person.crop.circle.fill")
        )
    }
)
```

An image may be a host asset returned in the snapshot, a safe package-relative resource, or a
system symbol. Raw paths and `NSImage` never cross the process boundary. Publications replace
the generation's previous primitive results atomically and are revoked with its token.

Threading applies provider resolver → built-in provider mark. Account precedence is stricter:
the user's explicit emoji, then the selected resolver, then the discovered/generated built-in
chip. Side-chat lineage remains host-owned. Invalid, missing, or undecodable images fall back
without leaving an empty icon.

### Composing the complete session identity

Declare `appearance.session-identity` to replace only the provider/account subtree. Read
`host.sessions.read` when the layout depends on account presence, side-chat lineage, or activity.
Publish through the same component patch endpoint used by `ui.components`; the narrower
capability may target only `sidebar.session-identity`.

```swift
let sessions = try await host.sessions()
let patches = sessions.sessions.map { session in
    var children: [ExtensionNode] = [
        .image(
            ExtensionSessionIdentityAsset.providerImage,
            role: .identity,
            accessibilityLabel: session.isSideChat ? "Side chat" : "Provider"
        )
    ]
    if session.accountID != nil {
        children.append(.image(
            ExtensionSessionIdentityAsset.accountImage,
            role: .icon,
            accessibilityLabel: "Account"
        ))
    }
    return ExtensionComponentPatch(
        id: "identity-\(session.id)",
        target: .sessionIdentity(sessionID: session.id),
        replacement: .stack(
            axis: .horizontal,
            spacing: .tight,
            children: children
        )
    )
}
try await host.publishComponentPatches(patches)
```

The contextual assets are already resolved. The provider image includes the selected primitive
resolver or native fallback, and becomes Threading's fork mark for a side chat. The account image
preserves explicit user-image precedence above primitive resolvers and native fallback. The
identity contract accepts only a compact horizontal tree of images and fixed spacing. Threading
retains the title, status, actions, selection, accessibility shell, dormant opacity, conflict
selection, and atomic native fallback.

### Wrapping a public component

Declare `ui.components` and target only a catalogue contract whose `hookConstraints` are
present. A hook is a semantic around hook, not a hierarchy patch. Its tree must contain the
number of `.proceed` nodes required by that contract; `application.main-window@1` requires
exactly one.

```swift
let hook = ExtensionComponentPatch(
    id: "main-window-wrapper",
    target: .init(component: .applicationMainWindow, contractVersion: 1),
    hook: .stack(
        axis: .horizontal,
        spacing: .none,
        children: [
            .proceed,
            .text("Extension-owned accessory", role: .detail)
        ]
    )
)
try ThreadingComponentCatalog.applicationMainWindow.validate(hook)
try await ExtensionHostClient().publishComponentPatches([hook])
```

`.proceed` is the next enabled hook and ultimately Threading's existing view. Do not assume which
extension is next. The host orders hooks, constructs the chain in memory, and reconnects it when
a process generation disappears. A missing resource or failed renderer skips that hook
atomically.

For a Metal-backed custom surface, also declare `ui.rendering.metal`. Put the `.metal` file under
the development project's `Resources/`; packaging copies it to the immutable package's top-level
`Resources/`. Threading displays a specific GPU-source warning during install. The extension
supplies this function:

```metal
float4 threadingExtensionFragment(
    float2 uv,
    constant ThreadingSurfaceUniforms &uniforms
);
```

The host supplies `ThreadingSurfaceUniforms` with `float2 size`, `float time`, one padding float,
and `float values[8]`. Values use the declaration order in `ExtensionMetalSurface.inputs`;
binding names are documentation and stable source identifiers, not shader reflection. The only
v1 live signal is `active-account.usage-remaining`, a `0...1` fraction with the binding's
fallback used when no active account reading exists. The host owns the `MTKView`, pipeline
wrapper, command queue, fullscreen geometry, transparency, hit testing, frame cadence and
reduced-motion behavior. Shader source is limited to 256 KiB at the actual opened-file read (a
package-size preflight is not trusted) and frame rate to 60 fps.

Use `Packages/ThreadingExtensionKit/Examples/RainWindowExtension` as the complete hook/surface example.
Never import Metal, MetalKit, AppKit or SwiftUI in extension Swift source.

Buttons in a selected full-content replacement arrive as
`ExtensionComponentActionRequest`. Return an `ExtensionActionResponse` with the matching
`requestID`; publish new component state through `ExtensionHostClient` when the action changes
the UI. Component actions cannot return a panel.

Each value must occupy exactly one line. Do not pretty-print protocol JSON. Do not write logs,
progress text, or any other values to stdout; diagnostics go to stderr. Startup and each action
have a three-second timeout, and each protocol line has a one-megabyte limit.

An action response may contain:

- `panel`: replacement semantic state for the originating panel;
- `message`: a short success receipt;
- both `panel` and `message`; or
- `error`: an extension-level failure, with no panel or success message.

Use the SDK's `ExtensionActionRequest` and `ExtensionActionResponse` rather than constructing
wire dictionaries. A panel action's `context` contains the opaque project and session IDs for
the display-pane tab that raised it; those values do not bypass host-data capabilities. Its
optional `value` is the current input string, stable picker value, or activated scene-item ID;
buttons and load actions send no value. Call `validate()` on decoded requests and encoded
responses.

Likewise, decode navigator requests with
`ExtensionWorkspaceNavigatorActionRequest` and answer with
`ExtensionWorkspaceNavigatorActionResponse`. Its optional `navigator` is a complete replacement
document and must keep the originating ID. A navigator response may carry that document, a
success `message`, both, or an `error` by itself.

For a command, decode `ExtensionCommandRequest` before falling back to action requests. The
context contains optional opaque `projectID` and `sessionID` values according to the declared
scope. They do not bypass host-data capabilities. Return `ExtensionCommandResponse` with the
same `requestID` and local `commandID`; use `message` for a short success receipt, `error` for
an extension-level failure, or neither when a component publication is the visible result.

MCP definitions must be present in both the manifest and `ExtensionRegistration`, and the values
must match exactly. Use `ExtensionJSONValue` for schemas and arguments. Tool IDs are local; never
construct the qualified `ext__...` name yourself. MCP responses are plain text and set `isError`
when the tool ran but could not fulfil the request.

The host supplies `THREADING_EXTENSION_PROTOCOL=1` and a minimal environment.
`THREADING_EXTENSION_SETTINGS_JSON` contains the effective declared settings before registration.
`THREADING_EXTENSION_LOCALE`, `THREADING_EXTENSION_PREFERRED_LANGUAGES_JSON`,
`THREADING_EXTENSION_LANGUAGE`, and `THREADING_EXTENSION_LOCALIZED_STRINGS_JSON` carry the
negotiated presentation context; use `ExtensionLocalizer` rather than decoding them by hand.
The two extension host variables exist when any implemented host capability was granted. Do not
depend on Threading's own environment variables or inherited credentials.

The process is sandboxed. It may read its installed package but cannot modify it. Under the
experimental launcher it may write only the private directories granted by `storage.kv` and
`storage.cache`; under the supported runner it has **no writable path at all** and both are
brokered by the host. Write through `ExtensionKeyValueStore` and `ExtensionCacheStore` and the
difference stays Threading's. Host API traffic is restricted to the exact loopback port supplied
by Threading, or to an inherited socket under the runner. Safe WebAssembly v1 has no arbitrary
outbound HTTP/DNS access: do not declare `network.client`. Outbound HTTPS is the bounded
`network.brokered` broker — declared origins, read-only methods, host-attached credentials,
described above. Child-process execution is not part of the
safe-extension contract, so implement work in the extension process or use the host snapshots
instead of launching `git`, shells, or helper binaries.

The executable should be a built native binary. Direct `#!/bin/sh` and `#!/bin/bash` entry
points are accepted for small fixtures, but other script interpreters are rejected because an
extension-controlled shebang must not grant execution of an arbitrary file outside its package.

The host terminates the process when the extension is disabled, reloaded, removed, the app
quits, or a protocol-level failure makes the stream untrustworthy. Do not assume process state
survives an app restart.

## Persistent values and cache

For small durable settings and cached metadata, declare `storage.kv`:

```swift
struct Preferences: Codable {
    var branch: String
    var refreshCount: Int
}

let values = try ExtensionKeyValueStore()
let preferences = try values.value(
    forKey: "project.preferences",
    as: Preferences.self
)
try values.set(
    Preferences(branch: "main", refreshCount: 1),
    forKey: "project.preferences"
)
```

Values may be any `Codable` value or an `ExtensionJSONValue`. Mutations atomically replace one
host-owned `values.json` file. Keys contain 1–512 UTF-8 bytes without control characters; the
store allows at most 2,048 keys and 1 MiB total. Handle quota and decoding errors without
discarding existing state.

For rebuildable files, declare `storage.cache` and use `ExtensionCacheStore`:

```swift
let cache = try ExtensionCacheStore()
if let index = try cache.data(forName: "index.json") {
    // rebuild from it, or ignore it and rebuild from scratch
}
try cache.setData(rebuiltIndex, forName: "index.json")
```

A name is one path component: 1–255 UTF-8 bytes, no `/`, no `.` or `..`, no control
characters. Entries are capped at 4 MiB each and 100 MiB per extension. **A miss is an ordinary
answer, not an error** — treat every entry as disposable, because Threading may reclaim it at any
moment. Do not ask for `ExtensionCache.directoryURL()`: it exists only under the experimental
launcher and reports `unavailable` under the supported runner, which grants an extension no
writable path at all.

Disable and reload retain both kinds of storage; uninstall moves them beside the recoverable
package. Never persist mutable data inside the installed `.threadingextension`.

User-facing extension settings are a separate, host-owned store described above. They do not
require `storage.kv`, and the settings file is never granted to the extension process.
Extension services use the host broker described above and never grant directory access.

For credentials, declare `storage.secrets` and use the broker:

```swift
let host = try ExtensionHostClient()
try await host.setSecret("token-value", forKey: "api-token")
let token = try await host.secret(forKey: "api-token")
let names = try await host.secretKeys() // names only, never a bulk value export
try await host.removeSecret(forKey: "api-token")
```

Opaque-data variants are available for non-UTF-8 values. One extension may own at most 256
names; each value is capped at 64 KiB. The bearer token supplies the namespace, so never place
an extension ID in the key and never send a secret through settings, KV, logs, command responses,
panels, or extension services. A durable large-file directory remains a future capability. Do
not read Threading's internal databases or another extension's directory as a substitute.

## Completion checklist

Before reporting an extension complete:

1. Call `manifest.validate()`.
2. Call `registration.validate(for: manifest)`.
3. For a scaffolded project, run `Scripts/package.sh <swift-wasm-sdk-id>`; this runs the
   policy-checked Wasm build and creates the source-bundled package under `Build/`.
4. Run `swift test` when the extension has tests.
5. Confirm the policy plugin ran.
6. Confirm every registered contribution has its required capability.
7. Exercise every button through `--threading-serve` and confirm each request receives one
   response with the matching `requestID`.
8. Report any SDK node the requested interface still needs.
9. Exercise each MCP tool through `--threading-serve`, including an error response.
10. For `ui.components`, call `extension_list_components`, describe the chosen contract, validate
    every complete patch with `extension_validate_component_patch`, preview visual replacements,
    publish an empty array once, and exercise every replacement button as a component action.
    For a hook, verify exactly-one-proceed validation, deterministic composition with another
    hook, atomic fallback for a missing resource, and native restoration after disable.
11. For primitive identity resolvers, test a host-asset echo, a package resource, an invalid
    resource fallback, and preservation of an explicit user account image.
12. For `settings`, test defaults, launch environment values, every control, a live correlated
    update, process rejection rollback, disable/re-enable persistence, and host-page injection.
13. For `services.provide`, test the exact registered version, verified caller ID, success and
    error responses, timeout, and disable/reload revocation. For `services.consume`, test an
    undeclared dependency rejection and unavailable required/optional providers.
14. For `panels`, install and enable the package, open every contribution from the display-pane
    `+` menu, exercise actions with project/session context, restore the tab after relaunch, and
    verify disable/reload produces host-owned unavailable/recovery states.
15. For `storage.secrets`, test missing, set, replace, list-names, remove, oversized-value,
    missing-capability, cross-extension isolation, and revoked-generation behavior without
    printing the value.
16. For `ui.rendering.metal`, review the packaged shader source, test its fallback signal value,
    compile it on a Metal-capable Mac, verify controls below it remain clickable, and verify
    reduced motion freezes animation.

Threading refuses an installed-package directory above 1,024 visible entries or 256 package
directories rather than performing unbounded discovery and eager Settings construction. Those are
product safety ceilings, not suggested extension counts.

Threading's Component Gallery remains the direct panel-rendering development harness. The
Extensions page in Settings and `extension_propose_install` are the product installation paths.
Both inspect first, show local/unsigned origin, runtime, and requested capabilities, ask the
user, and copy an approved package in the disabled state. Settings then lets the user enable,
reload, reveal, update, or remove it. Proposing a package whose identifier is already
installed becomes an *update* proposal through either door: the user approves the capability
delta, the running generation stops before the swap, and enablement is preserved — so the
build → propose → approve loop also serves iteration, not only first installs. Enabled panel contributions appear in the display pane's
`+` menu for a selected session.
