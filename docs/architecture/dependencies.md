# Dependencies

The application dependency boundaries and the seams in each that are ours.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

- **WebRTC** (remote, prebuilt): native ICE/STUN/TURN, DTLS/SCTP and ordered data channels for
  hosted Mac-to-iOS remote access.
  - Location: exact SwiftPM version `151.0.0`, package revision
    `19aa8c1fc7120d50df987b7111f42d5024df3d54`, wrapped only by
    `Packages/ThreadingPeerTransport/`.
  - The binary archive is pinned by SwiftPM checksum
    `64a218fad3d84a0d783321aa9a1eec58ca266ac7879123f86b0b44b703b7d8dc`. The upstream release
    identifies WebRTC source commit `f20ebb8adbf4fa781830e4384c61f732bd28a217`; those values must
    be reviewed together on every update.
  - **The bounded transport is ours.** Feature code never sees WebRTC objects. The package owns
    signaling frames, trickle candidate limits, channel and byte high-water marks, stream
    multiplexing, listener replacement, reconnect and shutdown. The Mac and iOS apps see only
    loopback TCP endpoints, preserving the existing remote protocol and its authorization.
  - The framework contains standards-based DTLS/SRTP cryptography. Keep the iOS export-compliance
    declaration and the WebRTC legal notice in sync with this dependency; do not revert to a
    system-crypto-only declaration.
  - This is a community binary distribution of Google's source. Before changing the pin, verify
    the package revision, release source commit, SwiftPM/archive checksum, license, privacy
    manifest, OSV result, GitHub advisories, supported deployment slices and both app builds.

