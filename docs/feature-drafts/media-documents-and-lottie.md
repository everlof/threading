# Media Documents and the Lottie Viewer Extension

> Status: feature draft — the product goal is a safe Lottie viewer extension; the durable work is
> four reusable host seams it needs. Nothing here is scheduled. No renderer dependency has been
> adopted.

## Decision

A user wants an extension that browses the Lottie animations in a project, plays one with
controls in its own pane, and previews a Lottie the agent just wrote in Attachments.

None of that is a Lottie feature. It is four missing primitives that happen to collide in one
request, which is the useful thing about it:

1. **Nothing in the extension vocabulary varies over time.** Every node is a still. The only
   animated pixels an extension can produce today come from the companion tier.
2. **A safe extension cannot find a file.** WebAssembly guests get no filesystem preopens, and
   `host.projects.read` deliberately returns no paths.
3. **Attachments has no extension seam.** The kind map, the preview switch, and the inspector
   rail are all closed.
4. **A panel cannot change on its own.** It can only answer an action.

The proposal is therefore not "add Lottie." It is:

- `ExtensionNode.media` — a document handle plus playback intent, rendered by a **host-owned**
  player, with Lottie as its first format;
- `host.project.files.read` — bounded, capability-gated file **handles**, never bytes and never
  paths;
- `attachments.preview@1` plus a host-owned content probe, so an extension can own a preview body
  Threading has no renderer for;
- host-owned playback state reporting, which sidesteps gap 4 for this feature and records the
  general fix as follow-on.

The extension itself is then an ordinary safe extension with no special authority.

## Why the host owns the renderer

The alternative — hand the extension a surface and let it draw — already exists and is wrong here.
`ExtensionRemoteSurface` carries premultiplied BGRA8 frames from a companion into a host view. It
works, and for a Lottie viewer it means shipping a separately signed macOS application to draw a
vector animation, taking the whole advanced tier's disclosure with it, and losing the mobile
mirror: a companion surface is deliberately not projected, and its required semantic root is the
portable fallback.

Host-owned rendering is also what the design rules already say. *A contribution describes meaning.
Threading chooses pixels.* It is the same altitude `display_chart` picked when it took data rather
than geometry, and it is the call already made once for attachments: `SessionAttachment.Kind`
has a `.diagram` case whose comment says the pane previews the source because "rendering would
take a diagram engine the app does not carry."

This proposal is that decision reversed, deliberately and once, behind a registry — so the engine
is carried in one place and every format after Lottie is an implementation of a protocol rather
than a new extension API.

## The four walls, precisely

### Wall 1 — no time axis

| Route | Why it cannot play a Lottie |
|---|---|
| `ExtensionNode.image` | Still by construction. `BoundedImageDecoder.decodedImage` (`Sources/Threading/UI/Design/MediaInspector.swift`) decodes index 0 only, so even a GIF attachment shows one frame today. Package images are capped at 4 MiB / 1,024², multi-frame rejected. |
| `ExtensionScene` | 500 normalized marks, no time axis. Rectangles and ellipses cannot express bezier paths, masks, mattes or trim paths. |
| `customSurface(.metal)` | Runs at 1–60fps, but is one fragment function with at most 8 **scalar** inputs (`ExtensionCustomSurface.swift`). No textures, buffers or geometry cross the boundary. |
| `remoteSurface` | Works — at the companion tier, unsigned-helper cost, and no mobile mirror. |

There is one latent mechanism worth noting: `ExtensionHostSignal` already has validation, range
mapping, curves and fallbacks, and exactly one signal (`active-account.usage-remaining`), usable
only as a Metal scalar. Generalising signals to bind node properties is attractive and is
**deliberately out of scope here** — a media document needs a decoder, not a scalar.

### Wall 2 — no file authority

`WasmLaunchPolicy` gives the guest WASI stdio, **no filesystem preopens**, and one
`threading.host_exchange` import. The host read APIs return sanitized snapshots: project ID,
display name, sanitized repository identity, branch, HEAD. No paths, by design.

