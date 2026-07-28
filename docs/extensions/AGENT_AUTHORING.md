# Agent Contract: Authoring a Safe Skalman Extension

This document is written for an AI creating or changing a Skalman extension. Follow it
literally. Do not infer APIs from Skalman's application source.

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
   [`SkalmanExtensionKit/Examples/HelloStatusExtension`](../../SkalmanExtensionKit/Examples/HelloStatusExtension)
   as the provider template and
   [`HelloStatusConsumerExtension`](../../SkalmanExtensionKit/Examples/HelloStatusConsumerExtension)
   as the consumer template.
10. Do not copy types from `Sources/Skalman`.

## Development and installed layouts

```text
MyExtension/                         # editable development project
├── Package.swift
├── skalman-extension.json
├── Sources/MyExtension/main.swift
├── Scripts/package.sh
├── Vendor/SkalmanExtensionKit/      # exact SDK snapshot; see SDK_VERSION
├── Vendor/docs/extensions/          # exact offline authoring contract + schemas
└── Resources/

MyExtension.skalmanextension/        # importable package
├── skalman-extension.json
├── bin/my-extension.wasm
├── Source/                          # complete project, including Vendor/
├── Resources/
├── README.md
└── LICENSE
```

Do not place SwiftPM's whole build directory in the package. The importable directory contains
the prebuilt `.wasm` module named by the manifest plus the source and resources required to
understand, fork, and rebuild it. Skalman copies imports into its own Application Support
directory and leaves them disabled; never write mutable state back into the installed package.

The supported dependency shape is a **vendored SDK snapshot**, not a path into Skalman's source
checkout and not a floating remote branch:

```swift
dependencies: [
    .package(path: "Vendor/SkalmanExtensionKit")
]
```

Copy the complete `SkalmanExtensionKit` package at one known `SDK_VERSION`, excluding its local
`.build` directory, into `Vendor/SkalmanExtensionKit`. Keep that snapshot unchanged while
developing a release. This makes an extension project outside the Skalman repository buildable
offline and makes the retained `Source/` tree state exactly which SDK it used. Updating the SDK
is an explicit source and package update, not something SwiftPM does behind the user's back.
The scaffold also copies the matching public contract to `Vendor/docs/extensions`; keep it with
the SDK so a future agent can discover the API, schemas, examples, and completion checklist from
the project or packaged `Source/` without needing the Skalman repository or network access.

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
- New safe extensions use `"runtime": "webAssembly"`. Omission means legacy native
  compatibility, not the recommended default.
- `executable` is relative to the installed extension directory.
- A WebAssembly executable ends in `.wasm` and does not need a POSIX executable bit.
- `executable` must not contain `.` or `..` path components.
- Do not request `network.client` for WebAssembly yet. Direct sockets are absent; a future
  network API will be host-brokered.
- A distributable WebAssembly package must retain a rebuildable Swift project. Skalman checks
  for `Package.swift` and at least one `.swift` file under `Sources/` without compiling it.
- The packager copies that project under `Source/` and omits `.build`, `.git`, `.swiftpm`,
  `DerivedData`, and `.DS_Store`. Do not put required source in those locations.
- Localization resources are flat JSON objects mapping the readable base-language string to
  its translation. Skalman negotiates `localizations` against the user's preferred languages,
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
core and does not receive the core's Skalman host-data authority.

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
  Accessibility to Skalman while Skalman directly supervises it. Skalman's capability-gated
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
  Copy the companion ID and generation from `ExtensionCompanionEnvironment`; Skalman refuses a
  mismatched or stale generation.
- Keep stdout reserved for the versioned control protocol. Read newline-delimited
  `ExtensionCompanionOperationRequest` values from stdin and answer each with exactly one
  `ExtensionCompanionOperationResponse` carrying the same request ID, generation, and operation
  ID. Also accept `ExtensionCompanionHostMessage` and exit on `.shutdown`.
- The host supervises startup, crashes, disable/reload, on-demand activation, operation timeouts,
  correlation, capability-scoped OS prompting, and remote-surface teardown. The companion
  receives no Wasm host bearer, broker descriptor, undeclared host snapshots, or storage paths.

### Companion remote surfaces

