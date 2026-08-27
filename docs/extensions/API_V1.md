# Safe extension API v1

Safe extension API v1 is the supported contract between Threading and source-bundled Swift
WebAssembly extensions. Its executable boundary is semantic data: an extension sends declared,
versioned values and Threading renders UI and brokers authority. AppKit, SwiftUI, view handles,
Objective-C runtime method replacement, arbitrary filesystem access, sockets, and subprocess
launch are not part of this API. A public component may instead expose a versioned semantic
around-hook: the extension describes a wrapper containing exactly one `.proceed` node, and the
host composes that node with the next hook or native view.

The machine-readable declaration is `ThreadingExtensionAPI` in the app-shipped
`ThreadingExtensionKit` SDK snapshot. `SDK_VERSION` and `ThreadingExtensionAPI.sdkVersion` are both
`1`.

## What v1 supports

- WebAssembly command modules using `runtime: "webAssembly"`.
- Manifest format 1 and process, host, companion, and remote-surface protocol version 1.
- Commands, globally conflict-checked shortcuts, stable menu anchors, and a semantic
  ordinary/destructive risk classification. Destructive invocation is gated by host-authored
  confirmation UI before a request reaches the extension. Menu anchors cover the menu bar
  (`extensions`, `project`, `view`) and the sidebar rows (`session-row`, `project-row`),
  whose invocation context is the row's own identity; the rows' native actions stay
  host-owned.
- Host-rendered panels with optional generation-scoped load actions, native text/search input,
  native single-choice pickers, and bounded semantic scenes for interactive visualizations,
  including host-navigated hierarchies over producer-supplied normalized geometry;
  complete Settings pages and built-in Settings sections.
- Validated `ui.workspace-navigation` registrations describing a complete semantic navigator
  interior with virtualized list, outline, and grid snapshots, optional initial load actions,
  correlated runtime replacements, host-routed project/session destinations, persistent user
  selection, and generation-scoped Native failback.
- Package-owned localization catalogues with host language negotiation. The selected catalogue
  localizes static Settings and runtime semantic contributions, and is also exposed through
  `ExtensionLocalizer` for dynamic messages and formatted copy.
- Dynamically registered MCP tools surfaced in Tools settings.
- Versioned brokered services between explicitly declared extensions.
- Host-owned settings plus private KV, reclaimable cache, and Keychain-backed secret brokers.
- Sanitized project, session, repository, provider, and account-presentation snapshots and
  cursor events. SDK snapshot 1 includes separately gated session-runtime readings: process groups,
  CPU, memory, and listening-port metadata already attributed to one exact session, without raw
  process-table access.
- Host-played media documents: a `media` node carrying a document handle and a playback intent,
  drawn by Threading's own renderer registry, with a coalesced state report back. The extension
  receives no decoder, surface or pixel, and `ui.media-documents` gates it independently of
  `panels` and `ui.components`.
- Bounded project-file enumeration as opaque, generation-bound content handles
  (`host.project.files.read`), plus the `attachments.preview@1` offer contract and
  `attachments.file-types` registration.
- Provider/account icon resolution and constrained session identity composition.
- Component contracts `application.main-window@1`, `sidebar.project-row@1`,
  `sidebar.project-hover-card@1`, `sidebar.session-row@1`,
  `sidebar.session-hover-card@1`, `sidebar.session-identity@1`,
  `toolbar.account-usage-popover@1`, `composer.session-start@1`, and
  `composer.conversation-reply@1`, plus separate
  `conversation.user-message@1`, `conversation.assistant-message@1`,
  `conversation.tool-call@1`, `conversation.permission-card@1`,
  `display.pane-header@1`, `display.tab-header@1`, and `session.corner-card@1`
  contracts, including their declared properties, slots, actions, replacement limits, and
  hook seams. The corner card's slot IDs name placements (`top-trailing` today;
  `top-leading` reserved for a future leading card as an additive slot).
- Deterministically ordered around-hooks on contracts that declare them. `.proceed` is the next
  hook in the chain and ultimately the host's existing view; a hook may place it in a stack or
  overlay but may not inspect or mutate the resulting AppKit hierarchy.
- Protected composer hooks may place compact semantic controls before or after `.proceed` in a
  horizontal stack. They cannot replace, overlay, duplicate, or suppress the native prompt.
  Threading retains text input, submission, keyboard routing, draft persistence, stream
  availability, permission state, and accessibility.