The only file door in the system is the companion capability `files.user-selected.read`, behind an
open panel. A safe extension cannot enumerate `animations/*.json`.

### Wall 3 — Attachments is closed at three points

1. `SessionAttachmentStore.kind(for:)` is a closed extension→kind map. A `.lottie` file returns
   `nil` and is never recorded, so the pane never sees it at all.
2. `SessionAttachmentsViewController` switches on the closed `Kind` to install one of five host
   preview views.
3. `mediaInspectorSelection(forRow:)` is an allow-list of `.image` and `.pdf`. A new kind that
   misses this silently drops out of the lightbox's arrow-key rail — the failure is invisible in
   the pane and only shows up when someone presses `→`.

The customization audit table has no attachments row. This adds one.

### Wall 4 — a panel cannot push

`ExtensionHostService` exposes `PUT` for component patches and identity resolutions and for
nothing else. Panels change only by answering an action or a `loadActionID`. An extension-drawn
elapsed-time readout is therefore impossible regardless of taste, which is a second reason the
transport is host-owned.

## Product shape

The extension contributes:

- a **display-pane panel**, "Animations", listing the project's Lottie documents with a filter, a
  selected document, a host-owned player and extension-owned controls beside it;
- an **attachments preview** for Lottie documents the session exchanged;
- a **command** and a `sidebar.project-row@1` menu entry to open the panel;
- **settings** for default loop mode, speed and canvas background.

The panel is deliberately the home, not a navigator. `ui.workspace-navigation` replaces the entire
leading navigator; nobody trades their project tree for an asset browser. That the navigator is
all-or-nothing — no additive section — is a real gap, recorded here and **not** solved by this
draft.

Panel layout, expressed entirely in existing nodes plus the new one:

```text
picker      source          (project files · this session's attachments)
textInput   filter          role: .search
stack       document list   vertical, virtualized, one row per document
media       canvas          host-owned player + transport
stack       controls        speed picker · loop picker · background picker · "Copy frame"
text        metadata        duration, frame rate, size, layer count (from the ready report)
```

## Host gap 1 — media documents

### The node

```swift
case media(ExtensionMediaDocument)

public struct ExtensionMediaDocument: Codable, Equatable, Sendable {
    /// Stable across document replacement. Playback survives a panel refresh keyed on this.
    public let id: String
    public let source: ExtensionMediaSource
    public let format: ExtensionMediaFormat
    public let playback: ExtensionMediaPlayback
    public let transport: ExtensionMediaTransport
    public let accessibilityLabel: String
    public let preferredAspectRatio: Double?
    /// Raised with a coalesced `ExtensionMediaStateReport`. Never per frame.
    public let stateActionID: String?
}

public enum ExtensionMediaSource: Codable, Equatable, Sendable {
    case extensionResource(String)   // package-relative, bounded, validated like every resource
    case fileHandle(String)          // opaque, from host.project.files.read
    case sessionAttachment(String)   // opaque, valid only inside attachments.preview@1
}

/// Raw-value type, so a newer manifest stays inspectable on an older host.
public struct ExtensionMediaFormat: RawRepresentable, Codable, Hashable, Sendable {
    public static let lottie: Self = "lottie"          // bare JSON
    public static let dotLottie: Self = "dot-lottie"   // .lottie ZIP container
    public static let animatedImage: Self = "animated-image"  // GIF, APNG
}

public struct ExtensionMediaPlayback: Codable, Equatable, Sendable {
    public let isPlaying: Bool
    public let loop: ExtensionMediaLoopMode        // .once | .loop | .pingPong
    public let speed: Double                        // 0.1 ... 4.0
    public let progress: Double?                    // 0...1; nil keeps the current position
    public let background: ExtensionMediaBackground // .surface | .checkerboard | .transparent
}

public enum ExtensionMediaTransport: String, Codable, Equatable, Sendable {
    case hostOwned   // Threading draws play/pause, scrubber, elapsed time
    case hidden      // canvas only; the extension supplies its own low-frequency controls
}
```

