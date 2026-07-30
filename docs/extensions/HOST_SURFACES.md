# Extension host surfaces and identity

This document defines the extension surface layer before process sandboxing. Project and session
component customization, tokenized process publication, safe project/session/provider/account
snapshots, cursor events, primitive provider/account identity resolvers, and the selectable full
session identity renderer are implemented.

[`COMPONENT_CUSTOMIZATION.md`](COMPONENT_CUSTOMIZATION.md) turns the surface model into an
incremental AppKit implementation plan, including full semantic HStack replacement.

The goal is to let extensions add useful state and change presentation without receiving an
`NSView`, importing Threading's models, reading its databases, or competing for undocumented
pixels in the view hierarchy.

## Two different kinds of contribution

### Additive accessories

An accessory adds information to a host-owned row without replacing its identity:

- a CI light on a project;
- a CI light on a session;
- a small unread, warning, deployment, or review marker.

Threading owns the size, spacing, hover behavior, accessibility, theme colors, and overflow.
An extension supplies semantic state:

```swift
ExtensionAccessory(
    id: "ci",
    state: .positive,
    accessibilityLabel: "CI passed",
    toolTip: "main · build 481 passed",
    actionID: "open-ci-run"
)
```

The initial stable slots should be:

- `sidebar.project.accessories`, between the project title and Threading's count/actions slot;
- `sidebar.session.accessories`, between the session title and Threading's activity/actions slot.

The built-in activity indicator and row actions are never replaceable accessories. They retain
their fixed trailing slot. Threading shows at most two extension accessories inline and places
additional values behind one host-rendered overflow affordance. Sorting is stable by the user's
extension order, then contribution identifier.

An accessory action is routed to the owning process with the entity kind, opaque entity ID,
accessory ID, and action ID. An extension never receives the row view as an action anchor.

### Replacing identity presentation

Icon replacement changes what an existing identity looks like:

- replace a provider mark;
- replace an account image;
- replace the complete provider-plus-account composition for a session.

These are resolvers, not accessories. One resolver is active for each replacement category. A
single candidate activates directly; when several candidates exist the registry refuses to pick
an install-order winner and waits for an explicit selection.

Three contributions cover the useful levels:

1. `providerIconResolver` receives a provider snapshot and may return an image reference.
2. `accountIconResolver` receives an account presentation snapshot and may return an image
   reference.
3. `sessionIdentityRenderer` receives the resolved provider and account images plus session
   state, and returns the final host-rendered composition.

The full renderer is deliberately last. It can use the primitive images supplied by Threading,
including images resolved by the first two contributions, without querying private stores or
knowing how those images were discovered.

## Image values, not AppKit

Images cross the boundary as references and recipes:

```swift
enum ExtensionImageReference {
    case hostAsset(id: String)
    case extensionResource(relativePath: String)
    case systemSymbol(name: String)
}

struct ExtensionIdentityComposition {
    let base: ExtensionImageReference
    let badge: ExtensionImageReference?
    let badgePosition: ExtensionBadgePosition
    let accessibilityLabel: String
}
```

The host validates extension-relative paths, caps a package image at 4 MiB and 1,024 × 1,024
pixels, rejects multi-frame images, and asks AppKit to validate a system symbol before drawing
it. A host asset ID is opaque and short-lived and can be returned untouched in a resolver
publication. Pixel reads are not implemented.

The first implementation should prefer recipes. A later `renderedImage` result may accept PNG
variants for extensions that really need custom CoreGraphics composition, with pixel, byte,
scale, and animation limits. Raw filesystem paths and archived `NSImage` values never cross the
boundary.

### Resolution precedence

Primitive images resolve in this order:

- provider: selected provider resolver, then Threading's built-in provider mark;
- account: the user's explicit per-account emoji/image, selected account resolver, discovered
  avatar, generated initial;
- project: the user's explicit project icon, Threading's current discovery, generated project
  tile.

A selected session identity renderer then decides how the already-resolved provider and account
images are composed. Side-chat lineage and dormant state are supplied as semantic context; the
host still applies row selection, accessibility contrast, and disabled opacity.

This preserves explicit user choices while allowing an activated renderer to replace the whole
provider/account layout.

The renderer is the `sidebar.session-identity` component contract. It accepts a constrained
horizontal `ExtensionNode` replacement containing images and fixed spacing. Contextual
`session.provider-image` and `session.account-image` host assets expose the already-resolved
layers without image bytes or paths crossing the process boundary. One renderer activates
automatically; conflicts wait for the user's persistent choice in Extensions settings.

The catalogue for this surface and every other public component is generated from
`ThreadingComponentCatalog`. Agents can discover it at runtime through the Extension authoring MCP
group, validate a complete patch with the same SDK function used by the publication registry,
and request a native preview that has no effect on installed extensions.

## Host snapshots an extension can query

Extensions receive versioned value snapshots with opaque stable IDs. They do not receive
`Project`, `AgentSession`, `AgentAccount`, paths to JSON files, or AppKit images.

The implemented first read APIs are:

```text
GET /v1/projects
GET /v1/projects/{id}
GET /v1/sessions
GET /v1/sessions/{id}
GET /v1/providers
GET /v1/providers/{id}
GET /v1/accounts
GET /v1/accounts/{id}
GET /v1/events?after={cursor}&limit={1...200}
```

They are exposed as the Foundation-only `ExtensionHostClient.projects()`, `project(id:)`,
`sessions()`, `session(id:)`, and `events(after:limit:)` methods. List and single-entity
responses include an event cursor captured with the snapshot. Start polling after that cursor
so a mutation between the snapshot and the first event request cannot disappear.

Implemented minimal snapshots:

- project: ID, display name, optional repository snapshot;
- session: ID, project ID, provider ID, optional account ID, display title, activity, branch,
  side-chat state, archive state, and native/terminal surface mode;
- repository: remote host/repository identity, branch, and HEAD revision.

Account config paths, login email, project folder paths, transcripts, prompts, and credentials are
not part of these snapshots. Each needs a later, narrower capability if a real extension cannot
work without it.

The repository identity is sanitized from HTTPS, SSH URL, or SCP-style remotes. User info is
discarded, `.git` is removed, and local remotes are omitted. A complete remote URL never crosses
the boundary.

Provider snapshots contain ID, display name, and the built-in image as an opaque host asset.
Account snapshots contain provider-qualified ID, display name, default/user-image flags, and an
optional built-in image reference. Email, config path, avatar URL, and image bytes are absent.

For a CI extension, repository identity and revision are enough. It should not need arbitrary
project-file access merely to ask GitHub or another CI provider about a commit.

## Capabilities

Implemented contribution capabilities:

```text
ui.components
appearance.provider-icons
appearance.account-icons
appearance.session-identity
```

Implemented read authorities:

```text
host.projects.read
host.sessions.read
host.sessions.runtime.read
host.repositories.read
host.providers.read
host.accounts.presentation.read
host.events
```

Future contribution/presentation authorities include `sidebar.accessories` and
`host.assets.read`.

Network and future filesystem access are independent authorities. Declaring component UI
does not imply project paths, account configuration, transcripts, network, or credentials.
`storage.secrets` is an independent implemented authority: values travel through the exact
generation-bound loopback broker and are persisted by Threading in an extension-scoped Keychain
namespace. It grants neither direct Keychain access nor a writable filesystem path.

`host.sessions.runtime.read` is separate from the ordinary session snapshot. It accepts one
stable session ID and returns only the process groups and listening ports Threading attributes to
that session's agent and shell roots. The result contains command name, PID, CPU, memory, port,
bind address, IP family, interface classification, and localhost reachability. It does not
expose the process table, parent traversal, arguments, environment, open files, paths, sockets,
or arbitrary PID lookup. A reading is capped at 256 processes and 128 ports; command names are
capped at 128 characters and addresses at 64.

A CI component extension which reads host state today asks for:

```json
[
  "ui.components",
  "host.projects.read",
  "host.sessions.read",
  "host.repositories.read",
  "host.events"
]
```

`network.client` belongs to the deprecated native capability vocabulary. It is not part of safe
WebAssembly API v1: the Wasm guest has no socket import, and a future network surface must be a
bounded, independently capability-checked host broker. An icon theme normally asks only for the
relevant appearance contribution and presentation snapshot/asset authorities.

## Transport

The host API does not share the extension's stdin/stdout request stream.

Today that stream is sequential: Threading sends an action or MCP request and waits for the
correlated response. If the extension sends a host query while handling that request and waits
for an answer on the same stream, another already queued host request can arrive first and the
protocol can deadlock.

Threading now exposes a separate `ExtensionHostService` over loopback HTTP. Each
process declaring any implemented host capability receives a short-lived URL and bearer token
in its environment. The
token identifies the extension, its launch generation, stable extension order, and granted
capabilities, so requests cannot claim another extension identity. Separate endpoints atomically
replace one generation's component patch set and primitive identity resolutions; GET endpoints
return independently gated snapshots and cursor events.

The service is extension-core, not an MCP endpoint. It currently reuses only the generic
loopback HTTP connection primitive; Core/MCP does not import extension types.

On disable, reload, crash, uninstall, or shutdown, Threading revokes the token and removes that
process generation's published patches. Cached extension state survives in its private KV
store, but stale UI contributions cannot.

## Events and refresh

The implemented event feed contains:

```text
project.changed
project.removed
session.changed
session.removed
provider.changed
account.changed
account.removed
```

Events carry IDs, project association for session events, timestamp, and monotonically increasing
cursor—not complete internal objects. An extension reads the latest snapshot after an event and
publishes a replacement patch set. The journal retains the latest 1,000 events; an expired cursor
returns HTTP 410 and requires a fresh snapshot.

Provider/account events use the same journal. A CI extension can publish a last-known state with
a timestamp, while the host visually distinguishes stale state rather than presenting an old
green light as current forever.

## Implementation order

1. ~~Add project/session snapshot values and component patch values to
   `ThreadingExtensionKit`.~~
2. ~~Introduce `ExtensionHostService` and per-process capability tokens, independently of MCP.~~
3. ~~Implement project/session component slots, entity patches, snapshots, and cursor events.~~
4. ~~Add provider/account snapshot values and primitive resolvers.~~
5. ~~Add the selectable full session identity renderer.~~
6. ~~Enforce the same capabilities with an OS sandbox after the useful surface has been
   measured.~~

The first, now legacy-only native enforcement layer is a generated Seatbelt profile behind
`ExtensionSandboxPolicy`. It keeps the package read-only, maps `storage.kv` and `storage.cache`
to the only writable paths, restricts broker access to the exact loopback port, and maps
`network.client` to outbound networking. Broker-only `services.consume` and `storage.secrets`
receive that exact port without gaining a writable path or arbitrary networking. The policy
fails closed, and both launch paths go through `ExtensionLaunchPolicy`.

That second enforcement layer now exists: a signed, App Sandboxed helper the extension is
`execve`d out of, replacing deprecated `sandbox-exec` without changing any extension API. Under
it the description above shifts — storage is brokered rather than granted as writable paths,
and the broker arrives on an inherited descriptor rather than a loopback port — see
[`SANDBOX_RUNNER.md`](SANDBOX_RUNNER.md).