- **SwiftTerm** (local fork): Terminal emulation engine handling VT100/xterm, ANSI parsing, PTY communication
  - Location: `./Packages/Vendor/SwiftTerm/` (vendored source in the main repository, not a git submodule)
  - Upstream: https://github.com/migueldeicaza/SwiftTerm
  - **This is our fork** - feel free to modify SwiftTerm source code directly to implement features or fix bugs. The iOS folder is excluded on macOS builds.
  - **The scroller seam is ours.** `MacTerminalView.installScroller` lets the embedding app
    replace only the visible `NSScroller`; SwiftTerm immediately restates its target, action,
    geometry and current scroll position and continues updating that instance. Threading uses
    this to install `ThemedScroller` with backdrop ink while retaining SwiftTerm's legacy-style
    column and all of its scrolling behavior. The scroller is a bare `NSScroller` in a plain
    view rather than a scroll view's, so nothing upstream fades it — AppKit's own drawing
    answers that by painting nothing at all, and a scrollbar that *does* draw has to hide
    itself. `ThemedScroller` carries that fade; see
    [`themes.md`](themes.md).
  - **The PTY seam is ours.** Local processes launch through `forkpty`; a `posix_spawn`-based
    wrapper cannot establish the child as the PTY's controlling terminal. The launch publishes
    the exact child PID synchronously, before its exit source is activated, and reaps that PID
    with `waitpid` so `TerminalSession` never guesses from the app's process table.
    `running` remains true after SIGTERM until that exact PID is reaped, so a rapid replacement
    cannot overwrite the exit monitor and make the old callback wait on a new child.
    `TerminalSession` retains a launch requested during that short interval and performs it from
    the old child's termination callback.
  - **The managed-grid seam is ours**, on both platforms. `TerminalView.shouldApplyFrameSizeChange`
    is consulted at the top of `processSizeChange`, *before* the emulator is touched, so a view
    whose grid does not follow its pixel size can refuse a frame-driven resize outright. The
    later `LocalProcessTerminalView.shouldApplyProcessSizeChange` is not a substitute: by the
    time it answers, `terminal.resize` has already reflowed the buffer, and putting the grid back
    runs SwiftTerm's resize path, which ends in `softReset()`. That cost a remote-controlled
    session its scrolling region on every layout pass — see [`../REMOTE_ACCESS.md`](../REMOTE_ACCESS.md).
    Keep both hooks when re-syncing: one gates the renderer, the other gates the PTY.
  - **Main-queue output is bounded.** PTY reads pause once pending terminal data reaches the
    4 MiB high-water mark and resume below 1 MiB. The kernel PTY buffer then supplies
    normal producer backpressure instead of an unbounded queue growing behind a busy AppKit
    thread. One completed `DispatchIO` read starts one successor; partial callbacks do not fork
    additional read chains. Reads and queued chunks carry a launch generation; starting the next
    process clears the previous generation so late DispatchIO callbacks cannot leak old bytes
    into the replacement terminal. Deinitialization closes the PTY, cancels the monitor and gives
    the child to an independent waiter so it cannot remain a zombie.
  - **Mouse-wheel coordinates are viewport-relative.** Full-screen clients such as Claude enable
    mouse reporting and receive ordinary wheel input themselves; Option-wheel is the explicit
    local-scrollback escape hatch. Holding history above the live edge sets
    `Terminal.userScrolling`, so output repaints do not pull the viewport back to the bottom.
  - **Wheel reports are rate-limited, and dropped rather than queued.** A pty carries no message
    boundaries and its input queue fills a byte at a time, so a client that is mid-render when
    reports arrive resumes reading *inside* one; a stdin parser that does not carry a partial
    escape sequence across reads then drops the orphaned `ESC [ <` and takes the rest for typing.
    `65;104;33M` appearing in Claude Code's composer while scrolling is this, and only this. The
    bytes themselves arrive in order — measured, `LocalProcess`'s per-write `DispatchIO.write`
    calls do not reorder — and writing a burst as one write instead of thirty made the splitting
    *worse*, so the rate is the whole fix. Against a reader on a 40 ms frame: 100 reports a
    second survived an 800 ms stall with every read still landing on a report boundary; 180 a
    second split one at 800 ms; 300 a second needed only 400 ms. `forwardWheelEvent` spends a
    token bucket of 100 a second with a burst of 6, and one classic notch now reports once
    instead of being multiplied by the scrollback velocity curve — which was worth up to a
    screenful of reports for a single event, and cleared 1000 a second on any momentum flick.
    A dropped report is right where a queued one is not: a scroll the client never saw is a
    scroll that did not happen, and the next gesture already says where the user wants to be.
    `TerminalMouseReportingTests` pins the counts.
  - **`pasteText` is ours.** Upstream reaches bracketed paste only through `paste(_:)`, which
    reads `NSPasteboard.general` — so text that never came from the clipboard could only be sent
    as typing, or by writing over the user's clipboard first. A drop is a paste, and the markers
    are what say so: Claude Code turns a *pasted* image path into `[Image #1]` and Codex into its
    own attachment, while the identical bytes typed stay a line of path. See
    `TerminalDrop` and `TerminalDropPasteTests`, which pin the wire format.
  - **Logical recent-buffer extraction is ours.** `getBufferAsData` is a screen-shaped export:
    every physical grid row ends in a newline, including a row the terminal wrapped only because
    the window was narrow. `getRecentLogicalBufferText(maximumUTF8Bytes:)` instead joins rows
    carrying `BufferLine.isWrapped`, preserves hard line breaks, and walks backwards under its
    byte budget before materialising text. It returns complete logical lines only, so a cap or a
    scrollback trim cannot turn the tail of a path into an apparently complete relative path.
    Threading's attachment detector uses this seam; agent TUIs that pre-wrap their own painted
    rows are covered separately by the provider transcript at the turn boundary.
  - **The selection seam is ours**, and it carries copy-on-select. `selectionGestureEnded()` is
    called when a *pointer* gesture settles a selection — a drag released, a double- or
    triple-click, a shift-click extension — and `selectedText` answers what is selected, nil when
    that is nothing. `SelectionService` is internal upstream, so an embedder could see neither.
    Deliberately **not** `selectionChanged(source:)`: that one is posted from every `dragExtend`,
    i.e. every mouse-moved event inside a drag, so a host copying there would rewrite the
    pasteboard dozens of times per gesture and hand back a half-made selection each time. Nothing
    calls it for `selectAll` or for a click whose only effect is to clear a selection. The policy
    lives in the app — `EmojiFixedTerminalView` reads `AppSettings.copiesTerminalSelection` at the
    moment of the gesture, so a toggle needs no notification to reach open terminals.
    Two smaller changes hang off it: `copy(_:)` now refuses an empty selection, because it clears
    the pasteboard *before* writing and so used to throw the user's clipboard away whenever
    something called it with nothing selected (⌘C never did — menu validation gates it — but the
    app's own terminal context menu did, and copy-on-select would have done it on every stray
    click); and `pasteboard` replaces the hardcoded `NSPasteboard.general` in `copy`/`paste` so a
    hosted test can exercise copying without spending the developer's real clipboard, which is
    the same trap as a test writing to `UserDefaults.standard`. `TerminalCopyOnSelectTests` pins
    all of it, including that a one-event drag selects nothing: the selection anchors at the
    first *drag* event, not at the press.
  - **The Option-word keys are ours.** `TerminalSession` sets `optionAsMetaKey = false` so
    Option still composes `~ | \ @` on non-US layouts. Upstream's meta branch is also the only
    place that turned Option-arrow into word motion, so that one switch silently dropped the
    whole family: AppKit resolves them to `moveWordLeft:`, `moveWordRight:` and
    `deleteWordBackward:`, which `doCommand(by:)` did not claim, and the entire keypress was
    lost — not a sequence the agent misread, nothing on the PTY at all. Those selectors now send
    `ESC b` / `ESC f` / `ESC DEL`: readline's `backward-word`, `forward-word` and
    `backward-kill-word`, bound by default in both zsh and bash, and all three honoured by
    Claude Code (measured by driving its TUI through a pty — the delete needed a forced repaint
    to read back, since it only writes the delta otherwise). Control-arrow keeps its own branch
    in `keyDown` and its xterm `CSI 1;5D`/`CSI 1;5C` form. `TerminalOptionWordKeyTests` pins each
    sequence, the unmodified keys beside them, and the composition the switch exists to protect.
  - **Answering "what colour are you?" is ours.** `OSC 10/11/12` take a list of colours, and
    upstream's `oscSetColors` read its `startAt` offset as an *index into the parameters*: OSC
    11's single parameter sits at index 0, the loop began at 1, and the whole sequence was
    dropped — no reply to `OSC 11 ; ? ST`, and no way for a program to set the background
    either. Only OSC 10 worked, because there the two numbers coincide. This matters because
    **Claude Code's default `"theme": "auto"` is not "follow macOS"** — it asks the terminal
    for its background and falls back to its *dark* palette when nothing answers. So every
    agent in every session painted dark-theme ink: on a light terminal theme (Bauhaus is paper)
    a diff's unchanged lines came through as near-white text on cream. The offset is now
    applied to the colour *slot*, each further parameter names the next colour along, and a
    query is answered with the code for the colour it asked about — 10, 11 or 12, where the
    cursor's reply used to claim to be 11. `TerminalColorQueryTests` pins the bytes on both
    sides. An agent asks once, at startup — so the fork also tracks `DECSET 2031`
    (`colorSchemeReportingEnabled`, answered through DECRQM too), and
    `reportColorSchemeChange` sends the subscribed program `CSI ? 997 ; 1|2 n` when the
    embedder changes the palette under it. The report prompts the program to *re-ask* `OSC 11`,
    which is how a theme switched under a running agent finally reaches it — see
    [`themes.md`](themes.md) for the whole three-leg contract.
  - **Final text-colour observation is ours.** `TerminalView.onLowContrastText` inspects the
    colours after inverse, bold-as-bright, faint alpha, palette lookup and background harmony
    have all resolved, while SwiftTerm is already grouping a visible row for drawing. It never
    changes output. Only meaningful visible runs with an explicit foreground qualify; default
    foreground, whitespace/ornament and SGR concealment do not. The evaluated and reported
    pair sets are independently capped because a process controls 24-bit colour cardinality.
    `TerminalSession` defers the callback out of the draw pass and turns it into the app's
    dismissible diagnostic; see [`themes.md`](themes.md).
  - **Still unclaimed, and dead the same way:** `deleteToBeginningOfLine:` (Cmd-Delete). Option
    with *forward* delete never reaches `doCommand(by:)` at all — `NSDeleteFunctionKey` carries
    `.function`, so `keyDown`'s function branch answers it first and sends plain forward-delete,
    dropping the modifier. Fixing that one means touching that branch, not this switch.