A remote surface is pixels from a companion inside a Skalman-owned view, not an AppKit object
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

`root` is required. Skalman uses it immediately while loading and as the accessible/unavailable
fallback if the companion cannot supply pixels.

When a declared surface is needed, the companion receives
`SKALMAN_COMPANION_SURFACE_FD`. Interpret its value as an inherited full-duplex file descriptor
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

See `SkalmanExtensionKit/Examples/SimulatorRelayExtension` for a complete source-bundled
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

Run migration before writing the registration line. Skalman records `targetVersion` only after
registration succeeds. A crash, timeout, invalid registration, or rejected startup leaves the
old committed value and the transition is presented again on the next launch. Migrations must
therefore be idempotent. The host refuses a package or stored-state launch that would decrease
`dataVersion`.

Settings, KV, cache, and secrets keep their existing public APIs; `dataVersion` says how your
extension interprets them, not how Skalman's own files are encoded.

## Provenance and removal

Skalman records local import provenance outside the immutable package: source filename, package
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
- Declare `host.projects.read` before calling `projects()` or `project(id:)`.
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
- Do not declare `network.client` for a safe WebAssembly v1 extension. It is reserved in the
  legacy native vocabulary and no safe network broker exists yet.
- Unknown capabilities are not permission.
- Use contribution identifiers beginning with a lowercase letter and containing only lowercase
  letters, digits, `-`, or `.`.

### Choose a contribution form

There is no manifest `type` field. Select capabilities by the surfaces the extension contributes:

- `commands` for user-triggered actions;
- `panels` for semantic UI rendered by Skalman;
- `mcp.tools` for tools callable by Claude or Codex;
- `settings` for complete Settings pages or sections appended to built-in pages;
- `services.provide` for versioned JSON APIs consumed by other extensions;
- `ui.components` for safe property, slot, or content patches to documented host components;
- any combination for a hybrid sharing one process and state model.

Skalman derives `ExtensionManifest.profile` and `contributionKinds` from that set. Do not add an
extra type discriminator to generated manifests, and do not request a capability merely because
another example does. An MCP-only extension should not register an empty panel; a panel-only
extension should not declare `mcp.tools`.

Panel registration is bounded to 32 panels. Each semantic tree is limited to 24 levels, 500
nodes, and 10,000 characters per text value; titles are non-empty and at most 120 characters.
Use valid contribution identifiers for every button so its returned action can pass the same
wire validation.

For a context-dependent panel, set `loadActionID`. Treat `root` as the immediate loading and
fallback state. Skalman sends that action once when the tab connects to each extension process
generation, using the same opaque project/session context as a button. Return a replacement
panel with the same panel ID. Keep `loadActionID` on replacement values for clarity; the host
tracks the generation and will not recursively invoke it. Make the load action idempotent
because reload and crash recovery intentionally run it again.

## Required package policy

The executable target must use `SkalmanExtensionPolicyPlugin`. Do not remove it to make a build
pass.

```swift
.executableTarget(
    name: "MyExtension",
    dependencies: [
        .product(
            name: "SkalmanExtensionKit",
            package: "SkalmanExtensionKit"
        )
    ],
    plugins: [
        .plugin(
            name: "SkalmanExtensionPolicyPlugin",
            package: "SkalmanExtensionKit"
        )
    ]
)
```

## Forbidden in a safe extension

Do not:

- import AppKit;
- import SwiftUI;
- construct `NSView`, `NSViewController`, `View`, or platform controls;
- access Skalman application internals;
- assume a theme colour, font, size, radius, or animation duration in *node UI* — panels and
  component patches describe meaning and the host chooses pixels. Stating appearance is done
  through the sanctioned data plane instead: an `appearance.themes` document or an
  `appearance.fonts` file, which the host validates and applies on its own terms;
- encode raw HTML as a substitute for an unsupported UI node;
- add a capability merely to silence validation;
- remove validation or the policy plugin.

If a requested interface cannot be expressed, report the missing semantic component. That is
an SDK design input, not permission to bypass the host renderer.

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
The stable placements are `.extensions` for Skalman's top-level Extensions menu and `.project`
or `.view` for a host-owned Extensions group at the end of those existing menus. A command may
name several placements. The first declared placement is canonical and owns the displayed key
equivalent; the other copies invoke the same command without duplicating shortcut dispatch. An
empty placement array makes a command shortcut-only after the user binds it in Keyboard settings.

