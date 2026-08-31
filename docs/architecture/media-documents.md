# Media Documents

Everything about a document that varies over time: the `media` node, the host-owned player and its
renderer registry, the Lottie engine, bounded project-file handles, and the attachments preview
seam that lets an extension own a preview body Threading has no native renderer for.

It also covers movies, which are the first format whose renderer reads its own file.

Read this before changing `Sources/Threading/Core/Media/`,
`Sources/Threading/UI/Design/MediaDocumentPlayerView.swift`,
`Sources/Threading/Core/Extensions/ExtensionProjectFileBroker.swift`, or the `.media` paths in
`SessionAttachmentStore` and `SessionAttachmentsViewController`.

## The problem this solves

An extension wanted to browse a project's Lottie animations, play one with controls, and preview a
Lottie an agent had just written. None of that was a Lottie feature. It was four missing primitives
that happened to collide in one request:

1. **Nothing in the extension vocabulary varied over time.** Every node was a still.
   `BoundedImageDecoder` decodes index 0, so even an animated GIF attachment showed one frame.
   `ExtensionScene` has 500 normalized marks and no time axis. `customSurface(.metal)` is one
   fragment function with at most eight *scalar* inputs — no textures, buffers or geometry cross
   the boundary. The only route that worked was `remoteSurface`, at the companion tier.
2. **A safe extension could not find a file.** `WasmLaunchPolicy` grants no filesystem preopens,
   and the host read APIs deliberately return no paths.
3. **Attachments was closed at three points**: the extension→kind map, the preview switch, and the
   inspector rail's allow-list.
4. **A panel could not change on its own.** It answers an action or a `loadActionID`, and nothing
   else.

## The decision: the host carries the engine

*A contribution describes meaning. Threading chooses pixels.* The alternative already existed and
was wrong here: `ExtensionRemoteSurface` carries premultiplied BGRA8 frames from a companion into a
host view, and using it for a vector animation would mean shipping a separately signed macOS
application, taking the whole advanced tier's disclosure with it, and losing the mobile mirror — a
companion surface is deliberately not projected.

This is the same altitude `display_chart` picked when it took data rather than geometry. It is also
the call already made once for attachments and now reversed **deliberately, once, behind a
registry**: `SessionAttachment.Kind.diagram` exists because "rendering would take a diagram engine
the app does not carry." `MediaDocumentRendererRegistry` is the one place an engine is carried, so
every format after the first is an implementation of a protocol rather than a new extension API.

## The public contract

| Value | What it is |
|---|---|
| `ExtensionNode.media(ExtensionMediaDocument)` | A document handle plus a playback intent |
| `ExtensionMediaSource` | `extensionResource` (package-relative), `fileHandle` (from `host.project.files.read`), `sessionAttachment` (valid **only** inside `attachments.preview@1`) |
| `ExtensionMediaFormat` | `lottie`, `dot-lottie`, `animated-image` — a raw-value type, so a newer manifest stays inspectable on an older host |
| `ExtensionMediaPlayback` | `isPlaying`, `loop`, `speed` (0.1–4), `progress`, `background` |
| `ExtensionMediaTransport` | `host-owned` or `hidden` |
| `ExtensionMediaStateReport` | Raised as the value of `stateActionID` |
| `ExtensionFileQuery` / `ExtensionFileHandle` / `ExtensionFilePage` | Bounded enumeration as opaque handles |
| `ExtensionPreviewableFileType` | One extension added to the attachments scanner's allow-list |
| `ExtensionAttachmentPreviewRequest` / `…Response` | The offer, and the decline |

Capabilities, each independent and separately disclosed: `ui.media-documents`,
`host.project.files.read`, `attachments.preview`, `attachments.file-types`.

### Who owns which control

**Host-owned**: the playback timeline and visibility lifecycle, the scrubber, play/pause, elapsed
time, and the optional Copy Frame pasteboard action. Scrubbing at display refresh over a JSONL
broker round-trip is not a design to tune — it is a Scaling Gate violation on its face, a callback
whose frequency is the display's. Copy Frame is host-owned for the same authority reason: the
extension asks for the affordance, and neither rendered bytes nor pasteboard access cross the
boundary. The action report carries no pixels either, and there is a test that says so.

**Extension-owned**: everything low-frequency and everything around the canvas — the document list,
speed, loop mode, background, marker selection. An action round-trip per change is correct there.

### `id` is the identity, and that is load-bearing

`ExtensionMediaDocument.id` preserves playback across a document replacement. When an extension
replaces its panel to update a label, the animation must not restart; a **changed** id is what
resets it. This is the same stable-identity rule the workspace navigator already follows for
selection and scroll position, and the panel host keeps players in
`playersByDocumentID` rather than per row — the table virtualizes, so a player rebuilt per
materialization would restart the animation every time a cell was reused.

### State reports are coalesced, never per frame