### The state report

```swift
public struct ExtensionMediaStateReport: Codable, Sendable {
    public let documentID: String
    public let phase: ExtensionMediaPhase   // .ready .playing .paused .completed .failed
    public let progress: Double
    public let metadata: ExtensionMediaMetadata?   // present on .ready
    public let failure: ExtensionMediaFailure?     // present on .failed
}

public struct ExtensionMediaMetadata: Codable, Sendable {
    public let duration: Double
    public let frameRate: Double
    public let frameCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let layerCount: Int
    public let markers: [ExtensionMediaMarker]     // capped at 64
}
```

Reports are raised on `ready`, `completed`, `failed`, play/pause, and **scrub end** — never per
frame, never per loop iteration when looping. The host parses the metadata, so the extension needs
no byte access to show duration or layer count. That is what keeps v1's capability surface to
handles alone.

### Who owns which control

Host-owned: the frame clock, the scrubber, play/pause, elapsed time. Scrubbing at display refresh
over a JSONL broker round-trip is not a design to tune, it is a Scaling Gate violation on its face
— a callback whose frequency is the display's.

Extension-owned: everything low-frequency and everything around the canvas — the document list,
speed, loop mode, background, markers, export. Those are ordinary nodes and an action round-trip
per change is correct for them.

`id` preserving playback across document replacement is what makes that split work: when the
extension replaces the panel to update a label, the animation must not restart. This is the same
stable-identity rule the workspace navigator already follows for selection and scroll position.

### The renderer registry

```swift
protocol MediaDocumentRenderer {
    static var formats: Set<ExtensionMediaFormat> { get }
    func open(_ document: Data, limits: MediaDocumentLimits) throws -> MediaDocumentHandle
    func metadata(of: MediaDocumentHandle) -> ExtensionMediaMetadata
    func render(_ handle: MediaDocumentHandle, at progress: Double, into: CGContext, size: CGSize)
}
```

`MediaDocumentPlayerView` in `UI/Design/` owns the display link, the transport, the theme and the
accessibility. The registry is the single place a format is carried, and `animatedImage` should be
implemented alongside Lottie precisely because it fixes an existing wart for free: an animated GIF
attachment currently shows a still.

### The Lottie engine — an open choice

| Option | For | Against |
|---|---|---|
| Vendor an **airbnb/lottie-ios** fork | Complete format coverage, macOS support, free scrubbing via its CoreAnimation engine, Apache-2.0 | Large; a fifth vendored package; its main-thread CoreAnimation path needs auditing against the theme boundary and the pane's occlusion rules |
| Vendor **rlottie** (C++) | Small, renders to a bitmap surface, no AppKit, trivially off-main | Unmaintained upstream; narrower format coverage; needs a Swift shim and a bitmap upload path |
| Ship the seam with `animatedImage` only, add Lottie later | Smallest first slice; proves the node, the handles and the preview contract | Does not answer the actual request |

Recommendation: **vendor a lottie-ios fork**, consistent with the existing policy that all
vendored packages are our forks and are modified directly. Whichever is chosen must be added to
`scripts/check_bundled_licenses.sh` inputs and the embedded legal notices.

Two format hazards are not optional to handle:

- **Expressions.** Lottie's expression subset is a scripting surface. Disable it. A document that
  needs an expression renders without it and says so in `metadata`.
- **External assets.** A Lottie may reference image assets by relative path. An untrusted document
  from an agent must not become an arbitrary file read. v1 supports **embedded base64 assets
  only**; a relative reference is dropped and reported, not resolved.
- `.lottie` is a ZIP container and gets the same archive ceilings `ClassicSkinImporter` already
  establishes — entry count, uncompressed total, path traversal, per-entry size.

## Host gap 2 — bounded project file handles

New independent authority, implied by nothing:

```text
host.project.files.read
```