- Conversation-row hooks may place bounded annotations above or below one protected
  `.proceed`. They are scoped by row kind and optionally by session, but receive no transcript
  text, tool arguments, output, or approval details as component context. Message content,
  transcript order, tool result attachment/expansion, and permission decisions remain native.
  Permission-card annotations are display-only and cannot contribute buttons.
- Display-pane header hooks contribute compact status and standard actions before the native
  new-tab control. Tab-header contributions are one display-only status after the native title.
  Both may be scoped by sanitized session ID; tab identity, selection, close, ordering,
  overflow, persistence, active state, pane visibility, and the new-tab menu stay native.
- Extensions contribute menu and shortcut metadata, never `NSMenuItem` or event monitors.
  Permission decisions, Keychain interaction, destructive confirmation wording and security
  control roles remain host-owned and are not component-replacement surfaces.
- Capability-gated Metal fragment surfaces in declared hook positions. Threading owns the native
  view, rendering lifecycle and scalar inputs; the extension supplies bounded shader source.
- Optional advanced companion apps with independently reviewed OS capabilities, declared
  operations, and bounded remote surfaces rendered inside host-owned views.
- Brokered HTTPS fetches (`network.brokered`) against origins declared in the manifest's
  `networkGrants` and shown verbatim in the install dialog. v1 grants are read-only
  (`GET`/`HEAD`), https-only, exact-host, and bounded in count, header, and body size. A grant
  may name a host-known credential provider (v1: `github`); Threading then attaches the user's
  best connected credential itself — app connection, `gh` CLI token, git credential helper,
  anonymous, in that order — walks the tiers on 401/403/404 GETs, and reports which tier
  answered in the response. Tokens never reach the extension. A credentialed grant is refused
  at inspection when the same manifest ships a companion holding raw `network.client`, because
  that pairing is the only way brokered data could leave the machine. Redirects may continue
  only over HTTPS on the same exact host and method; any other redirect returns its 3xx for an
  independently granted re-request. The response's optional `finalURL` reports the URL that
  answered after same-host redirects without breaking decoding from an older host.

`ThreadingExtensionAPI.safeCapabilities` is the normative capability set. `network.client` is
not a safe-v1 capability: it remains decodable for deprecated native format-1 compatibility,
but WebAssembly guests have no socket import. Safe networking is the bounded
`network.brokered` host broker above.

## The version domains

These numbers answer different compatibility questions and must not be substituted for one
another:

| Version | Owner | Meaning |
| --- | --- | --- |
| `SDK_VERSION` | Threading | Source API snapshot vendored into an extension project. |
| `formatVersion` | Threading | Shape and interpretation of `threading-extension.json`. |
| `protocolVersion` | Threading | Shape and semantics of a process or broker message family. |
| component contract version | Threading | One specific customizable host component. |
| extension `version` | extension author | Release identity shown during install/update. |
| `dataVersion` | extension author | Monotonic schema for that extension's retained data. |

Every v1 package includes the SDK source it built against under `Source/`, while the prebuilt
`.wasm` is the deterministic installation artifact.

Threading's extension API is still pre-release. Until the first public extension release, new
dogfood findings are folded into SDK snapshot 1 rather than represented as migrations from
private experimental snapshots. The compatibility promise below begins with that first public
release; locally installed development examples may need to be rebuilt before then.

## Compatibility promise

Within safe API major version 1, Threading will:

- keep manifest format 1 and protocol version 1 readable, or report explicitly that the host is
  too old/new before executing code;
- not remove or rename a public SDK v1 declaration, capability, contribution kind, JSON field,
  enum case, raw value, host endpoint, component ID, or existing component contract version;
- preserve the documented meaning, limits, authentication, lifecycle invalidation, and
  capability gate of existing operations;
- make wire additions optional to v1 readers, or publish a new protocol/contract version when an
  addition cannot be ignored safely;
- add a new component contract version instead of changing the interpretation of an existing
  version;
- continue deriving extension identity and authority in the host, never from a caller-supplied
  identifier;
- keep newly installed extensions disabled and require visible approval for first-install or
  newly added capabilities.

Source compatibility is promised for code using public `ThreadingExtensionKit` declarations.
Binary ABI compatibility of Swift modules is not promised: distributable extensions retain
source and should rebuild against a deliberately adopted SDK snapshot. The already-built Wasm
module remains compatible through the versioned wire contract.