The default shortcut is only a suggestion. It needs command, control, or option; Skalman
suppresses it on a conflict and lets the user resolve bindings globally. Never listen for keys
inside the extension.

Commands default to `risk: .ordinary`. Mark a command `risk: .destructive` if it can make a
change that is difficult or impossible to undo. Skalman will present its own confirmation before
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
`usage`, `storage`, and `archived`. Skalman appends contributed sections after native sections.
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
Skalman rolls the UI and persisted value back when the process returns an error or the request
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

Skalman decides how heading text, positive status, primary actions, spacing, focus,
accessibility, and live theme changes render.

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
correlation fields. The `callerExtensionIdentifier` was derived from Skalman's bearer token and
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

Skalman supports two executable modes:

- `--skalman-register` writes one JSON-encoded `ExtensionRegistration` line and exits. Keep
  this mode for validation and diagnostics.
- `--skalman-serve` writes the same registration as its first line, stays alive, reads
  `ExtensionSettingsUpdateRequest`, `ExtensionServiceRequest`, `ExtensionCommandRequest`,
  `ExtensionActionRequest`, `ExtensionComponentActionRequest`, or `ExtensionMCPToolRequest`
  lines from stdin, and writes the corresponding correlated response to stdout.

The persistent sequence is:

1. Skalman reads and validates `skalman-extension.json` without running code.
2. Skalman starts the declared executable with `--skalman-serve`.
3. The extension writes one compact `ExtensionRegistration` JSON line.
4. For a selected menu item or resolved shortcut, Skalman writes an
   `ExtensionCommandRequest`. The extension returns one `ExtensionCommandResponse` echoing its
   `requestID` and `commandID`.
5. When a registered panel has `loadActionID`, Skalman writes one
   `ExtensionActionRequest` as the tab connects to each process generation. A rendered button
   uses the same request type.
6. The extension copies its `requestID` into exactly one `ExtensionActionResponse`.
7. A returned panel must have the same ID as the panel that raised the action. Skalman validates
   the value and renders it through its own controls.
8. For a contributed MCP tool, Skalman writes an `ExtensionMCPToolRequest`; the extension copies
   its `requestID` into one `ExtensionMCPToolResponse`.
9. For a user settings change, Skalman writes an `ExtensionSettingsUpdateRequest`; the extension
   applies it and returns one `ExtensionSettingsUpdateResponse` with the same `requestID`.
10. For a brokered call, Skalman writes an `ExtensionServiceRequest` to the declared provider;
    it returns one `ExtensionServiceResponse` matching request ID, service ID, and version.

Component state does not share that sequential stream. A process with `ui.components` receives
`SKALMAN_EXTENSION_HOST_TOKEN` plus **either** `SKALMAN_EXTENSION_HOST_FD` (an inherited socket)
or `SKALMAN_EXTENSION_HOST_URL` (a loopback port), and can construct:

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
generation; pass an empty array to clear them. Skalman validates the entire publication before
changing visible state. Do not cache or share the host token. It is revoked on disable, reload,
crash, uninstall, and app shutdown.

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