```swift
public struct ExtensionFileQuery: Codable, Sendable {
    public let projectID: String
    public let scope: ExtensionFileScope       // .checkout | .sessionWorkspace
    public let fileExtensions: [String]        // ≤ 16, lowercased, no dot, no globs
    public let maximumResults: Int             // default 200, maximum 1_000
    public let cursor: String?
}

public struct ExtensionFileHandle: Codable, Sendable {
    public let id: String              // opaque, generation-bound, not a path
    public let name: String
    public let relativePath: String
    public let byteSize: Int
    public let modifiedAt: Date
    public let contentHint: ExtensionFileContentHint?
}
```

The load-bearing property is that **`id` is a handle, not bytes**. It is what
`ExtensionMediaSource.fileHandle` takes, and the host resolves it at render time. A 5 MiB
animation never crosses the Wasm broker, the extension never learns an absolute path, and the same
mechanism serves images, PDFs, video, fonts and models later.

Rules:

- the extension supplies no path, glob, command or root — only an authorized project ID;
- resolution is inside the active checkout, honours the ignore rules, refuses symlinks that leave
  it, and never returns a directory;
- handles are bound to the extension generation and revoked with it, like the bearer token;
- enumeration is bounded, cursor-paged, and runs off the main actor;
- **byte access is a separate, later authority** (`host.project.files.content.read`) and is not
  required for this feature. Do not fold it in to save a round trip.

## Host gap 3 — Attachments

### A host-owned content probe

`.json` is the ambiguity that decides the design: a Lottie *is* a `.json`. An extension must not be
able to claim every JSON file in a session.

So classification stays host-owned. `SessionAttachmentStore` gains a bounded first-N-bytes probe
producing a `contentHint` (`lottie`, `mermaid`, `graphviz`, `openapi`, …) on documents it already
records. The probe is the host's, not an extension's; it costs one bounded read; and it
independently improves the existing `.diagram` case.

### File-type registration

```swift
public struct ExtensionPreviewableFileType: Codable, Sendable {
    public let fileExtension: String    // lowercased, no dot, ≤ 12 characters
    public let displayName: String
}
```

Declared in `ExtensionRegistration` under a new `attachments.file-types` capability. It adds to the
scanner's allow-list and nothing else — the store still decides recording, copying, ceilings and
pruning. **A registration may not claim an extension the host already classifies**; `json`, `html`,
`pdf`, `png` and the rest are reserved. `.lottie` is free.

A new `SessionAttachment.Kind.media` carries them. Its native preview body is empty, which is
exactly the project-hover-card precedent: an extension-only presentation is legitimate, and
removing the last contribution closes the surface rather than leaving blank chrome.

### `attachments.preview@1`

| | |
|---|---|
| Context | new `attachmentPresentation` kind |
| Authority | replacement of the preview body only |
| Host retains | the chronology list, the All/Agent/You filter, selection, `Open in`, reveal, delete and pruning, the too-large refusal, the inspector rail |
| Context payload | opaque attachment ID, name, kind, `contentHint`, byte size, origin. **Not** the path, **not** the bytes |
| Vocabulary | text, status, picker, textInput, button, scene, `media`; no overlay; no `.proceed` when the native body is empty |
| Failback | native preview, or source text, when no extension accepts, the generation dies, the document is invalid, or two candidates conflict |

An extension **offers** for an attachment rather than owning a type. The host asks candidates in
user-chosen extension order and falls back on decline. That is what makes a `.json` Lottie
previewable without any extension owning `.json`.

### Two places that will be missed

- `mediaInspectorSelection(forRow:)` needs a `.media` case, or Lottie rows vanish from the
  lightbox rail with no visible symptom in the pane.
- `Sources/ThreadingMobile/RemoteAttachmentsView.swift` mirrors attachments to iPhone. Because the
  renderer is host-owned, the mirror is achievable — but the DTO in `RemoteDTO.swift` and the
  mobile preview both need the new kind, and the honest v1 answer for mobile may be a rendered
  poster frame plus a note rather than a live player.