- **ThinkingOrbs** (local fork): the dotted "working" thought-orb drawn beside the
  conversation status while a turn is in flight.
  - Location: `./Packages/Vendor/ThinkingOrbs/` (git submodule), referenced as a local Swift package through
    `XCLocalSwiftPackageReference` and mirrored entries in `project.pbxproj`.
  - Upstream: https://github.com/everlof/thinking-orbs-swift — **our fork**, mod it directly.
  - The app uses only the AppKit `ThinkingOrbView` (a plain `NSView` drawing through a
    CoreGraphics engine, display link on 14+ / 60Hz timer on 13). SwiftUI ships in the package
    but the app touches none of it, so the app itself stays AppKit-only.
  - The fork tracks upstream's nine tuned states at both 64pt and 20pt: working/orbits,
    searching/globe, solving/rubik, listening/wave, connecting/web, weaving/braid,
    composing/ribbon, breathing/ring, and shaping/morph. Threading exposes all nine as fixed
    Motion choices and includes all nine in the no-immediate-repeat Random pool.
  - **The `tint` seam is ours.** The stock engine draws grayscale ink keyed off a `dark: Bool`,
    so it follows macOS light/dark but knows nothing of Threading's accent. `paint` and the
    connecting mode's `paintLines` gained an optional `tint`: when set, depth rides on opacity
    instead of luminance (an ink mark's visibility is `1 - white` on either substrate), so a
    tinted orb reads identically in light and dark, only in the accent's hue. `WorkingOrbView`
    (in `UI/Design/`) is the theme boundary that drives it from `Design.Surface.accent`,
    re-resolved on a live theme switch and an appearance change.

- **LabelMorph** (local fork): the single-line label that morphs a name character by
  character when it changes, used for every session, project and checkout name the app shows.
  - Location: `./Packages/Vendor/LabelMorph/` (git submodule), a local Swift package like the other two.
  - Upstream: https://github.com/everlof/LabelMorph — **our fork**, mod it directly.
  - `MorphingTitleLabel` (in `UI/Design/`) is the theme boundary: the package owns glyph
    layout and animation, the wrapper owns the semantic ink, Reduce Motion, clipping,
    accessibility and the user's chosen preset.
  - **Tempo is ours.** `MorphPreset.recommendedTiming` is tuned to show an effect off — one
    large title, watched — and the wrapper brings it to the app's own pace before every morph:
    the per-character duration scaled by `Design.Motion.nameMorphTempo`, and the stagger held
    to a *total* cascade (`Design.Motion.nameMorphCascade`) rather than a per-character step.
    The second is the one that mattered. A stagger is multiplied by the name, so at the default
    preset's 45ms a 26-character session title took 1.7s to settle against a one-word project
    name's 0.8 — the same transition reading as slower the more there was to read, and sidebar
    names are sentences. Budgeted, a transition lands near half a second at any length, and a
    name short enough to fit inside the budget still cascades exactly as the preset asked.
    `morphSettleDuration(to:)` resolves the same timing for the name it is asked about, so a
    repeating preview waits for what will actually play rather than for the last morph's length.
  - **Truncation is ours.** The stock label lays a whole line out from the leading edge and
    lets it run past the view, which the wrapper's clip then cuts dead mid-glyph. That is
    fine for a toolbar item sized to its text and wrong for every sidebar row, where names
    are sentences and the pane is the narrow one. `MorphTruncation.tail` keeps the longest
    head that fits and ends it with an ellipsis — found with one `CTLineGetStringIndexForPosition`
    rather than a search, then verified and stepped back by *composed character* so a cut
    never lands inside a surrogate pair. `intrinsicContentSize` still reports the whole
    text's width, so Auto Layout hears what the label wants and truncation only describes
    what it does once given less.
  - **Assigning the value already in force costs nothing** (`font`, `textColor`,
    `alignment` all guard on equality). Each rebuilds or repaints every glyph layer, and a
    sidebar row restates all three on every configure — which happens continuously while an
    agent works.
  - **Glyph rasterisation is ours** (`GlyphRaster`, `GlyphLayer`). The stock label draws each
    character with a `CATextLayer`, which is invisible at 2x and measurably worse at 1x —
    an external monitor at its native resolution, where one point is one pixel. Against
    AppKit's own rasterisation of the same line at 13pt (ink = mean coverage, edge = mean
    absolute horizontal gradient), a `CATextLayer` line measures ink 0.1187 / edge 27.73
    where AppKit measures 0.1397 / 34.21. Two causes, and a trap under each:
    - *Font smoothing does not run in a transparent context.* Smoothing is the
      stem-darkening pass macOS applies below 2x, and a `CATextLayer` owns a transparent
      backing store, so it never gets it. The fix is to draw the glyph against an **opaque**
      ground — but the tiles cannot then be used as they are, because glyphs overlap by
      their side bearings and each opaque tile paints its ground over its neighbour's
      overhang. That version measured 0.0984, *lighter* than the `CATextLayer` it replaced.
      So the smoothed pixels are inverted back into a coverage mask, which keeps the
      dilation and restores transparency. Only the ground's **polarity** matters: coverage
      measures identical against white and any other light colour, and likewise on the dark
      side, which is why `MorphingTitleLabel` states one structural role rather than each
      row's exact fill.
    - *A fractional layer origin is resampled by the compositor.* The tile is snapped to
      whole device pixels and the remainder baked into the raster. The bake size is not a
      free choice: Core Graphics quantises horizontal glyph positions to **thirds** of a
      device pixel, so sweeping a glyph across one pixel yields exactly three distinct
      rasters. Three phases reproduce AppKit exactly; four looks entirely reasonable and
      lands a third of the glyphs in the wrong bucket.
  - **A glyph layer's frame is a raster tile, not the glyph's metrics.** It is padded for
    ink that overhangs the advance and snapped to the pixel grid, so it always overruns the
    text it draws. `CharacterSlot.inkFrame` (exposed as `MorphingLabel.glyphInkFrames`) is
    the box Core Text laid the glyph out in — that is what a caller asking whether a line
    fits, or aligning to its last character, means. Two tests asserted "no glyph runs past
    the label" against the layer frame and started failing on the padding.
  - **Backing-scale changes re-lay out rather than repaint.** A `CATextLayer` re-renders
    itself when `contentsScale` moves, so the old code only had to retag it. A bitmap does
    not, and the slots are scale-dependent besides — they are snapped to a specific pixel
    grid — so dragging a window between a Retina screen and a 1x one rebuilds the line.
  - **Width-only relayout reuses glyphs.** A divider drag used to make every visible title
    rebuild every glyph layer whenever tail truncation crossed one character boundary. The
    unchanged leading prefix now keeps its layers, a changed suffix alone is replaced, and a
    layer whose raster inputs stayed equal moves without invalidating its bitmap. A leading
    line whose displayed text did not change skips Core Text layout entirely; centered and
    trailing lines still respond to width, every alignment still responds to height, and a
    backing-scale change remains a full rebuild. The production sidebar sweep in
    `SidebarTreeBuilderTests` drives 5,000 sessions through 120 width ticks from 220 to 600
    points and back. On the profiling machine this moved resize p95 from 10.9–12.5 ms to
    6.0–6.4 ms, and total resize work from 400–453 ms to 282–300 ms.