`ready`, `completed`, `failed`, play/pause and **scrub end**. Never per frame, and never per loop
iteration while looping. The report travels as the value of an ordinary action, so the host gained
no new route and an extension that declares no `stateActionID` receives nothing at all. The panel
host invokes it *silently*: a state report is not something the user asked for, so it does not put
"Running…" over the panel and does not re-render the tree it was raised from — which would tear
down the player mid-frame and report again.

## The renderer registry

```swift
protocol MediaDocumentRenderer: Sendable {
    static var formats: Set<ExtensionMediaFormat> { get }
    func open(_ document: Data, limits: MediaDocumentLimits) async throws
        -> MediaDocumentPlaybackSession
}
```

`open` completes away from the main actor: parsing a document and expanding an archive are the two
most expensive things in the feature and neither belongs in a frame.

`MediaDocumentPlaybackSession` is **engine-neutral**, and `drivesItsOwnClock` is the fork. A
session that answers `true` owns its timeline and is only told what the user asked for; one that
answers `false` is asked to present a position by the player's clock. That split exists so the
abstraction never forces a CoreAnimation engine through a synchronous `CGContext` rasterization on
every tick — the mistake a bitmap-only protocol would have baked in.

`MediaDocumentRenderHost` has two ways in for the same reason: `contentLayer` for an engine with a
native animation layer, `present(frame:)` for a decoder that produces bitmaps. `present(frame:)`
**replaces rather than queues**: a frame that missed its deadline is superseded, never shown late
behind the one after it.

`animatedImage` is first in the registry on purpose. It fixes a wart that predates the seam — an
animated GIF attachment has always shown one frame — while proving the protocol with a decoder
nobody has to audit.

### `MediaDocumentFileRenderer`: the one format that reads its own file

`open(_ document: Data, …)` carries an assumption that every format here was happy with until
movies: **the whole document is resident**. A ten-minute screen recording is hundreds of megabytes,
and reading one into memory to hand to a decoder that is going to stream it anyway is the
allocation the seam exists to avoid. So a renderer may instead declare `open(fileAt:limits:)`, and
`MediaDocumentPlayerView` gained a second, **optional** resolver (`FileLoader`) beside its
`DocumentLoader`.

Three consequences, each deliberate:

- **The host resolves the file, never the extension.** The URL is minted on this side of the
  boundary from a handle the host already owns, and nothing about it — not the path, not the
  bytes — travels back. `attachments.preview@1` did not become a read authority.
- **A surface with no file refuses the format.** An extension panel's media comes out of a signed
  package, so it installs no `FileLoader` and a panel asking for `video` is refused with a stated
  reason rather than quietly gaining a filesystem. The attachments pane and the lightbox install
  one, because each already knows exactly which file it is looking at.
- **Bytes are refused, not spilled to a temporary file.** The default `open(_:limits:)` on a file
  renderer throws. Writing the buffer out to disk to "support both" would turn a refusal into an
  unbounded copy of whatever was handed over.

### Movies (`video`)

`VideoDocumentRenderer` is the second engine, and it is AVFoundation: `AVPlayer` hands frames to an
`AVPlayerLayer` installed in the canvas's `contentLayer`, so the session is **self-clocked** and
the player above it stops asking for positions and starts mirroring them — a `Double` read per tick
instead of a decode. AVKit is not used at any point: `AVPlayerView` brings its own chrome, and the
timeline here is the same `MediaTransportView` every other format uses. A movie hides that row's
duplicate Play button and puts the same host-owned action in `MediaPlaybackOverlayView`, centred
over the picture: Play stays visible while paused; while playing, Pause returns on hover or
keyboard focus and otherwise clears out of the frame.

- **Nothing decodes into this process**, so the ceilings that bound a parsed document — bytes,
  frames, duration — do not apply to a movie. They bound an allocation this path never makes. The
  one that survives is `maximumVideoPixelDimension`, its own value (8,192) well above
  `maximumPixelDimension`, because refusing a 4K screen recording would refuse the commonest movie
  in a coding session to save nothing.
- **A name is a claim; the decoder answers.** Admission is by extension (`mov`, `mp4`, `m4v` — what
  AVFoundation actually opens, which is why `webm`, `mkv` and `avi` are absent), and playability is
  confirmed when the document is opened. A file that is not a movie is refused with a sentence.
- **The presented size, not the stored one.** A portrait recording stores a landscape frame plus a
  rotation; a canvas given `naturalSize` alone draws it into a letterbox turned the wrong way.
- **The pane owns the rectangle; the movie owns the pixels inside it.** The attachment player fills
  the flexible preview host and `AVPlayerLayer.resizeAspect` aspect-fits the frame. Its document
  ratio and the standalone player's 120-point canvas floor are low-priority hints in this host,
  not competing minimums that stop the fold. If the fold leaves less room than a useful canvas and
  timeline together, the timeline detaches and returns on expansion; centred Play remains.