## Host gap 4 — panels cannot push

Host-owned transport avoids this for Lottie: Threading draws the elapsed time, so nothing needs
pushing. Record the general fix and do not build it here:

> A generation-bound `PUT /v1/panels` publication, mirroring the existing component-patch
> publication, letting an extension replace one panel document it owns without an action. Needed by
> the next watcher, monitor or player; not needed by this one.

## A themed scrubber does not exist yet

`NSSlider` is banned by `scripts/config/theme-boundary.json` and `UI/Design/` has no slider,
scrubber or transport component. Before any player work, add:

- `ThemedScrubber` — a themed track/knob with keyboard support, VoiceOver value, and a scrub-end
  callback distinct from continuous change;
- `MediaTransportView` — play/pause, the scrubber, elapsed/duration, composed from existing
  tokens.

Both need behaviour, accessibility, live-theme-switch and rendered-state tests, and both must be
added to the duplicated component name lists in `ThemedControlTests` — that file keeps its own copy
of the component inventory and will fail until it is updated.

## Security model, consolidated

- No path, byte, or `NSImage` crosses the boundary in either direction. Handles only.
- Handles are opaque, generation-bound and revoked with the bearer token on disable, reload, crash,
  uninstall and shutdown.
- Rendering is bounded before it starts: document bytes, layer count, pixel dimensions, frame
  count, ZIP entry ceilings. A document that exceeds any ceiling fails with a stated reason rather
  than being partially drawn.
- Lottie expressions are disabled; external asset references are dropped, not resolved.
- `attachments.preview@1` grants no attachment read authority. An extension previewing a document
  learns its name, size and hint, and nothing about its content that the host did not already
  publish.
- `host.project.files.read` is not implied by `host.projects.read`; installation and enablement
  disclose it separately.

## Performance contract

Answering the Scaling Gate before implementing, not after:

- **Cardinality.** Expected 10–200 documents in a project; stress 5,000. The list is a virtualized
  vertical stack, so realized rows are O(visible).
- **Frequency.** The player is the only high-frequency path in the feature. It runs on a display
  link, capped at the document's own frame rate or 60, whichever is lower.
- **Bounded unit.** One canvas. There is never more than one playing document per panel, and a
  panel that is not the selected tab does not run its clock.
- **Must remain exact.** Scrub position, loop boundaries, and the transport's reported time.
- **Stops.** The clock stops when the tab is deselected, the pane is collapsed, the window is
  occluded or miniaturized, or the session is deselected. This is the single most likely defect and
  deserves its own test rather than an assertion inside another one.
- **Off-main.** Document parsing, ZIP expansion, file enumeration and the content probe run off the
  main actor. Only the per-frame draw is main-thread, and it is bounded by the canvas size.
- **Fixture.** An opt-in stress fixture with a synthetic 200-layer document at 60fps and a
  5,000-file project, measuring realized view count, main-thread frame cost, footprint across a
  tab switch, and that the clock actually stopped.

## The reference extension

`Packages/ThreadingExtensionKit/Examples/LottieViewerExtension`, built only on the public seams,
in the style of `HelloStatusExtension`. It exists to keep these APIs exercised by an ordinary
extension rather than by host-only fixtures — the reason Hello Status uses both hover-card
contracts today.

## Implementation order

Each phase is independently useful and independently shippable.

**Phase 0 — design-system groundwork.** `ThemedScrubber` and `MediaTransportView`, their tests, and
the `ThemedControlTests` inventory update. *2–3 days.*

**Phase 1 — the media document seam.** `ExtensionMediaDocument` and friends in the SDK; the
renderer registry and `MediaDocumentPlayerView`; `animatedImage` as the first implementation;
`ExtensionNodeRenderer` support; panel and component constraint gating (`allowsMedia`, default
false, so no existing contract silently gains a player); the manifest capability
`ui.media-documents`; the Wasm broker route; schema, catalogue and localization updates. Ships a
working animated-GIF node with no Lottie in the tree. *6–8 days.*