Additive APIs may appear in later SDK snapshots without changing the major version. An extension
does not gain their authority merely by updating source: it must declare the corresponding
capability, and additions to an installed package's capability set require approval.

## Advanced companion declaration

SDK snapshot 1 defines the optional `companions` declaration used by the advanced superset. A
companion is a separately identified macOS `.app` attached to a WebAssembly core.
Its OS-facing capabilities are independent from `ExtensionCapability`: screen capture or process
launch does not grant project, session, account, storage, or other Threading host data. Install and
update review show the two authority sets separately.

This snapshot validates package-relative app layout, a bounded `Info.plist`, the bundle
identifier derived as `<extension-id>.companion.<companion-id>`, the nested executable, known
capability vocabulary, permission widening, a valid hardened code signature, App Sandbox, and
agreement between reviewed capabilities and signed network/file/Apple-Events entitlements.
Unknown sandbox entitlements fail closed.

The host now supervises the companion lifecycle. It re-inspects the nested app and validates it
against the designated code requirement pinned for the current installed generation immediately
before every spawn. `whileExtensionEnabled` workers start after the WebAssembly core registers;
`onDemand` workers remain dormant until the host activates them. Startup requires a bounded
`ExtensionCompanionHello` carrying the exact companion ID and generation. Disable, reload, core
failure, update, and uninstall revoke that generation and send a bounded shutdown before
escalating to process termination.

App Sandbox entitlements remain scoped to the separately signed companion. macOS TCC attributes
Screen Recording and Accessibility requests from a directly supervised child to Threading as the
responsible application. The host therefore requests only those interactive grants named by the
reviewed companion capabilities before spawn and fails closed when they are absent. The
companion still preflights them before use. This attribution does not transfer the core's bearer,
host snapshots, storage, or any other Threading authority to the worker.

The lifecycle also carries declared, correlated operations. Each companion may publish bounded
operation metadata (`id`, title, description, input schema, and output schema), and the Wasm core
must request `companions.invoke`. The core calls
`ExtensionHostClient.callCompanion(_:operation:arguments:)`; Threading derives the extension
identity from that generation's bearer, verifies that both companion and operation belong to
the same installed manifest, activates an on-demand worker if necessary, and relays a
generation-bound `ExtensionCompanionOperationRequest` over the worker's private stdin/stdout
channel. Requests and responses are bounded to 64 KiB and correlated by a host-owned request ID.

Companions may also declare bounded remote surfaces under the independently reviewed
`ui.remote-surfaces` capability. A WebAssembly registration connects one of those surfaces to an
ordinary `ExtensionPanel`; the panel's semantic root remains its loading, accessibility, and
failure fallback. Threading owns the `NSView`, presentation IDs, viewport and visibility state,
pixel decoding, and event normalization. The companion receives a private inherited socket and
may send only premultiplied BGRA8 frames within its declared size and the 32 MiB frame ceiling.
There is at most one unacknowledged frame per presentation, sequences are monotonic, and every
frame is acknowledged as displayed or dropped. Pointer coordinates are normalized with a
top-left origin; keyboard and pointer input are emitted only when declared. Revoking either the
core or companion generation immediately disconnects every presentation.

The companion still receives only its extension ID, companion ID, generation, reviewed
companion-capability list, and the arguments of the declared operation being invoked. It receives
no Wasm host bearer, broker descriptor, undeclared project/session/account data, or storage path.
An opened remote panel may receive only the project/session IDs already present in that panel's
host-owned context. Cross-extension companion addressing is not an API. Distribution author
trust/PKI is also separate from pinning the exact installed signature.

## Outside v1

The deprecated native format-1 compatibility runner, direct AppKit/SwiftUI, in-process native
plug-ins, sandboxed web/canvas panel bodies, author signing/PKI, automatic
enablement, a general network client, developer-mode
watch/rebuild, hierarchy selectors, and hooks on components that have no published hook contract
are not part of safe extension API v1.

The reference behavior and authoring rules live in:

- `AGENT_AUTHORING.md`
- `DECLARATIVE_UI.md`
- `WORKSPACE_NAVIGATORS.md`
- `AUTHORING_FLOW.md`
- `HOST_SURFACES.md`
- `COMPONENT_CUSTOMIZATION.md`
- `CUSTOMIZATION_SURFACE_AUDIT.md`
- `SANDBOX_RUNNER.md`
- the JSON schemas under `schema/`
- the generated component catalogue under `generated/`