Skalman applies provider resolver → built-in provider mark. Account precedence is stricter:
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
resolver or native fallback, and becomes Skalman's fork mark for a side chat. The account image
preserves explicit user-image precedence above primitive resolvers and native fallback. The
identity contract accepts only a compact horizontal tree of images and fixed spacing. Skalman
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
try SkalmanComponentCatalog.applicationMainWindow.validate(hook)
try await ExtensionHostClient().publishComponentPatches([hook])
```

`.proceed` is the next enabled hook and ultimately Skalman's existing view. Do not assume which
extension is next. The host orders hooks, constructs the chain in memory, and reconnects it when
a process generation disappears. A missing resource or failed renderer skips that hook
atomically.

For a Metal-backed custom surface, also declare `ui.rendering.metal`. Put the `.metal` file under
the development project's `Resources/`; packaging copies it to the immutable package's top-level
`Resources/`. Skalman displays a specific GPU-source warning during install. The extension
supplies this function:

```metal
float4 skalmanExtensionFragment(
    float2 uv,
    constant SkalmanSurfaceUniforms &uniforms
);
```

The host supplies `SkalmanSurfaceUniforms` with `float2 size`, `float time`, one padding float,
and `float values[8]`. Values use the declaration order in `ExtensionMetalSurface.inputs`;
binding names are documentation and stable source identifiers, not shader reflection. The only
v1 live signal is `active-account.usage-remaining`, a `0...1` fraction with the binding's
fallback used when no active account reading exists. The host owns the `MTKView`, pipeline
wrapper, command queue, fullscreen geometry, transparency, hit testing, frame cadence and
reduced-motion behavior. Shader source is limited to 256 KiB and frame rate to 60 fps.

Use `SkalmanExtensionKit/Examples/RainWindowExtension` as the complete hook/surface example.
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
the display-pane tab that raised it; those values do not bypass host-data capabilities. Call
`validate()` on decoded requests and encoded responses.

For a command, decode `ExtensionCommandRequest` before falling back to action requests. The
context contains optional opaque `projectID` and `sessionID` values according to the declared
scope. They do not bypass host-data capabilities. Return `ExtensionCommandResponse` with the
same `requestID` and local `commandID`; use `message` for a short success receipt, `error` for
an extension-level failure, or neither when a component publication is the visible result.

MCP definitions must be present in both the manifest and `ExtensionRegistration`, and the values
must match exactly. Use `ExtensionJSONValue` for schemas and arguments. Tool IDs are local; never
construct the qualified `ext__...` name yourself. MCP responses are plain text and set `isError`
when the tool ran but could not fulfil the request.

The host supplies `SKALMAN_EXTENSION_PROTOCOL=1` and a minimal environment.
`SKALMAN_EXTENSION_SETTINGS_JSON` contains the effective declared settings before registration.
The two extension host variables exist when any implemented host capability was granted. Do not
depend on Skalman's own environment variables or inherited credentials.

The process is sandboxed. It may read its installed package but cannot modify it. Under the
experimental launcher it may write only the private directories granted by `storage.kv` and
`storage.cache`; under the supported runner it has **no writable path at all** and both are
brokered by the host. Write through `ExtensionKeyValueStore` and `ExtensionCacheStore` and the
difference stays Skalman's. Host API traffic is restricted to the exact loopback port supplied
by Skalman, or to an inherited socket under the runner. Safe WebAssembly v1 has no arbitrary
outbound HTTP/DNS access: do not declare `network.client`. A future network API must be a
bounded host broker with its own reviewed contract. Child-process execution is not part of the
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
answer, not an error** — treat every entry as disposable, because Skalman may reclaim it at any
moment. Do not ask for `ExtensionCache.directoryURL()`: it exists only under the experimental
launcher and reports `unavailable` under the supported runner, which grants an extension no
writable path at all.

Disable and reload retain both kinds of storage; uninstall moves them beside the recoverable
package. Never persist mutable data inside the installed `.skalmanextension`.

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
not read Skalman's internal databases or another extension's directory as a substitute.

## Completion checklist

Before reporting an extension complete:

1. Call `manifest.validate()`.
2. Call `registration.validate(for: manifest)`.
3. For a scaffolded project, run `Scripts/package.sh <swift-wasm-sdk-id>`; this runs the
   policy-checked Wasm build and creates the source-bundled package under `Build/`.
4. Run `swift test` when the extension has tests.
5. Confirm the policy plugin ran.
6. Confirm every registered contribution has its required capability.
7. Exercise every button through `--skalman-serve` and confirm each request receives one
   response with the matching `requestID`.
8. Report any SDK node the requested interface still needs.
9. Exercise each MCP tool through `--skalman-serve`, including an error response.
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

Skalman's Component Gallery remains the direct panel-rendering development harness. The
Extensions page in Settings and `extension_propose_install` are the product installation paths.
Both inspect first, show local/unsigned origin, runtime, and requested capabilities, ask the
user, and copy an approved package in the disabled state. Settings then lets the user enable,
reload, reveal, update, or remove it. Enabled panel contributions appear in the display pane's
`+` menu for a selected session.