**Phase 2 — the Lottie renderer.** Vendor and fork the engine; the format implementations for
`lottie` and `dotLottie`; expression and external-asset refusal; ceilings; licenses and legal
notices; the render-state tests. *4–6 days.*

**Phase 3 — file handles.** `host.project.files.read`, the query/handle values, host service route,
enumeration off-main, handle lifetime bound to the generation, consent copy, denial tests. *3–5
days.*

**Phase 4 — attachments.** The content probe; `Kind.media` and file-type registration; the
`attachments.preview@1` contract and its host shell; the inspector-rail case; the remote DTO and
the mobile presentation; failback tests for decline, death, invalid document and conflict. *4–6
days.*

**Phase 5 — the reference extension** and its UI-scenario coverage. *3–4 days.*

**Phase 6 — reconsider.** Only after this ships: additive navigator sections, panel push, and
whether `ExtensionHostSignal` should bind node properties generally. Do not pre-build any of them.

Estimates exclude auditing the vendored engine, which is genuinely unknown until one is chosen.

## Verification gate

- Codable and JSON-schema round trips for every new value, plus backward decoding of a manifest
  containing an unknown media format and an unknown capability.
- Capability denial: media node without `ui.media-documents`; file query without
  `host.project.files.read`; a preview contribution without the contract; a handle replayed from a
  dead generation; a `sessionAttachment` source used outside the preview contract.
- Path safety: traversal in a package resource, a ZIP entry, and a Lottie asset reference; a
  symlink out of the checkout; a reserved file-type registration.
- Ceilings: a document at each stated cap, and one past it, asserting a stated failure rather than
  a partial render.
- Attachment failback: no candidate, decline, generation death mid-preview, invalid replacement,
  two conflicting candidates — each returning the native body.
- The inspector rail contains `.media` rows and arrow-keys through them.
- Playback: position preserved across a document replacement with a stable `id`; reset on a changed
  `id`; the clock stopped on tab deselect, pane collapse, occlusion and miniaturization.
- Rendered-state tests, light and dark, for the player, its transport and the attachment preview.
- Stress fixtures at the stated cardinalities with no main-actor file work and O(visible) rows.
- `ThreadingComponentCatalogGenerator --check docs/extensions/generated` clean; new test files
  registered via `scripts/add_test_file.py`; `scripts/ci.sh` green.

## Rejected alternatives

- **A companion drawing frames.** Works today and is the wrong tier: a signed helper application
  to play a vector animation, plus no mobile mirror.
- **A Lottie-shaped node.** `lottiePlayer` as vocabulary would bind the public API to one format's
  data model. `media` with a format registry costs the same and carries the next four formats.
- **Bytes instead of handles.** Simpler to specify, worse in every other way: a 5 MiB document
  through the broker, a decode surface inside the guest, and an extension that has read the file
  and can do anything with it.
- **Extension-owned scrubbing.** Impossible over the wire, and the attempt would have produced a
  laggy transport that looked like a rendering bug.
- **Widening `ExtensionScene` with keyframes.** Generic and appealing, and still unable to draw a
  bezier path with a matte. It is a separate idea, not this one.

## What this unlocks beyond Lottie

Recorded so the seams are not sized for one caller: SVG, video and screen-recording previews,
audio waveforms, USDZ and GLB, notebooks, CSV and parquet tables, and the Mermaid and Graphviz
rendering the `.diagram` kind currently declines. Every one is the same shape — the host carries
an engine, the extension carries discovery and framing.

## Rollout rule

Treat the chosen engine, the probe's hint list and every ceiling as host implementation detail.
Treat the capability names, the media document and handle field meanings, the failure and
completeness states, the privacy omissions, and the attachment failback order as the public
contract. If a real extension cannot state something important inside those boundaries, version the
contract deliberately rather than leaking a host model as a shortcut.