- **Sound is the new question**, and it is answered in three places. `MediaPlaybackState.isMuted`
  is host-side and deliberately absent from `ExtensionMediaPlayback` — an extension that could
  unmute a document could make a noise in a window nobody was looking at. `MediaTransportView`
  grows a speaker only for a session that answers `hasAudio`, since a control that can change
  nothing reads as a muted document rather than a silent one. And
  `MediaDocumentRendererRegistry.autoplaysWhenHostOpens(_:)` states, once, that an animation the
  host opens plays and a movie does not: a row reached with an arrow key is not a request for
  audio, and a movie's first frame is a perfectly good picture of it. Reduce Motion still overrides
  the answer in the direction it always did.
- **Only a self-clocked session can see its own end.** `hasReachedEnd` exists because the player
  reaches `.once` completion through arithmetic a self-clocked session never runs — without it a
  finished movie sat at the end with the transport still offering Pause. `.pingPong` is honoured as
  `.loop` for video: playing backwards needs a decoder that can, and most movie files' cannot.
- **Copy Frame is synchronous** through `AVAssetImageGenerator`, rather than attaching an
  `AVPlayerItemVideoOutput` that would make every movie pay a buffer copy for an action almost
  nobody takes. It is one user-initiated request against a local file, and a frame that arrived
  after the menu closed would land on a pasteboard already pasted from.

### The Lottie engine is in-tree, and here is why

The feature draft recommended vendoring an airbnb/lottie-ios fork. That was not done, and the
reason is worth recording because it should be re-examined rather than re-derived:

- The four vendored packages in this repository are all **our forks**, small, and modified
  directly. A ~100k-line third-party animation engine is a different kind of dependency: it would
  arrive unaudited, and the format's real hazards — expressions, external asset references, archive
  ceilings — are host policy that would have to be enforced *around* it anyway.
- Carrying a bounded subset in `Core/Media/Lottie/` keeps every refusal in one readable place, and
  the registry means swapping the engine later changes one file rather than the public contract.
- Nothing third-party was added, so `scripts/check_bundled_licenses.sh` and the embedded legal
  notices need no new entry. **If an engine is ever vendored, they do.**

#### What a real corpus said

The subset was validated against **122 real animations** (the LottieFiles sample set and the
lottie-ios regression fixtures). 116 parsed; the six refusals were five documents with no layer
this engine draws and one past the 4,096-pixel cap — all stated refusals, none partial. Of the
116, **106 draw ink**; the ten that do not are lottie-ios's own pathological regression fixtures,
at least one of which (`issue_1854`) has a shape group with geometry and no paint and is correctly
blank.

The frequency of what was dropped, which is the evidence for whether the subset is still the right
call: `mattes-dropped` 20, `effects-dropped` 14, `text-layers-dropped` 9, `expressions-disabled` 7,
`repeaters-dropped` 5, `external-assets-dropped` 4.

**That corpus found three real bugs a synthetic fixture never would**, and each now has a
checked-in regression fixture of its own:

1. **Layer visibility was tested in the wrong clock.** `ip`/`op` are composition time and `st`
   shifts only the layer's *own* clock. Testing visibility against the shifted clock made every
   staggered copy of a precomp invisible forever — a four-burst firework rendered as an empty
   canvas from beginning to end.
2. **Gradient ramps are animated in real documents.** Bodymovin keyframes the whole flattened
   ramp; reading only the first frame drew a blank rectangle for every moving gradient.
   `LottieGradient.ramp` is a `LottieVector` for that reason.
3. **Exporters mislabel keyframed properties as static.** Real files ship `"a": 0` beside a
   keyframe array. Trusting the flag read the property as its fallback, so a fill whose opacity
   keyframes start at zero never drew at all. The *shape* of `k` decides now, not the flag.

Gradient strokes (`gs`) were added in the same pass, drawn by clipping the ramp to the stroke's
own outline — the loading-spinner idiom, and common enough that several corpus documents used it.

`LottieRendererTests.testARealLottieCorpusParsesAndDraws` is how to repeat this. Point
`THREADING_LOTTIE_CORPUS` at a directory of real documents and it asserts that every one either
parses or fails with a stated reason, that a parsed document draws ink somewhere on its own
timeline, and prints the refusal/notes histogram above. **The corpus is deliberately not checked
in**: the public sample collections carry a share-alike licence, and taking that obligation on for
a test fixture is a worse trade than pointing the test at a folder.

**Reopen this if** the subset stops covering real documents: text layers, mattes, effects,
repeaters and non-additive masks are dropped and reported today, and a user whose animations keep
coming back with `text-layers-dropped` is evidence, not an opinion.

The subset is stated rather than implied. `LottieDocument.Note` is the vocabulary of what was
declined — `expressions-disabled`, `external-assets-dropped`, `text-layers-dropped`,
`effects-dropped`, `mattes-dropped`, `repeaters-dropped`, `unsupported-layers-dropped` — and it
reaches the extension through `metadata.notes`. A document that quietly loses its text layers is
indistinguishable from a rendering bug; one that says so is not.

### Three format hazards, handled at parse time

- **Expressions.** Lottie's expression subset is a scripting surface. A property carrying one is
  read as its static value and the document is marked `expressions-disabled`. Refusing the document
  outright would be worse: it renders, minus the thing it was not allowed to run.