- **BorderBeamKit** (local fork): the breathing agent-activity ring over both composers,
  extracted from the author's own verified SwiftUI port.
  - Location: `./Packages/Vendor/BorderBeamKit/` (git submodule), a local Swift package like the other two.
  - Upstream: https://github.com/Jakubantalik/border-beam — the `ports/ios/BorderBeamKit`
    tree of the MIT-licensed web library, extracted into a standalone package with a macOS
    demo app (`Demo/run.sh`) replicating the site's playground. **Ours to modify directly.**
    All visual data decodes from the bundled `beam-spec.json` generated from the web source;
    the package's snapshot suite renders the full 40-combination matrix through the real
    SwiftUI + Metal pipeline and fails on any blank frame, which is what pins the pixels —
    app-side tests deliberately assert judgement, not beam pixels.
  - **The AppKit seam is ours** (`BorderBeamHostView`). The rendering is SwiftUI Shader API,
    which the app must never touch (ThinkingOrbs' containment): the package exposes an
    `NSView` that is decorative by contract — `hitTest` answers nil, no accessibility
    elements — and whose `rendersStatically` pins the internal frozen-time environment. That
    pin now also *pauses* the driving `TimelineView` (t and fade are both constants there),
    so the Reduce Motion mode is a genuinely static picture rather than 60 identical frames
    a second. AppKit's recursive `cacheDisplay` does not preserve a transparent
    `NSHostingView` root: it rasterizes the centre white even though the live compositor is
    correct. `BorderBeamHostView.withCachedDisplayFallback` is therefore the explicit
    offscreen-render contract. It hides only the live shader host for the synchronous draw and
    paints a deterministic spec-derived ring, preserving every surface pixel beneath it. The
    package regression samples the centre after a parent-view cache, and application screenshot
    code reaches the contract only through `AgentActivityBeamView` so the package type remains
    contained at the design-system boundary.
  - **The platform floor is ours.** The Shader APIs need macOS 14 but Threading deploys to
    13, so the package declares `.macOS(.v13)` and every SwiftUI view carries
    `@available(macOS 14.0, *)`. `AgentActivityBeamView` (in `UI/Design/`) is the theme
    boundary that embeds the host behind a runtime availability check — on macOS 13 the
    ring simply does not exist. It also owns the whole visual policy: the count-to-strength
    curve, the adaptive-mono-to-colorful escalation at top ladder effort, and the System-theme-only
    gate (re-read on `AppThemeDidChange`; a styled theme removes the ring outright rather
    than letting the beam's own half-second fade trail the one-pass theme sweep).
  - The `.metal` shader is compiled by Xcode's build system only — a plain `swift build` of
    the package leaves it uncompiled and the beam invisible, which is why the package's
    scripts all go through `xcodebuild`.

- **NativeDiffKit** (remote, ours): the diff *rendering* — line layout, syntax highlighting,
  wrapping, sizing — shared between this app's AppKit views and a UIKit sibling.
  - Location: resolved by SwiftPM (`XCRemoteSwiftPackageReference`), **not** a checkout in
    this tree; editing it means working in its own repository and bumping the pin.
  - Upstream: https://github.com/everlof/NativeDiffKit — ours.
  - `DiffView` (in `UI/Views/`) is the boundary: a thin theme/defaults adapter over
    `NativeDiffAppKit.DiffAppKitView`, re-resolving its palette on theme and backdrop
    changes. Git loading, staging and app theming stay in the app; `GitFileDiff` is a
    typealias for the package's `DiffFile`, and `GitDiffParser.files(fromUnifiedDiff:)`
    delegates to its `UnifiedDiffParser`.
  - **One parser trap worth knowing:** `UnifiedDiffParser` checks `isBinary` before the
    change kind, so a binary add/delete/rename collapses to `.binary` and loses its mode and
    rename lines — which is why Git Review's image rows cannot tell a renamed binary from an
    added one.
  - `ImageCompareView` lives in the app (`UI/Design/`), not the package, for now — hoisting
    it beside the text renderer is the intended move once its modes settle, and its theme
    adapter seam was cut to make that mechanical.