- **External assets.** A bare Lottie may name an image by relative path. Resolving one would turn
  any animation an agent just wrote into an arbitrary file read, so only an embedded base64 asset
  is decoded. A `.lottie` container *may* resolve an image — but only to an entry inside that same
  already-validated archive, never beside it and never elsewhere on disk.
- **`.lottie` is a ZIP**, and gets archive ceilings: entry count, per-entry size, total expanded
  size, encryption, unsupported compression, and path traversal. `BoundedZipArchive` is the shared
  reader; `ClassicSkinImporter` was migrated onto it rather than keeping a second copy, because a
  hobbyist's `.wsz` and an agent's `.lottie` are the same attack surface with different consent
  copy.

## Bounded project-file handles

`host.project.files.read` is a **separate authority**, implied by nothing. `host.projects.read`
returns a sanitized snapshot with no filesystem in it at all; this returns names,
project-relative paths, byte sizes and modification dates, which is a different question and is
disclosed separately.

The load-bearing property: **`id` is a content handle, not bytes and not a path that can be
opened.** A 5 MiB animation never crosses the Wasm broker and the extension never learns an
absolute path. It *does* learn bounded filesystem metadata, because an asset browser cannot present
or filter a list without it — that disclosure is explicit rather than disguised as "handles only",
and the consent copy says so.

Rules, each with a test:

- the extension supplies no path, glob, command or root — only an authorized project ID and, for
  `.sessionWorkspace`, the exact session ID whose execution checkout it wants. The broker never
  infers a workspace from UI selection, and a session belonging to another project is refused;
- resolution stays inside the captured root, skips dependency and build directories, skips hidden
  files, and **refuses symlinks rather than following them** — a link named `assets` is how a walk
  leaves the checkout;
- containment is re-checked when a handle is **opened**. Enumeration and rendering are separated by
  however long the user took to click, and a file replaced with a symlink in between would
  otherwise be read through an honestly minted handle;
- handles are bound to the process generation and revoked with the bearer token, on disable,
  reload, crash, uninstall and shutdown;
- enumeration is lexically ordered, bounded, cursor-paged, and runs off the main actor. The cursor
  is bound to generation, root identity and normalized query — a changed root or query invalidates
  it rather than silently continuing in a different workspace;
- **byte access is a separate, later authority** (`host.project.files.content.read`) and was not
  folded in to save a round trip.

## Marking up a picture (`ImageAnnotation`, `MediaInspectorAnnotationHost`)

A numbered pin on an image, a field per pin, and one seam deciding who owns the list.

**The inspector never owns the marks.** Opened from the element-report sheet it is a second view
of a list that sheet is already showing in its rail, and a pin dropped at 400% has to appear in a
field the user goes back to. Opened from anywhere else — an attachment, a chart an agent drew, a
browser baseline — the host stores an editable `ImageAnnotationDocument` in session continuity
and exposes it from the Attachments pane. Both are the same gesture over the same picture, so the
difference belongs in *who is asked*, not in a mode flag inside the inspector.
`MediaInspectorAnnotationHost` is that question; `MediaInspectorPresenter.defaultAnnotationHost`
is who answers it when the opener named nobody, installed by `AppDelegate` because this file draws
pictures and knows nothing about sessions or composers.

Three decisions worth their words:

- **The point is normalized into the image's own space**, never a view coordinate. One mark is
  read in four rectangles — a preview scaled to fit a column, the zoomed canvas with a pan
  offset, a flattened copy at the file's pixel size, and a coordinate in prose — and storing any
  one of them makes the other three a conversion somebody forgets.
- **A mark is a click; panning is a drag; the mark is decided on the way up.** Both start with
  the button going down on the same pixel, and a zoomed picture is exactly when someone wants to
  pan *and* has a reason to mark a detail. Deciding on the way down dropped a pin at the start of
  every pan.
- **Close means close; publication is explicit.** Edits are committed on every mutation, while
  **Add to chat** creates an immutable flattened attachment revision with the coordinates beside
  it. A stable context id upserts that revision in a native composer instead of multiplying
  receipts; a terminal receives the same file-and-prose handoff. Sent revisions remain immutable
  while the source document can be reopened and changed.
- **The first layout is the real layout.** The notes document is flipped and top-anchored before
  its first frame. A reopened list of several notes cannot begin below the viewport and wait for
  collection-arrow navigation to provoke a second layout pass. The collection filmstrip follows
  the same rule: `NSScrollView` replaces a newly installed document view's frame with its initial
  viewport, so the rail seeds its full content extent only after that handoff and settles the
  stack against the first usable viewport. A click may change selection; it may not be the first
  event that restores fixed thumbnail sizes or spacing.

`ChatImageAnnotationHost` is held **strongly** by `MediaInspectorSession`: the view's reference is
weak, and a host built on demand by the default provider has no other owner. It keys documents by
stable attachment identity where one exists, promotes an otherwise transient image into session
custody on its first mark, and keeps the file-path key as an alias so the same document is found
from either route.

The pin is `BrowserAnnotationOverlay`'s pin — same chip height, border weight, accent fill with
the ground stroked around it, numeric face, top-most-wins hit test. A second numbered mark with
its own anatomy would be two annotation vocabularies in one app.

## Attachments

### The probe, and why it runs before admission

`.json` is the ambiguity that decides the design: a Lottie *is* a `.json`. An extension that could
claim `.json` would claim every configuration file in every session, and a store that admitted
`.json` on its extension alone would fill the pane with `package.json`.

So classification stays host-owned and structural, and it happens on the right side of the
admission gate. `MediaContentProbe` reads a bounded prefix and recognizes a signature it knows.
Two routes reach `Kind.media`:

- a **registered** extension, decided by name alone — which is why a registration may not claim a
  reserved one;
- an **ambiguous** extension, decided by the bytes. `MediaContentProbe.admissionHints` is
  deliberately tiny (`lottie`), because admission is the gate that keeps configuration out. Other
  hints may enrich a kind already admitted without becoming admission rules.

Work ceilings, not permission for an extension to supply a parser or receive the prefix: at most
64 KiB from at most 32 ambiguous candidates per scan, and existence is checked first so a path in
prose that names no file cannot spend the budget a real one needs. The bodymovin signature requires
`layers` **and** two of `fr`/`ip`/`op`, because `layers` alone appears in map styles, design tokens
and half the configuration formats in a modern checkout.

### `attachments.preview@1`

| | |
|---|---|
| Authority | replacement of the preview body only |
| Host retains | the turn-grouped chronology and collapse state, the All/Agent/You filter, selection, `Open in`, reveal, delete and pruning, the too-large refusal, the inspector rail |
| Context payload | opaque attachment ID, name, kind, `contentHint`, byte size, origin, session ID. **Not** the path, **not** the bytes |
| Vocabulary | text, status, picker, textInput, button, scene, `media`; no overlay and no `.proceed` |
| Failback | native preview, bounded source text, or an explicit unavailable message |

**An extension offers for an attachment rather than owning a type.** The host asks candidates in
the user's own extension order and the first valid acceptance wins. A decline, a timeout, a
generation that died mid-offer and an invalid body all do the same thing — advance. Exhaustion
reaches the native fallback. There is no separate "two candidates conflict" state, because
**ordering is the conflict policy**. At most eight candidates are consulted for one presentation,
so a broad set of installed extensions cannot turn selecting a row into unbounded process work.

Overlay and `.proceed` are absent from the vocabulary for a structural reason: offer and decline
happen *before* one exclusive body is chosen, so there is no native content behind this to proceed
into.

The native body is always drawn **first**, then replaced if a candidate wins. It is what the pane
shows when no extension accepts, when the winner's generation dies, and when the last contribution
is removed — removing an extension never closes the built-in surface or leaves blank chrome.

### A movie is a kind, not a registration

`.media` means *no native preview exists for this*. A movie has one, so filing it there would hide
a playable file behind an extension that may never be installed — `SessionAttachment.Kind.video` is
a first-class kind beside `.image` and `.pdf`.

Two rules in the pane follow from the file never being read:

- **The 64 MB preview ceiling does not apply to it.** That gate exists because every other preview
  decodes, lays out or renders the whole file on the main thread. A recording passes the ceiling
  before it has finished recording, and previewing it costs the same at two gigabytes as at two
  megabytes.
- **A poster frame is generated off the main actor, once per file, and only for a row that
  exists.** `viewFor` is called for materialized rows, so the work is O(visible) — eight open
  decoders in a hundred-recording session, not a hundred. Successes are cached by path, size and
  modification date like every other thumbnail; refusals are remembered too, because the cost of a
  refusal is the cost of a success and a row that cannot have a picture would otherwise pay it on
  every scroll. A movie row also carries a small play mark: a poster frame is a picture of a
  moment and so is a screenshot, and at 26 points nothing else tells them apart.

The phone shows a movie the way it shows an animation — a card saying it plays on the Mac, and no
bytes are asked for. Note what the *listing* already does above it: `RemoteAccessServer` omits any
attachment over `RemoteAccessDefaults.maximumAttachmentBytes` (24 MB) from the list entirely, which
for movies is the common case rather than the exception. That is the existing whole-file rule
rather than something movies introduced, and it is the same reason the follow-on is a frame-stream
or poster endpoint rather than a larger download.

### The attachment handle's scope

`ExtensionMediaSource.sessionAttachment` resolves only for the attachment currently on screen, in
the pane that is showing it. Replayed into a panel it resolves to nothing, and there is a test for
that. The teardown path is split (`hideInstalledPreviews` versus `hideNativePreviews`) precisely
because an accepted body replaces the fallback while the offer that won is still current —
clearing the offer there would revoke the handle the winner is about to resolve.

### The fold between the two halves is the reader's

The pane is a chronology above a preview, and the list asks for its rows' height up to a share of
the pane. Half was the opening answer and stayed the permanent one, which is a different claim: a
session with eighteen attachments *fills* that cap, and the HTML report the selected row is
pointing at then has half a pane to be read in however long it is. Nothing in the pane can know
which half a reader needs, so the fold between them moved (`PaneFoldDivider`).

Three decisions hold it together.

- **The pane's own answer is content-sized; a fold the reader placed is a position.** Until the
  fold is moved the list is as tall as its rows under a cap — a session with three attachments
  opens as three rows, not as half a blank pane. Once it *has* been moved, the height is where
  they left it, rows or no rows. The two used to be one rule (`min(rows, cap)` always), which
  meant a drag downwards stopped dead at the last row with pane plainly left underneath: reported
  as "can't expand it beyond the cells, feels buggy", and correctly so — the thing under the hand
  is a divider, and a divider that springs back is a divider that does not work. This is still not
  an `NSSplitView`: what a drag moves is a constraint on a content-sized half, which a split view
  has nowhere to say.
- **The travel is clamped to what the fold can express.** The running total is held between the
  pane's limits rather than accumulated past them, so the drag back moves on its first point
  instead of crossing an overshoot nothing on screen reflected. (The shell drawer keeps its
  overshoot deliberately, because *there* the travel past the floor is the answer — it shuts the
  drawer.)
- **The pane keeps two limits the user cannot see past.** Never below one row, and never past
  `maximumListShareOfPane`, because a stored height is a point value read back in a pane that may
  be much shorter than the one it was chosen in. A double-click on the fold hands the position back
  to the pane, and `WindowLayoutReset` clears it with the window's other geometry.

The preview is the flexible half all the way through its renderer. In particular, a movie player
is pinned to all four preview edges and its canvas minimum compresses below the fold's constraints;
the movie's aspect belongs to the `AVPlayerLayer` inside that rectangle. Making the player state a
required document-shaped height recreates a second divider owner and makes a legal drag appear to
stop before the pane's own limit.

The fold runs edge to edge, so its leading end lands on the window's split seam — and holding the
point where two seams cross while moving only one of them is the gesture arriving at half its
meaning. A press within `PaneFoldDivider.Layout.cornerReach` of that end therefore takes the seam
beside the pane as well (`ThemedSplitView.holdSeam(beside:on:)`), and one diagonal drag moves the
fold down and the panel wider. See [`window-chrome.md`](window-chrome.md#the-corner-where-two-seams-meet).

`AttachmentsListHeight` keeps one value app-wide, in `PreferenceStore` — a fold is how someone
wants to read their attachments rather than a fact about one conversation, and the scratch suite is
what stops a hosted test's drag from moving the divider in the pane the developer is looking at.

The chronology's timestamp loses resolution with age instead of dropping every non-today row
straight to a date. Today shows the local time; the preceding six calendar days keep an abbreviated
weekday and time; rows up to one year old keep day and month; older rows keep month and year. Calendar
days are evaluated in the user's current time zone, so midnight — not an elapsed 24-hour interval —
moves a row out of "today". The same localized value remains part of the row's one accessibility
sentence.

The rows are separated by collapsible turns from `GitTurnBaselineStore`, not by transcript
indexes. A recorded file carries an optional exact user-turn identity plus a temporal placement:
agent output points to the current turn, prompt attachments point to the next turn until admission
can pin them exactly, and pane-local comparison input points to neither. This distinction is what
keeps a file staged for a queued prompt out of the response that happened to be running when it
was recorded. A collapsed section contributes one disclosure row and no file-row views; an empty
latest checkpoint remains visible so “nothing attached this turn” is not confused with an older
turn being latest.

### Two places that are easy to miss

- `mediaInspectorSelection(forRow:)` needed a `.media` case. A row missing from the rail has **no
  visible symptom in the pane**; the failure only appears when someone presses `→`. A `.media` row
  belongs on the rail only when the registry can actually draw it — a registered format with no
  renderer is a real row in the pane and a rail slot the lightbox would have nothing to put in.
- `Sources/ThreadingMobile/RemoteAttachmentsView.swift` mirrors attachments to iPhone.
  `RemoteAttachmentDTO.kind` is a string exactly so an older phone decodes a newer kind, and
  nothing on the wire had to change. The honest v1 presentation is a card that says the animation
  plays on the Mac: a live player needs a poster-frame or frame-stream endpoint the remote surface
  does not have yet, and a silent blank card would be worse than a sentence. **That endpoint is the
  follow-on**, and it is achievable precisely because the renderer is host-owned.

### A Quick Look renderer lives no longer than its window

`MediaInspectorDocumentView` caches the `QLPreviewView` it builds for the formats Threading has no
renderer of its own for. Quick Look closes that view **with the window it is in** —
`shouldCloseWithWindow` defaults to true — and a closed preview view does not refuse the next item,
it *aborts the process*: `-[QLPreviewView setPreviewItem:]` raises "Trying to set a preview item on
a closed preview view" through `_QLCrash` → `abort()`.

Nothing exotic was needed to reach that. An Attachments tab dragged into its own window and then
closed hands the **same** `SessionAttachmentsViewController` back to the display panel, and the next
attachment it was asked to preview killed the app (crash of 2026-08-13, `EXC_CRASH (SIGABRT)` with
`QLPreviewView setPreviewItem:` two frames under `abort`). Explicitly closing the lightbox had the
same shape: `close()` closed the preview view and kept it.

So the cached reference means exactly one thing — *Quick Look will still take an item for this* —
and it is dropped both when the window announces its close and when the view leaves a window at
all, because those two arrive in an order AppKit does not promise and either alone leaves a hole.
`display(_:)` builds a fresh renderer. Two regression tests in `MediaInspectorTests` hold both
doors: the window-closed one and the explicitly-closed one.

**What is dropped is the renderer, not the document.** Unparenting a document view is ordinary —
the display panel unparents a tab's controller every time another tab is shown, and nothing
re-runs the pane's preview for a tab that merely came back — so `MediaInspectorDocumentView` keeps
the URL Quick Look was asked for and rebuilds the renderer when it next reaches a window. Discard
alone would have traded an abort for a pane whose list names a document over an empty preview.

**The renderer is dropped, never `close()`d**, which the second of those tests found by aborting
the test host on its first run: `-[QLPreviewView close]` raises the same way from `deactivate`
when the view was never *activated* — a document previewed before the pane reached a window, which
is every cold open of the attachments pane. Between "abort if you set an item on a closed view"
and "abort if you close a view that was never active", the only call that is safe from both sides
is no call: `shouldCloseWithWindow` is left true, Quick Look tears its own view down with the
window, and this type's teardown never crosses the framework boundary — which is also what makes
it safe to run from inside `NSWindow.willCloseNotification`, where Quick Look's identical observer
may already have run.

## Panels still cannot push

Host-owned transport avoids this for media: Threading draws the elapsed time, so nothing needs
pushing. The general fix is recorded and deliberately not built:

> A generation-bound `PUT /v1/panels` publication, mirroring the existing component-patch
> publication, letting an extension replace one panel document it owns without an action. Needed by
> the next watcher, monitor or player; not needed by this one.

## Design components

`ThemedScrubber` and `MediaTransportView` were built first, because `NSSlider` is banned by
`scripts/config/theme-boundary.json` and `UI/Design/` had no scrubber or transport at all.

- **`ThemedScrubber`** — the load-bearing claim is that **the travel and the commit are different
  events**. `onChange` is the travel, `onScrubEnd` is the decision, and a keyboard step raises both
  because one key press *is* a complete scrub. Committing on every intermediate value is how a seek
  turns into a queue of seeks. Assigning `value` raises neither: a control that echoed its own
  assignment would make a player's state report a feedback loop.
- **`MediaTransportView`** — play/pause, the scrubber, and a monospaced-digit reading. A movie can
  detach Play and use the row as the timeline below its picture. The digits
  are not decoration: a proportional readout re-lays out on almost every tick (`0:09` → `0:10`
  changes width), which moves the scrubber under the pointer dragging it. Its length property is
  `documentDuration` rather than `duration` because the boundary lint reserves `.duration`
  assignments for `Design.Motion` — content length is not motion the app chose.
- **`MediaPlaybackOverlayView`** — the movie's 48-point centred Play/Pause affordance over a
  full-canvas primary playback target. A left click anywhere on the picture raises the same
  host-owned toggle, including the activation click when the window was inactive; secondary
  clicks still open the canvas context menu. Space/Return and VoiceOver reach that same action,
  and setting `isPlaying` never raises it.
- **`MediaDocumentCanvasView`** — the bounded surface, with the checkerboard drawn from theme roles
  rather than the conventional two greys, since a system-grey checkerboard is the one thing a fully
  themed page cannot have.

## Performance contract

- **Cardinality.** Expected 10–200 documents in a project; stress 5,000. The panel's list is a
  virtualized vertical stack, so realized rows are O(visible).
- **Frequency.** The player is the only high-frequency path. A bitmap session is driven by a
  display link whose `preferredFrameRateRange` is the document's own frame rate capped at 60 — a
  three-frame GIF asked for a frame sixty times a second is fifty-seven decodes nobody sees. A
  self-clocked engine runs its own clock under the same visibility gate.
- **Bounded unit.** One canvas. The backing store is capped at 4,194,304 pixels and 4,096 on either
  axis; a larger canvas renders at a reduced internal scale rather than allocating an unbounded
  frame.
- **Never queued.** The Lottie session holds at most one render in flight and *supersedes* the
  pending position rather than accumulating one. A display link asking for sixty positions a second
  while a frame takes twenty milliseconds would otherwise drift further behind real time the longer
  the document played.
- **Off-main.** Document parsing, ZIP expansion, file enumeration, the content probe and Lottie
  rasterization all run off the main actor. Only attachment, transport state and final presentation
  are on it.
- **Measured, not asserted.** `MediaDocumentPerformanceTests` is the fixture, and the figures are
  recorded in [`performance.md`](performance.md#media-document-stress-target): a 200-layer document
  rasterizes in 5.5–10.7 ms per frame across the three canvas sizes, the main actor spends
  **0.00 ms per tick**, and sixty positions arriving during one render produce **two**
  rasterizations rather than sixty. Measuring the content probe also found it 5× slower than it
  needed to be, and the three fixes are recorded there — including the one that made it 20× worse.
- **The clock stops when nobody is looking.** A deselected tab, a collapsed pane, a hidden
  ancestor, an occluded window, a miniaturized window and a player with no window all stop it. This
  is the single most likely defect in the feature and has a test of its own rather than an
  assertion inside another one.

`MediaDocumentPlayerView.windowVisibility` is a seam rather than a direct window read, for a reason
that is also the rule: an **unshown** window correctly reports that it is not visible, and every
fast test in this repository builds a window it never orders on screen. Production keeps
`defaultWindowVisibility`; a test states the answer, which is also how occlusion and
miniaturization are exercised without a visible window to occlude.

## Reduce Motion

Media playback is content, but **autoplay is motion the app chose**. A document requested as
playing opens paused under Reduce Motion; an explicit Play still plays it, and the transport's
focus, keyboard and VoiceOver behaviour are identical in either state.

## Security model, consolidated

- No absolute path, file byte, rendered pixel or `NSImage` crosses the extension boundary. The
  project-file authority deliberately *does* return bounded filesystem metadata, and its consent
  copy says so.
- Handles are opaque, generation-bound, and revoked with the bearer token. Their captured
  root/query scope is revalidated when opened.
- Rendering is bounded before it starts: document bytes, layer count, pixel dimensions, frame
  count, duration, ZIP entry ceilings. The layer ceiling is reserved from the raw composition and
  precomp arrays before any `LottieLayer`, transform, path or asset is built; unsupported layers
  count because classifying them is still parser work. A document past any ceiling fails with a
  stated reason rather than being partially drawn.
- Lottie expressions are disabled; bare-JSON filesystem asset references are dropped. A `.lottie`
  asset resolves only to an already-validated entry in its own archive.
- `attachments.preview@1` grants no attachment read authority.
- `host.project.files.read` is not implied by `host.projects.read`.

## Rollout rule

Treat the chosen engine, the probe's hint list and every ceiling as host implementation detail.
Treat the capability names, the media document and handle field meanings, the failure and
completeness states, the privacy disclosures and omissions, and the attachment failback order as
the public contract. If a real extension cannot state something important inside those boundaries,
version the contract deliberately rather than leaking a host model as a shortcut.

## What this unlocks beyond Lottie

Recorded so the seams are not read as sized for one caller: SVG, audio waveforms, USDZ and GLB,
notebooks, CSV and parquet tables, and the Mermaid and Graphviz rendering the `.diagram` kind
currently declines. Every one is the same shape — the host carries an engine, the extension carries
discovery and framing.

**Video and screen-recording previews were the first of these to be built**, and they are the
evidence that the shape holds: one new renderer, one optional resolver on the player, and no new
extension API. What they *did* cost is recorded above — a second `open` route, because the byte
assumption was the one thing in the seam a movie could not live with.

## Where the code is

| Area | File |
|---|---|
| SDK values | `Packages/ThreadingExtensionKit/Sources/ThreadingExtensionKit/ExtensionMediaDocument.swift`, `ExtensionProjectFiles.swift`, `ExtensionAttachmentPreview.swift` |
| Registry, limits, failures | `Sources/Threading/Core/Media/MediaDocumentRenderer.swift` |
| Animated raster documents | `Sources/Threading/Core/Media/AnimatedImageDocumentRenderer.swift` |
| Movies | `Sources/Threading/Core/Media/VideoDocumentRenderer.swift` |
| Content probe | `Sources/Threading/Core/Media/MediaContentProbe.swift` |
| Lottie | `Sources/Threading/Core/Media/Lottie/` |
| Shared ZIP reader | `Sources/Threading/Core/Storage/BoundedZipArchive.swift` |
| Player and canvas | `Sources/Threading/UI/Design/MediaDocumentPlayerView.swift`, `MediaDocumentCanvasView.swift` |
| Transport | `Sources/Threading/UI/Design/ThemedScrubber.swift`, `MediaTransportView.swift` |
| File handles | `Sources/Threading/Core/Extensions/ExtensionProjectFileBroker.swift` |
| Attachment offer | `Sources/Threading/UI/Views/SessionAttachmentPreviewOffer.swift` |
| Registered file types | `Sources/Threading/Core/Session/AttachmentMediaTypeRegistry.swift` |
| Reference extension | `Packages/ThreadingExtensionKit/Examples/LottieViewerExtension/` |
| Tests | `Tests/ThreadingTests/MediaTransportTests.swift`, `MediaTransportRenderTests.swift`, `MediaDocumentSeamTests.swift`, `LottieRendererTests.swift`, `ExtensionProjectFileBrokerTests.swift`, `SessionAttachmentMediaTests.swift`, `SessionAttachmentVideoTests.swift` |
