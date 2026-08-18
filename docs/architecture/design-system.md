# Design System

The component vocabulary, the themed controls, and the bugs each rule came from.

Part of the [CLAUDE.md](../../CLAUDE.md) index. The boundary *policy* — what feature code may
construct, and what a new component owes — is [`docs/THEME_BOUNDARY.md`](../THEME_BOUNDARY.md);
this file is the vocabulary and the reasoning behind it.

**New UI is built from `Sources/Threading/UI/Design/`, not from stock AppKit controls.** This is
the default, not a preference: a screen assembled from `NSPopUpButton`, `NSBox` and bezelled
buttons will not match anything else in the app.

`Design.swift` holds every measurement, weight and surface colour. Reach for a token rather
than a number — a literal in a view is how the language erodes. The scale is deliberately
small (`Spacing` is 2/4/6/10/12/20/32); a value between two steps is nearly always a mistake.

**Type is applied with `applyFont(.role)`, never with `label.font =`.** A theme states a
typeface as well as a palette (`AppTheme.Material.typeface`), and an assigned `NSFont` freezes
onto a label exactly as a `CGColor` freezes onto a layer — so a direct assignment looks right
and then keeps the previous typeface through every live switch, which is invisible until
someone switches one. `Design.FontRole` is the *recipe* (`.body`, `.detail(weight: .medium)`,
`.code()`), `applyFont` records it on the view, and `AppThemeRefresh`'s sweep resolves it
again. `.swiftlint.yml`'s `frozen_theme_font` catches the direct form in the editor; note that
the canonical SwiftSyntax checker does **not** cover this one, so the fast rule is the only
guard.

`Design.Typography` also owns the user's **semantic text scale**. `AppTextSize` is a bounded
compact/default/large/extra-large preference, and every role factory applies its scale at the
point where a font enters the system. This includes prose, monospaced code, fixed-width
numerics, control marks, conversations, Settings, and semantic extension nodes. It deliberately
does not include a terminal: `TerminalProfile` stores an explicit family and point size, so
terminal sizing remains useful independently of the surrounding interface. A text-scale change
joins the same `AppThemeRefresh` sweep as a family override, which re-resolves roles already
recorded on live views and rebuilds attributed surfaces through `AppThemeDidChange`.

Git Review adds a second, deliberately local scale on top of that global choice.
`Design.CodeTextScale` is the bounded compact/standard/large/extra-large/maximum ladder used by
the review header's smaller/larger controls. `Typography.code` composes it after the app and
theme scale, so making a diff easier to read neither changes prose throughout the app nor loses
the user's global accessibility choice. This is a reader preference, not arbitrary point-size
state: persist the named step and disable the controls at the ends of the ladder.

**The app and an extension have separate localization domains.** Built-in presentation copy
resolves through `L10n` and `Localizable.xcstrings`; shared `SettingsUI` builders localize their
built-in titles and descriptions by default. Extension Settings renderers explicitly disable
that lookup because their strings have already passed through
`ExtensionLocalizationResolver`. That separation prevents an extension base string such as
“General” from accidentally borrowing Threading's translation. Stable page IDs, setting IDs,
command IDs, values, and schemas are never localized.

The global command palette is a design-system surface, not menu chrome rebuilt in feature code.
`CommandPaletteViewController` uses `ThemedSearchField`, `ThemedTableView`, `ThemedScrollView` and
`ThemedSurfaceView`; its table owns the viewport while descriptor values remain lightweight. The
palette caps presentation at 100 rows, filters on a cancellable background task, preserves the
resolved shortcut spelling, and exposes disabled reasons to both visible detail and accessibility.
It owns focus, Escape, arrows and Return only; command meaning stays in the host command plane.

Four consequences worth knowing before adding UI:

- **Prose in the conversation passes `.conversation`**: `applyFont(.body, in: .conversation)`.
  The thread is the surface a reader *reads*, so it has its own override slot the way the
  terminal beside it always has — the recorded surface is what lets the sweep re-resolve a
  thread label against the conversation's font and a settings label against the app's. Chrome is
  the default and needs no argument. See [`themes.md`](themes.md) for the four resolution layers.
- **A view type joins by conforming to `FontRoleApplying`**, not by observing a notification —
  `NSTextField`, `NSTextView`, `MorphingTitleLabel` and `ThemedButton` do. A drawn control that
  reads `Design.Typography` inside `draw(_:)` follows for free and needs nothing, *unless* a
  call site overrides its `font`, which is a stored property like any other.
- **A built `NSAttributedString` does not follow**, because the font freezes into the string
  rather than onto the view. Those surfaces rebuild instead: Git Review re-reads on
  `AppThemeDidChange`, `ThemedTextField` rebuilds its placeholder. Prefer drawing in `draw(_:)`
  (as `PromptView`'s placeholder does) where the choice is available.
- **A detached tree is in no window, so the sweep never reaches it.** A cached settings page takes
  `AppThemeRefresh.repaint` on attach for that reason. Retained conversations use
  `repaintIfNeeded`: every whole-window sweep advances a generation and stamps the views it
  reached, so a tree that actually missed a theme/accessibility/font change is repaired on
  return while an ordinary hot session switch does not recursively repaint hundreds of rows.
  The same invalidation rule applies to any surface the app keeps alive off-screen, and it covers
  stale layer colours as well as stale fonts. **A list's reuse queue is the third such surface
  and the least visible**, because nothing in a list's code says a view is being kept: it is
  handled once, in `ThemedTableRowDefaults.vendedView(for:recycling:)`, so no list has to know.
  See [`themes.md`](themes.md#2026-08-14--a-view-in-the-reuse-queue-misses-the-sweep) for the
  Tiger sidebar row this shipped as.

Components so far:

| | |
|---|---|
| `ChipView` | A compact chooser that opens a menu. **The pill is the hover, not the chip**: at rest it draws no plate, no border and no glow — the answer it is showing is content, and content on this surface is set in text, which is the rule `PageTitleView` and every plain `ThemedButton` already keep. The plate rises for the three states that mean *you are on this one* — the pointer, an open menu, the keyboard focus — and the ink rises with it on one ramp: the title `secondary`→`label`, the mark and chevron `tertiary`→`secondary`. Quiet at rest because a row of settings is not the content of the screen it sits under; the step is **ink only**, at a fixed `controlRegular` weight, since a bolder face on hover is a wider one and the row would reflow under the pointer. `horizontalPadding` is `Spacing.small` and is carried by the frame in every state, so nothing reflows as the plate appears, and `OpticalInsetProviding` reports it for a row aligning by ink. A material may instead request the classic square dropdown anatomy: sunken value well, separate raised arrow button, regular control text, and no SF-symbol decoration. The same authorable choice carries through the shared menu presenter, whose compact rows, flat selection band, etched separators, filled arrows, edge attachment, and hard panel edge complete the control instead of leaving a modern popover under a period button. See [2026-08-13 below](#2026-08-13--a-row-of-pills-was-six-objects-where-the-answer-was-six-words). |
| `UsageReadingLabel` | An account's rate-limit windows as one line — `5h 43% · 7d 73%` — that gives up **whole windows** rather than characters when the row squeezes it. Given room for one it states one, complete; given room for none it draws nothing and leaves the row to the controls. Its intrinsic width is always the whole line, so a dropped window returns when the window widens — sizing to what it last drew would be a ratchet. One composition, shared with the toolbar pill (`AccountUsageItemView`), so the reading a session is started on is the reading the pill goes on showing: name a tier under value, and the value tinted only once its window is close enough to its limit for the colour to mean anything. |
| `CodeContextPreviewView` | The bounded diff-shaped context above a code-comment field. It keeps two neighbouring rendered rows around an ordinary target, preserves additions/removals and line numbers, and marks every target row with the theme's selection surface plus a leading `›` so the distinction survives without colour. The presentation model draws at most ten code rows; a larger selection retains both ends around one counted omission row, while the attachment still carries the complete selected excerpt. |
| `ConversationContextRailView` | The compact reference/comment receipts shared by the Chat composer and sent-message transcript. It groups a large batch into quiet count chips, then uses the themed menu for inspection, removal, re-reference, and comment actions. |
| `SubagentSummaryView` | The compact child-agent navigator shared by the overview and transcript pane. Feature code supplies `SubagentSummaryItem.TranscriptAvailability` as one of three states: unavailable, openable from memory/while still running, or on disk with the file URL. A file-backed row is therefore structurally openable and revealable; the chevron and Finder action cannot disagree through independent Boolean/optional inputs. Optional usage arrives as already formatted semantic text, keeping provider accounting out of Design while adding no new rows beyond the navigator's existing cardinality. |
| `ThemedSegmentedControl` | Two or three fixed choices with all of them on screen: a track at `controlResting` with the selected segment lifted to `controlHover`. Built as a container of small `ThemedControl`s, the same shape as `ThemedTabStripView`, so each segment inherits hover, focus and its `.radioButton` role rather than one element re-deriving all three for parts of itself that are not views. An unselected segment answers the pointer in *ink* rather than taking a third fill step, because the scale has two control fills and a third invented here is how a scale stops being a scale. Arrow keys walk the run and take the selection with them; the ends hold rather than wrap. A pointer press leaves the segment as first responder so those arrows remain available, but the focus ring is drawn only when focus arrived from the keyboard: the filled plate is the held choice, and outlining it after a click is a second, misleading selection mark. |
| `PromptView` | A rounded container holding a growing text view and its submit control, as one input. |
| `AnnotatedImageView` / `ImageAnnotationRailView` | A picture you can point at, and one numbered field per place you pointed. `ThemedImagePreview`'s sibling rather than a mode on it: that control's whole gesture is *one press opens the inspector* — click, Space, force click and VoiceOver's press all land on the same action — and a click that sometimes drops a pin instead would make the most-used image affordance in the app conditional on a flag its call sites cannot see. Here the click is the mark and the **keyboard** opens the picture full size, which is the inverse contract stated once rather than a branch inside the shared one. The scale is `ThemedImagePreview.fittedRect` itself so the two never disagree about size; the placement differs deliberately (centred, not top-pinned — this view *is* its column and runs the full depth of the sheet). Neither view owns the list: the host does, because the same marks are shown by the picture, by the rail, and by the fullscreen inspector's canvas at the same time. Focus is the tie — a field taking the caret lights its own pin, and a click on a pin puts the caret in its field. Bounded at `ImageAnnotationDefaults.maximumCount` (20), which is what makes a retained stack of rows the right shape. The pin is **`BrowserAnnotationOverlay`'s pin**: same chip height, border weight, accent fill with the ground stroked around it, `numericDetail` number, top-most-wins hit test — a second numbered mark with its own anatomy would be two annotation vocabularies in one app. |
| `PaneNoticeView` | A standing condition between a pane header and its content, pushed into layout rather than drawn over it. Ordinary notices are one message line; a technical diagnosis may add a short title above a two-line explanation. The warning/information mark, exact copy, compact intrinsic-width actions and keyboard-reachable dismissal remain one accessible group. It owns its ground because the pane beneath it may be an unrelated terminal palette. A condition whose evidence is a picture may add one `accessory` view, placed between the sentence and the answers and never squeezed by either: evidence belongs with the words it supports, not out at the margin among the controls. |
| `ColorPairSpecimenView` | Two reported colours shown touching, with type-specimen glyphs drawn in the first over the second, under a two-word caption. Nothing is drawn between the halves on purpose — a divider is a seam the eye finds whether or not the colours differ, and a pair that still reads as one field is the finding. The outline is what keeps the swatch legible when that happens, and it is stroked outside the fills' clip. The caption is not decoration: the reported case draws *nothing*, and an unlabelled empty rounded box in a row of controls reads as a text field rather than as a colour sample — which is also why the swatch is a mark's height rather than nearly a button's. The pair is a *reported* colour and never follows the app theme; the outline, caption, glyph typography and size do. |
| `ThemedControl` | The base for a control that draws itself from the theme. |
| `ThemedToggle` | A drop-in `NSSwitch` whose on-track is the theme's accent. `material.toggle_style` may instead select the compact ON/OFF hardware latch; behavior, target/action, keyboard access, and its checkbox accessibility contract stay identical. |
| `ThemedCheckbox` / `ThemedRadioButton` | Binary and mutually-exclusive option marks with their own focus, accessibility, disabled, and period geometry. Win98's named family uses a 13px square tick field and the pinned 98.css 12×12 indexed pixel radio sprite with a separate four-pixel dot, while modern materials retain the standard accent marks. |
| `ThemedPopUp` | A drop-in `NSPopUpButton`, button included and dropdown excepted. `addHeader` files a long list under `ThemedMenuEntry.header` section names without demoting anything into a submenu; because a head is an entry and not an item, the control opens on its first *item* and callers find a row with `indexOfItem(where:)` rather than by an index taken from the model they built it from. |
| `ThemedButton` | A drop-in `NSButton`: bordered, plain, or prominent — `emphasis` names those three as primary/secondary/tertiary, `buttonStyle.primaryTreatment` decides whether a primary is filled, outlined, or a classic raised default action, and `shortcut` draws the chord it answers to on its own face. Ordinary actions centre their icon/title unit; a menu cell opts into leading content alignment and fills its host column, so the hover and hit target describe the whole cell while the ink keeps a stable edge. `showsSubmenuIndicator` reserves a real trailing chevron column for a hover/detail destination, so long titles truncate before the cue instead of taking it with them. `buttonStyle.titleRendering: pixel_5x6` selects the clean-room one-bit display alphabet for supported titles; a title containing any unsupported localized character stays whole and falls back to the scalable font. |
| `ThemedActionPopoverViewController` | A bounded rich preview followed by a short menu-like command list. It takes structured action/separator entries, makes every action a full-cell `ThemedButton`, and applies `SeparatorView`'s visible-ink spacing. The caller constructs the optional preview only from the hover scheduler's presentation callback, never while mounting the anchor list. |
| `ThemedTextField` | A drop-in editable `NSTextField`, bezel drawn rather than stock. `SurfacePresentation.persistent` is the ordinary standing well; `.onInteraction` keeps the same text inset, frame and hit target while drawing no plate at rest, raises `controlHover` under the pointer, and restores the ordinary well and focus ring for editing — the browser address bar's content-first grammar. `Design.Size.fieldHeight`, its own step: it borrowed `chipHeight` for as long as a field was "a chip you can type in", and a chip holds a word at rest where a field holds a caret. With a 2pt rule on each side, 26 left twenty points inside for a 13pt face — about three points of air — and the text read as wedged against the border. The two fields placed by frame rather than by intrinsic size (`TextPromptDefaults.fieldHeight`, `SidebarDefaults.renameFieldHeight`) restate the same token. **The cell is put on `wraps = false`, `isScrollable = true` in `setup()`**, which AppKit gives only through the `NSTextField(string:)` factory that `cellClass` rules out: a cell built by `init(frame:)` wraps, and a wrapping cell grows its *field editor* rather than scrolling it — 128pt of editor inside the `fieldHeight` well, unclipped by the control, so a sentence longer than the row drew its earlier lines through the field's own top border and over the row above. Settings' opening message shipped that way; multi-line editing is `ThemedTextView`, not a taller field. |
| `ThemedSearchField` | The same field with a magnifier, replacing `NSSearchField`. |
| `PanelListView` | The display panel's list vocabulary: a scrolling stack of full-width rows under quiet section headings, with wrapped notes for a section that has no rows. Extracted after the Info and Sharing panes each built the same scroll–clip–stack by hand with silently different insets, which is how one pane's headings stopped lining up with anything above them. The geometry is stated once — content ink at `Spacing.inset`, on the pane header's own column — and `rowSpacing` is the one density decision a pane keeps. A heading never carries the count of its rows: the rows make the count apparent, a decision the Sharing pane made first and the component keeps panes from re-deciding apart. |
| `SearchMatchLabel` | The other half of a search field: a line of text that says which of its own words the query accounts for. **Two signals, always both** — the matched run takes its role's `emphasized` weight *and* `Design.Surface.searchMatch`, an accent held at `Opacity.searchMatchGround` behind it. Weight alone vanishes in a list where several rows matched; a tint alone is the first thing Differentiate Without Colour takes away. It is a component rather than a call to `NSTextField.label(attributed:)` because an attributed string freezes its fonts and inks and `AppThemeRefresh`'s sweep re-resolves a *recorded role*, which it cannot reach inside — so this rebuilds on `AppThemeDidChange`, the same wiring `ThemedTextField`'s placeholder carries. `SearchTextMatch` is where "a query landed here" is decided, and filters may read its `comparisonOptions` so a result cannot be admitted by a more forgiving spelling than the mark uses. Its second rule is the one to know: **a token containing the whole line marks all of it**, which is what makes a row showing eight characters of a session id answer honestly to a pasted thirty-six-character one. |
| `SearchResultRowView` | One destination a search turned up, with where it lives: a `SearchMatchLabel` title over a quiet caption path line — the settings sidebar's "Alert sound / Notifications" under the General row. A component of its own rather than a taller `ThemedTabItemView`: a tab names a *place* and holds one line forever, while a result names a thing the reader just asked for and owes them the path to it; what the two share (hover plate, press, keyboard activation, focus ring, ink source) they share through `BackdropThemedControl`. The host hands it the leading inset of the rows above so results align with the page row's title ink. Choosing one reports page **and** row, because the row is the answer — the settings sidebar routes that through `SettingsRowReveal`, which scrolls the built page to the anchored row (`SettingsRowAnchor`, the tag `SettingsUI` puts on every titled row) and stands the wash below on it. |
| `RevealHighlightView` | The wash a search leaves on the row it just scrolled to: `Design.Surface.searchMatch` — the same ground `SearchMatchLabel` puts behind matched text, so "the query landed here" is one signal at both scales — fading in, standing `Design.Motion.revealHold`, and leaving. Decorative by contract: `hitTest` nil, not an accessibility element (the reveal posts its own announcement), drawn in `draw(_:)` so a live theme switch re-resolves it. The fades collapse under Reduce Motion; the hold does not, because a hold is not movement and being seen standing still is its whole job. |
| `SemanticSceneView` | A bounded semantic visualization drawn from normalized marks. It is intentionally not a named chart or extension-specific tree: rectangles, rounded rectangles, and ellipses cover treemaps, heatmaps, timelines, scatter plots, and bubbles. Measured values belong in `ChartCardView` instead: this component is handed geometry and trusts it, which is the right contract for a caller that already has coordinates and the wrong one for a caller that has numbers. Each mark is a native accessible element and, when actionable, a `ThemedControl` with pointer, keyboard, hover, focus, enabled, and selected states. Callers supply semantic colour roles; the design system owns every pixel. |
| `ChartCardView` | One agent-produced chart — title plus chart — over a `ChartSpec` of values, categories and words. The same card serves the display panel and an inline conversation row, so a chart the user scrolled past and a chart they opened in the panel cannot be two different pictures. It answers `preferredHeight(for:)` before it exists, which is what a virtualized transcript row needs, and rounds the value axis to a readable ceiling rather than fitting it to the data. In a pane it takes the height its own shape asks for (`boundedHeight(for:)`) instead of whatever the panel has: a **ranking** is a row per category and leaves a taller pane as ground beneath it, since stretching a category axis only stretches the gaps, while a chart whose vertical axis is the *value* fills the pane because there the room is resolution. Re-applying a spec re-animates the retained chart; only a change of composition rebuilds it, because a stacked total cannot be interpolated from independent heights without drawing a frame that described no data. |
| `ThemedTimeSeriesChartView` / `ThemedStackedBandChartView` | Two reusable retained time-series boundaries over the same data model. The first keeps independent zero-baseline series; the second requires aligned timestamps and draws additive bands whose final upper edge is the total. Both own axes, native drawing, bounded monotone curves, hover/keyboard inspection, accessibility, a 240-point-per-series cap, two-edge morph animation and synchronous Reduce Motion. Material selects presentation: continuous curves normally, or a segmented spectrum analyzer for Classic Player and imported player skins. Projections may remain explicitly linear and dashed in either material. Both also draw **bars** — grouped or stacked, vertical or as a horizontal ranking — over a categorical axis, on the same geometry: a bar is `baselineY → y` in the space a line already occupies, so composition alone decides grouped versus stacked. A bar stays a bar in every material; the spectrum analyzer renders filled bands, and running a three-category comparison through it answers the question with a column of cells. **A categorical chart's name gutter is part of its hover target**: a category name is a word in a fixed-width slot, so a long one is drawn as an ellipsized stub, and the pointer that goes to read it used to land outside the plot and be answered by nothing. Pointing at the name or at the band it labels states the same lines — the whole name *and* its reading, since a thin bar prints no number of its own — from the one list the accessibility value reads. With nothing to plot the model's `emptyMessage`/`emptyDetail`/`placeholder` reach `ThemedChartPlaceholderView` and the **value axis prints no numbers**: an empty chart labelling its rules 0/0.2/0.5/0.8/1 is the automatic domain describing itself rather than anything anyone measured. See [`usage-dashboard.md`](usage-dashboard.md) and [`mcp-and-display.md`](mcp-and-display.md). |
| `UsageDashboardView` | The retained Usage composition has separate Overview and Limit History tabs. Overview pairs a large total and top-three tool split with the shared stacked-band chart—top three routes plus an additive Other band—then a five-metric strip, virtual breakdown and explicit coverage. Limit History owns its chooser, reset/projection summary and independent-series chart. It accepts immutable report/history values; filesystem scans, CLI exports, provider calls and journal I/O remain outside the design boundary. |
| `ThemedSpinner` / `ThemedProgressBar` | `NSProgressIndicator`, in the theme's accent. A spinner nested in a host-painted emphasized selection takes that ground's label ink instead, so the accent does not draw invisibly on the accent. |
| `DiffSkeletonView` | The ghost of a diff body whose real document is deferred or still loading — Git Review's scroller-thumb seek rows and its pending progressive rows. A repeating hunk-shaped silhouette of quiet context bars whose changed run splits by the file's own +/− counts, tinted at `Opacity.skeletonDiffTint` so it whispers the weight without becoming content; a file lacking a kind ghosts none of it. Drawing visits only the bar rows intersecting `dirtyRect`, so a document-sized body costs the viewport. The pulse is a layer-opacity loop — the spinner's no-redraw-timer discipline — removed rather than slowed under Reduce Motion, the still bars remaining as the status; a rehosted row re-arms it itself, since a virtual table drops layer animations constantly. Decorative by contract: the row's header carries the loading state. |
| `ThemedChartPlaceholderView` | What a chart says when it has no series: a ghost of the shape that is coming, the status in words, and a `ThemedProgressBar` when the work reports a total. It sits over the *plot rectangle*, so the message lands where the marks would be and the axes keep their gutters. Two states that must not look alike — `.empty` is a finished answer and stands still under a dotted zero baseline, `.loading` is a promise and breathes `DiffSkeletonView`'s pulse over a two-run silhouette at `Opacity.skeletonChartBand`. The status is real labels rather than a centred string in `draw(_:)`: drawn text cannot be reached by VoiceOver, cannot wrap in a narrow pane, and cannot carry a bar beside it. Not a target (`hitTest` returns nil), so the chart underneath keeps its hover and selection; not an accessibility element itself, since the chart's group value already carries the summary. Built lazily — a chart that always had data never constructs it. |
| `ThemedScroller` | AppKit's live scrollbar value and tracking with two authored presentations. `automatic` draws a modern proportional thumb/track from the correct ink source and owns SwiftTerm's otherwise-missing overlay fade; System delegates to AppKit. A named period family owns persistent legacy geometry, arrow hit regions and placement, track relief or stipple, and the era's thumb/grip — including Aqua gel — while continuing to use the normal `NSScroller` action path. A period trough with no range is **empty**, arrows quieted: AppKit disables a spent scroller but keeps the knob proportion its page last needed, and drawing from that stale figure gave a settled Settings sidebar a two-thirds thumb it could not move. A period appearance also declines `wantsUpdateLayer`, because the layer path calls only the part hooks and clips each to AppKit's own rectangle rather than to this component's (see [`themes.md`](themes.md)). |
| `ThemedScrollView` | An `NSScrollView` that starts transparent — the stock one paints a system surface — and installs themed vertical and horizontal scrollers without enabling either. A period scroller forces legacy-width space because its arrows are permanent furniture. A material may move the vertical scroller to the leading edge; layout mirrors AppKit's reservation. The project tree opts into `.sidebarNavigator`, which resolves an authored fill/bevel and insets the document inside its edge; every other call site stays transparent. A nested horizontal-only viewport opts into `forwardsVerticalScrollToAncestor`, so code and tables do not trap a conversation's vertical gesture. |
| `ThemedTextView` | An `NSTextView` in theme colours; `.scrolling()` replaces `scrollableTextView()`. |
| `ThemedTableRowView` | Every list's row, including the lists that never say so (`ThemedTableRowDefaults`). It draws selection — held back to the ink it contains under a style, handed to AppKit under System — and any *other* plate a row needs, today `isDropTarget`. Such a plate takes **the selection's own silhouette**, which is not always ours: under System an inset-style table pads its selection 10 points in from the row (`systemInsetStylePadding`) while our path stops a hairline in, so a wash drawn from `selectionPath` ran the full width of a list whose selection did not, and one drawn from the *cell* — inset further still — stood as tall as the selection and visibly narrower. Neither number is AppKit's to publish, so the pin is a pixel comparison of the two plates as drawn (`testTheDropWashTakesTheSelectionsOwnShape`). |
| `ThemedTableView` / `ThemedOutlineView` | Tables that start transparent, replacing the system background. A row's secondary click — and accessibility's "show menu", its pointerless twin — is *reported* (`onContextMenu`, with the row under the gesture and the anchor it carries) rather than answered with an `NSMenu`, so the host presents an app-owned dropdown; the two classes restate that hook rather than share it, because `NSOutlineView` is already an `NSTableView`. A list that draws its own drop affordance instead of AppKit's also needs `onDraggingExited`: a drag leaving or ending is told to the *view* and to no delegate method, so without it the affordance stays lit on the last row the pointer crossed. `onQuickLook` reports the preview keys — bare Space on the selected row, the trackpad's three-finger tap or force click on the row under the pointer — on the same contract: the host answers whether that row holds anything to inspect, and a `false` answer hands the event back to AppKit, so type-select survives in every list that sets no hook and a modified Space is never taken from the system. |
| `ThemedTableHeaderView` | A semantic-role table header that retains AppKit resizing and tracking. |
| `ThemedTableRowView` | The row a list is *selected* in, handed back from `rowViewForRow:`/`rowViewForItem:`. Fills with `Design.Surface.selection` — the accent held back far enough that the row's own label tiers still read over it, so a themed list needs no second set of inks — at the theme's control corner, inset a hair so two selected rows read as two. Under **System** it defers to `super`, keeping AppKit's own highlight. Not the sidebar's row: `SidebarHoverRowView` fills with the accent at full strength because the selected session is the window's subject, and draws its own capsule under every theme — System included — because that shape closes with the column the divider narrows. |
| `SeparatorView` | A hairline rule, replacing `NSBox(boxType: .separator)`. `frameGap(to:forInkGap:)` and `applyOpticalSpacing(in:precededBy:followedBy:inkGap:)` keep an authored gap between the rule and visible content on either axis: the adjacent `OpticalInsetProviding` control owns its invisible padding, while bare content keeps the full gap. |
| `HoverTrackingView` / `HoverPopoverScheduler` | The pointer bridge and timing policy for hover-presented detail. A `ThemedControl` anchor reports its already-shared state through `onHoverChange`; a feature does not install a competing tracking area over it. The surface root reports crossing into the popover, while the scheduler owns dwell, crossing grace, and cancellation. |
| `ThemedStatusProgressRing` | A compact semantic ring for bounded completed/pending/failed counts. It draws a neutral track plus positive and negative slices; adjacent text must name every non-zero bucket so hue is never the only signal. |
| `ThemeSwatchView` | A palette chip; the one place `NSColorWell` still lives. |
| `ThemedSplitView` | An `NSSplitView` whose divider is measured against the window backdrop on every ground, stepping up to the theme's border on chrome or neutral ink over an unrelated terminal palette when its rule would disappear, and weighed by the theme's rule width rather than AppKit's fixed hairline. |
| `ThemedSurfaceView` | A pane's ground, and the one view that re-resolves its fill on a *system* light/dark switch. |
| `SidebarBackdropView` | The sidebar's ground: the platform's sidebar material under the identity theme, an opaque themed surface under a style — plus the gradient and image layers a style's `SidebarStyle.Background` states, every frozen layer colour restated per apply. |
| `ThreadingMarkView` | The Threading mark drawn live from `ThreadingMarkGeometry` (the same normalized silhouette the app icon and the SVG state): brand threads under System, the theme's accent held legible under a style, and a one-shot `playDrawIn()` that strokes the shield, stitches the six strands and lands the core. Its opt-in particle presentation samples that same geometry into individually tintable points and offers Weave, Breathe and Orbit cadences; no particle layer is built for passive marks, no cadence runs at rest, and none is constructed under Reduce Motion. Decorative; the brand row beside it carries the accessible name. |
| `SidebarBrandView` | The sidebar's brand row: the mark (or a theme's own logo, or nothing) beside the wordmark, a `MorphingTitleLabel` so a chrome that renames the row morphs it. Self-wired to `AppThemeDidChange` and the appearance flip; one accessibility element carrying the brand's name. |
| `ControlButtonGroupView` / `ToolbarButtonGroupView` | Related icon actions as one compact run, so their internal spacing is the component's rather than an `NSStackView` decision at each call site. A content `ControlRowView` hands its live theme metrics to the group and the group promotes every button; the named toolbar subclass preserves the same contract when the group is one `NSToolbarItem`. |
| `SplitIconButtonView` | Two actions on **one** plate: a press, and a chevron welded to it that offers the other ways to take it — the pane header's Open in control. Its counterpart above is the right container for buttons that act on different things; this is for two halves of one thing, which read as an icon and an unrelated chevron the moment they are spaced apart. The surface is drawn once, here, and the halves draw none (`ThemedIconButton.drawsSurface`): a raised half fills *inside* the plate's silhouette, clipped to it, so the outer end keeps the plate's corner and the join is a straight edge that exists only under the pointer. Nothing is drawn between them at rest. The halves are deliberately unequal (`Design.Size.splitMenuWidth`) — the press is the point, the chevron the exception. See [`external-apps.md`](external-apps.md). |
| `SplitButtonView` | The same weld for a **titled** press on the pane's own ground — the attachments footer's Copy Path with its menu chevron. The plate draws exactly what the press it holds would have drawn for itself at that emphasis (`ThemedButton.plate(for:material:)` — the material's resting fill, hairline, frame and depth), and the halves — a `ThemedButton` press, a `ThemedIconButton` chevron (`Target.titledSplitMenu`) — bring no surface of their own (`SplitControlHalf`). **Welding follows matched emphasis**: nothing is drawn between the halves at rest, so a plate holds no seam while both halves stand on the same ground, and what cannot share one is a *mismatch* — an accent-filled press against a chevron still reading the chrome's roles is the permanent colour seam the weld exists to remove. So a primary plate paints the primary face and *names the ground it painted* to its chevron (`InkSource.primaryAction` through `hostGround`), which is how a glyph built for the chrome stays legible on a block of accent. The spread form is then a real choice rather than a workaround: the composer's Start Session keeps its clock *beside* it (`Target.besidePrimary`) and the prompt's compact send keeps its schedule chevron beside the glyph because a send and a schedule act on different things. |
| `WorkingOrbView` | The dotted "working" orb, tinted with the accent — the theme boundary for the `ThinkingOrbs` view. |
| `AgentActivityBeamView` | The breathing border ring — the theme boundary for `BorderBeamKit`, and the whole visual policy: one working agent lights the ring at 30% in adaptive mono, each additional agent adds 10% to a cap of 1, and it turns colorful while any working session runs at the top of its provider's reasoning ladder. Adaptive mono is load-bearing: the package's pulse palette stays light over a dark System surface but inverts its RGB channels over a light one, keeping ordinary activity neutral and visible while reserving the multicolor effect for top effort. System theme only — a styled theme (retro chrome especially) states its own idea of glow, so anything else removes the ring outright rather than fading it. Decorative by contract: `hitTest` nil, no accessibility elements, and under Reduce Motion it renders a genuinely static frame (the host's paused mode), not an animation drawing identical frames. Two surfaces wear it, told apart only by the corner the ring follows (`Surface`): both composers, fed the app-wide `AgentWorkload` from `AgentWorkloadDidChange`, and the sidebar's **selected** session row (`.sidebarRow`, the stock selection capsule's radius), where `ProjectSidebarViewController` stamps that one session's own workload onto `SidebarHoverRowView` while it loads or works — the ring that keeps the selected row's activity visible while the pointer swaps its status mark for the archive button. See [`dependencies.md`](dependencies.md) and [`session-activity.md`](session-activity.md). |
| `PageTitleView` | How the content pane names what it is showing: a mark, the page's name, and the `⋯` that acts on it. **Not a tab, and that is the point** — it *was* one, and a lone chip drawn as a selected tab promised a strip of siblings just out of view, with a `+` beside it that started a session taking this page's place rather than joining it. So there is no plate at rest, no `×` and no `+`: text on the pane's ground, with a quiet plate under the pointer because the name is still pressable (it reveals its row in the sidebar). The plate stops before the `⋯`, which answers a press of its own. See [`window-chrome.md`](window-chrome.md). |
| `ThemedTabItemView` | **Every** tab: the display pane's strip and the settings sidebar. Settings itself is deliberately not a header tab: it is one temporary mode, shown by a static label and Done action while its categories remain destinations in the sidebar. A middle-button click closes a closable tab on release without selecting it first; dragging away cancels, and other auxiliary buttons keep their own meaning. |
| `ThemedTabStripView` | **Every** horizontal run of those tabs: the scroll-not-shrink overflow, the clipped-edge fade, chip spacing, and drag-to-reorder, stated once. Chips are reused by id — a rename morphs, a drag survives its own re-render. Its live `bandHeight` is `PaneHeaderView.bandHeight`: tab, equal `Spacing.small` margins, then the theme's structural rule, so a heavy Bauhaus separator cannot consume the lower margin. Hosts hand it items and get selection/close/reorder back; a `chipDecorator` lets the display pane keep its extension slot around each chip without this component knowing extensions exist. Every pointer capability has a pointerless twin: the chip's secondary-click menu (also reached via accessibility "show menu") carries the standard closes (`TabHosting.standardTabEntries` — Close Tab / Close Other Tabs / Close Tabs to the Right / Close All Tabs), Move Left/Right, and the cross-pane moves — a rule, not a courtesy, for anything this strip grows next. While the reorder gesture holds a chip it is `isLifted`: its translucent fill flattens over `InkSource.ground` so the neighbour it crosses cannot show through it. A drag can also *leave*: `externalDropTarget`/`onDropOut`/`onDragEnded` let the window offer another strip's band as the drop, the chip dimming to `Design.Opacity.dragAway` while it would land, the receiving strip washing as a drop target (`isDropTarget`), and the slot named by the same midpoint rule as the reorder (`insertionIndex(forWindowPoint:)`) — and a lone chip may begin a drag exactly when that wiring exists, since with one tab there is nothing to reorder but still somewhere to go. A host that pins **both** of the strip's edges says so with `fillsHostWidth`: the default `.defaultHigh` hugging is what lets a control placed *after* the tabs follow them, and in a host that has no such control it is a *maximum on the host* — it capped the display panel at its own tab titles (see [`mcp-and-display.md`](mcp-and-display.md)). |
| `ThemedDisclosureRow` | The header of a collapsible run of rows — the settings kit's folded cards (`SettingsUI.disclosureCard`/`disclosureRow`) are built on it. A real `ThemedControl`: whole-row click with slip-off cancel, Space/Return, focus ring, hover lift, pointing-hand cursor, and a `disclosureTriangle` accessibility role whose value is the expansion state. The chevron leads in a fixed slot so every header's title starts on one line, and it re-tints at draw time so a live theme switch reaches it. The caller's interactive accessory (a toggle, a Remove All button) stays a **sibling**, never a child: the row is one accessibility element, and a control nested inside it would vanish from the accessibility tree. Replaced Storage's hand-rolled click-gesture fold, which no keyboard or assistive technology could operate. Setting `isExpanded` does not fire `onToggle`, so an owner restores state without re-entrancy. |
| `ThemedIconButton` | **Every** icon-only button: toolbar actions, a tab's `×`, a sidebar row's `⋯`. The role states a *slot* (layout: what the padding is measured from) and a *point size* (optics: what the symbol is configured at) — see the 2026-07-31 note for why those are two numbers. `setImage` is its one documented exception to "a symbol": artwork whose silhouette is not ours — an installed application's own icon, which is what the header's Open in control wears (see [`external-apps.md`](external-apps.md)). Foreign artwork is capped to the slot (`GlyphView.slot`); `setSymbol` clears the cap and configures to fit. A hidden but pointerless-accessible control may request deferred glyph materialization: its real geometry, action and accessibility shell remain installed, while CoreUI resolves only the latest symbol or image at first draw/reveal. |
| `GlyphView` | A tinted glyph on the device pixel grid — `NSImageView` minus the fractional placement, inside `ThemedIconButton`, `ThemedTabItemView` and `PageTitleView`. A symbol's natural size is fractional by design, so an image view centres it at a half-point offset: slight softness at 2×, a smeared stroke at 1×. This view centres the same rect and then `backingAlignedRect`s it (inward — nearest can push an edge past `bounds`, and a view clips its own drawing) before handing it to `TemplateImageDrawing`. Decorative; the control around it carries the name. |
| `ThemedFileIconView` | The File pane's one icon renderer. System keeps the path's native Finder artwork; authored themes use a semantic SF Symbol and theme roles, without paying LaunchServices for artwork they will not draw. It classifies from path metadata only, aligns either renderer to the device pixel grid, and switches live between them. |
| `PaneFooterView` | The bottom band of a pane: hairline, band height, corner-aware insets, controls aligned by their ink (`OpticalInsetProviding`) horizontally and — for loose text — vertically: a bare label sits on the first titled control's baseline (`TextBaselineProviding`, `PaneBandTextAlignment`) rather than on its own centre, because two point sizes centred never share one. See [2026-08-15 below](#2026-08-15--a-band-centred-its-text-and-centring-is-not-a-line). |
| `PaneFoldDivider` | The fold *inside* a pane, where the two halves are not both flexible — the attachments chronology above its preview. The rule keeps the theme's weight at the top edge and the band under it is the pane's own gap made hittable, so a seam becomes a grip without anything below it moving. It reports travel in points and nothing else: only the host knows what floor and ceiling the travel is answered against, and the host is also where a stored position is clamped. The seam takes the accent wherever a drag would attach — pointer, hand or keyboard focus — which is `ThemedSplitView`'s answer, and the reason focus is shown that way rather than as a ring around a 7pt band. A press takes the focus so the arrows work on the fold the hand just left, and that focus is drawn only if it arrived from the keyboard (`KeyboardFocusOrigin`, as the media canvases do): drawn for a click too, every drag ended with the seam still lit, the one divider in the window that did — the split and the shell drawer never take focus at all. Arrow keys and the splitter role's increment/decrement move it too; a double-click asks the host to place it again. Not `NSSplitView`: one of the halves states a content-derived height, which a split view has nowhere to say. **Where it reaches its pane's own edge, that end is a corner and holds both seams**: a press within `cornerReach` asks the enclosing `ThemedSplitView` for the divider beside the pane and drags it across while the fold travels down, so the panel gets wider and the chronology taller in one movement. Resolved live rather than configured — a fold inset from the edge, or beside a collapsed pane, has no corner — and pointer-only, since both seams are already draggable on their own. The gallery story stands in a real split view so the corner can be tried at all. |
| `PaneHeaderView` | The footer's mirror at a pane's top. Its live height is the content pane's header-strip measure (`PaneHeaderDefaults.height` reads it): row, equal top and bottom air, then the theme's rule. It remeasures on a theme change, so the two panes' separators land on one line without using their ink as spacing. It states the footer's text-baseline rule too. |
| `ControlRowView` | Those two bands' rule for a row that belongs to **content** rather than to chrome: a leading run, a trailing run, one shared centreline, and one shared height. The height is the row's to state and the members' to take — every `ControlRowMember` (`ChipView`, `ThemedButton`, `ThemedIconButton`, `ThemedSegmentedControl`, `ControlButtonGroupView`) is handed a `ControlRowMetrics` and resizes to it, glyph included, and only a row can make one. `.compact` resolves to the material's `choiceHeight`, so a style switch relevels the whole row rather than half of it. The runs are pinned to opposite edges with a real inequality between them, and the outer controls' full hover/focus silhouettes stay inside the row's edges. See [2026-08-05 below](#2026-08-05--a-row-of-controls-had-no-owner). |
| `WindowTitleBandView` | The title band a chrome-takeover theme draws across the window's top (`WindowChromeStyle`, see [`window-chrome.md`](window-chrome.md)): active/inactive gradients and texture, full-width or compact leading-tab shape, optional app icon, leading or centred upright/italic title, trailing/split/bookended authored caption controls, and the titlebar's own gestures — a press drags the window, a double-click performs the user's System Settings choice. Application commands stay in `WindowCommandBandView` below. Not a control (its `interactiveComponent` exception records why); its buttons are. |
| `WindowCommandBandView` | The button-face row beneath an app-drawn title bar, hosting the sidebar/history controls the native toolbar held. It keeps application commands out of title-bar geometry and uses ordinary chrome ink. Collapses with the title band in native dress. |
| `WindowChromeButton` | A takeover window's Window menu/close/minimize/zoom/depth, one component for every role and glyph family (`squares`, `platinum`, `beos`, `openstep`, `irix`, `amiga`, `plain`) — the tab strip's "every" lesson applied to period chrome. Calls the *semantic* window operations, because the `perform*` forms animate a standard button a frameless window does not have and refuse outright; zoom follows the window and becomes Restore while maximized, Window menu opens app-owned `ThemedMenuPresenter` rows, and Workbench Depth orders the window behind its peers. Full `ThemedControl` contract: keyboard, focus ring, AX press. |
| `WindowChromeFrameView` | The border around a takeover window's edges, in the theme's border role with the bevel inside when the material states one. A shaped title tab leaves transparent shoulders and seats the rectangular body beneath it. Draws nothing in native dress, where the terminal-palette backdrop showing through the titlebar strip is load-bearing. |
| `PairingCodeImage` | The Remote Access QR code, drawn rather than scaled up from `CIQRCodeGenerator`: Chromium's geometry (dots at 0.8 of the pitch, rounded finder patterns), a four-module quiet zone Core Image does not supply, and a plate and ink carrying the accent's hue at a stated saturation. The only artwork here a *machine* has to read, so it is tested by decoding the render, not by asserting on the constants that drew it. |
| `ToastView` / `ToastPresenter` | A receipt for something already done, floating above a pane's footer, with the way back on it. The view is one message, one optional detail line, one `ThemedButton` carrying the way back and one `ThemedIconButton` carrying the way out; the presenter owns everything that is about *time* — one band at a time, a six-second dwell (a request may ask for longer, and the one an agent raises does), the clock pausing while the pointer is on it, and the VoiceOver announcement a surface that takes no focus would otherwise never make. The pointer **pauses** the dwell rather than refunding it: the timer's remaining interval is read before it is cancelled and rescheduled when the pointer leaves, because time spent reading a receipt under the pointer is that receipt's time being used — restarting meant a pointer crossing the band en route somewhere else bought it a whole second dwell, and a band leant on twice never had to leave. The dwell is also *drawn*: the band's own bottom border, in the accent, drains as the clock runs, freezes with it under the pointer, and carries on from where it froze — at the same pace, since the line's remainder and the timer's are read at one instant. It is a layer animation for `ThemedSpinner`'s reason, it lives inside the band's existing bottom inset so showing the clock costs no height, and Reduce Motion removes it rather than freezing it full — a still rail is a band claiming a countdown it is not showing. **It rides the edge rather than floating in the padding**: held a step in from three sides it was a rule between nothing and nothing, read as an underline belonging to the way back under it. Pinned flush, masked to the band's own silhouette so its ends follow the corners, and weighed at `Design.Radius.border` like every other rule the theme draws, it is a second edge on top of the first — which is also why it needs no track: what it leaves behind as it drains is the band's own border. A layer draws its border above its sublayers, so the line sits one rule *inside* the edge rather than on it, or the band's own border would paint it out. The band's words argue for **no** width at all (`ToastDefaults.contentWidthPriority`, hugging and compression both): pinned inside a host, a wrapping label's 750 outranked the sidebar's own holding priority, and the column jumped wider as a receipt arrived and back again as it left. The presenter's own fill pin sits *below* every pane's holding priority for the mirror-image jump (`ToastDefaults.fillPriority`): a pin the band cannot satisfy is one the solver satisfies with the *column* instead, and at `defaultHigh` it did — the sidebar snapped in to meet the band's old 320-point cap as the receipt arrived and sprang back when it left. That cap is gone (2026-08-12, below): the band spans whatever column it is given, since every host a receipt has is a column and a card stopping short of one reads as stranded beside the list it is reporting on. Anything **waiting** behind the band is drawn rather than merely queued: one `ToastWaitingCardView` per waiting receipt — two at rest, the whole queue once the deck is opened — each the same card a step up and a step in on both sides, pinned to the band's own top *and* bottom so no theme's corner radius becomes a constant here. Opened, each card's uncovered strip carries that receipt's own line and its own way back, and the grip that opens it (`ToastDeckGripView`) reports the pointer without taking a click. See the queue paragraphs below. The **way out** is a ✕ in the corner and a throw across the band, and the two are one thing: see the paragraph below for why the mark is never hidden until hovered and why the gesture is only ever an accelerator for it. Two layout rules follow the ✕ and both were bugs first: the message stops at the mark while the detail runs the full width beneath it, so each wrapping label is told **its own** width rather than one figure derived from the band (handed the band's, the message believed it had 26 points it did not and a clipped receipt read *Archived “Refactor* with the session's name gone); and each label's height is measured with `cell.cellSize(forBounds:)` rather than taken from `intrinsicContentSize`, because the two disagree about whether a string wraps at a width it very nearly fits — under Claymorphism's rounded face the same receipt reported 175 points on one line inside the 178 it had while the cell typeset two, and the band clipped the second. |
| `ThemedPopover` | Every app-owned anchored transient surface. It owns the themed body and arrow, preferred-edge placement with screen-edge flip and clamp, parent-window movement, live theme changes, transient/semitransient dismissal, Escape, accessibility announcement, and both halves of focus — taking it when the content names an `initialFirstResponder`, and giving it back on close. Content remains an ordinary view controller. Native application and context menus do not use it. The chrome is **one closed outline** — body and arrow walked as a single path, filled once and stroked once (`ThemedPopoverLayout.outline`); drawing them as two paths and repainting their seam erased the tails of the arrow's own sides, a border gap a picture showed and no assertion did (now one does, on drawn pixels). A popover also cannot outlive its owner or its anchor: `deinit` detaches a still-shown panel — a child window its parent *retains*, so a dropped reference otherwise floats forever with its monitors gone — and the next interaction anywhere closes one whose anchor left the window, since a sidebar reload discards rows without a pointer exit. Hover-presented sites drive it through `HoverPopoverScheduler`, whose `Policy` states the site's open dwell, close grace, and whether pointing at the popover itself holds it open — the sidebar's cards dwell and close on exit, the toolbar's usage pill is instant both ways while it shows the native reading and flips to a held policy the moment an extension composes actionable content in, an extension row's detail dwells, grants a grace and holds because it carries actions. Timing is configuration beside the site's other measurements, not four copies of timer code. |
| `ThemedFloatingSurfaceChrome` / `ThemedFloatingGlyphView` | The rectangular and semantic-content halves of that same material grammar for an app-owned card inside another view. The resolver applies the popover style's opaque surface role, edge/bevel, material depth, and density; the glyph view selects SF Symbols or the theme's simple one-bit marks. `GitStatusOverlayView` uses both, so a terminal remains the ground around the card without becoming the card's visual owner. |
| `ThemedAlert` | Every app-owned modal statement, confirmation, choice, error, and text prompt. It owns themed severity, copy, accessory, suppression choice, button hover/press/focus, Return policy, universal Escape, sheet/modal presentation, accessibility, and focus return. `ConfirmationAlert`, `NoticeAlert`, and `TextPromptAlert` remain the semantic policy layer above it. |
| `MediaInspectorView` / `MediaInspectorCanvas` | The in-window inspection surface for visible files. Images use an app-owned renderer with fit/actual/custom zoom, anchored pinch, pan, collection navigation and a thumbnail rail. PDFKit and embedded `QLPreviewView` live only inside `MediaInspectorDocumentView`, a named `SystemChromeBoundary`; System Quick Look is an action-menu fallback rather than the primary route. It installs through `InWindowOverlay`, not by pinning to the content view's top: under a full-size content view that is the top of the window, and this header opened under the traffic lights. It fills with `Design.Surface.elevated`, **not** `ground` — the ground is by definition what the window behind it is already filled with, so in a dark palette the inspector's header simply continued the window's own, and a screenshot of the running app showed the two as one surface. The canvas's focus ring is shown only under keyboard traversal (`KeyboardFocusOrigin`): the inspector hands the canvas focus as it opens, because the arrows, the zoom keys and Escape all belong there, and an unconditional ring drew an accent rectangle around the whole window the moment a thumbnail was clicked. |
| `InWindowOverlay` / `InWindowOverlayHosting` | The one place that decides where a covering surface starts. A window drawing full-size content has no room at `contentView.topAnchor` — the traffic lights float over it — and a takeover dress puts the app's own title and command bands in the same place. The helper asks the window's root for its `overlayArea` guide and falls back to `safeAreaLayoutGuide` for a root that states none (a fixture, the gallery). See [`window-chrome.md`](window-chrome.md); the rule is the panes' "nothing pins to `topAnchor`", arrived at a second time by the transient surfaces. It also installs the **scrim** under that surface, and hands back an `InWindowOverlay.Presentation` owning both: the two views arrive and leave together, where before each session removed its own surface and a wash added beside it would have had to be remembered on the close, the Escape and the replacement path separately. The wash reaches *further* than the surface — `overlayScrimArea`, everything below whatever draws the window's own buttons, which in native dress is the whole content view and in a takeover starts under the app's title band. That difference is the point: the strip the surface has to clear is app-drawn chrome (session tabs, panel toggles, the sidebar's top corner), and left lit it stacked on the surface's own header with a hairline between them and read as one window. A modal may dim a way out of the window; it may not cover one. Clicking the wash runs the same dismissal the close button does — required rather than defaulted at the call site, since a scrim swallows every click it covers. It draws `Design.Surface.overlayScrim`, the one fill here deliberately *not* derived from a theme role: every authored shade in this app is a bevel edge (`#808080` under Windows 98), and a mid-grey wash barely dims a light window while it lifts a dark one. |
| `ImageCompareView` | Two images against each other: a draggable wipe seam (either axis), a crossfade, a pixel difference, and side by side, with per-side captions and a mode chip. The captions are given a band **outside** the images before anything is fitted, never a pill over them: printed on the picture they hid the pixels the comparison exists to show, and at rest they sat exactly where the wipe starts, so reading a label meant scrubbing it out from under. Position carries the mapping — old at the start of the scrub's travel, new at its end, above and below it for the vertical wipe, over each image in side by side — and difference names the pair `old → new` centred rather than splitting two titles across edges that mode has no sides for. **Neither title is styled as the important one.** Both come off one ramp, `tertiary` to `label`, read by how much of its picture each side is showing — the fraction for the wipes, whose seam divides the canvas by area, and its inverse for the fade, whose fraction is the new side's alpha instead. Held at the middle the two match exactly, at the tier the captions used to be fixed at; scrubbed, the side being revealed comes forward and the side being covered recedes. The horizontal wipe divides its band where the seam divides the picture, so a name keeps to the pixels on its own side of the handle and a side scrubbed off the canvas takes its title with it. That is what ties a caption to the image beside it: ranking them old-under-new said which file was newer, which is not the question the surface is asking, and left a fully covered picture wearing a title as solid as the one filling the canvas. A slot too narrow for a couple of glyphs and an ellipsis draws nothing — the mark saying a name was truncated is not a name. One scrubbed fraction serves every mode — there is deliberately no slider control: the seam *is* the control (accent-inked, since it is the one thing on the surface asking to be used), fade held at the middle is the onion skin, and both images draw at one shared scale so a resized asset stays visibly resized rather than being normalised into "looks identical". The canvas is a `ThemedControl`: arrow keys nudge the scrub, Space recentres it, and VoiceOver reads it as a slider. The caption's clearance from the surface's edge (`captionMargin`) is a step above the gap under it: equal to the gap, the title sat as close to the border — the focus ring is two points of it — as to the picture it names, and the pair read as one crowded line. The controls row carries one more thing: the button that opens the comparison in `CompareInspectorView`, on wherever the surface is inline, off in the one place it would offer to open what is already open. `hostControls()` hands that row's two controls to a host that will place them itself and stops the surface reserving a row under the canvas — one call rather than two accessors and a flag, because taking the controls and giving up the row are the same act: a host that took them and forgot to detach would leave a chip in two places, and one that detached without placing them would lose the modes entirely. The controls stay wired to the surface they came from; what the host gains is where they sit. The Compare tab uses it to lift them out of its scroll view (see [`mcp-and-display.md`](mcp-and-display.md)). |
| `CompareInspectorView` | The expanded comparison: the pair named once in an inspector header (`Design.Size.inspectorHeaderHeight`, the media inspector's band, so the two open at one height) and `ImageCompareView` given the whole window under it. The surface inside is the *same component*, not a second implementation of a wipe — which is the point: inline it is inside somebody else's height, capped so one tall screenshot does not become the page; opened, it fits the window, and the mode chip is the chip the user has already used. `CompareInspectorPresenter` is `MediaInspectorPresenter`'s rule again — one session per window, presented into the window's own themed hierarchy rather than a panel, so it follows a live theme change and takes no key-window status from the session behind it. Escape closes it from any child, since AppKit offers key equivalents down the tree. Closing **hands back** the mode and the scrub as a `CompareInspectorResult`: the surface it was opened from carries on from there rather than snapping back to whatever it was opened at, and a host listening for `onModeChange` is told, so a persisted mode is persisted. Focus returns to the source, then to the responder before it, then to the window — a comparison switched to a static mode declines first responder, and leaving the removed inspector holding it would strand every key press in a view no longer in the tree. It takes the media inspector's presentation whole: `elevated` rather than `ground` so it is a surface *over* the window instead of more of it, the dimming scrim under it with the ground around it closing it, and `ImageCompareCanvas`'s ring held back until a key press asks for it, since the scrub takes focus as the surface opens and that ring follows the canvas's own bounds — here, the window's. |

`ToastPresenter` teardown is synchronous: `invalidate()` cancels its timer and layer drain before
removing the band, with `deinit` as the fallback. Short-lived render hosts invalidate explicitly;
AppKit may extend a local object's debug lifetime beyond its lexical scope while layer work is
still committed.

`ThemedPopover`'s presentation is material data, not a hard-coded speech bubble.
`AppTheme.Material.PopoverStyle` chooses a triangle or stemless anchor, a semantic floating fill,
a flat/absent/material edge, native/authored/automatic/no shadow, regular or compact geometry,
and System or classic semantic glyphs. A stemmed popover remains one closed outline, preserving
the border continuity described in the component table; a material edge requires the stemless
shape so `ThemedSurface` can interpret the same hard or soft bevel panels use. Authored depth is
drawn inside a transparent gutter in the child window, preventing the window from clipping hard
offset shadows or paired soft light. Theme and appearance changes re-place the live panel because
stem, density, and shadow gutter change geometry as well as pixels.
`ThemedFloatingSurfaceChrome` consumes the rectangular subset of the same style for embedded
floating cards: it deliberately ignores arrow placement, while preserving the surface role,
edge/bevel, material depth, and density. `ThemedFloatingGlyphView` preserves the style's semantic
glyph choice across both forms. This is one authored floating-surface grammar, not a second theme
field whose values can drift from popovers.

**A component is its interaction contract, not its resting render.** Before a new component is
finished, walk it through pointer, keyboard, assistive technology, and the ordinary AppKit host
that will contain it. Decide hover, press, drag cancellation, first-click behavior and cursor;
Space/Return, arrows, Tab order, shortcuts and Escape; role, label, value/state, primary and custom
actions, and announcements; then focus on open, focus containment, nested-surface dismissal, and
focus restoration on close. A transient surface always gives Escape a meaning — Cancel for a
question, otherwise Close — and nested surfaces peel one layer per press. Every gesture has a
non-gesture route, motion disappears rather than merely slowing under Reduce Motion, and state
never depends on colour alone. Finally put the fixture in the real kind of host: a control that
works in a plain view can still lose its click to a table, its shortcut to a text editor, its
scroll to a nested clip view, or its focus to the window behind an overlay.

**The motion vocabulary has one verb per kind of change, and the newest one is a *handoff*.**
`quick` and `standard` are a control answering; `appear` and `vanish` are a surface arriving or
leaving in one place; `Design.Motion.handoff` is the one that carries an object *between* two
surfaces. It exists for the swap that starts a session: the pane replaces the composer with the
conversation, and exactly one thing is on both sides of that swap — the box just typed into. So
that box is what moves, from where it stood to where replies are written, while the rest of the
composer leaves as a picture of itself and the thread comes up underneath (`ComposerHandoffAnimator`,
[`sessions.md`](sessions.md)). Naming the destination is the whole point: the alternative reads as
one screen being replaced by another, and what the move says instead is that the conversation *is*
the thing that was being written in. It is the longest token here (0.35s) because a trip across a
pane has to stay legible as one object the whole way, where a fade only has to be noticed; and
like every other token it is zero under Reduce Motion, which lands the same end state with nothing
built. A future transition that hands an element over rather than swapping a surface takes this
token rather than a second number near it.

**A curve is chosen by the distance it covers, not by the direction it goes.** `glide` and `drop`
were written for the toast — a card rising over a pane's lower edge and falling back out of it —
and `glide` decelerates hard on purpose: it crosses most of its distance at once and eases in for
the rest, which over a card's height reads as *put there*. The floating scroll target
(`ThemedButton.floatingScrollToEnd`, the arrow that returns Git Review's diff or a conversation to
its live end) took the same curve for the obvious reason, that it is also a thing arriving, and it
was wrong: a 20pt rise on `glide` is four fifths finished within three frames at 60Hz, so the
arrow appears at four fifths of its opacity already in place, and the movement paid for is never
seen. Hence `Design.Motion.lift` — a gentler deceleration that spends the rise across the whole
duration — with the departure still on `drop`, because that half is only ever a short fall the eye
has already left. The rule to carry forward: an arrival's curve is picked against the distance
that arrival covers, and a third curve here is cheaper than a movement nobody sees. The measured
form of that claim is a test (`FloatingScrollTargetMotionTests`), which samples the *presented*
layer through a paused animation and asks the timing function itself how far along the arrow is a
quarter of the way in — `lift` answers about two fifths, `glide` about six sevenths.

**The affordance itself is one component with two hosts, and its own presence transition.** The
arrow is a `ThemedButton` factory rather than a view each pane builds: both hosts had switched it
with `isHidden`, and switching is the one thing a target floating over content must not do, since
it appears exactly when the reader is looking somewhere else. `setFloatingPresence(_:)` owns the
whole contract — rise and fade in on `lift`, sink and fade out on `drop`, hidden only when the
departure has finished (so it is still clickable while leaving), an arrival that interrupts a
departure adopting the same arrow instead of racing a second animation against it, and a plain
applied state under Reduce Motion. The transition is *presentation only*: the model transform and
opacity stay the resting ones, so an arrival cut short by a rehost, a theme change or a dropped
layer animation leaves the arrow exactly where it belongs rather than mid-flight. "Below" is read
from the host's geometry rather than written down, because a layer-backed view under a flipped
pane inherits flipped layer geometry and a bare `-rise` would invert the whole arrival the day a
pane becomes flipped.

**Two components say "every" for a reason, and it is the design system's sharpest lesson so
far.** Each of them was two or three implementations, and each had already been "unified" by
sharing constants — one radius, one type scale, one height, read from a common enum. It did not
hold, in either case, and both times the reason was the same: **what drifts is not the metrics.**
The pane's tab gained hover and press states while the toolbar's stayed inert; one faded its
close button in, the other showed it always; one was an `NSControl` with a `.radioButton` role
and keyboard activation, the other a plain `NSView` that could not be clicked at all. A shared
constant reaches none of that. The `⋯` and the `×` were 16pt and 20pt around 16pt and 12pt
glyphs — two paddings nobody chose, each measured where it was used.

So the thing that genuinely differed became **data instead of a type**. A tab in the pane and a
tab in the toolbar differ only in which ground they draw on, which is now an `InkSource` they are
handed rather than a base class they inherit — see `Design.Ink.chrome` and `BackdropOverlay`. An
icon button names a **role** (`ThemedIconButton.Target`) rather than taking an `NSSize`, and the
role states the target, the glyph and therefore the padding between them; there is deliberately
no size parameter, because that is the seam a fourth slightly-different button arrives through.
The hover fill is part of the role too: a toolbar button lifts to `surface` because it sits on
the bare backdrop, an inline one to `surfaceHover` because it sits on a fill that is *already*
`surface` — a distinction previously set by hand at the one call site that had noticed.

**A control's ground can move without the control moving.** `inkSource` says which ground a
component was built for, and that does not change; what it cannot say is what the component's
*host* paints in between. A sidebar row fills with the theme's accent when it is selected, and its
`⋯` and archive are suddenly over a colour the chrome's roles were never measured against — under
Botanical a dark green glyph on a dark green fill, in the one row the eye is already on, beside a
title that had already inverted. The host is the only thing that knows what it painted, so the
host is what says so: `BackdropThemedControl.hostGround` **names** the ground (`InkSource.selection`
→ `Design.Ink.selection`, measured against `Design.Surface.selectionFill`, which is the theme's
accent or AppKit's own fill under System) rather than handing over an ink, so a live theme switch
is answered again at the next draw instead of keeping the ink the selection began under. Only the
*emphasized* fill is named: the unemphasized one is the accent held far back over the sidebar's
surface, where the chrome's ink still reads. All three selectable sidebar rows state it, and
`SidebarRowRenderTests` sweeps every stock theme × every row kind — by asking which of the two
candidate inks the rendered glyph *is*, since contrast cannot separate them (under Bauhaus the
wrong ink reads better than the right one).

The session status slot follows the same rule. Its accent spinner and unread ring otherwise become
the emphasized selection's fill drawn on itself; its warning dot and limit triangle have no
guaranteed contrast against a theme's accent either. `SessionStatusIndicator.hostGround` carries
the row's answer to every mark. On selection they share `Design.Ink.selection.label`, while their
filled ring, hollow ring, and triangle silhouettes keep the statuses distinct without colour; off
selection they keep their ordinary accent, warning, and negative roles.

A standalone terminal has only one transient status — a foreground command owns its PTY — so its
row uses `ThemedSpinner` directly rather than materializing the session indicator's attention and
limit vocabulary. It occupies the terminal action's fixed trailing column, yields to that action
under the pointer, and takes the same selection ground through `hostGround`. The terminal icon
remains identity at the leading edge; replacing it with activity would make the row stop saying
what kind of thing it is precisely while it works.

**Status says whether an agent is working; Overview says what the session is doing and where its
work has landed.** Sidebar rows
carry status only: the former 3pt repository strip and its expanded hover card were too compressed
for the information and duplicated a surface with more room. The display panel's single Overview
tab has Activity and Info sections in a themed segmented control. Activity places the bounded
repository atlas, recent action ribbon, and counts above the real filesystem tree. Every visible
file row states exact reads and edits; a directory states the touched-file and read/edit totals
below it. New paths retain one stable overflow cell in the summary rather than resorting the map
under the pointer. Info owns the working directory, live process tree and listening ports. Only the
selected child is attached, which makes the control a lifecycle boundary: an unseen Info does not
poll, and an unseen Activity does not build or enumerate filesystem views.

The implementation stays inside the design boundary: `FileActivityMapView` is the drawing
primitive and `AgentWorkSummaryView` composes only `Design/` controls. The detailed map is one
accessible image with a summarized file count, and its directory/path hover label is supplementary.
The filesystem rows expose spoken read/edit totals as well as their compact labels. Colour is never
the only encoding because reads, edits, overlap and activity categories also differ in shape,
position, or text.

The summary card learned figure-ground the hard way (2026-08-11). Untouched files once drew two
tertiary-based resting tiers, and at 2,400 cells that ground summed into a checkerboard louder
than the 94 marks resting on it; both tiers now derive from the quietest label tier
(`FileActivityInk`), still alternating per directory run, so the touched files own the light. The
counts are the encoding's own legend: the number leads in fixed-width digits, and the little mark
beside "59 edits" / "53 reads" is drawn with the atlas' exact ink recipe, while each action count
wears its ribbon hue — which retired the three-clause prose legend down to the one fact no mark
carries alone, the multi-agent cap, shown in project scope only. The ribbon itself draws only
non-file actions (file work is the atlas' story) as merged same-category runs at one height in
dimmed ink; the hues it does not name fold into a muted "other", the `CodeStatsBar` rule. Two
mechanical lessons live beside those decisions: the detail grid re-derives its column count from
the rounded row count, because sizing for an aspect heuristic's phantom columns stopped the grid
visibly short of the ribbon's edge below it; and the card's wrapping labels take
`preferredMaxLayoutWidth` from their laid-out width, because a fixed popover-width guess clipped
the contributor list to one line ending in a dangling separator.

**A translucent glyph tint composites over the ground, not into the artwork.**
`TemplateImageDrawing` filled the symbol `.sourceAtop` inside its transparency layer, which is
right for an opaque tint and wrong for every other one: a template's own artwork is black, so atop
blended the tint *into that black* and a tint below full opacity could never reach the colour it
asked for — white at 70% came out an opaque 70% grey whatever it stood on. Every ink tier below
`label` is an alpha, so that was every secondary glyph in the window quietly drawn dark. `.sourceIn`
keeps the silhouette and replaces its colour, alpha included, leaving the layer to composite it
over the ground the ink was measured against.

**A slot is a box a mark sits in, never a shape it is stretched into.** `NSImage.draw(in:)` scales
to the rect it is handed on each axis independently, and an SF Symbol is square only by
coincidence: `folder` renders 18×14, `trash` 15×17, `ellipsis` about four times wider than it is
tall. Every component here hands `TemplateImageDrawing` a *square* slot, so each was quietly
deforming its glyph — the sidebar's add-project menu drew a folder squeezed a ninth narrow and
pulled a seventh tall, checkbox marks were widened into their box, and `ellipsis` overflow buttons
drew three vertical bars. `ThemedButton` had already fixed it for itself; the fit now lives in
`TemplateImageDrawing.fitted(_:in:)` where the whole system inherits it, and the button's own
copy delegates to it because it *lays out* around that rect rather than only drawing into it.
Fitted rather than capped: the mark still fills the axis that constrains it, so correcting the
proportions never also shrinks a glyph the caller measured a layout around. `GlyphView` and
`ThemedFileIconView` keep their own `min(1, …)` cap on top — for artwork that is not ours a slot
is a ceiling, not a target — and the shared fit is a no-op over an already-fitted rect.

The other half of that bug is *where the mark comes from*. A menu row resolves its symbol through
`ThemedMenuIcon.symbol(_:)`, the one place that states how large and how heavy a menu's marks are;
a raw `NSImage(systemSymbolName:)` arrives at whatever size the system hands out — larger than the
16pt slot — and is then rescaled from a finished render, which thins the stroke off the weight the
optical size chose. Six menus were building rows the raw way. `GlyphTests` holds both rules: the
fit is measured off the rendered pixels, and its fixture asserts that the un-fitted draw it
replaced still fails, so the test cannot go blind.

**A menu opens on the press; an action fires on the release.** Which of the two a button does is
`ThemedIconButton.presentsMenu`, and the split is not a preference — press-drag-release onto an
item is the platform's menu gesture, and the open menu tracks the press for exactly as long as it
is held (see below), so the button reads as held while its menu is up. It is also the only
*reliable* half. A press that waits for its release depends on AppKit
routing that release back to the same view instance, and nothing promises it will: the sidebar
rebuilds a row under the pointer whenever the tree's shape changes, `reloadData` hands every cell
back to the reuse pool, and a detached view is sent no mouse-up while the view that replaced it is
sent none either. Measured against AppKit directly — down, remove the view, up — the mouse-up
reaches nobody, so the press disappears with nothing on screen to say so. That is the `⋯` that
"needs three or four presses", and it is why the report about it came back after the hit-testing
fault behind the first one (a status dot over the button) had been fixed. An action button keeps
the release, and now also lets go of the press when the drag leaves it, which `ThemedButton` did
from the start and this one did not: the press was decided at the release and shown nowhere, so a
slip off a 20-point target cancelled silently and left the button drawn as though held.

**A menu row's mark column is reserved only when something goes in it, and a check and an icon
share it.** The rule used to be "always leave room for a checkmark", and it cost twice. An
icon-less menu of plain actions — which is most of them — began every title 16pt inside the panel
behind a gutter nothing was ever drawn in, so a column of names read as a column of names that
had lost its icons. And it made icons unaffordable: added behind a permanently reserved gutter, a
glyph and its title started 48pt in and the panel grew to hold a column of air. `CheckColumn`
answers `.none`, `.shared` or `.separate` per panel, and only `.separate` — some row carrying
*both* a mark and an icon, which today is Open in marking the preferred app in a list where every
row wears that app's own icon — pays for two columns. This is the rule Win32 has always used
(`ThemedMenuMetrics.resolved` keeps the historical grammars on their own authored anatomy:
Platinum and Workbench reserve both columns unconditionally, Win98 exactly one).

**Icons on an action menu are structure, not decoration.** The session's menu is the longest in
the app — past thirty rows on a shared, running session — and read as an unbroken wall of words
in which finding Archive meant reading every title above it. Separators grouped it; the glyph
column is what it is now *scanned* by, and the two together are why it fits in one glance. A mark
is drawn in `Design.Text.secondary` rather than the label's ink, because the words are what is
being chosen between and a glyph inked as loudly doubles what competes for the first look; real
artwork (an app icon, an account's mark, a theme swatch) ignores the tint and keeps its colours,
which is right, since those *are* content. Build one through `ThemedMenuIcon.symbol` — the single
place that states the size and weight — never a bare `NSImage(systemSymbolName:)`, which arrives
at whatever size the system hands out. A row with no honest mark is left without one: a gap in
the column beats two rows sharing a glyph they do not share a meaning with.

**Press-drag-release belongs to the menu, not to whatever opened it.** Holding the button down,
sweeping to a row and letting go is the other half of how every platform menu is used, and it was
implemented per opener: `ThemedPopUp` and `ChipView` forwarded their `mouseDragged`/`mouseUp` to
`ThemedMenuPresenter`, and the fifteen other call sites did not, so the gesture worked on a
settings pop-up and on an account chip and nowhere else in the window. A secondary-click menu
could never have joined them by forwarding — nothing owns the right button between its press and
its release, and the view that saw `rightMouseDown` is not asked again — which is exactly where
it was reported: the menu sat inert under a held press and only a second, separate click could
choose anything.

An open session now watches that press itself, through a local monitor for the button that was
down as it opened (`ThemedMenuPresenter.heldPressMask`). A menu opened from the keyboard, from an
accessibility action, or by a click already released adopts no press, so a later unrelated drag
cannot end it. Three things had to be true before that generalized safely:

- **The menu answers before the source does.** A release back on the opening control is the
  ordinary click-to-open and leaves the menu up for browsing — but a context menu is presented
  *from the view it was invoked on* and opens over it, so asking the source first read every
  release on a row as a release on the control. Rows are resolved first, and the source only for
  a release that missed the panel.
- **A release where the press went down is a click, not a choice.** A `.pointer`-anchored menu
  puts its first row under the pointer immediately, so tracking a right-click naively would
  choose whatever landed there the instant the button came up. `ThemedMenuMotion.stickyPressDistance`
  is the platform's sticky-menu rule: travel first, or the menu just stays.
- **A release outside every window carries no window**, and states itself in screen coordinates.
  Measured raw against a window-relative panel, a release far from the menu could name a row.

AppKit's own routing was ruled out as the cause first: a full-window overlay added during
`mouseDown`, with first responder moved to it, does not stop the window routing that press's drag
and release back to the source view. The forwarding was sound; there was simply only ever two of
it.

**A press that goes down on the open menu is the same gesture, started later.** A menu is browsed
two ways and a platform menu answers both: hold the opening press and sweep, or let that click go
and press again anywhere on the panel. Only the first was tracked, because tracking began at the
opening event and ended at its release — so after a plain click-to-open the panel was inert under
a held button. Nothing lit on the way down, and the release chose nothing, which is what "the
dropdown doesn't follow the cursor" means from the outside. The row that took the press owned the
whole gesture on its own, and a row's `mouseUp` fires only inside its own bounds, so letting go
one row further down was silently nothing at all. Rows now report their press, and the overlay
reports a press that landed on a panel's own ground; the session adopts it exactly as it adopts
the press that opened the menu, so the *rest* of the machinery above — sticky distance, rows
before source, screen-coordinate releases — is the same code and the same rules. Tracking is per
gesture, not per menu: a press reported while a sweep is already tracked keeps the origin it
started with, so nothing restarts mid-drag.

That overlay half fixed a second thing on the way. A press on the panel's inset, on a separator,
or on the strip the filter opens is not handled by any row, so it walked the responder chain up
to the overlay — whose `mouseDown` is the click *outside* a menu — and closed the menu from a
point the pointer was inside.

**The click that dismisses a menu lands on a sibling that opens one.** The dropdown's overlay
swallows its dismissing click the way `NSMenu` does — a click on the terminal to let a menu go
must not also type into it — with one exception it first owed to hover. Hit testing is what the
overlay takes over; hover is driven by tracking areas, which at the time nothing silenced, so a
chip under an open menu kept its hover invitation and even widened to its full label, and a
control that invites the click must honour it: with the composer's account menu open, clicking
the model chip closed one menu and opened nothing, a dead click on a control that was actively
lit. The invitation is gone since 08-16 — `CoveredWindowPointer` withholds hover beneath an open
menu (see that entry) — and the handoff stays for the reason it always had underneath: sibling
openers trade one click the way menu-bar titles do. The overlay therefore
resolves what its dismissing click landed on, and when that is a `ThemedMenuOpening` control
(`ChipView`, `ThemedPopUp`, a menu-presenting `ThemedIconButton`) — and not the very control whose
menu is open, whose click stays a toggle-close — it hands the press over, drag and release
included, so the menu moves between siblings the way menu-bar titles have always traded one click.

**The source stays present while its menu is present.** A menu's overlay necessarily takes the
pointer away from the control and row that opened it. Treating that exit as an ordinary hover exit
made every sidebar source erase itself on the trip: a project's `+ ⋯`, a session's `⋯` and archive,
and a terminal's `⋯` all faded before the pointer reached the first menu row. The presenter now
publishes one open/close lifecycle through `ThemedMenuPresentationObserving`, to the source and
the presentation-aware ancestors captured when it opens. `ThemedIconButton`, `ChipView` and
`ThemedPopUp` therefore own their held treatment without caller bookkeeping; the three sidebar
row hosts carry their hover-only action group until the same dismissal. The observer chain is
weak and captured before the overlay is attached, so a transient menu neither retains a recycled
row nor loses the close notification merely because the hierarchy moved. This is intentionally
not folded into pointer tracking: an open menu is semantic interaction state, not a claim that the
pointer remains over its source.

**A pane's contents may say how wide they would like to be; they may not say how wide the pane
is.** A centred column is usually written as "the pane's width, capped" — an equality against the
container at `.defaultHigh` beside a required maximum. Auto Layout reads that pair as a statement
about the *container*: the composer's column said the terminal pane is at most 784pt wide, at a
priority that outranks the 250/260 a split view holds its panes at, so in a 1200pt window the
sidebar could not be dragged below 415pt — its divider stopped 200pt above its own floor, and
pushing on shut the column instead. Both halves of the fix are needed and both are in
`ComposerDefaults`: the measurement drops below every holding priority
(`columnMeasurePriority`), and the stack's own hugging drops below *that*
(`columnHuggingPriority`), or the column starts hugging its widest row instead of filling.
`testTheComposerColumnDoesNotCapThePaneItFills` states the rule against a host that claims its
width the way a split item does.

**A menu too tall for its panel cuts its last row in half.** `ThemedMenuLayout` clamps a panel
twice — to `maximumHeight(in:)` and to the room on the side it opened — and either clamp is free
to land on a row boundary, at which point the menu looks complete. The session row's menu grew
past the cap and did exactly that: Copy Session ID, Move to Account and Delete Session were below
the edge, and nothing on screen said so, because the scroller only appears once the pointer is
inside the panel. The cap itself is window-relative (`maximumHeightRatio` of the window, floored
at the old flat 360): the flat cap was set when the longest menu was half its eventual size, and
once the session menu outgrew it, scrolling was the *normal* state in every ordinarily sized
window with the destructive item permanently below the fold. A tall window now shows the whole
list; a cramped one keeps exactly the behaviour the flat cap gave it. `ThemedMenuMetrics.clippedHeight(for:atMost:)` takes the clamped height down to the
nearest half row, and `frame`/`submenuFrame` apply it through `whenClipped` only when the panel is
actually cut — half a row hanging off a complete list would promise rows that do not exist. Only
items are cut; a separator sliced down its middle reads as a stray rule against the panel's edge,
so it is carried whole into the hidden part and the item above it peeks.

**A panel with no room beside its control takes the window instead of a sliver.** The room a
dropdown has is the room its *window* has, because the overlay is a view inside that window's
content — and a dialog sized to its own two lines of text has almost none. A pop-up in one opened
a list of ninety-six quarter hours **one and a half rows tall**: a scroller, a peek, and not one
answer anybody could be looking for. `ThemedMenuLayout.minimumUsefulHeight` is four rows, the
point at which a panel still reads as a list; below it `frame` stops clearing the control, takes
`bounds` less the screen inset, and slides the panel back inside the window — lying over the
control the way a platform menu does on a screen too short to hold it. It is a floor, not a
preference: a window with room still opens the panel off its control's edge. (The dialog that
found this now has no pop-ups at all — see
[`scheduled-messages.md`](scheduled-messages.md) — but the geometry belonged here.)

**A dropdown and a popover never share a window; the dropdown wins.** `ThemedMenuPresenter`
draws inside the window's content view — that is what lets it escape a scroll view and take no
key status — while `ThemedPopover` hangs a child *window* above the same window. So a popover is
over every dropdown in that window whatever order they open in: press `+` on a sidebar row whose
hover card is up and the menu opens *behind* the card, which also swallows the clicks meant for
its rows. Both directions are closed in one place. Opening a menu calls
`ThemedPopover.closeAll(presentedFrom:)`, which closes the popovers hanging off that window —
and only those, so a menu opened from a control *inside* a popover (presented in the panel's own
window) leaves the surface carrying it alone. Presenting a popover asks
`ThemedMenuPresenter.isMenuOpen(in:)` first and declines, because the overlay cannot silence
tracking areas: a row crossed on the way down an open menu would otherwise raise a card over it.
Owners therefore ask `popover?.isShown` rather than trusting the reference they hold — a row
reading a stale one as "still showing" never raises a card again.

**A popover that is only ordered front cannot be typed into, and says nothing about it.** The
panel is a child window above the presenting one, and `show` orders it front without making it
key — right for the pointer-driven majority, since a hover card that took key status would pull
the caret out of the composer and unemphasize every list behind it. But on a panel that is merely
visible, `makeFirstResponder` still returns true and still installs the field editor, so a caret
blinks in the popover's own search field while every keystroke goes on reaching the window
underneath. That is what ⌘J's jump-to-file shipped as: a popover that opened, focused, and could
not be typed into, with no assertion anyone would write catching it. Content that wants the
keyboard names its responder — `ThemedPopover.initialFirstResponder` — and setting it is what
makes the panel key; `close()`'s existing `wasKey` path hands the keyboard back to the responder
it was taken from. A borderless `.nonactivatingPanel` can hold key status while the host
application is inactive, so the two tests pinning both halves need no window on screen.

**A menu opened by a secondary click hangs from the pointer, not from the view that was
clicked.** `ThemedMenuPresenter` was written for dropdowns, where the anchor is the button and
the panel lines up under its leading edge with a small standoff. A context menu presented the
same way opens in one fixed place however large the thing clicked is, and however far from that
place the click landed — the composer's attachment thumbnail showed it, the panel jumping to the
thumbnail's corner rather than answering the click. `ThemedMenuAnchor` names the two idioms:
`.control` is the dropdown and stays the default, `.pointer` puts a corner on the click and drops
the standoff, because the gap exists to clear a button's edge and a pointer has none. Which one
applies is the *gesture's* knowledge, so it travels with the report — `ThemedTabItemView` hands
its strip an anchor rather than a bare "a menu was asked for", and the accessibility
show-menu route, which has no pointer behind it, asks for `.control`.

**A window carries one root menu.** The ordinary left-click route dismisses an open dropdown
through its overlay before handing the press to another menu-opening control, but a list's
secondary-click route is independent of that overlay. With the pane's Context menu open,
secondary-clicking a sidebar row therefore presented a second menu while the first was still up.
The sidebar retains one menu token; replacing it deallocated the first session without removing
the first overlay, leaving a full-window hit-testing surface that no owner could ever dismiss —
the visible menu stayed over the pane and blocked controls such as the project `+` permanently.
`ThemedMenuPresenter.present` now closes every open session belonging to the source window before
constructing its replacement. The dismissal is synchronous, so a caller's one token slot is
cleared before it receives the new token, and a menu in another window remains independent.

**An open menu owns itself; the token is not a lifeline.** The replacement rule above cured one
way a session could die under a live overlay, and the composer's clock found the other: it
presented its refusal menu ("Write the brief first.") fire-and-forget, and with the session
roster weak, dropping the returned token deallocated the session the moment the menu opened.
The stranded overlay is the worst state this component has: it spans the window, swallows every
click and key the way a menu must, and each of its dismissal callbacks holds the dead session
weakly — so nothing the user can do closes it, and the window reads as hung. The session roster
is therefore strong for exactly as long as a session is open — `finish` is the only exit, every
path funnels through it once, and a `willClose` observer ends a session whose window leaves
without resigning key. The token `present` returns is still how a caller dismisses
programmatically or forwards a held press's drag; it is no longer what keeps the menu working,
so a call site forgetting it is a style nit rather than a hung window
(`ThemedControlTests.testAMenuWhoseTokenWasDroppedStillDismissesForTheUser`).

**An open menu owns key events, not merely the current first responder.** The overlay takes first
responder and temporarily becomes the window's initial responder so focus and accessibility agree
with what is on screen. That is not a sufficient event boundary: AppKit can install a field editor
or apply deferred responder bookkeeping while the dropdown is already visible. The session
therefore carries a window-scoped local key monitor for its whole lifetime and routes key-down
events through the overlay before ordinary responder dispatch; `finish` removes it synchronously
with the focus observer and restores the source. The regression sends Escape through `NSApp` after
deliberately moving first responder away, because calling `overlay.keyDown` directly would only
prove the handler and a timed run-loop wait would make scheduler speed part of the contract.

**Scrolling a menu moves the rows, not the hand, and the highlight belongs to the hand.** A
row's hover *is* the menu's highlight, and hover is a tracking-area fact: wheel a clamped menu
(the session row's is the one that overflows `ThemedMenuLayout.maximumHeight`) and AppKit hands
`mouseEntered` to every row that slides under the stationary pointer, so the highlight walked
the list as the list moved — and each landing re-armed the submenu hover-open while the scroll
closed the panels it opened, so Session Options flickered in and out on the way past. Worse,
a highlight also used to `scrollToVisible` unconditionally, so a scroll-induced landing on the
half-peeked row answered the wheel by scrolling *against* it. Three rules close this, all in
`ThemedMenuOverlayView`: a scroll records the pointer's position and freezes hover-driven
highlights until the pointer moves past `ThemedMenuMotion.scrollHoverTolerance` (`mouseMoved`
then re-lands the highlight from position, because the row under the pointer got no fresh
enter — it has believed itself hovered since the scroll); a scroll kills the armed hover-open;
and only *keyboard* highlights scroll their row into view — a pointer highlight names a row
already under the pointer. This is deliberately menu-local: `PointerTracking`'s contract
("only ever answers *left*, never *arrived*") stays untouched, because a chip sliding under
the pointer keeping its hover invitation is the behaviour the overlay-handoff rule above
depends on.

**A menu row's line stops being a line once the menu is a table.** `ThemedMenuMetric` is a
reading a row states as a *column* — a name, a bar, and the value — instead of as words inside
its subtitle, and `ThemedMenuEntry.header` is the name over a group of such rows. Both exist for
the account rows (see [`accounts.md`](accounts.md)), and both come from one observation: in a
sentence, a value's position is decided by the length of the name in front of it, so three
logins put their three 5-hour numbers at three different x positions and the comparison the menu
exists for becomes a search. The menu measures **one column plan across every row**
(`ThemedMenuMetrics.metricColumns` / `metricColumnWidth`), so a label appearing on any row gets
the same slot on all of them; a row with no reading for a column leaves the cell **empty rather
than closed up**, since closing it would slide that row's remaining readings under a different
heading. The reservation comes out of the *title's* width rather than being added to the panel's
once the width cap is reached — the inversion is the point, because the line this replaced
truncated its countdown (`7d resets in 5d 1…`) while the name it was competing with stayed
whole. A name is the one thing on a row still recognisable from its first half, so the name is
what gives way. `trailingDetail` is the right-aligned column after the metrics, `titleDetail` the
quiet qualifier sharing the title's line, and `spokenSummary` all of it joined for the two
consumers that see neither a column nor a bar — the tooltip and VoiceOver. A header is not a
submenu and adds no press, which is what lets grouping pay for itself: the group's name comes off
every row inside it. Between the readings and the countdown there is a **rule**, not more air:
they are different kinds of fact, and at the gap that parts two columns they joined into one run
of numbers. Its *space* belongs to the menu's column plan so the cursor steps over it on every
row; its *ink* is the row's, or a runtime with no login draws a rule standing alone in an empty
row.

**A menu row may explain more than its title without becoming two lines tall.**
`ThemedMenuItem.help` is supplementary consequence text: the shared row presents it as the Help
Tag after pointer dwell and as accessibility help, while the visible title remains the menu item's
accessible name. It is distinct from `subtitle`, which is standing content and participates in
the height and column plan. The limit-recovery outcomes are the first use: “Continue on the Best
Login” names an outcome, while its help explains the stop, move and queued continuation. The row
owns the Help Tag so a feature never installs competing hover tracking over menu chrome.

**Three things a row does not decide for itself: its height, its first line, and the gap inside
it.** All three shipped wrong in the account rows and all three are one mistake — treating a row
as if it were the only one on screen.

- **Height is the run's**, not the row's (`ThemedMenuMetrics.heights(for:)`). Asked entry by
  entry, a row with a second line is `subtitleRowHeight` and one without is `rowHeight`, so a
  group of logins where three carry a scoped window and two do not had two rhythms stacked in
  direct contact — which reads as a spacing defect, not as rows that happen to differ. The unit
  is a run of consecutive rows delimited by separators and heads: every row in a run takes the
  tallest kind in it, and the delimiters are what keep this from flattening every menu in the app
  into one tall rhythm (the project menu's two actions sit after a rule and stay short while the
  projects above keep the height their paths need). It is also the **one** source: the same call
  sizes the panel, positions the rows and lays out the document view, which used to derive heights
  by view *class* and so laid a 30pt section head out in a 13pt separator's slot.
- **The first line is an axis, not each element's own centring**
  (`ThemedMenuMetrics.firstLineCenter(inRowOf:reservesSubtitleLine:)`). The checkmark, the mark,
  the title and its qualifier, the metric columns, the trailing detail and the submenu chevron all
  sit on it. Every one of them was centred on the row instead — right for a single-line row, wrong
  for every row beside one: a title with a subtitle is placed as a centred *block*, so its line
  sits above the row's middle while the mark next to it sank to between the two lines, and a
  neighbouring row without a subtitle put its name where that row's ink was not. The axis is
  computed from what the **run** reserves, so a row with no subtitle keeps its title on its
  neighbours' line and leaves the second line empty, the way a table leaves a cell empty.
- **`subtitleGap` is not zero.** Stacking the two lines flush was argued from the line box already
  carrying the font's own leading; that holds for the modern face and fails for the classic ones,
  whose boxes are drawn tight around the glyphs — the pair touched and read as one wrapped
  sentence. The classic `subtitleRowHeight` went 31 → 36 to absorb it, since at 31 the two lines
  filled all but 2.5pt of the slot and the gap *between* two rows was narrower than the gap
  inside one.

**A menu subtitle is one ink until its line is a comparison.** `ThemedMenuSubtitleSegment` lets
a row's subtitle carry toned runs — standard, muted, warning, critical — resolved to colours in
`draw(_:)` from `Design` roles, so a live theme switch re-inks the next frame rather than
honouring colours frozen in at decoration time. It exists for the account rows' usage reading
(see [`accounts.md`](accounts.md)), where the one number a three-login comparison turns on sat
in a line of twelve equally grey ones. The tones are semantic and the row owns the palette,
which is what lets a classic selection band flatten every run to its own authored subtitle ink:
that pair is the only ink measured against the band's solid fill, and a status hue over Win98
navy is exactly the unrecorded contrast it exists to prevent. `setSubtitle(_:)` is the one
entry point — it derives the plain join the tooltip, the type-to-filter and the width
measurement keep reading, so the drawn line and the measured one cannot disagree — and tones
change ink only, never font, so the plain string measures exactly what the styled line draws.
The same pass gave both text runs an honest overflow: a line wider than the panel's width cap
ends in an ellipsis rather than a hard clip, because `7d resets in` with its number sliced off
is a sentence claiming to be complete.

**A menu row answers a press with one action, and a list of sounds needed a second.**
`ThemedMenuAccessory` is a control a row carries at its trailing edge — the play button on a
sound — and it exists because a name is not a sound. Auditioning one by *choosing* it means the
only way to hear `Funk` is to accept it, so comparing three left the third written into the
setting; that was the state the sound pickers shipped in, described in
[the sounds section of the user guide](../../USER_GUIDE.md). Four rules make a second target
inside a row safe, and each of them was arrived at from the thing that goes wrong without it:

- **It never chooses.** The press is consumed in the row and `onChoose` never fires, so the menu
  stays open and the setting stays put. A version that also chose would look completely correct
  to anyone who clicked it once.
- **Its column is reserved by the menu, drawn by the row.**
  `ThemedMenuMetrics.hasAccessoryColumn` answers for the whole panel exactly as the image, preview
  and chevron columns do, so a slot appearing under the pointer cannot shorten the title beneath
  it. The accessory owns the outermost trailing column and a submenu chevron steps inward by its
  slot.
- **It is a hover-revealed control, so it steps in ink only** — `secondary` where the row is
  merely current, `label` under the pointer, `label` dimmed while held, the same alpha step
  `ThemedButton` gives a press. A plate behind the glyph was tried first and was invisible, since
  the accessory only ever appears on a row already filled with `controlHover`; the render is what
  said so, and `ThemedMenuAccessoryTests` now asserts a held press does not draw like a hovered
  one.
- **It stays an accessibility *action*, not an element.** A menu item is a leaf here, and a second
  focusable thing inside one would hand every consumer that walks a menu a row wearing a button.
  `accessibilityCustomActions` names it, and the right arrow reaches it from the keyboard on a row
  that opens no submenu — Space and Return are unavailable by definition, since both choose, which
  is the commitment being avoided.

**A surface role is translucent on purpose, and that purpose ends where live content begins.**
`surface` is the base tone at 14%, which is what makes a pill read as a lift off the backdrop
rather than as a patch stuck on it — right for a control on an empty stretch of chrome, wrong for
anything floating over text. The git status card is the one thing in the app that does float over
the pane's own content, and at 14% over a native conversation the agent's answer ran straight
through the branch name; a view-level `alphaValue` for "quiet at rest" thinned the fill along with
it. `WindowBackdrop.opaque(_:)` flattens a role against the ground it will sit on — identical
colour over bare backdrop, no see-through over anything else — and quiet-at-rest belongs on the
card's *contents*, never on the card. Embedded floating chrome also applies the neutral system
shadow requested by its material when no authored material glow replaces it; unlike a popover
window, an embedded view receives no platform shadow for free. A new floating surface takes the
same rules.

**The session status card is a column, not a shrink-wrapped pill.** Its minimum width gives every
row one stable menu-like measure, and every interactive row stretches across that measure so the
hover and click target cover the whole cell. Native information is grouped with `SeparatorView`:
checkout/review/activity above recent attachments, then extension rows behind a second rule. The
rules use their own optical gap rather than the list's ordinary row gap. The shared separator
API asks the adjacent row for its `OpticalInsetProviding` correction, so changing the final row
from bare text to a button cannot silently add the button's padding; bare extension text receives
the full gap. Connected-review
rows use primary ink, and checks show both a sliced progress ring and every non-zero count rather
than collapsing already-passing work into the overall pending state. The
attachment projection creates at most three fixed buttons and one optional View all row before
layout. Those three rows retain only validated kind/URL metadata and decode no picture until the
hover dwell asks for one. Image rows carry a trailing menu chevron and open a bounded thumbnail
over `ThemedActionPopoverViewController` actions (Copy Image, Copy Path, Open in Attachments and
Reveal in Finder); non-image rows use the same action anatomy without inventing a fake preview.
`session.corner-card@1` remains semantic: compact rows may combine host-rendered icons,
text and status, while a disclosure gives arbitrary bounded structured detail and standard
actions on a host-owned second level. In a horizontal reading, a short trailing status keeps its
measured text width before the compact name and flexible spacer spend the remainder; prose-length
states are still capped and truncate. Extensions never draw the chrome or supply AppKit controls.

Two guards keep it: `MainWindowToolbar.makeOverlayItem` asserts that anything placed in the
toolbar inks from `.backdrop` (the protocol can only say a view *can* be inked, not which ink it
took, now that one component serves both), and `ToolbarChromeRenderTests` pins that the display
pane's and the settings sidebar's tabs are the same type rather than comparing two classes'
measurements — a test that could only ever catch drift after it happened, and which passed for a
long time over two tabs that visibly differed. The window's own header no longer draws a tab at
all; `PageTitleView` names the page instead, and the same storybook renders it beside them.

The rule behind the table now covers **every chrome-drawing AppKit class**, not just the seven
that eroded first: content containers (`NSScrollView`, `NSTextView`, tables) because their
stock backgrounds are system surfaces, and every control the app has never used, so the first
slider arrives through a themed wrapper rather than establishing stock. Layout types
(`NSView`, `NSStackView`, `NSGridView`), labels, chromeless `NSImageView` and genuinely system
workflows (native application/context menus and file panels) stay allowed — they draw nothing
the theme owns. App-owned popovers and alerts do not: `ThemedPopover` and `ThemedAlert` own those
surfaces. `scripts/config/theme-boundary.json` owns the list; the build and test suite both run
its SwiftSyntax checker, while `.swiftlint.yml` provides fast editor feedback. A class with no
wrapper yet gets one in `UI/Design/` first.

### Confirmations

`ThemedAlert` owns presentation, but *asking the user a question* still requires a semantic
policy. Every app confirmation goes through `ConfirmationAlert` in `UI/Alerts/`, and every one
names a case in `ConfirmationPrompt`. The web delegate's JavaScript dialogs are the narrow
exception: the page, not Threading, dictates their questions and answers.

The register exists because the alternative is a reflex. There were 44 alerts and no suppression
anywhere: writing one more `NSAlert` with two buttons required no decision about whether the
interruption was earned, and offered no way to stop it. `ConfirmationPrompt.policy` is an
exhaustive `switch` with no `default:` and no defaulted value, so a case added to the register
does not compile until somebody has answered the question — and the answer is a type rather than
a `Bool`, because a `Bool` records which way it went and not that anyone chose.

**The first question the register asks is whether there should be a question at all.** A
confirmation stops everybody who meant the action in order to catch the one who did not; a
receipt with a way back on it charges the mistake alone. So an action whose whole effect can be
put back by pressing something takes a `ToastRequest` instead of a `ConfirmationPrompt` — it
acts, says what it did, and leaves the undo on screen for six seconds. Archiving a session is
the first of them, and its case was *removed* from the register rather than left switched off,
because a case nobody asks still ships a Settings row for a question that no longer exists. The
line, written beside the remaining lifecycle prompts: **a prompt is right where the way back is
a different action the user has to know to take, and wrong where the way back can be handed to
them.** Deleting is the other side of it — nothing survives to undo with, so it still asks.

**A question that is new each time it is asked is its own policy reason.** The software-update
prompts (`.installUpdate`, `.installUpdateAndRelaunch`) are `.alwaysAsks(.newQuestionEachTime)`:
each names a version that did not exist when the last answer was given, so a remembered answer
would approve something sight unseen — which is automatic installation, a capability the app
deliberately does not offer. Return stays on the affirmative, since nothing on that branch is
destructive and declining is one Escape away. The whole update flow otherwise composes what this
file already owns — `ThemedAlert` sheets, `ThemedProgressBar`/`ThemedSpinner`, `MarkdownView`
release notes — with one recorded exception: after the app terminates for the file swap,
Sparkle's own installer agent can put a small progress window on screen if the swap runs long.
No user driver can take that over; it appears only when no Threading window exists to disagree
with it, and forking Sparkle to remove it is the escape hatch if it ever grates
(see [`releasing.md`](releasing.md)).

**How long a receipt holds is a fact about who caused it, so it belongs to the request.** The six
seconds are measured from a click: the hand is on the mouse and the eye is on the row that
changed. An agent archiving its own session (see [`sessions.md`](sessions.md)) puts the same band
in the same pane with none of that — the user asked for it a turn ago, in words, and has been
reading something else since — so `ToastRequest.dwell` overrides the presenter's, and that
receipt takes `ToastDefaults.unattendedDwell`. It also names the agent in its message, because a
row that leaves the sidebar on its own is the one report where "what happened" without "who did
it" is the wrong half of the sentence.

**An operation updates one band; it does not arrive once per unit of work.** A request may carry a
determinate `progress`, `persistsUntilDismissed`, and a `replacementID`. Matching identifiers
restamp a structurally compatible `ToastView` in place: the themed progress bar changes value,
the words may advance, and neither arrival motion nor a VoiceOver announcement replays for each
directory. The final request keeps the same identifier and progress anatomy, changes the message,
turns persistence off, and starts the ordinary dwell. This is separate from the bottom-edge dwell
rail: one says how much work is done; the other says how long a completed receipt remains.

**Nothing that can be taken back is dropped, so bursts queue.** One band at a time is still the
rule — two of them in a 240-point column is a wall over the list they report on — but the band
already up is no longer overwritten by the next arrival. Four archives in a row are four separate
undos, and a receipt replaced a moment after it lands is one whose action nobody ever gets to
press, which is precisely the safety net that justified archiving without asking first. So a band
**with a way back** holds the pane and later reports wait behind it (`ToastDefaults.queueLimit`,
oldest dropped first, because the queue is measured in dwells and a receipt surfacing most of a
minute after the click is news rather than a receipt); a band with **nothing to offer** is still
replaced where it stands, since nothing is lost and the newer line is the one that describes the
state the user is in — the navigator's error arriving behind its own progress message.

**A queue nobody can see is a promise nobody can act on, so the waiting receipts are drawn.** A
band with three behind it looked exactly like a band that was the last thing that happened, and
the only way to learn otherwise was to read one, watch it leave, and be handed a second — by
which point the user who turned away as the first landed has already turned away from all of
them. Each waiting receipt now stands behind the band as `ToastStackEdgeView`: the *same card*,
one `stackStep` up and one `stackInset` in on either side, so all that shows of it is its top
edge. Not a dimmed copy — what is behind the band is a receipt exactly like it, and the depth
comes from the offset plus the front band's own glow falling across it. Stepped in on **both**
sides, because offset in one direction it reads as a page sliding off a desk rather than as the
next card in a deck. The edges are pinned to the band's own top *and bottom* rather than given a
height, so everything below the band's top edge is behind an opaque surface however tall the
receipt in front turns out to be, and no theme's corner radius has to be measured into a
constant. Two edges at most **at rest** (`ToastDefaults.stackDepth`), whatever the queue's depth: closed, the
stack answers *is this the only one* rather than *how many*, and a count is the one thing it could
not honestly report — the bound drops from the front of the queue when a burst overruns it. Closed
it says nothing to VoiceOver either, which is read each receipt as it arrives.

**A queue you can count but not read is only half the promise, so the deck opens.** Drawn edges
answer *how many are coming* and nothing else, and the thing people wanted was on the third card:
a burst of archives is four separate undos, and reaching the last one meant sitting through the
three dwells in front of it. Reaching into the strip above the band (`ToastDeckGripView`, on the
app's shared hover timing) fans the deck out — `peekStep` instead of `stackStep`, so what uncovers
of each card is a strip its own line can be read in, with that receipt's way back on the end of
it. Three decisions hold it up:

- **Opened, the deck is the whole queue.** The resting stack stands two edges for up to three
  waiting receipts, which is honest while a card says only *another is coming* and dishonest the
  moment it has words: a reader looking at an open deck asked what is in it. The third card is
  dealt hidden behind the band and rises with the rest, so the fan opens as one movement.
- **The band's clock stops while it is open**, on the same remainder rule the pointer already had.
  Every card in the fan is pinned to the band under it, so a dwell allowed to run would take the
  list out from under the hand reaching into it — and each card in that list carries an action.
- **The grip takes no click.** It has to lie over the whole fan or a pointer travelling up the
  deck would leave the region holding it open, which means it lies over every way back in it;
  tracking areas are geometric and do not consult hit testing, so a region can report the pointer
  and swallow nothing (`ToastLaneView`'s trick, for the same reason).

Taking one back removes that receipt alone: its card stays where the hand left it and fades while
the ones behind step forward into the slots, the band in front is untouched, and a deck with
nothing left in it closes itself rather than hanging an empty fan over a clock it is holding. A
card is an accessibility element only while the deck is open — closed it is a four-point sliver
standing for a receipt VoiceOver is already promised when its turn comes.

**A receipt you have already read is furniture, so it can be sent away.** The band leaves on its
own, which is what made it safe to archive without asking — but "on its own" is six seconds of a
card sitting over the list the user is trying to get back to. Two ways out, and they are one
decision:

- **A ✕ in the corner**, visible whenever the band is. Hiding it until the pointer arrives is a
  tab's grammar and the wrong one here: hovering this band *stops its clock*, so the gesture that
  would discover a hidden mark is the same gesture that makes the band stay. A receipt that has to
  be leant on before it admits how to be rid of it answers "make this go away" with "it will stay
  as long as you keep looking for the button". It is quiet without being hidden — a
  `ThemedIconButton` rests at `secondary` and lifts to full strength only under the pointer.
- **A throw**: drag the band sideways, or swipe it with two fingers, and letting go past
  `throwCommitFraction` of its width or above `throwVelocity` sends it out the way it was going.
  Speed counts only in the direction it is already travelling, so pulling a band back is a change
  of mind rather than a throw the other way; anything short of both springs back. It fades towards
  `Design.Opacity.dragAway` as it goes, which is the only thing that says *let go now and it goes*
  on a gesture whose threshold is otherwise invisible until it is crossed.

The gesture is an **accelerator for the ✕ and never the only route** — that is what keeps a
mouse-only dismissal out of a transient surface, and it is the whole of `ToastView`'s
`interactiveComponent` exception. The band draws nothing pressable; both its controls are real
ones. The carry holds the clock exactly as the pointer does, and for a stronger version of the
same reason: a band that expired halfway through the gesture aimed at it would be dismissed by its
own dwell while somebody was still deciding. The two holds are reported as one signal, because
handing the presenter a second pause would spend a paused clock's remainder against itself.

**The deck moves the way a deck of cards moves, and nothing fades.** Every card is somewhere the
whole time: a receipt arrives by rising over the pane's lower edge — whole, with its deck pinned
behind it — a newly waiting receipt's edge is dealt in at the band's own silhouette and rises
from behind it into its slot, and a dismissal is one motion in which the front card drops out of
the pane while the next receipt takes over from the deck's front slot and the surviving edges
step one slot shallower behind it. The promoted band is a real `ToastView` stood in the exact
silhouette of the edge that stood for it, so the swap is invisible and the settle — down one
`stackStep`, out one `stackInset` a side, the width cap widening with it — reads as the card
coming forward. Fading was how stacked receipts moved before this, and it made the queue's own
grammar illegible: a deck announced itself as cards and then dissolved like vapour. The one
opacity left is the throw's — the carry fades the band towards `dragAway` as a threshold signal,
and a thrown departure finishes that fade because it is finishing that gesture. Timing is
`Design.Motion.travel` on `ToastDefaults.glide` (hard deceleration — placed, not floated) for
everything arriving or settling, and `ToastDefaults.drop` (acceleration — a card falls, it does
not lower itself) for the settled departure. Being *below the pane's edge* is what a subview
cannot do alone, so the presenter keeps every card in a `ToastLaneView`: a full-pane,
event-pass-through, draw-nothing overlay whose bottom is the edge the band rests above. It crops
(`layer.masksToBounds`) **only while a card is crossing the edge**, held per transition and
counted because a fast-walked burst overlaps them — never at rest, since a theme may hang up to
`Design.Size.glowGutter` of shadow off a card and a resting crop would slice it off every
receipt. The z-order trick was tried first and cannot work: `PaneFooterView` draws nothing but
its hairline, so a card "behind" the footer reads straight through it. Travel distances carry
`ToastDefaults.clearance` (the glow gutter again) past the edge, so no departing card leaves its
own shadow hanging over the footer.

How a band leaves is the request of the departure rather than of the presenter (`ToastDeparture`):
a receipt that was pushed sideways must not then drop back down the way it arrived, since the
throw is half an animation the hand already performed and the departure owes it the other half —
quick where the settled drop takes the full travel, because the hand already supplied its first
half. The queue is untouched by *how* a band went — throwing one hands the pane to whatever was
waiting exactly as running out of time does, so a burst can be walked through card by card, each
promotion riding the departure before it.

**A card floating over a list takes the pointer, not only the press.** The band swallows its own
`mouseDown` so a click cannot fall through to the row it is covering, and the pointer needed the
same rule for a reason that is not visible in either file: `NSTrackingArea` reports crossings of a
*rectangle* and knows nothing about what is drawn over that rectangle, so both views are sent
`mouseEntered` whichever one a click would reach. Resting on a receipt therefore lit the sidebar
row hidden behind it — and because the row's highlight and the band happen to be inset from the
column by the same 10 points at the width it opens to (`SidebarRowDefaults.hoverHighlightInsetX`,
which started from the stock source list's selection and now closes with the column, and
`ToastDefaults.hostInset`, which is `Design.Spacing.medium`), that 6%
wash lined up exactly with the band's sides and stood six points proud of its top edge. It read as a backplate belonging to the band, rounded to a corner that was
not the band's, which is how it was reported. The wash was the visible half: the session row under
it also armed its hover popover, which would have opened over the band somebody was reaching
across. The sidebar's rows now ask `NSView.isPointerCovered(at:)` before they accept a crossing —
hit testing is how a click is aimed, so it is also what says which view the pointer is on. It is
*asked for* rather than folded into `hoverIsStale`, because a dropdown's dismissing overlay is a
view in this same window and covers every control under it: the chip whose menu is open has to
stay lit and clickable, which is the handoff rule above.

Five rules, each one a bug it prevents:

- **`.suppressible` carries its settings copy as a payload, not an optional computed property.**
  An optional can be `nil`, and a `nil` there ships a prompt the user can silence with nowhere to
  un-silence it. A payload cannot be absent. The Settings ▸ General card is built from
  `ConfirmationPrompt.suppressible`, and `GeneralSettingsRenderTests` holds every case to having
  a row — the half of the invariant a type cannot state.
- **`.alwaysAsks` names *which* kind of irrevocability, and the name does something.**
  `.irreversible` puts Return on Cancel and marks the action destructive; `.securityGrant`
  deliberately leaves Return on the affirmative button, because the agent is blocked while the
  sheet is up, approving is the common answer, and every grant is scoped and revocable in
  Settings. A free-text `reason:` was the first design and was rejected: prose can be `"because"`,
  nothing reads it, so nothing can be wrong. This version generalises the rule
  `ExtensionCommandInvoker` had applied by hand to exactly one alert out of eight.
- **Suppression is remembered only when the action was accepted.** Ticking the box and pressing
  Cancel stores nothing, or the next attempt sails past an action the user had just declined.
  `ConfirmationAlert.remembers(accepted:suppressionChecked:)` is pure so the matrix is testable
  without a modal — the same split `AttentionAlertPolicy` keeps from its center.
- **`choose` refuses a suppressible prompt.** A remembered answer has to be *an* answer, and a
  checkbox beside three affirmative buttons says nothing about which one it would repeat. Grants
  live on that path and carry their own narrower memory instead: "Always Allow This Host" is one
  host, "Allow for This Session" is one tool in one chat.
- **`AppSettings.asks(before:)` consults the policy before the stored set.** The suppressed set is
  raw strings on disk. Without that guard, a prompt reclassified `.suppressible` → `.alwaysAsks`
  in a later release stays silent for exactly the users who had switched it off — the population
  least able to notice that a destructive action stopped asking.

**The lint is what makes the register the only door**, because the exhaustive switch only forces a
decision for prompts already routed through it — it says nothing about a direct two-button
`ThemedAlert`. Stock alert construction is banned, and the semantic signal is narrower still:
*an informational alert never inspects its response*. So `confirmationResponse` reports any read of
the AppKit response names or `ThemedAlert.firstButtonResponse` outside
`confirmationGateDirectories`. One exception exists, for the JavaScript dialogs a web page
dictates in `BrowserViewController`. Honest gaps: comparing `response.rawValue == 1000`, running a
two-button alert and discarding the answer, or adding a second gate. Those are deliberate evasion;
reflex is what the lint catches.

**A repeated statement earns the same way out a repeated question does.** An OK-only alert asks
nothing, which is why the register above deliberately does not cover it — but a receipt shown
after every invocation of the same command ("Checks refreshed.") interrupts exactly as a
question would. `NoticeAlert`, in the same directory for the same reason (honouring the box
means reading the response the lint bans elsewhere), shows a statement whose request may carry
an `AppNotice` key; the box says "Don't show this message again" rather than "Don't ask again",
because nothing was asked, and it is honoured only when OK dismissed the alert. The registers
stay separate because their shapes differ: notice keys are **dynamic** — the first ones are
extension command receipts, one per qualified command id — so there is no compile-time case per
key to hang a policy switch on, and the Confirmations card carries one "Hidden extension
messages ▸ Show All" control instead of a row per key (a hidden receipt whose extension was
removed has no honest title left for a row; `GeneralSettingsRenderTests` holds the control to
existing). "Errors always show" is enforced by construction rather than by a flag: an error
path is never given a key at all, and `ExtensionCommandInvoker.resultNotice` is the one seam
that states it.

`TextPromptAlert` lives in the same directory and carries no prompt, because an input prompt's
answer *is* the input and cannot be remembered. It is there so the lint's exception list stays at
one entry rather than holing five files that also hold real confirmations — and collapsing the
five copies fixed a drift while it was at it: two trimmed whitespace only and three trimmed
newlines too, so a pasted name kept its trailing return in some places and not others.

**A choice that *is* an animation is shown in the list, not named in it.** A dropdown row can
carry a live view (`ThemedMenuPreview` on `ThemedMenuItem`), and the Motion settings page is
what needed it: "Bounce" describes a transition exactly as well as "Searching" describes an orb,
which is to say not at all, so deciding meant selecting one, watching it, selecting the next, and
comparing against a memory of the first. An image would not have helped — a still of an animation
says only that there is one.

The view is the caller's, made once and handed over, which is what keeps a preview honest: the
row draws the same `WorkingOrbView` the conversation status draws and the same
`MorphingTitleLabel` the sidebar morphs, rather than a second rendering of either. Two
placements, because the two settings need different shapes — `.leading` puts a preview in its own
reserved column beside the title, `.title` puts it *in* the title's slot and the row draws no
text, which is the only way a text transition can be demonstrated at all.

Four rules, and each is about legibility rather than cost:

- **Who moves is per placement, and the previews decide.** Ten orb rows run at once because
  comparing animations means seeing them together; eleven names morphing at once is unreadable,
  so a transition plays on the highlighted row only. The row reports its highlight
  (`highlightChanged`) and says nothing about what that should mean.
- **A demonstration holds the row's own name first** (`Design.Motion.demonstrationHold`). The
  highlight is also where it lands when the menu *opens*, and a list whose selected row read
  "Threading" the moment it appeared had answered a question nobody asked with the one name the
  user came to read. It doubles as the dwell that lets a pointer cross the list.
- **Only the row that owns a demonstration may end it.** The menu keeps its rows in a
  dictionary, so a highlight moving from one row to the next reports in no defined order, and an
  unguarded stop cancelled the row that had just started.
- **A closed menu takes its demonstration with it.** Nothing reports a highlight *leaving* when
  a dropdown is dismissed — the surface deliberately stops moving the highlight once it is
  closing — so the row's own departure from the window (`viewWillMove(toWindow: nil)`) delivers
  the `false`. Without it a timer steps forever against a view nobody can see.

Under Reduce Motion the rows keep their names and stay still: `setStringValue` would not animate,
so demonstrating there would be two names swapping outright — more visual change than the list it
replaced, in the setting that asked for less. The orbs need no branch, since `ThinkingOrbView`
already idles its display link.

The second name is the **app's own**, read from the bundle (`AppInfo.name`) rather than written
down. A transition acts on a change, so a demonstration needs two names, and that is the one
string every install has.

`PromptView` is an `NSTextView`, not an `NSTextField`, for two things a single-line field
cannot do: a task worth describing runs past one line, and what is dropped on a composer is
as often an image as it is text. It grows with its content to `Design.Size.inputMaxHeight`
and scrolls past it — two separate mechanisms, the box's own height constraint and the text
view's frame inside its clip, and a prompt that grows without scrolling hides what is typed
into it (see the `maxSize` rule under [Themed Controls](#themed-controls)). Which
is why the scroller is decided *before* the height guard in `updateHeight`: by the time text
overflows, the box is already at its cap and the constant has stopped moving.

**Undo has two owners, and both are required.** `ThemedTextView.allowsUndo` makes user edits enter
the text system's manager; the application menu then reaches that manager through AppKit's window
responder actions, `undo:` and `redo:`. Those colons are load-bearing. `UndoManager.undo` and
`.redo` expose different zero-argument selectors, so sending them through the responder chain
finds no target even while the focused prompt has an operation waiting. A component test that
calls the manager directly proves only the first half; `PromptInputTests` drives ⌘Z and ⇧⌘Z through
the real main-menu items and a fixture window's responder chain so the shipping route is covered
too. Hosted `xcodebuild` cannot make that window genuinely key, so the test supplies it as the
otherwise-targetless items' target — the same window `NSApplication` selects in the running app.

**A drag the composer can take lights the whole box while it is over it**: the accent ring at
focus width over a well tinted `Design.Surface.fieldDropTarget` — the row wash's accent-at-alpha
sentence composited over the field fill, because `applySurface` records exactly one fill and a
second layer would be a theme colour frozen outside the record. One state for two destinations:
the rounded surface and the editor inside it are separately registered drag targets (AppKit
routes to the deepest), so `PromptTextView` reports its own enters and exits up through
`onDropTargetChange` the way it reports focus, and the box answers as one input. The state is
reported by what the composer would *take* (`PromptAttachment.canRead`), not by what the editor
would accept — a plain-text drag is inserted as text and must not light the attachment
affordance — and it clears on `draggingEnded` as well as exit, because a drop or a cancel ends
the gesture without the pointer ever leaving.

**What Return does follows where the send control is** (`PromptView.SubmitPlacement`), because
the two answer the same question and must not disagree:

- **`.inside`** — the glyph in the box's corner. Return submits, Shift/Option-Return breaks the
  line. The shape every chat composer has, and what lets a reply box be multi-line without
  losing the one-key send. The commit message, an inspector note.
- **`.footer`** — the glyph at the end of a control row along the bottom of the box, which the
  owner fills through `setFooterControls(leading:trailing:)`. Return submits, exactly as
  `.inside`: the send did not change surface, only the row it sits on. The conversation's reply.
- **`.outside`** — no glyph; the owner places a button. Return is an ordinary line break and
  ⌘Return sends. The session brief, whose text is a *brief* — several lines, often a pasted
  paragraph — so a Return that sends spends one of those breaks on an accidental launch; and the
  two *fields* that are not composers at all, the inspector's note and Help ▸ Report a Problem.
  Neither of those sends a message to an agent — each is a paragraph attached to a report,
  submitted by the sheet's own button, and Return inside it is ordinary typing.

**The placement decides the send, not the row.** A box gets its control row from
`setFooterControls`, so the brief carries the same choices the reply does while its send stays
outside. Reading the row as the send's — `footerRow.isHidden = !isFooter` — is what briefly put
the brief's send on the row and, through this table, took Return away from its text. It sent on
a key the send control's own tooltip did not name, which is the state a send may never be in.

**What a message is sent *with* goes in the box, on that row.** Model, permission mode,
reasoning effort and speed are properties of the next message, so they belong inside the thing
that message is being written in — leading group for the choices, trailing group for the context
meter, and the send closing the row. Model then mode then effort opens the group, matching the
opening composer wherever its selected model publishes levels; see
[`native-conversations.md`](native-conversations.md) for what choosing a mode there actually
does per provider. Outside, as the strip of chips this replaced, they read as belonging to
neither the conversation above nor the input below; and because that strip sized itself to its
content and was pinned by one edge, the chips clustered against the leading edge with the pane's
whole width empty beside them. Every chat client that has grown model choice has landed on the
same arrangement.

The row comes **out of** the box's minimum height rather than adding to it — the opposite of the
attachment strip above it. A strip is content the user put there and must not shrink the field
they are typing in; the row is the box's own chrome and is present from the first keystroke.
Added instead, an empty reply box opened at a hundred points, a paragraph of height asking for
one line. `Design.Size.inputMaxHeight` still caps the whole box, so the row cannot push a full
composer past what the pane budgeted. `PromptViewDefaults.footerVerticalInset` replaces the
13pt padding for the same reason: 13 exists to centre one line in a 44pt box and means nothing
once there is a second row under that line.

The row sits at the content stack's **own** step, not a tighter one. Closed up to `small` it was
nearer the text than the box's padding held that text off its own edges, and the two rows read as
crowded together inside a box with room to spare — equal air above the text, between the rows,
and under the pills is the rhythm.

⌘Return sends under **both**, handled in the text view rather than only by a button, because
the chord belongs to the field — a prompt is used with no button beside it at all.

The two halves move together on purpose. A glyph cannot name a chord, so a composer that took
the send away from Return had to put it somewhere with room to say `⌘↩` — which is exactly what
`ThemedButton.shortcut` draws.

**That is a default, not a rule** — `AppSettings.promptReturnKey` (`PromptReturnKey`, on the
Keyboard settings page) can override it in either direction. This is the one keystroke in the
app that every comparable product has ended up making configurable — Slack, Zulip, Teams,
Discord and, since early 2026, Cursor all ship the same preference — because the two camps are
drawn by *what people write*, not by taste: a one-line reply wants Return to send, a paragraph
of context wants Return to be a line break. `matchesComposer` is the default and keeps the split
above; `sends` and `startsNewLine` give one answer everywhere. Naming the split in the settings
is itself the point — what people report hating is not either behaviour but discovering,
mid-sentence, that this box disagreed with the last one.

Three invariants hold under every setting, so there is always a key that cannot surprise:

- **⌘Return sends.**
- **Shift- or Option-Return breaks the line.** Zulip's rule, and the one worth copying: a
  setting that changes a key without leaving a working replacement is how people end up unable
  to type a second line at all.
- **Return while an input method has marked text belongs to the input method.** With a Japanese,
  Chinese or Korean IME, Return is how a conversion candidate is *accepted*, and it arrives at
  `keyDown` long before the word is finished; sending on it posts a half-written prompt missing
  the very characters still uncommitted, since marked text is not yet in `string`. The same bug
  is filed against Claude Code, Copilot Chat, Cursor and JetBrains' AI assistant. `hasMarkedText()`
  guards **every** Return including ⌘Return — a send that drops the uncommitted tail is the
  defect, not the modifier.

The setting is read **at the keystroke**, not cached in `applySubmitPlacement`. The Settings
window is open *beside* the composer while the choice is made, so a value written at setup would
leave the one composer the user is looking at as the only one still behaving the old way. A
`UserDefaults` read per Return is cheap, and it keeps an observation out of a design-system
component. The mapping from setting to surface lives in `PromptView.submitsOnReturn()` rather
than on `PromptReturnKey`, so the Core type knows nothing about a view's submit affordance.

**The send names the key that sends it.** A glyph's tooltip is its only name — `ThemedButton`
reads it as the accessible name for a button with no title — so it says "Send · Return" in a box
Return sends and "Send · ⌘Return" in one it does not, resolved through the same
`submitsOnReturn()` and refreshed by `refreshSubmitTitle()` on every edit rather than stored.
A fixed "Send · ⌘Return" is what let a composer send on Return with nothing in front of the user
saying so: the chord was true and incomplete, which is indistinguishable from wrong at the moment
a half-written brief launches. A stated reason for being disabled still outranks both.

Height is re-measured in `layout()`, not only when the text is set. Text height depends on
the width the box was given, which is unknown at assignment — a draft restored before layout
measured against a container of the wrong width and opened at the wrong height, showing the
*tail* of the prompt. Setting text also scrolls back to the top for the same reason.

Drops and pastes both land in `readSelection(from:type:)`, so one implementation serves the
pointer and the keyboard. Non-image files become their own paths in the text. Images instead
join a thumbnail strip above it, with one accessible remove control per image; their paths stay
out of the editor and are appended only to the string submitted to the CLI. Raw image data is
written to the temporary directory first (`PromptAttachment`) — a screenshot on the pasteboard
has no path, and a path is still the only form of an image either CLI can act on. The visual
distinction is for the person composing the prompt, not a second transport. A thumbnail is also
a keyboard-focusable control: click it, or focus it and press Space/Return, to open the app-owned
media inspector at that item in the prompt's collection. Its corner remove button remains a
separate action. The context menu keeps file actions at this boundary too: Inspect, the default
app, Finder reveal, copying the pixels/name/path, explicit System Quick Look, and removal.

The strip adds its height to the text input rather than consuming the text's existing minimum.
That matters most in `SessionComposerViewController`, whose generous empty prompt asks for a
description: attaching a screenshot must not turn that back into a one-line field. More images
scroll horizontally instead of shrinking into unrecognisable tiles. The same `PromptView` serves
the first message and the native conversation reply, so attachment behavior cannot drift between
the two surfaces; a terminal follow-up remains the CLI's own input. Thumbnail mode is an explicit
`showsImageAttachments` capability rather than the component's default, because `PromptView` also
serves commit messages and inspector notes — those are plain text fields where a dropped path must
remain plain text.

Chat references and comments occupy a separate rail above those image thumbnails. They are typed
`ConversationContextAttachment` values, not pasted prose and not `PromptImageAttachment`s: the
former names an existing message, code line, or attachment and may carry a review instruction;
the latter is still a file being sent. `ConversationContextRailView` renders both the staged and
sent form, grouping by reference/comment count so a review batch does not make the composer taller
for every line. A staged receipt makes an otherwise empty composer sendable; `clear()` removes the
text, images, and receipts as one completed turn.

**Chip or segment is decided by the option set, not by the look.** A **chip** when the choices
come from data and change while the app runs — accounts, models, branches, effort — because a
menu can be any length and a runtime-empty one can hide itself. A **segment** when the set is
fixed, there are two or three of them, and seeing the ones you are *not* on is part of using it:
the Attachments pane's All / Agent / You, where the question being asked is "where did the one
*I* sent go" and a menu answers it only after you already know to open it.

Two or three is the rule, not a guideline. `GitReviewMode` has six cases and `ImageCompareMode`
five, and both stay chips — at that length a run of segments is a row of equally-weighted words
nobody reads, and it takes the width the content needs. A fourth segment is the signal that a set
has outgrown the control, not an invitation to widen it.

The vocabulary these encode, which new work should follow:

- **Flat over bezelled.** Pills and panels with a subtle fill. Stock bezels are heavier than
  anything here and pull attention away from content.
- **Quiet until relevant.** Surfaces rest below full opacity and lift on hover. A control
  offering a single option *hides* rather than showing a dead menu — the composer's account
  and model chips both do this.
- **A chooser owns its measure and anatomy.** Modern chips use the design system's 26-point
  height. Period materials author `choiceHeight` independently and choose a sunken dropdown,
  raised popup, paired-arrow Platinum popup, or cycle gadget through `choiceStyle`; both
  `ChipView` and `ThemedPopUp` interpret the same pair. Text scale is not control height.
- **Content leads.** One element per view carries emphasis, usually what is being typed into
  or read. Everything else is secondary or tertiary label colour.
- **Three tiers of button, one primary per screen.** `ThemedButton.Emphasis` names the shapes
  the control always had: **primary** is the material's prominent treatment (`isProminent`) —
  normally an accent fill, but a classic material can keep the ordinary raised face and mark the
  default action with an outer frame and inset dotted keyboard focus — **secondary** is the
  surface-and-hairline (`isBordered`), **tertiary** the mark with no surface until the pointer
  reaches it. There is deliberately no destructive colour — a destructive button says so in its
  *title*, and red on a theme whose accent is already red says nothing. **A destructive
  confirmation has no primary at all**, which is the one place the tier is decided by the action
  rather than by the key equivalent: `ThemedAlert` fills whichever button carries Return, and
  `ConfirmationAlert.applyDefaultButton` deliberately moves Return to *Cancel* for an
  `.irreversible` prompt — so the accent fill went with it, and in Swiss Minimalist, whose
  `accent` and `statusNegative` are the same `#D6180B`, the loudest and reddest thing in a delete
  dialog was the button that does not delete. Filling the *action* instead was the other
  candidate and is worse: it makes the irreversible button the most clickable thing on a sheet
  whose whole purpose is to slow the user down. Neither is filled. **A focused primary keeps a
  band of its own fill outside its ring**, which is a separate rule the destructive one used to
  hide: a ring is stroked *inside* the silhouette it is given, and on a primary that silhouette
  is the accent fill, so `Text.selected` — a near-ground tone, by definition — replaced the
  outermost 2pt on all four sides and the pill read 4pt shorter and 4pt narrower than the Cancel
  beside it. Nothing in the picture said "focus"; it said "two buttons of different sizes", on
  every theme and in every ordinary confirmation, and it was reported twice before the ring was
  suspected. `drawKeyboardFocus(around:color:keepingEdge:)` states it where the ring is drawn; a
  bordered button asks for no band, because the edge its ring lands on is a hairline rather than
  a surface. `ThemedCheckbox` broke the same rule at the other extreme — an accent ring inside
  an accent-filled box is invisible, so a *checked* box showed nothing at all about where the
  keyboard was — and answers it the way `ThemedToggle` does, by reserving margin and ringing the
  box from outside, which is also the only treatment that reads alike in all three states. A second primary makes
  both of them ordinary: a sheet's Save beside its Cancel is one primary and one secondary,
  which is what tells you which of the two the screen is
  about. A button that owns a chord names it on its own face through `shortcut` — one
  `KeyboardShortcut` drives both the drawing and the match, so a button cannot answer a chord it
  does not name or name one it does not answer. That match is modifier-exact, unlike
  `keyEquivalent`, which matches the character whatever is held with it: a `"\r"` key equivalent
  on a pane holding a text field claims the Return meant for the field, since AppKit offers every
  key-down to the view tree before the first responder sees it. The chord **inks the same band as
  its title**, which takes two corrections and neither is guessable. First the baseline:
  `NSString.draw(in:)` sets a line down from its rect's *top* by the layout manager's offset for
  the **nominal** font — not the ascender, and not `ceil` of it — which is what keeps `⌘` and `↩`
  landing where the theme's face says even though they are absent from most of them and arrive
  from a fallback. Then the drop: `⌘` is drawn taller than the caps around it and stops short of
  the baseline, so on a shared baseline all that excess sticks out of the top of the line. Under
  SF that hides, because the title's own `t` and `i` reach nearly as high; under a serif face,
  whose ascenders are shorter, the hint visibly floats. Centring the chord's band of ink on the
  band a title inks costs SF a fifth of a point and a serif theme three fifths. That band is
  measured from a fixed reference pair (`"bo"` — an ascender and a round letter) rather than from
  the button's own title, or a descender in "Apply" would drag its hint half a point below its
  neighbour's. This was got wrong twice: first by centring the chord's inked path on its own line
  box and adding the correction to `y` in a view that is **not flipped**, which lifted the hint by
  what it meant to drop it; then by fixing only the baseline and calling the rest inherent.
- **System colours only.** Every surface derives from a system colour, so light and dark both
  work and the accent is the user's own. No hardcoded RGB.
- **`.continuous` corners.** The default circular curve looks subtly wrong beside system
  controls at these radii; `applySurface(fill:radius:border:)` handles this.
- **Aligned by ink, inset from the corner.** Containers place controls by their visible
  content, not their frames — a plain button's frame includes its invisible hover surface,
  which is what `OpticalInsetProviding` reports and the container subtracts. Margins that
  meet the window's rounded corners come from the corner-adapted layout guide
  (`layoutGuide(for: .safeArea(cornerAdaptation:))`), which states clearance only where a
  curve actually is — measured for the sidebar's band: 16pt at the window corner, zero at
  the divider. `PaneFooterView` is the reference for both. Equal frame margins are not
  equal visual margins.

  The rule reaches the sidebar's trailing slot too, and the bug it fixes is worth stating
  because the slot holds *both* kinds of thing: a session count and a status dot, whose frames
  are their ink, beside a `⋯`/gear/archive, whose frames are click targets with a glyph
  floating inside. Pinned alike, they landed 5pt apart — so a project row's edge visibly
  stepped inboard the moment the pointer arrived and the count crossfaded into the `⋯`.
  `SessionRowView` and `ProjectRowView` widen the slot itself by
  `ThemedIconButton.opticalHorizontalInset` and pull the count back in by the same amount,
  which keeps the buttons inside the slot they are sized into.
  `SidebarRowRenderTests.testEveryTrailingMarkLandsOnOneOpticalLine` asserts the one line.

  **Only visible controls earn width.** A session row rests with one inline target reserved for
  its 12pt status mark, then expands the trailing slot before the `...` and archive actions fade
  in. On exit it collapses only after they have faded out, so a visible target never overhangs the
  parent that hit-tests it. The title yielding while two controls are on screen is honest;
  permanently truncating every title for an invisible second target was not. The hover transition
  re-lays out only the recycled row under the pointer, so session cardinality never reaches that
  path.

  **The expansion is one geometry, not one per state — and the pair takes the edge.** The archive
  button sits in the very column the status mark occupies, and the two *crossfade in place*: the
  status fades out as the actions fade in, inside a geometry that holds still. This is the second
  answer to a drift met twice. The first version sized the slot to the row's actual state — the
  pair at the edge with no status, one column inboard with one — so the archive button sat 22pt
  further out on an idle row than on a working one, and moved *under the pointer*:
  `SessionLoadingState.presentation` is raised because the sidebar is putting the row you just
  clicked on screen, so reaching for archive on a row you had selected made the button step aside
  and step back. The first fix (2026-08-12) reserved the status column unconditionally and parked
  the pair one column inboard, which held the pair still at the cost of the row's own edge:
  archive — the row action reached most — was no longer the outermost thing on the row, which is
  where a trailing action is looked for. The crossfade keeps both properties at once: one
  position, and that position is the margin. What it spends is status visibility *under the
  pointer* — deliberate, because the pointer is on the row to act on it, the hover card still
  names the state, and the selected row (the one whose spinner is most often under a pointer,
  since clicking it is what raised it) wears its activity as its own `AgentActivityBeamView`
  ring instead — stamped by the sidebar controller, System theme and macOS 14+ only, exactly one
  live host because exactly one row is selected.
  `SessionRowActionsTests.testTheActionPairSitsInOnePlaceWhateverTheRowIsDoing`,
  `...DoesNotMoveWhenAStatusArrivesUnderThePointer` and
  `...ArchiveTakesTheStatussColumnUnderThePointer` hold the geometry and the crossfade,
  `SidebarSelectedRowBeamTests` holds the ring's judgement, and
  `SidebarRowRenderTests.testRendersEveryHoveredTrailingState` draws the column.

  `ThemedTabItemView` is the same rule at the other end of a much shorter row, and was the last
  container not following it: a 12pt × inside a 20pt target put the "10pt after the title" at 14
  and the "12pt from the tab's edge" at 16, while the leading icon — a 14pt symbol in a 16pt slot
  — sat on the 12 it was given. A tab is four things in 180 points, so 4pt at one end is the
  difference between a row that reads as spaced and one that reads as shoved left.

  **The rule also points inwards, and `OpticalInsetProviding` cannot reach that case.** That
  protocol is a *container's* correction: the frame is bigger than the ink and the container
  subtracts the difference. The other failure is a component whose frame is honest and whose
  *path* is not — and then nothing above it can help, because every container is placing the
  frame correctly. `OpticalCentring` / `NSBezierPath.centringInk(in:)` is that half: centre what
  is drawn, weighted by how the ink sits inside its own box.

  Two separate things move ink off the line, and `ThemedWarningMark` hit both at once. A rounded
  corner is a tangent arc, so it eats the vertex it replaces — on an upward triangle only the
  *apex*, since the base corners are cut sideways — and the triangle drew a point low while its
  three construction points were exactly centred. Then, centred by its ink, it still read low:
  a triangle's area centroid is a third of the way up from its base, so nearly all of its ink
  lies under the box's middle, where a disc's lies on it. Measured off the rendered pixels beside
  the dots it shares a column with, the attention dots sit 0.25pt under the title's optical
  centre; the triangle sat 1.25pt under before this and on the line after. The generalisation is
  not the triangle — a stroke, an asymmetric transparent margin and any corner treatment all do
  the same thing, and none of them is visible in a constraint.

  **The optical half is computed, which is why it is a rule rather than an eye.** The first
  version declared it — an `InkMass` of `.baseHeavy` worth `height / 12` — and that is a claim
  the author can get backwards on any shape more complicated than a triangle.
  `OpticalCentring.centreOfMass(of:)` weighs the path instead: flattened, summed with the
  shoelace formula over signed subpath areas, exact for the polygon actually drawn and cheap
  enough to run inside `draw(_:)`. A disc measures its middle and moves not at all; a triangle
  measures `height / 6` below its box and moves half of that, which is where the declared number
  came from in the first place. The one judgement left is `balance` — how far towards the mass to
  go — and it is 0.5, stated once: at 1 the apex is thrown half again as far above the line as
  the base falls below it, which reads as badly as the original. `InkMass` survives only for ink
  a path cannot describe: a template image, a glyph run, a layer's contents. Those would want an
  alpha-weighted centroid off a raster, which is the same idea one cache away.

  `SessionLimitMarkTests.testRendersTheCenteringGuides` is how it stays fixed, and the shape of
  that test is the reusable part: measure each element's ink centre **from the render**, assert
  they land on one line, and draw the line into the PNG so the number and the picture agree. Two
  ways to write it wrong both read as "everything is perfectly centred" — scanning the whole
  sheet rather than one row's band, since every row shares those columns, and taking the ground
  colour from `Design.Surface.background` when the row draws its own surface over it, which
  makes every pixel count as ink.

- **A slot is not the line drawn in it.** `MorphingTitleLabel` draws from its leading edge
  (LabelMorph centres by default, which suits the one large title its showcase demonstrates),
  and a host that *caps* its own width sizes to `width(fitting:)` rather than to the cap.
  Tail truncation lands on a character boundary, so the ellipsized head is up to one character
  narrower than the room it was offered — measured between 0.1 and 8.1pt for one tab title
  across the widths a cap can fall on. Sized to the cap, that remainder sat between the title
  and the ×, moving from tab to tab with the name; centred, half of it also became a leading
  indent. Where the room is genuinely the host's — a strip holding its tabs to a floor so it does
  not resize itself around every name — the title is the view that absorbs it (`.fill`
  distribution, lowest hugging), so the × keeps the trailing inset instead of the slack landing
  after it. `PageTitleView` carries the same pair of properties for the same reason.

- **A paragraph cannot morph; lines can.** LabelMorph diffs one Core Text line, so a wrapped
  block has no single line to be diffed against. `MorphingMultilineTitleLabel` keeps a value as
  lines instead — one `MorphingTitleLabel` per line, split on newlines and never wrapped — which
  is what lets the composer's hero morph between a chat's one-line greeting and a manager's
  three-line brief (`ComposerDefaults.managerGreeting`) rather than hide one label and show
  another. Three rules make that read as one motion. Every slot is the **font's** line height
  rather than the height its characters happen to measure, so the block's size is a function of
  its line count alone — which is what makes the count animatable at all. The count then
  **travels**: every line either value uses stays in layout for the length of the morph, and the
  block's own height runs from what the old count is worth to what the new one is, on the morph's
  clock. Resolved up front instead, the block snaps to its new shape and the line it dropped is
  gone before it can be seen going; resolved afterwards, everything jumps once the animation has
  finished, which reads as a defect however good the animation was. The stack's bottom pin is
  therefore `.defaultHigh` rather than required, so a block passing through a smaller height lets
  its lines reach past its own bounds instead of squeezing them. And the block is held at the
  wider of the two states while the lines swap, below `.required` so a narrower host still wins:
  the lines share one width, and without the hold the second line's morph resized the first one
  mid-flight, which makes a `MorphingLabel` re-lay its glyphs where they are going while the
  animations are still carrying them there. Both holds are released on a `DispatchQueue` deadline
  rather than in the animation's completion handler — that handler belongs to a Core Animation
  transaction, and a window that is never flushed would leave the block pinned at the shape it
  was passing through. Releasing moves nothing: a centred block gives its width back from both
  sides at once, and the height it gives back is the height the travel has just arrived at.

**One silhouette per strip.** `TabAppearance` states a tab's geometry and type scale in one
place, because the app draws tabs in two views that cannot share a class: the pane's strip reads
the chrome's roles, while a surface over the terminal inks itself from the backdrop
(`BackdropOverlay`) — which is what the header's page name does today. They differ by that alone and had drifted in everything
else — a 13pt semibold pill beside a 12pt regular rounded rect — which is how one navigation
idea came to look like two. The toolbar's controls join them: `ToolbarButtonView` and the usage
pill draw at `Design.Radius.control` rather than a pill radius, because these buttons are square
and a pill radius on a square is a *circle*, so the strip held a rounded rect, a pill and three
circles at once. `ToolbarChromeRenderTests` draws the strips on a near-black and a near-white
backdrop, since a relationship between neighbouring shapes is visible in a picture and in no
assertion anyone would write.

**Height is part of that silhouette, and the radius rule alone missed it.** The usage pill kept
its own 20 points — the number a 12pt ring and one line of text add up to — between a 28pt page
tab and 28pt action buttons, so the shared corner radius landed on a shorter side and the strip
still read as two ideas, with the smaller one in the middle. A control in a strip takes the
strip's height (`Design.Size.toolbarButtonHeight`) and sizes only its *width* to its contents.
`ToolbarChromeRenderTests.testTheUsagePillIsAsTallAsTheControlsBesideIt` measures the pill
against the two components it actually sits between rather than against a number.

A tab's icon takes the **label's** colour, never the accent. The accent means "this wants you"
here — the sidebar's attention dot is the same colour — and spending it on whichever tab happens
to be open says that about nothing. The info panel's process dots follow the same rule and draw
in the positive status role, which is what a running process actually is.

**The info panel is `PanelListView` speech.** Its fixed Usage form and live sections
("Processes", "Ports"), notes
("Nothing listening.") and header block all stand on the component's one ink column — the panel
once had four different leading edges, each individually "correct", and the misalignment was
visible only in a picture (`SessionInfoRenderTests` now takes that picture). Its rows carry the
process *tree*: children indent under their parent by `Spacing.medium` per level, drawn by the
dot column itself, and the dot is honest about state — filled positive for alive, a hollow
`circle` in the warning role for stopped, because a suspended process holding its memory and
its ports is a fact the "alive" dot must not paint over. A zombie is not a state here: Darwin's
`proc_pidinfo` cannot see one at all (measured; `SessionInfoTests` pins it), so an unreaped
child leaves the list instead. The value column is a `CompoundValueLabel` — `12% · 248 MB`
gives up whole segments, never characters — and the row speaks as one accessibility element: a
pressable link where the row opens a port, a quiet group otherwise. Command lines render
through `CommandLineRedactor` (secrets behind credential-shaped flags become `<redacted>`,
shared vocabulary with the execution audit); the raw line is one right-click away, per row,
forgotten on rebuild. Both text fields explicitly use AppKit's single-line mode: a truncating
line-break mode alone still lets a paragraph-long launch command wrap outside the fixed-height
row and paint through its siblings. The hover plate belongs only to the port rows, whose whole
surface is a click; a stoppable process row hovers by revealing its `✕` in the value's place — a
`ThemedIconButton` that asks (`ConfirmationPrompt.stopSessionProcess`, `.irreversible`) and
signals exactly one pid through `SessionProcessTerminator`'s identity-checked SIGTERM.

`SessionComposerViewController` is the reference implementation, and **the only way a session
is created**. Reading down its column: **two** chips above the box answer *where* and *who* —
a location breadcrumb (`AnotherTerminal ▸ master`) and an identity (`Claude Code · work`) — and
the box's own footer carries what the session will run *with*: model, mode and catalog-backed
effort on the leading side, then the account's usage reading, the surface, and the send closing
the row. **Import _n_
conversations** sits quietly under the box, the other way to arrive at the same place.

**Two chips, not four.** The row was project / agent / account / checkout, which is four
controls for two questions: a project and the checkout inside it are one place, an agent and
the login it runs as one identity, and the reader was assembling each answer out of parts
before deciding anything. Merged, placement carries the meaning — above the box is *who and
where*, inside it is *what with* — and the first line of the screen is two phrases instead of
four pills. The separators say which kind of pair it is: `▸` steps *into* something, the way
the app's own copy writes a path through menus ("Settings ▸ Themes"), while `·` joins peers and
is what `Opus · 1M` on the row below already looks like. The second half of each is withheld
where it answers nothing — a folder outside a repository has no checkout, and an agent with one
login has no choice of account, which is the same threshold that used to decide whether an
account chip appeared at all.

**A merged chip's menu keeps its two verbs apart.** The location menu opens with the checkouts,
and the projects live one layer in, under *Switch Project*. They read alike and are not alike:
choosing a checkout **routes this session** and leaves the composer standing — the half-written
brief, the agent, the model all survive it — while choosing a project **navigates**, resetting
every choice in the composer including the words in the box. One flat list of places would have
made the second reachable by a mis-click aimed at the first. `New Worktree…` closes the
run-here section rather than opening the other one, because it is the single row that does both.
The nesting appears only where there is something to keep the projects apart *from*: with no
project chosen, or a folder that is not a repository, there is no checkout section and the
projects are the menu, since a menu whose only row opens a submenu is a hover standing in front
of the answer. The identity menu is the same shape without the nesting — the selected agent's
logins, a line, then the other runtimes; the selected agent itself has no row, because the chip
is already showing it.

Only the location chip is capped (`ComposerDefaults.locationChipMaxWidth`, 320 — the 260 the
project name alone had, plus room for a branch). It truncates from the tail, which costs the
checkout rather than the project name: per-half truncation would mean budgeting characters
against a width in points on a single label that draws its own ellipsis. The chip widens to its
full contents on hover, and the tooltip states the whole answer — the *destination* folder,
which is the one place a chosen sibling checkout can be told apart from the project the
breadcrumb names.

Every shortcut that created a session outright is gone — the project row's `+`, the per-agent
and per-account items in the Project menu and the sidebar, `⌘N`'s old behaviour, and the
session a newly added project used to get. Each answered four decisions with defaults the
user never saw. `⌘N` and selecting a project now both land here. The composer is replaced by
the conversation the moment it is used, so it costs a click and nothing else — which is also
why it is laid out generously rather than compactly, and why its column is
`ComposerDefaults.contentWidth` (720) rather than `Design.Size.readableWidth`: that measure
paces prose, and squeezing a row of chips into it collapsed every one of them to an
unlabelled icon. The column takes that width by **filling the pane up to the cap**, rather than
inheriting it from whichever row is widest. It used to inherit it, and the widest row was the
chips — so moving three of them into the box would have quietly narrowed the box they moved
into; a measure that changes because a control was rehoused is a coincidence, not a decision.
Filling rather than stating a constant matters for the other axis of the same rule: a fitting
size honours an optional constraint wherever nothing opposes it, so a 720 written as a *width*
would also have become the pane's **minimum**, and the window would have refused to narrow past
a number that is a maximum.

The column yields to the pane at `columnMeasurePriority` (240), which is under every split
item's holding priority — otherwise the measurement reads as "this pane is 784 wide" and the
divider stops dead short of its floor. For that to mean anything the stack must hug its content
*below* 240, and the knob for that is **`NSStackView.setHuggingPriority(_:for:)`**, not the
`NSView.setContentHuggingPriority(_:for:)` it inherits: a stack view lays out by its own
property, which stays at its 250 default however the inherited one is set. Set on the wrong one,
the column went on hugging its widest row and the whole measurement was inert — the box drew 415
points wide in a 1454-point pane, with the chips on its footer crushed against each other and
the pane empty on both sides. `ComposerWindowFitTests` asserts the filled width in a wide pane
and in a narrow one, since neither reading alone tells a fill from a coincidence.

**The opening composer and the reply composer are one box, with one difference.** Both carry the
same control row, so the thing a user learns before a session starts is the thing they go on
using inside it: text in the box, what it is sent with on the row along the bottom. What differs
is the send, and it differs because the *text* does. A reply is usually one line and sending it
is the only thing that happens next, so the glyph closes the row and Return sends. A brief is
several lines and usually a pasted paragraph of context, so its send is a titled primary under
the box (`SubmitPlacement.outside`), Return breaks the line, and `⌘↩` is drawn on the button's
own face — the only surface with room to name a chord.

Putting the brief's send on the row instead cost exactly that: `matchesComposer` reads "the send
is in the box" as "Return sends", so a brief began launching on the break meant to be its second
line, while the glyph's tooltip went on promising ⌘Return. One box and one row is worth having;
one *key* is not, when the two boxes hold different lengths of text.

`PromptReturnKey` on the Keyboard page overrides either direction for a user who wants one
answer everywhere, and it is what a disagreement about this should be settled with rather than a
change of placement.

The button under the box is the row's trailing end, with the import offer at its leading one —
the loud action where the box's own edge is, the quiet alternative opposite it.
`startButton.isEnabled` and `PromptView.submissionDisabledReason` move together: with no project
chosen both the button and the box are disabled and say why ("Choose a project first"), because
⌘Return reaches the box directly and a disabled button alone would leave the chord starting a
session the button says it cannot start. `ThemedButton.shortcut` is what both draws `⌘↩` and
answers it; there is no bare `keyEquivalent` anywhere near this pane, since a `"\r"` equivalent
would take Return back off the prompt it was just given to. ⌘Return is handled inside the text
view as well, which is why it works in a box with no button beside it at all.

**A chip names the answer, not the setting.** The model chip said "Default model", which tells
the user the one thing they already know — that they have not chosen — while the question it
exists to answer is *which model will this session run on*. Both CLIs record that per account
(Claude in `settings.json`, Codex in `config.toml`), so `AgentModels.defaultModel` reads it and
`ModelName` turns the identifier into a name: `claude-fable-5[1m]` → `Fable 5 · 1M`. The menu's
first item names it too, so picking the CLI's own choice and leaving it alone are visibly the
same thing. An identifier the table does not know is handed back intact rather than dropped — a
wrong friendly name is worse than an unfamiliar accurate one on the string that says what the
session costs. "Default model" survives only where the account states nothing at all.

## Themed Controls

Preferences used stock AppKit deliberately — a settings window being one place where matching
the platform beats matching the app. **App themes ended that argument**, because under a style
there is no platform look left to match: a page of system-blue switches, softly-bezelled
pop-ups and a system-grey spinner on a Cyberpunk-green or Swiss-red surface is not "native", it
is a theme that reached the cards and stopped at the controls. The System theme is what keeps
the original promise, and it keeps it exactly — every role resolves to the system colour, so a
user who never picks a style sees the app they always saw.

So there are no stock AppKit controls left outside `UI/Design/`, and
`scripts/check_theme_boundaries.sh` is what keeps it that way. The Xcode target runs the
SwiftSyntax checker before compilation, and
`ThemedControlTests.testNoStockControlsOutsideTheDesignSystem` invokes that same checker rather
than maintaining a second list. `.swiftlint.yml` remains fast editor feedback. **Labels are
deliberately exempt**: `NSTextField(labelWithString:)`
draws no bezel and no background, so it is already nothing but text in a themed colour. The
bezel is the erosion, not the type.

`ThemedControl` is the base and closes a whole class of bug at once. It **draws in `draw(_:)`,
never into a frozen layer** — `layer.backgroundColor = colour.cgColor` resolves once and keeps
that value, which is why a live theme switch used to leave stale colours across the app — and it
answers a theme change with one `needsDisplay = true`. `ThemeRedraw` is that behaviour on its
own, for the themed views that cannot inherit from `ThemedControl`: `ThemedTextField` has to
subclass `NSTextField` for the field editor, the formatter and the whole of text editing.

It also has to declare `isAccessibilityElement`. A stock control is one because its *cell* is,
and a control that draws itself has no cell; without it a themed control is invisible to
VoiceOver and to UI scripting alike. That was found by a settings page reporting no pop-up
buttons on a page that visibly had one.

Two things are contained rather than replaced, and both are platform workflows whose behavior is
the value: the **application menu bar** (Services, responder-chain command routing, system key
equivalents — `AppDelegate` is the one file the source checker excepts for `NSMenu`) and the
**system colour panel behind `ThemeSwatchView`**. Every menu *inside* the window — dropdowns,
right-click menus, the terminal's own — is `ThemedMenuPresenter`: one presenter carries
type-to-select, arrow-key navigation into and out of submenus, press-drag-release tracking,
hover-safe submenu travel, and pointer anchoring, so the app never mixes two menu languages in
one window. Nested menus ride on `ThemedMenuItem.submenu`; a parent row draws the chevron,
opens beside its panel on hover or right-arrow, and keeps the menu-path highlight while the
pointer is anywhere in the chain. A menu item's destination is one algebraic value — inert,
action, or submenu — because a row carrying both would answer a press with the action and hover
with the submenu. Callers still depend on a named boundary rather than constructing their chrome.

Nine bugs are worth keeping, because each is a trap the next drawn control will walk into:

- **`NSImage.draw` states its own compositing, so a blend mode set on the context beneath it
  is silently overridden.** `ImageCompareView`'s difference mode set
  `CGContext.setBlendMode(.difference)` and then drew the second image — which
  `draw(in:from:operation:fraction:)` composited `.sourceOver` exactly as its `operation:`
  argument said, and the "difference" was the new image, whole. The operation has to ride the
  draw call itself. Found by the render test sampling the composite for black, not by eyes: the
  wrong picture was a perfectly plausible one.

- **A layer corner clips what `draw(_:)` lays down, and a stroke is centred on its path.** Both
  halves cost the focus ring. `applySurface` puts the corner on the *layer*, so a control drawing
  over its own applied surface is drawing inside that shape whether it knows it or not: the
  accounts pane's 30pt icon well is a disc, the ring was built from
  `Design.Radius.control(fitting:)` — a rounded rect — and the two shapes meet only at the four
  edge midpoints, so what survived was four 1pt dashes and no corners at all. Half of the ring's
  width also falls *outside* whatever path it is centred on, and the clip takes that too, which
  is why every other control's ring drew at half weight. `ThemedControl.drawKeyboardFocus` now
  takes a `ThemedSurface.Shape` — a rect and a corner, insettable, where a `NSBezierPath` is
  not — resolves it against `appliedSurfaceRadius` when a surface was applied, and insets by half
  the ring's width. Pinned by sampling the drawn control all the way round the ring, diagonals
  included: those are the places the mismatch erased.

- **An inside ring assumes slack the switch does not have.** Everything above holds for a control
  with room between its edge and what it draws inside it. `ThemedToggle`'s knob is inset by
  exactly `focusRingWidth`, so the ring landed on the entire accent gutter: the knob came out
  flush against a near-white ring (`Text.selected`, the only ink that reads *on* an accent track)
  with the track's own colour gone from three sides, and what survived at each knob corner was the
  wedge between the knob's arc and the ring's square inner edge — four accent specks around a knob
  that otherwise looked flush, which is how it was reported. Two fixes, and the second is the one
  that was always wrong: `drawKeyboardFocus(around:color:outsideBy:)` strokes the ring outside the
  silhouette, in margin `ThemedToggle.intrinsicContentSize` reserves for it, because drawing is
  clipped to `bounds` and a ring in unreserved room comes back at partial weight or not at all;
  and the knob's corner is now *derived* from the track's (`Layout.knobRadius`) instead of stated,
  because a knob holding a radius of its own is not concentric with its track — the gutter was
  `knobInset` on the flats and `knobInset √2` across the diagonals the whole time, and the wedge
  was only ever invisible because a full gutter hid it. `ThemedSurface.Shape.outset` is `inset`'s
  mirror, and keeps a squared theme square for the same reason.

- **A view that draws more than it is does not get the clip for free.** `MediaInspectorCanvas`
  draws the picture at whatever the zoom says, which above fit is deliberately larger than the
  canvas — and nothing stopped it at the canvas's edge. At 100% the image climbed 36 of the
  header's 52 points, leaving the file's name, its dimensions, the Fit/100% control and the close
  button standing on the photograph with no band under them; the window read as broken, which is
  how it was reported. A `ThemedControl` is layer-backed, and that used to be the same sentence as
  "clipped", but `NSView.clipsToBounds` is `false` by default for anything built against the
  macOS 14 SDK and `draw(_:)` now runs unbounded. The property itself is macOS 14 and this app
  ships to 13, so the canvas takes the clip in `draw(_:)` — `NSBezierPath(rect: bounds).addClip()`
  inside a saved graphics state, which every supported version honours. The focus ring is
  unaffected: it is inset by half its width and was already inside `bounds`. Anything else that
  draws content sized from *data* rather than from its own frame owes itself the same two lines.
  The regression boundary is a picture the assertion can read — a saturated fixture image at 100%,
  sampled across the empty middle of the header band, where every pixel must stay the palette's
  grey.

- **`withAlphaComponent` replaces alpha, it does not scale it.** Dimming a disabled button
  against a resting surface that is *already* translucent — Cyberpunk holds its neon at 10% —
  made the disabled controls the loudest things on the page. Resolve, then multiply.
  The same dimming belongs to a primary button's face and outline, not only its title: leaving an
  unavailable primary at full accent weight still asks to be pressed, even when its faint words
  technically report that it cannot be. Outlined themes owe the rule to the edge because their
  centre is deliberately transparent.
- **`NSString.draw(in:)` wraps.** A title measured a hair too narrow for its own rect breaks at
  the space and draws its second word below the button, with no ellipsis to show for it: the
  sidebar footer read "Add" instead of "Add Project". Measure and draw with the *same*
  attributes, and give the draw a paragraph style that truncates. Centring the title's full
  intrinsic width after Auto Layout has squeezed the control is a different version of the same
  escape: its origin moves outside the leading edge and the visible text becomes an arbitrary
  middle slice. Centre while the content fits; otherwise lead-align it and truncate the tail.
  That overflow rule does not apply to an image-only button: the image is one indivisible mark,
  not a title with a tail to lose. A 14pt mark in a 26pt bordered button has only 6pt left after
  the title's 10pt insets; pinning it to that inset moved those Themes-page actions 4pt right.
  Image-only content stays centred on the button face even when title padding would not fit.
- **A rect sized from `boundingRectForFont` top-aligns the words it was meant to centre.** That
  rect is the union of a family's glyph extremes, not the line `draw(in:)` actually lays out,
  and `draw(in:)` sets its line down from the rect's *top* — so the difference becomes dead air
  above the text. SF 12 reports 14.79 against a 15pt line, which is why a rect centred on it
  looked square and was copied into the menu row, the closed chooser and the checkbox; Geneva
  reports 24.41 against 16. Under Platinum, whose Charcoal falls back to Geneva on a current
  macOS, every menu row's title sat 5pt above the checkmark and the icon in its own row — and
  above a *hosted* preview in the title column, which is centred by constraint. Place drawn text
  with `Design.Typography.lineHeight(of:)`; reserve space with the bounding rect if you like, but
  never place ink with it. Pinned by measuring the ink
  (`ThemedControlTests.testAMenuRowsTitleInksTheBandItsIconIsCentredOn`), since under SF every
  arrangement measures the same.
- **`NSTextField(string:)` is a class factory method**, free to return a plain `NSTextField`. A
  subclass declares its own or is one only by the annotation at the call site.
- **A single-line field draws on the *field's* baseline, not the string's.** A label built from
  a plain string and then handed attributed text keeps AppKit's 13pt default font, so a string
  of 11pt runs drew a little over two points below the baseline the field itself reported —
  while `firstBaselineOffsetFromTop`, the baseline anchors and the intrinsic size all said
  otherwise. The words sat low in their own box, close enough to clip a descender, and anything
  centred beside them read high: the git card's branch mark was centred correctly on a line the
  words were not on. `NSTextField.label(attributed:)` now adopts the string's tallest font
  before assigning it — the measured size does not move, only the drawing. Pinned by measuring
  the *ink* (`ThemedIndicatorsTests.testTheGitCardsMarkAndItsWordsShareOneOpticalLine`), since
  every frame involved was already right.
- **A `CGColor` on a layer is frozen**, which is the whole reason these controls draw. The one
  place a layer is unavoidable is `ThemedSpinner` — it animates off the main thread — so its
  `strokeColor` is re-applied on every redraw instead.
- **`NSTextView(frame:textContainer: nil)` builds no text system**, and that is not the same
  thing as building the default one. `init(frame:)` creates the storage, layout manager and
  container; the *designated* initializer takes them from you, and nil means the view joins no
  text network at all. Such a view lays out, draws its box, takes first responder and shows its
  focus ring — and then silently discards every keystroke, refuses every selection and reports a
  nil `layoutManager` to whatever sizes itself to the text. From 23 July it cost the app **every
  `PromptView` it has** — the session composer, the conversation's reply box, the commit message —
  and every `ThemedTextView.scrolling()` besides.
  `ThemedTextView`'s only initializer is `init(frame:textContainer:)`, so
  the boundary rewrite had to pass *something*, and `nil` reads as "the usual one". `ThemedTextView`
  now builds a TextKit 1 network when given none, and holds the storage — ownership runs storage →
  layout manager → container, and the view retains only the container, so an unheld network is
  released the moment the initializer returns. Pinned by `PromptInputTests`, which types into the
  prompt through the responder chain rather than asserting about its appearance: nothing visible
  distinguishes a dead text view from a live empty one, which is why nothing caught this.
- **`isVerticallyResizable` is capped by `maxSize`, and `maxSize` defaults to the initializer's
  frame** — `.zero` for every text view built here, after which the scroll view hands the document
  view the clip's size and *that* becomes the cap. The frame then stops at exactly the visible
  height while layout runs on past it, so `documentRect` equals the clip: a scroll view AppKit
  believes already fits. No range, wheel constrained to zero, no scroller, and
  `scrollRangeToVisible` unable to reach the caret. Measured at 480pt of text in a 154pt box.
  Reported as "the text area has no scroll — when I write it just protrudes and I can't read it":
  the session composer accepted a long brief and then hid everything past `inputMaxHeight` under
  its own bottom edge. **Growing and scrolling are two mechanisms, and only one of them was
  wired.** `PromptView` measures its own text through the layout manager, so the box grew
  correctly and the cap looked deliberate — which is exactly what hid this for as long as it did.
  `ThemedTextView` now states an unbounded `maxSize` and a zero `minSize` in `setup()`, so the
  correct state is the starting state for `PromptView` and `ThemedTextView.scrolling()` alike.
- **A tracking area reports crossings the *pointer* makes, and none that the *view* makes.**
  Closing the display panel widens the content pane, which slides its header — and the pane
  toggles at its trailing edge — a few hundred points sideways, out from under a pointer that
  never moved. No `mouseExited` is delivered for that, and none arrives late either:
  `updateTrackingAreas` installs a fresh area, which assumes the pointer is outside, so the
  crossing that would have cleared the flag has already been forgotten. The panel toggle sat
  filled with the panel closed — and on a toolbar icon button the resting hover wears the same
  `surface` fill as *selected*, so a stale hover is a button claiming to be on. Six controls had
  each written the same `trackingArea` + `isHovered` + `updateTrackingAreas`, and so inherited it
  six times; `ThemedControl` now owns hover outright and offers `hoverDidChange()` to the controls
  that hover by moving a layer or a constraint rather than by drawing. It re-derives the flag from
  `NSView.isPointerInside` whenever tracking is rebuilt, which is precisely when the geometry
  moved. The correction only ever **clears**: entry is what drives the sidebar's dwell timers and
  popovers, and synthesising those on every relayout would flash a popover under a still pointer.

That freeze has **two** invalidating events, and only one of them was ever swept. A theme change
runs `AppThemeRefresh.repaintEverything`; a **system light/dark switch ran nothing**, so dynamic
text turned dark while the surfaces under it stayed dark too. It hid for a long time behind two
accidents: the largest surface in the window was a system material AppKit repainted itself, and
the terminal beside it is a palette with no light and dark to switch between.
`AppThemeRefresh.startObservingSystemAppearance` fires the same sweep from **two** triggers —
KVO on `NSApp.effectiveAppearance` and the system's distributed interface-theme notification,
because the KVO alone was measured missing a live switch — and both converge on
`systemAppearanceDidChange`, which waits until the windows actually wear the new appearance
before re-resolving anything against it. Defence in depth for the same trap:
`applySurface`/`applyLayerBackground` freeze in the **view's own** effective appearance rather
than the thread's ambient one, and `AppTheme.terminalPalette` anchors to
`NSApp.effectiveAppearance` because palettes are consumed as data from contexts with a stale
ambient appearance.

What that sweep cannot fix is a pane whose *ground* is the terminal palette while its content is
drawn in system colours: a native conversation under a dark terminal theme in light mode is dark
text on a dark ground. That is the documented cost of the conversation drawing in system colours,
not a stale layer, and it is the same trade in the other direction that made the old sidebar look
right by luck.

`ThemedPopUp` carries two rules that are not obvious: an item that already has an action keeps
it (which is how a pull-down like the themes gear works, and only unclaimed items route through
the control), and an out-of-range `selectItem(at:)` leaves the control unselected rather than
trapping, since the index usually comes from looking a stored preference up in a list that may
have moved on.

## 2026-07-30 — a row's control has to be allowed to take its own click

Three reports, one cause: a session row's archive box "did nothing at all", its `⋯` "worked
sometimes", and the sidebar's selection was "sometimes gray sometimes blue".

`NSTableView` decides in **`validateProposedFirstResponder(_:for:)`** whether a click inside a
cell reaches the view it landed on or is taken by the table to select the row, and its answer for
anything in a row that is **not already selected** is no. That is the right gesture for a text
field — click to select the row, click again to edit — and the wrong one for a button, which is
why AppKit exempts its own `NSButton`s. Nothing about it was visible here until this app started
building row buttons out of `ThemedControl`, which AppKit has never heard of.

So the button drew its hover fill, took a press that went nowhere, and the click was spent
selecting the row underneath — which also switched the session on screen and moved the sidebar's
focus. The "sometimes" was the row happening to be selected already. `ThemedTableView` and
`ThemedOutlineView` both override it now, through one shared rule (`RowControls.takesItsOwnClick`)
stated as *a control that acts on its own click*: every `ThemedControl` in the app is one — button,
toggle, chip, pop-up, recorder, no text editor among them — plus `NSButton` for AppKit's own,
including the disclosure triangle. A label, an image and the row's ground are none of these, so
clicking a row anywhere else still selects it.

**The row's own tests could not see any of this**, and that is the more useful lesson.
`SessionRowActionsTests` presses the button on a row held in a plain `NSView`, where no table sits
between the click and the button — so it passed against a button that was unreachable in the app,
through two rounds of fixing the *wrong* half (hit testing, then the lost mouse-up).
`SidebarRowClickRoutingTests` puts the row in a real `ThemedOutlineView` and asserts the decision
against a **stock** `NSOutlineView` in the same fixture, so the test says what AppKit does rather
than only what we want: if a future macOS starts exempting custom controls, that assertion is what
reports it.

**That rule was right and asked the wrong question**, which is why the report came back the same
day: the archive box "still basically impossible to press", the `⋯` "a bit more reliable, nowhere
near 100%". AppKit proposes the **deepest view under the pointer**, and a `ThemedIconButton` draws
its glyph in an `NSImageView` child — so the responder the table was asked about was that image
view, another `NSControl` AppKit does not exempt, vetoed in the middle of a button that had just
been allowed. What was left of each target was the four-point padding ring around its glyph.

The two reports were the same bug at two glyph sizes, and the numbers are worth keeping because
they are what made it read as flakiness rather than as geometry: swept a point at a time over a
20×20 target, `archivebox` (12×16) leaves **192 of 400 points dead**, dead centre where the eye
aims; `ellipsis` (12.5×9) leaves **108**, with live bands above and below that a slightly high or
low click lands in. Hence "impossible" and "sometimes" for one cause.

So `RowControls.takesItsOwnClick` asks whether the click landed *inside* a control that acts on its
own click, walking up from the proposed responder to the row and no further. A control's glyph,
label or chip is part of the target it draws. Letting it through is the whole fix — the press then
reaches the control the way it already does outside a list, an `NSImageView` with no action of its
own forwarding it up the responder chain, which is why none of this ever showed in the toolbar or
on a tab's `×`. A plain image that is *not* inside a control — the row's agent mark — still gives
its click to the row.

**A test that presses the middle of a button, and a test that presses its edge, both pass on a
button with a dead centre.** `testEveryPointOfARowsTrailingButtonsReachesThemRatherThanTheList`
sweeps the whole target and reports the dead count, because "does the button answer" is not a
question about one point. The older assertion shape — `hit === button || hit.isDescendant(of:
button)` in a plain `NSView` host — is what hid this twice: in a plain host the glyph is a
descendant *and* forwards, so the answer is yes and means nothing.

Second, smaller half of the same report: `ThemedIconButton.mouseDown` used to call
`makeFirstResponder(self)`. In a sidebar row that is visible — the outline view resigns, its
selected row drops from emphasized to unemphasized, and under the **System** theme that is the
difference between the accent blue and a flat grey. Pressing one row's `⋯` recoloured the
selection of a different row, which is what made the selection read as random. A press no longer
takes the keyboard focus, which is what every AppKit button does; Tab still reaches the button and
still draws the ring.

## 2026-08-04 — a list's selection follows its window, not the focus inside it

**The rule, once, for every list: `ListSelectionStrength`.** AppKit ties
`NSTableRowView.isEmphasized` to the *first responder*, which is right for an app where a click
leaves focus in the list it landed in. This is not one — selecting a session attaches its
controller and calls `focusTerminal` — so a row was demoted a turn after the click that picked it,
into a fill a hair from the hover wash. The second click selected nothing new, presented no
session and took no focus, so it was the one that appeared to work: *first tap hovers, second tap
selects*, reported against a pane that had been showing the right session since the first.

This is the entry above, a second time. That fix stopped **one control** taking focus, which left
every other way of taking it able to bring the defect back, and the terminal duly did. So the
answer moved from defending the places focus is taken to stating the rule where every row still
passes: `ThemedTableView` and `ThemedOutlineView` hold their rows' emphasis to the window's key
state, from `viewWillDraw` — the last moment before a row paints, which covers AppKit demoting all
of them *and* a row built later while scrolling — plus the key notifications, which are the one
transition nothing else would repaint.

**Why the list and not a row class.** The row that gets this wrong is the one nobody wrote: a
delegate returning no row view is handed a plain `NSTableRowView`, and no amount of care in
`SidebarHoverRowView` or `ThemedTableRowView` reaches it. Those two classes, by contrast, are
*provably* every list in the app — subclassing `NSTableView` or `NSOutlineView` anywhere else
fails `check_theme_boundaries.sh` — so a list written later inherits the rule without its author
needing to know it exists. `ListSelectionStrengthTests` pins both halves: the rule holds through a
real focus move and a real display pass, and the sweep for list declarations fails if a third one
ever appears. Rows stay dumb; they read `isEmphasized` and draw.

> **Superseded in part — see "the row refuses the demotion" (2026-08-07).** Deciding this on the
> list is still right, but applying it from `viewWillDraw` does not run in the app, and the
> premise above is false: a delegate returning no row view is handed `ThemedTableRowView`, because
> the list intercepts `makeView(withIdentifier:)`. The rows are not quite dumb any more — each one
> asks its list before believing a demotion. And none of the tests named here had ever run; the
> file was missing from `project.pbxproj`.

The strength is still two-valued — a background window keeps AppKit's quiet fill, which is what it
was for. Only the question changed, from *who has focus* to *which window is in front*.

## 2026-07-31 — the chrome's ink weights agree, and glyphs land on the pixel grid

One report ("the icons look light, and blurry on my external display") that decomposed, under
measurement, into four separate defects. The numbers are worth keeping because every one of them
was assumed fine until rasterised.

**The anchor for every stroke in the chrome is the body text's stem: ~1.25pt** (SF 13 regular,
measured by drawing an `l` at 8× and taking the median ink run). Rules are capped *down* to it —
see the rule-ink budget in [`themes.md`](themes.md) — and glyphs were raised *up* to it:
`Design.Symbol.configuration`'s default weight is `.medium`, whose 11pt stroke is exactly that
1.25pt, where `.regular` strokes at 1.0 — every icon in the window sat below the weight of its
own label, and on a 1× display a 1pt stroke at a fractional offset is two rows of antialiased
grey. `GlyphTests.testTheDefaultGlyphStrokeMatchesTheBodyTextStem` pins glyph to stem by
measuring both, so an OS symbol redesign surfaces as a failure instead of a drift.

**A symbol is configured to fit its slot, never rendered and then shrunk.** One hard-set 11pt
configuration served every role, and symbol natural sizes are the symbol's own: `gearshape`
renders 14×14 at 11pt, the sidebar's arrange glyph 15×14 — both squeezed into the 12pt inline
slot at ~0.8×, thinning the stroke the configuration had chosen and dropping it off the grid,
while the same 11pt glyphs *underfilled* the toolbar's 16pt slot in the other direction.
`ThemedIconButton.Target` now states both numbers (slot = layout, point size = optics;
`Design.Symbol.toolbar` is 13), and `Design.Symbol.image(_:slot:pointSize:)` re-configures at
the fitted point size when the render overflows — keeping the weight compensation SF's optical
sizes exist to provide. Fitting never configures up.

**Placement is aligned to the backing store, not to the arithmetic.** `GlyphView` (see the
component table) replaced the `NSImageView` inside icon buttons and tabs.

**A hand-added `CAShapeLayer` rasterises at `contentsScale` 1 until someone says otherwise.**
`ThreadingMarkView` documented the trap and fixed itself; `ThemedSpinner` had the identical
construction and spun blurry on every Retina display for as long as an agent worked — minutes at
a time, in every sidebar row. It now re-applies the scale on `viewDidChangeBackingProperties`,
and `ThemedIndicatorsTests.testHandAddedShapeLayersCarryTheWindowsBackingScale` sweeps the
hand-layered indicators so the next one cannot reintroduce it. (`SidebarBackdropView`'s layers
were checked and are immune: gravity-resized `contents` and a gradient rasterise nothing.)

**The mark itself was at the floor of what 20pt can carry.** Its stroke ratios come from a 128pt
SVG canvas — 7/128 and 7.5/128, which in the sidebar's slot are 1.09pt and 1.17pt of *curved*
stroke: sub-pixel by construction on a 1× panel, and fractional even at 2×. `layout()` now snaps
both widths to whole device pixels (floored at one) and backing-aligns the drawing box, and
re-snaps when the window changes displays. The hover lift scales the raster, so while lifted the
`contentsScale` carries the lift as headroom — full lift is pixel-exact, and the resting mark,
where the time is spent, keeps the plain scale. If the mark still reads soft on a ~110ppi panel
after this, the remaining move is a small-size cut (heavier ratios, or the mono form below a
real-pixel threshold) — a design decision deliberately not taken here.

## 2026-08-04 — a list that says nothing about selection gets the system's accent

Reported as "wrong colour for the selected attachment — doesn't match Claymorphism at all": a
Finder-blue bar across one row of a lavender window. Nothing in the attachments pane had set that
colour, and nothing had to. `NSTableRowView` draws the selection itself, from
`NSColor.selectedContentBackgroundColor` — the **user's** accent, read from System Settings, with
no relationship to what the app has painted around it. A list is themed by default only in the
parts it draws; the selection is the one surface it gets for free, and free means AppKit's.

`ThemedTableView` had said as much and drawn the wrong conclusion — that selection was the
sidebar's business, because the sidebar was the only list that had claimed it. Four others had
not: the attachments pane, the theme list in Settings ▸ Appearance (a page for *picking* a theme,
showing the system accent), the project file tree, and the import-conversation list. One omission,
five instances, so the fix is a component — `ThemedTableRowView`, returned from
`rowViewForRow:`/`rowViewForItem:` — rather than a colour at one call site.

**The fill is the theme's `selection` role, not the accent.** That role is the theme's accent at
roughly a quarter alpha, which is what lets the row keep its own label, secondary and tertiary
inks: at full strength every tier in the row would need a selected twin, which is the work the
sidebar does through `BackdropThemedControl.hostGround`. Full accent stays the sidebar's, where the
selected session is the window's subject; two selections at equal weight in one window is a
hierarchy, not a pair. (*"Roughly a quarter alpha"* was a description of the themes that existed,
and two of them never matched it — see the 2026-08-05 note below, which turns it into a
construction.)

**Under System it hands the highlight straight back** — the stock accent, its emphasized and
unemphasized strengths and its vibrancy are worth more than consistency with a theme that is
trying to look like the platform. `SidebarHoverRowView` followed the same rule until the capsule
had to *move*: AppKit hangs its selection view at a fixed 10pt from each edge whatever the
divider does, and a column fitted to its width cannot leave its outermost shape out of the
fitting (see [`window-chrome.md`](window-chrome.md), *the list is fitted to the column it has*).
That row draws the shape itself under every theme now and takes only the colour from the system —
which is why the two classes answer this differently: one sits in a list of a fixed width, the
other in the one column the user drags.

One AppKit behaviour worth keeping, found while writing the test: **a row view that overrides
`drawSelection(in:)` is called; one that does not is skipped entirely.** A detached stock
`NSTableRowView` therefore draws nothing at all, so "ours matches AppKit's" cannot be asserted by
comparing the two outside a list — `ThemedTableRowSelectionTests` asserts the colour instead, and
asks which of two candidate fills each rendered pixel is rather than matching one exactly, since
the display's colour management moves a saturated fill by a hundredth or two.

### What was hardened, and why each layer was needed

The question this raised is the more useful one: *the build lint, the runtime audit and the render
tests all passed, so what would have caught it?* Nothing, as written — every one of them is a
**presence** check, and this was an absence. Each layer below turns the absence into something one
of them can see, and they are listed in the order they should be reached for whenever AppKit
supplies a default that the theme should have chosen.

**1. Answer it in the component, so no call site can forget.** `ThemedTableView` and
`ThemedOutlineView` now create the themed row themselves. AppKit's route is public and was
verified rather than assumed: default row views are made through
`makeView(withIdentifier:owner:)` with `NSTableViewRowViewKey`, *after* the delegate has been
asked and declined — so the sidebar's own row still wins, `super` runs first and the reuse queue
keeps working, and a list gets the right answer by existing. This is the layer that matters:
`ThemedTableView`/`ThemedOutlineView` are provably every list in the app, since subclassing
`NSTableView` or `NSOutlineView` anywhere else fails the source lint. The five delegate methods
that had just been written to fix the five panes were deleted again — a rule enforced at each call
site is the thing that was already missing.

**2. Give the audit a class it can name.** `ThemeBoundaryAudit` treats an `NSTableRowView` that is
not a `ThemedComponent` as a violation (`SidebarHoverRowView` conforms, saying what it already
was). This is the general move for an absence: find the object the framework substitutes and make
*it* the thing that is forbidden.

**3. Render the screens with rows in them.** An audit of a list with no rows is an audit of
nothing, which is why the per-controller audits scattered through the tests could not have caught
this either — they check panes before any row exists. `ThemeLeakSweepTests` builds each
list-bearing screen, materialises its rows, selects one, and audits *that*.

**4. Sweep the pixels for what no rule anticipated.** Under a theme whose accent is nowhere near
the system's, a fill's worth of system accent anywhere in a screen means a framework default drew
itself, whatever the mechanism. It needs no knowledge of *which* default, which is the whole
point — it is the layer that catches the next one. A run of 32 device pixels rather than a single
one, because artwork is allowed to be blue: a file icon, an agent mark and a status dot all carry
colours the theme never chose, and none of them is sixteen points of unbroken accent.

Each layer was verified by breaking the construction on purpose and watching it fail — a net
nobody has seen catch anything is a green light, not a test. Layers 1–3 fail exactly as intended
with the construction disabled.

**Layer 4 did not, and the reason is worth recording, because it bounds what any test in this
repository can see.** AppKit draws a list's own selection *only in a key window*, and
`isEmphasized` does not override that: a regressed build renders every row unselected in an
unshown fixture, so the sweep stayed green against the very defect it was written for. Hosting the
screens in windows did not fix it, and a key window is not available either — the test host cannot
activate under `xcodebuild`, so `makeKeyAndOrderFront` leaves the fixture unkeyed and asserting
`isKeyWindow` fails outright. The keyed variant was therefore deleted rather than shipped green.

What survives is honest and still useful: the sweep covers framework defaults that draw regardless
of key state, its scanner is proven by `testTheSweepReportsASystemColouredFill` (which paints a
system-coloured fill and asserts the scan reports it, pinning the 32-pixel run and the tolerance to
a measurement), and the row's own case is held by the three layers that *were* watched to fail.
The general lesson is the one this whole exercise is about: a test that renders a state the
framework refuses to draw is a test of nothing, and the only way to know which one you have
written is to break the code and watch.

## 2026-08-05 — a fill and the ink on it were two decisions, made in different files

Reported as **"black text on dark blue background is hard to read"**, in the account dropdown under
Windows 98. It is one bug with two symptoms pointing in opposite directions, which is why neither
call site looks wrong on its own.

`Design.Surface.selection` was a token anyone could take, and four surfaces did. Two of them wrote
`Design.Text.label` on it — the ink for the **chrome's** ground, not for the fill they had just
painted. Two wrote `Design.Text.selected`, which is `Text.on(Design.Surface.accent)`: measured
against the *opaque* accent, not against a role that most themes state as that accent at a fifth
of its strength. Measured over each theme's own surface:

| | fill | `Text.label` on it | `Text.selected` on it |
|---|---|---|---|
| Windows 98 | `#000080` opaque | **1.31:1** | 16.01:1 |
| Platinum | `#3151B5` @ 0.88 | **3.70:1** | 5.67:1 |
| Christmas | `#C1121F` @ 0.2 | 11.93:1 | **1.76:1** |
| OpenStep / IRIX / Amiga / BeOS | 0.82–0.88 | 5.97–13.62:1 | below 4.5 |

**The fix is that the fill is no longer available on its own.** `SelectionSurface` vends it
together with a `Design.Ink` measured against the fill *as composited over the ground it is painted
on*, and `scripts/check_architecture_boundaries.sh` fails a build that reads `.selection` from the
palette anywhere but there. A call site can no longer make half of this decision, which is all
either of them was doing.

**Two strengths, and the surface does not choose freely.** Which one it takes answers one question:
*can it reach the ink of everything drawn inside it?*

- `stated` paints the theme's own value and inverts its ink to suit — white on Windows 98's navy,
  the ordinary near-black on Christmas's wash, neither call site knowing which it got. For a
  surface that inks its own contents: a run of selected text (`ThemedTextSelection`), a row that
  draws its own labels (`ExecutionAuditEventView`, `PromptCompletionView`).
- `quiet` holds the fill back toward its ground until `Design.Text.label` reads on it, and leaves
  the ink alone. For `ThemedTableRowView`, which draws the fill while the **cells** are feature code
  in nine different view controllers. A theme that already passes is returned untouched and never
  second-guessed, so only Windows 98 and Platinum move at all, and only as far as they must.

Held back *toward the ground* rather than moved along its own lightness the way
`NSColor.legible(on:)` moves an ink: a selection is not a colour anyone reads, it is a colour that
says *this row, not that one*, and the honest way to say less is to say it more quietly. Moving its
lightness keeps the strength and loses the hue, which turns navy into a pale blue nobody chose.

`ThemedTextSelection` needed a third form. `selectedTextAttributes` is set once and read by TextKit
for the life of the view, and a field editor arrives from AppKit already built — neither redraws
through a call site that could resolve a colour again — so `SelectionSurface.dynamic` returns the
pair as dynamic `NSColor`s over a **closure** for the ground, since what a text view sits on moves
with the theme too.

`SelectionSurfaceTests` states the promise over every stock theme × every appearance it ships,
which is the part that was missing: `ThemedTableRowView`'s own documentation had claimed "the
accent held far enough back that the row's own label tiers still read over it" since it was
written, and no theme had ever been checked against it.

## 2026-08-05 — an overlay that must not take the click

`BrowserBaselineOverlay` holds an approved picture of a page over the live page. It looked, at first,
like a mode of `BrowserAnnotationOverlay`: both are native layers above WebKit, both watch document
scroll through the same isolated-world channel, both draw the accent mode frame and corner badge that
say "this surface is in a mode". Reusing the annotation overlay would have been three lines.

It would also have made the page unusable. Annotation mode overrides `hitTest` to return **itself**
over its whole bounds, because that is how a pin gets placed. A baseline overlay exists so the user
and the agent can *keep working* on the live page while watching the seam, so it must return the
handle and nothing else — every other point passes through.

Two things follow, and both are the reason this is a sibling component rather than a flag:

- **The handle is a real subview, not something drawn.** A drawn control would need `hitTest` to
  answer "yes" over a region, which is one refactor away from swallowing a click on a link. As a
  subview, the pass-through rule is one `guard` that cannot drift.
- **It is a `ThemedControl`.** The overlay is otherwise invisible to the keyboard and to VoiceOver,
  which for a surface drawn over the user's own page is not acceptable. The handle reports itself as a
  slider, takes focus, answers arrow keys at `ImageCompareDefaults.keyboardStep` — the same nudge the
  compare surface uses, so the app's two scrubbing gestures move by the same amount — and its press is
  the mid-point reset.

The bug the test caught is worth recording, because every assertion about the *page* still passing
would have kept passing while it was there: `hitTest(_:)` takes its point in the **superview's**
space, and `NSView.hitTest` on a child wants it in that child's superview — which is this view.
Converting a second time, into the handle's own coordinates, made the handle unclickable. Assert on
the control you must be able to reach, not only on the clicks that must get past it.

Two other rules landed with it. The overlay is native, so `browser_screenshot` never bakes it into
page pixels — a documented non-goal that this component is the most able to break by accident. And a
viewport baseline is only true at the offset it was captured at: scrolling away is stated in the badge
rather than corrected by sliding the image, because sliding it would present pixels at positions they
were never captured at.

## 2026-08-05 — a row of controls had no owner

Reported on the Compare tab: **"the buttons next to Wipe feel unbalanced and too small"**. Two
complaints, one cause, and neither is a property of the buttons.

The header was an `NSStackView` holding the compare surface's mode chip, a caption, the export
action and the expand action. Every part of it was chosen locally and no part of it was wrong on
its own:

| | height |
|---|---|
| `ChipView` (`.compact`) | `Design.Size.choiceHeight` — **the material's**, 16 under Platinum, 26 under System, 14–44 for an authored theme |
| `ThemedIconButton` (`.inline`) | `Design.Size.inlineButtonTarget` — a fixed **20** |
| `ThemedButton` (bordered) | `Design.Size.chipHeight` — a fixed **26** |
| `ThemedSegmentedControl` | `Design.Size.chipHeight` — a fixed **26** |

So the mismatch was not a constant, it **changed sign with the theme**: six points short under
System, four points *proud* under Platinum, and eighteen short under a theme authoring the maximum.
`chipHeight` was the right number for all of these on the day the chip was 26 and stopped being one
the day a chooser's height became the theme's, which no call site could have noticed.

"Unbalanced" was the other half. The row's actions were meant to sit at the pane's trailing edge,
and the thing holding them out there was **an empty caption label set to hug loosely**. A label with
no text is not a spring: it collapsed, and the actions came to rest against the chip in the middle
of an otherwise empty row.

`ControlRowView` is the answer, and the shape of it is the point:

- **A size is the row's to state and the member's to take.** `ControlRowMetrics` carries the height
  and the glyph slot derived from it, its initializer is fileprivate to `ControlRow.swift`, and
  `ControlRowMember.adopt(_:)` is the only way in. A caller cannot hand a control a height, so a
  caller cannot hand it one that disagrees with its neighbours'. `ThemedIconButton.Target` keeps its
  role — what the button is *for*, and what it hovers to — and gives up being the authority on how
  big it is.
- **The glyph grows with the button.** A promoted 26pt button keeping its 12pt mark is more padding,
  not more button. `Design.Symbol.glyphFraction` is the three-fifths the toolbar (16 in 28) and the
  inline button (12 in 20) already held without either having said so, and
  `Design.Symbol.pointSize(forSlot:)` steps a mark at or above the toolbar's slot up to the
  toolbar's heavier optical size.
- **Slack is a spring, and the spring is a view.** One stack holding leading members, a stretching
  view, then trailing members. Two stacks pinned to opposite edges was the obvious shape and was
  built first; it cannot carry pressure. A stack whose width comes from its own content refuses to
  be narrower than that content — `clippingResistancePriority`, **required** by default — which
  outranks any inequality holding two such stacks apart. In a pane too narrow for the row,
  something therefore had to give, and it was never the right thing: at required the run kept its
  width and the row grew past the pane; lowered, the run shrank while its members hung out of it
  unchanged. One stack pinned to both edges has a definite width, so the squeeze reaches the
  members and a label truncates, which is what should give. Measured at the display pane's
  protected 260pt: a two-segment picker that would not go below 287 either way compresses to 153
  here, beside a chip that goes 94 → 40.
- **The margins align complete interaction surfaces.** The first implementation aligned by ink,
  which looked exact only while an ink-only chip was resting: its stable frame also carries the
  hover, open-menu, and keyboard-focus plate, so pulling that frame outside the row made the plate
  break the pane margin as soon as the control was used. The full silhouette now stays inside the
  row; content ink receives the component's own inset, just as content inside a card does.
- **It relevels itself.** The compact height is the material's, so the row re-reads its metrics on
  `AppThemeDidChange` *and* in `layout()`. The event is the prompt; the layout pass is the
  guarantee, because a row built while detached would otherwise keep the geometry of a theme the
  user has left. Both writes are guarded on the value actually changing — a `layout()` that dirties
  itself never settles.

`ControlRowTests` pins each claim, including under Platinum's 16 and a fixture theme's 40, and
renders the row in four themes: the picture is where "the buttons are too small" is legible and no
assertion is.

**What this does not do is decide the row's typography.** Git Review's header baseline-aligns its
counter to `ChipView.contentFirstBaselineAnchor` rather than centring it, which is a deliberate
choice a `.centerY` run would quietly overwrite. That pane is therefore still hand-built. A row
whose members want a shared *baseline* rather than a shared centreline is the next thing this
component should learn, not something to work around at a call site.

## 2026-08-06 — the brand's orb is a sampling of the mark, not another logo

The request began as “orbs in the taste of Threading's icon,” including the possibility of dots
moving inside its shape and tinting the individual pieces. The tempting implementation was a
Threading state in the `ThinkingOrbs` package. That would put application identity into a generic
dependency and leave two owners of the silhouette: the package's approximation and
`ThreadingMarkGeometry`, which already feeds the live mark, app icon and SVG.

`ThreadingMarkView` instead samples its canonical quadratic shield, cubic strands and core
vertices into `ParticleSeed`s. A point retains its semantic role, strand number and path progress,
so colour and motion are properties of the point rather than of an overlaid bitmap. Under System,
the points move along the shield → thread → core brand ramp; under an authored style they inherit
the already-legible theme ink. This is deliberately an array of small shape layers rather than a
single dashed stroke: each point can take a different tint, phase and press beat.

Three cadences share that data:

- **Weave** advances the shield's points around its closed path and each strand's points from its
  outer end into the knot. It is the sidebar choice because motion reinforces what the mark means
  and remains readable in the real 24pt slot. An ordinary pass only weaves; after a deliberate
  dwell, the sampled mark's shared parent makes a closed pitch-and-yaw turn with perspective.
  The dots keep travelling in that parent's local coordinates, so the implied box rotates as one
  rigid object instead of the individual dots orbiting around its centre.
- **Breathe** pulls each point inward and returns it, phase-offset just enough to keep it organic
  without letting the silhouette expand out of its box.
- **Orbit** turns the whole field exactly one sixth per cycle. Six-fold symmetry makes the seam
  exact instead of hiding a reset.

The continuous vector remains the resting state. Particle layers are opt-in (the passive composer
hero builds none), repeating animations start only on pointer entry and are removed on exit, and
Reduce Motion constructs no pointer animation at all. A deterministic phase seam exists for the
Component Gallery and render tests; visual verification therefore compares real Core Animation
layers without depending on the wall clock.

## 2026-08-06 — a one-column list's column is as wide as the list

Reported as "that git layout is massively broken", with a screenshot of the Review pane: file
cards about 76pt wide down the left edge of a 900pt pane, each diff wrapping source code three
characters to a line, filenames compressed out of existence, and two thirds of the pane empty.

**Nothing was broken in Git Review.** The pane, its header, its counters and its table were all
the full width. Only the *cells* were not, because `frameOfCell(atColumn:row:)` measures the
column and the column was still at `NSTableColumn`'s 100pt default. A programmatically built
column starts there, and `columnAutoresizingStyle` only redistributes width when the table's
frame changes *while the column is installed* — so a list handed to a scroll view that already
has its final size never sees a change to divide up. Measured directly: a table installed that
way reports `table=900 column=100 cell=100`, and resizing the window afterwards does not repair
it — the column is still 100 at every later size.

The pane did fit its column, from `viewDidLayout`. That is the trap: its diff arrives from a
background git read, so `documentView = fileTableView` happens long after the pane was laid out,
and a document-view swap deep inside a scroll view lays out no controller root. `viewDidLayout`
was never called again. Every assertion in the suite passed, because every test in it sets
`view.frame` and *then* renders — the one ordering the app never uses.

So the rule moved to the list, where the width actually changes: `SoleColumnFitting` on
`ThemedTableView` and `ThemedOutlineView`, from `setFrameSize`, `layout` and `viewWillDraw`.
Provably every list in the app — subclassing `NSTableView` or `NSOutlineView` anywhere else fails
`check_theme_boundaries.sh` — so a list written later inherits it without its author knowing it
exists, which is the same argument `ListSelectionStrength` makes one entry up. Only for a
*single* column: with two, which one absorbs the slack is a real decision and
`NSTableColumn.resizingMask` is how a list states it.

**The fit is keyed on the list's width, not on the column's.** "Is the column as wide as the list
yet?" is the obvious test and never settles: `sizeLastColumnToFit()` is AppKit's own accounting,
and under `.inset` — what `.automatic` resolves to — it deliberately keeps 16pt at each side, so
the column it returns is 32pt short of the list *by design*. That test would be true forever,
re-fitting on every frame change and every draw. Recording the width fitted at settles in one
pass and is the re-entry guard too, since `sizeLastColumnToFit()` re-tiles straight back through
`setFrameSize`.

**A column already standing exactly on the list's width is owed nothing, and is left alone even
the first time** — which is a correctness clause, not an optimization. Fitting it anyway subtracts
the style's padding from a column that was *stated*, so the cell narrows by 32pt under a row that
does not, and a row's trailing buttons end up hanging outside the cell that hit-tests them. That
is a defect this app has shipped once already, and the first version of this fix reproduced it:
`SidebarRowClickRoutingTests` went from every point of the archive box reaching it to none of
them. It is the reason the whole suite is worth running for a change to a list, and the reason
that test presses all 400 points instead of the middle one.

Three tests, because the fault had three faces. `ThemedControlTests` pins the component rule and
its two-column exclusion. `GitReviewViewTests` pins the *ordering* — pane laid out first, diff
after — which is what no existing test exercised. `GitReviewRenderTests` now draws the real pane
through its real table rather than a hand-built stack of rows, because that is the only one of
the three that would have shown a human this in a picture.

## 2026-08-07 — the row refuses the demotion, because nothing draws the list to repair it

*First tap hovers, second tap selects*, reported a third time. The rule from
"a list's selection follows its window" was right and its two tests were green; the sidebar still
showed a grey bar under the row a click had just picked, and the accent only after a second click.

**The rule was correct and its trigger never fired.** It was applied from `viewWillDraw` on
`ThemedTableView`/`ThemedOutlineView` — described there as "the last moment before any row of this
list paints". That is true of the tests and false of the app. Every window is layer-backed on
modern macOS, so a row whose emphasis AppKit just changed repaints from its *own* layer and the
list it sits in is never asked to draw at all. Probed against a live window: `viewWillDraw` fires
once, for the first paint, and not once more as focus enters and leaves. The tests missed it by
construction — they draw through `cacheDisplay` from the host view, which forces a recursive draw
and therefore always reaches the list. A hook at the draw cannot hold a rule the draw skips.

**So the demotion is declined where it arrives.** `NSTableRowView.isEmphasized` is overridden in
both row classes to ask the list it is in — `SelectionStrengthStating.drawsSelectionAtFullStrength`,
which is the same `ListSelectionStrength` answer as before, so there is still one rule and one
place it is decided. A row's `superview` *is* its table, so nothing is wired up and nothing can
fall out of sync, and there is no ordering to get right: AppKit sets, the row substitutes.

The `viewWillDraw` pass stays, and now has a reason it can keep: AppKit gives a row its emphasis
while building it, **before** it has a superview to ask — measured, not assumed — so a fresh row
cannot refuse anything yet. `viewDidMoveToSuperview` takes the list's answer at the first moment
there is one, and the draw covers what is left. Two applications, one decision.

**"A row class cannot carry it" was the previous entry's premise and it was wrong.** The row
nobody wrote is not out of reach: `ThemedTableView`/`ThemedOutlineView` intercept
`makeView(withIdentifier:)`, so a delegate that returns no row view gets `ThemedTableRowView`, not
a plain `NSTableRowView` — and the two row classes are as provably total as the two list classes,
now swept for by `testEveryRowBuiltFromScratchInTheAppIsOneOfTheTwoThatRefuseTheDemotion`.
Deriving from either inherits the refusal; building straight on `NSTableRowView` fails the sweep.

**And `ListSelectionStrengthTests` had never run.** At the time, `Tests/ThreadingTests` carried an
explicit project-file list and the file was absent from it, so the suite guarding this rule
compiled nowhere and reported nothing. `ThemedTableRowSelectionTests` was in the same state. The
target is now a filesystem-synchronized group, so every Swift file below it is compiled without a
second registration list.

The new test is the one that fails on the old code: demote every row and assert the strength
*immediately*, with no draw of any kind in between — which is the only form of the rule the
running app ever exercises.

## 2026-08-12 — a row's trailing control is not always one view, and a stack does not hear the row

Reported from the Storage page: the three artifact rows' Remove buttons floated in the middle of
the card, each at a different distance, while the card's own Remove All sat on the trailing edge
above them.

Storage's rows carry two things at the trailing end — the size and the button that reclaims it —
so what they hand `SettingsUI.row(title:subtitle:control:)` is an `NSStackView` rather than a
control. The row does one thing to a control it is given, and it is the load-bearing thing:
`setContentHuggingPriority(.required, for: .horizontal)`, so the label column beside it is the
only view willing to absorb the row's slack. **A stack view does not lay out by that property.**
It has no intrinsic content size for hugging to describe, and reads its own `huggingPriority`
instead, which starts at `.defaultLow` — exactly the willingness to grow that the label column
was given deliberately. Two views equally willing, and the layout engine picked.

Which is why this shipped, and why it is worth writing down: **it picked differently in a fixture
than in the app.** Measured in a `SettingsCard` held at 620pt by a width constraint, the group sat
on the trailing inset and every assertion anyone would have written passed. Inside
`SettingsUI.page`'s scroll view — same card, same 620pt — the group took the slack and its
contents clustered at its leading edge, at 439/457/460pt of a 608pt row, each row's own size
string setting where its group began. The 420pt case was accidentally correct in both, because a
narrow row has no slack to misassign. This is the "component tested outside the container it ships
in" trap from CLAUDE.md in its quietest form: the fixture was not wrong about the row, it was
wrong about which of two ambiguous answers the engine would give.

`SettingsUI.controlGroup(_:)` is the fix and the vocabulary: a composite trailing control, hugging
its content at `.required`, spaced and centred like the row expects. `holdsItsWidth` applies it
from both `assemble` and `disclosureHeader`, so a page that hands either one a stack cannot hit
this again. Nothing else about the stack is touched — its clipping resistance is already required,
so under pressure the group keeps its content width and the row's own title truncates, which is
what should give.

Two places in this codebase had already met this fault and solved it locally: the Usage dashboard's
`sectionHeader` parks an inert spacer beside its compound controls, and the composer's column
carries a comment naming the property a stack view does not lay out by. The kit that builds rows
now says it once.

Storage's sizes align as a consequence rather than by arithmetic: the group is flush to the
trailing inset, the buttons all read "Remove", so every size label ends on one edge and the
monospaced digits form the column the page exists to be read down. What is *not* aligned is the
card's own summary and its fold row's total, which sit at their own trailing ends because their
rows carry different controls — three numbers at three right edges. Making those one column means
reserving a size column and an action column across a whole card, which is a table, and the
disclosure summary is shared with Tools ("35 tools") and Extensions ("Running") where such a
column would mean nothing. Left alone deliberately.

`SettingsRowLayoutTests` pins it in the page, not in a card: the group reaches the trailing inset,
the buttons and the sizes each share a column, and at 420pt the group still keeps its fitting
width. `SettingsDisclosureRenderTests`' storage-shaped fixture is now unfolded and carries the
two-part control, because collapsed it drew none of this.

## 2026-08-12 — a picture's own corner has to be the corner that clips it

Reported from a screenshot: hovering the attachments pane's preview drew an accent ring with no
top-left and no top-right arc. Both top edges simply faded out into nothing about twelve points
short of the corner, while the two bottom corners drew a clean arc.

The measurements name the culprit before the code does. The ring is a one-point stroke — a
`borderWidth` hairline. Its bottom arcs have a radius of eight points — `controlRadius`. The alpha
along each broken top edge follows a circular-arc coverage profile of radius twelve —
`panelRadius`, to better than a twentieth over eleven samples. Three tokens, three matches: this is
one silhouette being cut by another.

`SessionAttachmentsViewController` gives its preview host `applySurface(fill:radius: .panel)` and
pins every installed preview to all four of its edges. A layer corner clips what is under it, and
`ThemedImagePreview.fittedRect` pins the picture to the *top* edge and stretches it across the
width — so a picture wide enough to fill the pane lands exactly on the host's two rounded corners
and nowhere near its other two. An eight-point silhouette drawn inside a twelve-point clip loses
the corners it is flush with, keeps the ones it is not, and that asymmetry is the whole bug. It is
the trap `ThemedControl.drawKeyboardFocus` already documents — "a layer corner clips what `draw(_:)`
lays down" — arriving from the *superview* rather than from the control's own applied surface,
which is why the existing defence did not catch it.

So the picture asks what clips it: `superview.appliedSurfaceRadius`, when this view fills that
superview and the fitted picture spans its width. Flush inside a panel, the picture is rounded at
the panel's radius, because that corner is the one the user can actually see. Anywhere the panel
does not reach — a narrower picture floating in the pane, the display panel's own square
`.fixed(0)` host — it keeps the nested `control` corner, which is what that token means.

Two smaller things came with it. The ring is now held one border width *inside* that silhouette
rather than stroked along it: the clip is a layer corner and therefore `.continuous`, while
`NSBezierPath` rounds circularly, and two curves that agree at the tangents and part company
between them will shave a stroke laid exactly on the boundary. And the picture is clipped to the
silhouette it is given, instead of being drawn square under a rounded ring — that mismatch was
invisible on the dark screenshots this pane usually holds and a wedge of unrounded picture at each
corner on a light one.

Verified by rendering rather than by argument, because `cacheDisplay` runs `draw(_:)` and ignores
the layer corner that causes this — the real drawing was captured, then the panel's clip applied
over it, and the accent ink counted in each corner. Before: 64, 64, 126, 126. After: 124 in all
four. `MediaInspectorTests` keeps the geometry rather than the pixels, since the clip is a layer
property no offscreen render reproduces: a picture flush inside a panel takes the panel's corner,
a narrower one and a square host both keep the control's.
## 2026-08-12 — a receipt stopped at a width the column it was reporting into did not have

The archive band was capped at 320 points. In a sidebar dragged wider than that it sat at the
leading edge with the rest of the column empty beside it: a card stranded next to the list it was
reporting on rather than part of it. The cap read as a reasonable measure decision and was not one
here — it only ever engaged in a column somebody had dragged, and at every width the app itself
opens the sidebar at (180 to 400) the band already filled. What it produced was a layout that
changes character mid-drag: filling at 340, floating at 360.

The cap is gone, and nothing replaced it. Every host a receipt has is a column — the sidebar, an
extension's navigator shell, the gallery's stand-in for both — so "stops well short of spanning a
pane" was guarding against a pane no toast is presented in. The fill pin stays weak and breakable
all the same, because that priority was never about the cap: it is what stops a receipt from
resizing the column it reports into, which is a bug this component has already shipped once in
each direction.

The same edit moved `hostInset` from `Spacing.medium` to `Spacing.inset`. The band's edge is read
against the pane footer directly under it rather than against the column's edge, and
`PaneFooterView` stands its first control's *ink* at `Spacing.inset` — so at 10 the card sat two
points inside the gear it was stacked on, close enough to read as a miss rather than as a
decision. `ToastRenderTests` now builds its footer with the sidebar's real Settings button for
this reason: the relationship that was wrong is only visible against the thing it was wrong
against, and the storybook's empty footer band could not show it.

## 2026-08-12 — a queue you can count but not read

The deck of waiting receipts answered *how many are coming* and nothing else, and the way back
people actually wanted was on the third card: a burst of archives is four separate undos, and
reaching the last one meant sitting through three dwells. Reaching into the strip above the band
now fans the deck out, each card showing its own line and its own way back. The rationale for the
three decisions that hold it up — the whole queue rather than the resting two, the clock held
while it is open, a grip that reports the pointer and takes no click — is in the queue section
above, beside the drawn-stack note it extends.

**The fan is the app's first spring, and it had to be one.** The deck opened on `glide` at first
and read as a snap, which is `lift`'s documented failure exactly: over a step's distance `glide`
is 84% finished within three frames, so the movement paid for is never seen. The fix wanted an
overshoot — a hand fanning cards does not set each one down on its mark — and the obvious route is
a cubic bezier whose second control point sits above 1. **That route does not exist.**
`CAMediaTimingFunction(controlPoints: 0.15, 0, 0.4, 1.3)` stores the point back unchanged when
asked for it, and then Core Animation clamps the value it interpolates: sampled off the
presentation layer, a card authored with a 4.5% overshoot stopped dead on its slot, peak 25.93 of
a 26-point step. So `Design.Motion.Spring` exists beside the curves, `Motion.settle` is its one
instance (damping ratio 0.70), and the deck moves its cards by settling the constraint first and
springing the *picture* of the card from where it stood. Measured the same way afterwards: peak
27.18pt on a 26pt step — 4.5% past, exactly the ratio's arithmetic — back inside a third of a
point by 0.4s. Cards also start one `peekStagger` after the one in front, so the deck unfolds from
the band outward rather than changing shape as one object. Closing takes no spring at all: it is
`drop`, an acceleration, because a card bouncing as it is *put away* is the animation arguing with
the intent.

Three other things were verified rather than assumed. That a `hitTest`-nil overlay still receives
`mouseEntered` from its tracking area, and that a click aimed through it lands on the button
underneath: both were probed with a throwaway AppKit binary before the grip was built on them,
because the whole design rests on tracking being geometric where hit testing is not. And the fan
itself is a rendered state (`toast-opened-*`), since whether three strips of words over a band in
a 240-point column read as a queue or as a wall over the list is not a thing an assertion says —
rendered through `openDeck(_:animated:)`, whose unanimated path exists so a still is a picture of
the settled deck rather than of one two frames into opening.

## 2026-08-13 — a row of pills was six objects where the answer was six words

Reported from a screenshot of the session composer with three arrows on it. The first: *can we
make all the "pill" only show the actual pill on hover, and just be plain text when not — that
would make them take less space and look cleaner.*

The vocabulary already said this and the chip was the one control not keeping it. A plain
`ThemedButton` is "a mark until it is wanted"; `PageTitleView` has no plate at rest and raises a
quiet one under the pointer; `ThemedIconButton` rests on a clear fill. `ChipView` alone wore a
`controlResting` plate at all times — and a chip is not an action waiting to be taken, it is an
**answer being shown**, so the plate was contrast spent on saying "control" beside the words the
user is writing. Six of them along the composer's footer read as six objects.

So the plate now belongs to the pointer: `.clear` at rest, `controlHover` for the three states
that mean *you are on this one* — hovered, menu open, keyboard focus — and the control glow goes
with it, since a theme that haloes its controls would otherwise ring a plate nobody drew.

**The ink moves with the plate, on one ramp.** Removing the plate alone left the row *louder*
than before: white `label` text at the control face's medium weight, with nothing around it to
share the contrast, was the brightest thing in a composer whose point is the brief being typed
above it. The second look at the same screenshot said so — "a little more subtle… compare to
Cursor/ChatGPT, it is not the main focus" — and both of those draw the same row as muted
regular-weight text with a small chevron. So a chip rests at `secondary` for its title and
`tertiary` for its mark and chevron, and the pointer lifts each one tier while the plate appears.
The title is deliberately **not** kept at full strength: the earlier note here argued it was the
answer and had to stay bright, which is true of a chip standing alone and false of six in a row
under the thing they modify — the hover is what makes one of them the answer being read.

The step is ink only. The weight is fixed at `controlRegular`, one tier below the `control` face
this app gives an *action*: a bolder face on hover is a **wider** face, and a row that reflowed
under the pointer would be a worse distraction than the one this quiets. A period material is
exempt — its value sits in a drawn well, and a well is a container for a value at full strength.

**A sub-point of rounding is not a squeeze.** Dropping to regular took away a point of slack the
medium measurement happened to carry, and `Claude Code · Everlof` began drawing as
`Claude Code · Everl…` inside a chip whose frame was its own full intrinsic width. The repair
already existed for the classic anatomy — a minimum on the label itself at `defaultHigh`, since
a text cell's natural width is fractional and stack layout rounds the arranged frame down — and
it is now stated for every anatomy. The chip's own edge pins are required, so a real squeeze
still costs characters; only the rounding no longer does.

**The padding stayed in the frame, and shrank a step.** Nothing may move as the plate appears — a
run of chips that reflowed under the pointer would trade one distraction for a worse one — so the
frame carries the plate's padding at rest as well, and `OpticalInsetProviding` reports it so a
`ControlRowView` puts the chip's *text* on the margin rather than the edge of a shape that is not
drawn. But ten points is what a **drawn** pill needs to hold its text clear of the curve at each
end, and at rest there is no curve: on the composer's footer that was eighty points of invisible
air in the one row with none to spare. `ChipView.horizontalPadding` is `Spacing.small`, and the
plate still reads at six points because only one chip wears it at a time.

### The reading beside the send was not short of room; it was bidding against a gap for it

The second arrow pointed at `5h 86…` — *this is so compacted that it can't be read* — and it was
two bugs wearing one symptom.

**A tail-truncated reading is not a shorter reading.** The line was an `NSTextField` with
`byTruncatingTail` and the row's lowest compression resistance, on the reasoning that a chip is
unreadable half-drawn while a reading keeps its meaning as it loses characters. That is wrong
about where a reading's meaning lives: what `5h 86…` lost is the `%` that made the number a
proportion, and the week beside it went without a trace. `UsageReadingLabel` gives up **windows**
instead — the whole line, else one complete reading, else nothing at all, with the full pair still
on the tooltip and the accessibility value. Its intrinsic width stays the whole line whatever it
last drew, so a widened window brings the dropped window back; sizing to the drawn text would have
made the first squeeze permanent.

**And the row had slack the reading never saw.** `PromptView`'s footer spacer held `defaultLow`
for both hugging and compression resistance — which is the usage reading's own compression
resistance to the point. Two claims on the same slack at the same priority is an ambiguous system,
and it was resolved by squeezing the reading to a third of its width and handing the difference to
the gap: a footer sitting on spare points beside a truncated number. The spacer is
`PromptViewDefaults.spacerPriority` (1) now, the same value and the same sentence as the
composer's own `chipSpacer`: the empty middle stretches last and collapses first.

Measured on the row from the screenshot — five posture chips and a two-window reading in a
720-point column — the reading went from 31 points (nothing drawable) to enough for a complete
window, and `SessionComposerRenderTests` pins both ends of it: whole windows in the crowded row,
and no squeeze at all in a roomy one.

### A dimmed glyph with its reason on a tooltip is the same dead end, quieter

The third arrow, on the schedule clock: *why is this disabled for me?*

Because a screenshot was attached, and a pasted screenshot is a file in a temporary directory that
a plan firing on Monday cannot count on. `scheduleEntries` already answered that in a sentence —
written, in that file, on the stated grounds that "nothing happened when I clicked it" is the
worst possible answer — and `refreshScheduleChip` then disabled the button, so the press never
arrived and the sentence was reachable only by hovering long enough for a tooltip. The composer
makes the opposite promise about its send two hundred lines earlier: it "says why rather than
sitting there dimmed with nothing to explain itself".

The button is always pressable now and the menu is the refusal — one disabled row carrying the
sentence. The missing-project case joined it rather than returning an empty menu, using the
composer's existing `chooseProjectFirstReason`, so the screen states one blocker once instead of
in three phrasings.

## 2026-08-13 — a dropdown covered the seam, but not the cursor over it

Reported straight from use: **"if a dropdown is open and I have the mouse inside it, but behind it
there's a pane, the cursor turns ↔ even though it's still inside the dropdown."**

Nothing about the menu was wrong. `ThemedMenuPresenter` draws a dropdown as a *view* over the
window's content — deliberately, and for four reasons stated on that file — and AppKit's cursor
rectangles are a **window's** list, not a view's. `ThemedSplitView` puts a resize rectangle over
each seam; the menu overlay registered none; so the strip of window where a seam ran behind the
open panel kept answering the pointer with the divider's arrows. The one thing a click could reach
there was the menu, and the cursor was offering to drag a pane edge. Every platform menu escapes
this by being a window of its own, whose cursor rectangles stop at its own edges.

The fix is the switch AppKit already has for a surface that has taken a window over —
`NSWindow.disableCursorRects()` — held for as long as the dropdown is up, with the arrow set once
on the way in, because disabling stops the *next* answer and leaves whatever the seam already put
on screen. A menu opened by pressing a control that sits beside a divider is exactly the case that
needs that second line.

**What AppKit does not have is a count**, and that is why `CoveredWindowCursor` exists rather than
two calls inside the menu session. Measured on `NSWindow`: two `disableCursorRects()` followed by
one `enableCursorRects()` leave cursor management **on**. One surface closing inside another would
therefore hand back a window the outer one is still covering. The claims are counted here, keyed
weakly to the covering view, and a surface that leaves its window without releasing stops counting
on the next claim — the failure being guarded against is a window whose cursor never answers again
for the rest of the session, which is not a thing to leave to a `guard` somebody may move.

**Only a surface that answers for every cursor beneath it may claim, and that is the boundary of
this fix.** A dropdown qualifies: it covers the whole content view and contains nothing that wants
a cursor other than the arrow. A modal on an `InWindowOverlay` scrim does not — the command
palette's search field, the media inspector's drag handles and its own resize rectangles are
registered in the same window's list, so a window-wide switch would silence the cursors it means
to keep along with the ones it means to stop. The scrim has the same defect over a seam it covers,
and it needs a different answer: either a claim held only while the pointer is over the bare scrim
rather than over the surface in front of it, or a cursor rectangle on the scrim itself if a
front-most rectangle is shown to win over one behind it. That precedence is **not** established —
an attempt to measure it in a scratch app failed to make its window key, and no measurement means
no rule. Do not extend `CoveredWindowCursor` to the scrim on the assumption either way.

## 2026-08-14 — a corner a theme states is not a corner every shape can turn

Reported from a screenshot of the Component Gallery under Botanical: the theme menu's highlighted
row "looks pointy", and every card's copy "comes so friggin close" to its rounded edge. Two faults,
one cause — a theme that states a broad corner, and geometry that assumes a modest one.

**The point.** Botanical's `controlRadius` is 24 and a menu row's fill is 26pt tall. A layer takes
that pairing to a capsule: `CALayer.cornerRadius` clamps to half the *shorter* side. A path does
not — `NSBezierPath(roundedRect:xRadius:yRadius:)` clamps each axis separately, so the same token
on the same rect produced a corner 24 wide and 13 tall: two quarter-ellipses meeting in a taper.
Measured off the reported screenshot, the cap ran 15pt in along the top edge of a 13pt half-height,
which is the pointing the eye saw. The same unfitted token reached the sidebar's selected chat,
where hover and selection are documented to be one silhouette and had quietly become two: the
selection drew `Design.Radius.control(fitting:)` and the hover under it drew the raw token.

`ThemedSurface.Shape` now fits its radius to its rect, so no drawn surface can be handed a corner
wider than the shape can turn — the clamp a layer already applies, applied where the path is built
rather than at twenty call sites. The menu row and the sidebar row additionally ask for
`Design.Radius.control(fitting:)`, which is what a row-shaped fill takes everywhere else in the
window; the structural fit is a floor, not a substitute for asking correctly.

**And what "fitted" means now depends on the shape.** The third-of-the-shorter-side rule was
written for a 16pt square that drew as a disc, and applied to a row it produced the opposite
mistake: under Botanical the settings sidebar's selected row is layer-backed and clamped itself to
a capsule, while the theme menu's row was drawn and cut to a third — one window, two silhouettes
for the same token. A square has no flat edge to spare and a row does, so the fraction runs from a
third at square to a half at twice as long as tall, interpolated rather than switched so two rows
of similar proportion do not come out visibly differently cornered. Nothing about System moves:
its corner is 8, under every cap these produce.

**The crowding.** `Spacing.inset` is 12, and a 40pt corner has already curved 11pt inwards at the
height of a card's first line of text — so a title held 12pt in stood against the curve with half a
point to spare. `Design.Spacing.inset(inside:)` states the rule the shape states: content's own
corner stays `inset` clear of the arc along the diagonal, where the arc comes closest —
`√2·(radius - i) ≤ radius - inset`. Corners at or under 12 ask for nothing, so only four themes
move: Botanical to 20, Claymorphism to 18, and the 14/16pt styles by a single point.

A constraint's constant freezes exactly the way a layer's colour and corner do, and nothing was
re-stating it: a card built under a 10pt theme kept 12pt of padding when Botanical's 40pt corner
arrived under it. So the padding is recorded beside the surface (`PanelContentInset`) and re-fitted
by the same sweep that re-applies the corner — `AppThemeRefresh.repaint` owns both, and they cannot
drift apart. Call sites keep their own constraints and their own signs; only the magnitude is the
token's.

Two things a call site states for itself. **What it pads by when the corner asks nothing** (`from`):
a card's `inset`, but a chat bubble's own measure is `medium` and being widened to a card's would
be a different bubble — the corner may only push content further in, never pull it back. And
**what its content already carries** (`less`): a settings card stacks rows that pad themselves
10pt, so the card owes only the difference at its two ends, or the first row would sit 30pt down a
card whose rows are 10pt apart.

Adopted by the surfaces that pad a `.panel`: the gallery's story cards, the settings rows, the
dividers that start on their label column and the card's own two ends, the usage dashboard's metric
and coverage cards, the subagent summary, and both user bubbles — where at 40pt the arc has crossed
x=13 by the height of the first line, so 10pt of padding put the opening word outside the shape
that was holding it.

One known edge, pre-existing and now slightly more visible: the conversation's row-height cache is
keyed by presentation and width, and a theme change invalidates neither — a bubble that grows by
the corner's difference (or by a theme's own typeface) is measured again on the next width change
rather than immediately.

### The same corner, one layer out: a fill that runs past the panel holding it

Reported from the render above, under Botanical: the highlighted **first** row's fill draws
*outside* the menu panel's own border. Measured off that PNG, the row's wash spans x 37…222 where
the border spans 39…220 — two to three points proud of the edge, on both sides, for the top ~19pt
of the panel.

Nothing clips it, and that is structural rather than an oversight: the panel's corner lives on a
**layer** (it has to, because the panel also carries the theme's halo, and `masksToBounds` would
take the halo with the overflow), while the rows live in a **scroll view** whose frame was inset by
the same 6pt at the ends as at the sides. Six points is outside the silhouette while the corner is
still turning — a 40pt corner has not curved past x=6 until 19pt down the edge — so the fill is
placed beyond the shape and simply drawn there.

`Design.Radius.edgeReach(of:clearing:)` states where the corner finishes for content held a fixed
margin in from the side (`radius - √(2·radius·margin - margin²)`), and `ThemedMenuMetrics` gains a
`verticalOuterInset` — the row area's inset at the panel's two **ends**, where its corner is, as
against `outerInset` along its sides. Botanical takes 19, Claymorphism 14, and every other theme's
corner is at or under the margin, so they keep 6 (or Platinum's 1, or 2) exactly. The panel is that
much taller, which is the honest cost: a menu that reserved the old inset would put its last row
where the corner is.

This is the third fault from the same root as the two above, and worth stating as a rule rather
than three fixes: **a broad corner is not only a look — it takes space away from the panel's own
edges, in every direction, and anything drawn to a fixed margin has to be told where the corner
finishes.** Text asks it as a diagonal clearance (`Spacing.inset(inside:)`), a fill asks it as an
edge reach (`Radius.edgeReach(of:clearing:)`), and a shape asks it as a fitted corner
(`ThemedSurface.Shape`, `Radius.control(fitting:)`).

## 2026-08-15 — a band centred its text, and centring is not a line

Reported from a screenshot of the sidebar's footer: the DEV build mark "doesn't align" with the
Settings button beside it. Measured off the screenshot, the mark's baseline sat two device pixels
above the title's, and its cap tops poked past the taller font's ascenders — small enough that no
frame assertion would ever have said so, large enough that the eye read the badge as floating.

The cause was structural, in two layers. `PaneFooterView` centred every band item on
`centerYAnchor`, which is exactly right for icon buttons and plates and never right for two runs
of *text at different sizes*: the Settings title is 12pt `controlRegular`, the badge 11pt
`detail`, and centring two line boxes aligns their middles, not their baselines. Under SF the
error is a fraction of a point; a theme family widens it, the same arithmetic `lineHeight(of:)`
and the chord's drop already record. The attachments pane's scope band wore the identical bug —
an 11pt caption centred against a titled toggle.

And the call site could not have fixed it, because `ThemedButton` draws its title by hand and
never told Auto Layout where that title sits: `NSView`'s default first baseline is a frame edge,
so a `firstBaselineAnchor` constraint against the button aligned text to its bottom. The button
had already solved this exact problem *internally* — its shortcut chord centres its ink band on
the title's ink band — without exposing any of it to a sibling.

Two seams, both now stated:

- **`ThemedButton` reports its title's baseline** (`firstBaselineOffsetFromTop`, and the last
  baseline from the other edge), computed from its intrinsic height with the same numbers
  `drawContent` lays the title out with — every host gives this control its intrinsic measure,
  and a value read from the solved frame would be a moving target while the engine is solving
  it. The pixel-title path answers too, from the cell's own ink rows. The conformance that
  advertises this is `TextBaselineProviding`: a marker whose whole contract is "my baseline
  anchor is the drawn line, not a frame edge".
- **The bands align loose text by baseline** (`PaneBandTextAlignment`, used by both
  `PaneFooterView` and `PaneHeaderView`): controls keep the band's centre — their plates set the
  band's rhythm, and tilting a hover surface to serve its title would move every control in the
  chrome — while a bare `NSTextField` joins the first titled control's line instead of centring
  itself. A band with no titled control centres everything, as before.

What a render found became assertions: `PaneFooterTests` pins the constraint (including across
the two runs, which is the scope band's shape, and across a live font change),
`PaneFooterRenderTests.testBandTextSharesOneDrawnBaseline` renders the band at 2× and requires
the title's and the badge's most common bottom-ink rows to land on one device pixel — the
non-circular half, proving the *reported* baseline is the *drawn* one.

## 2026-08-16 — a dropdown covered the controls, but not the pointer over them

Reported from a screenshot of the composer's model menu, two faults on one panel: hovering a
menu row's *text* showed the I-beam, "as if the text were selectable", and the hover "bled back
to the controls behind it" — the chips under the panel lit as the pointer travelled the rows
above them. The instruction that came with it: fix it structurally, so it is not fixed again
somewhere else. Three days earlier the same overlay had let a pane seam offer its `↔` inside the
open menu ([above](#2026-08-13--a-dropdown-covered-the-seam-but-not-the-cursor-over-it)), and
that fix was scoped to cursor rectangles because that was the mechanism measured. These two are
the *other* two mechanisms, and the three are now one claim.

**What was measured, and what it rules out.** A dropdown is a view over the window, and AppKit
carries the pointer to the content beneath a view by three routes, none of which looks at
z-order:

- Cursor rectangles — the window's list, already handled.
- Tracking areas: `mouseEntered` reaches every view whose rectangle the pointer entered,
  whichever one a click would land on. That is the bled hover, and it is why the sidebar's rows
  were already asking `NSView.isPointerCovered(at:)` themselves under a toast band.
- Mouse-moved delivery. `NSTextView` installs one area with `.mouseMoved`, `.cursorUpdate` and
  enter/exit (`options == 551`), and both `-[NSTextView mouseMoved:]` and `-[NSTextView
  cursorUpdate:]` end in `_mouseInside:`, which sets the I-beam — `disableCursorRects` never
  touched it. That is the I-beam.

The obvious structural move — swallow the pointer at a local event monitor while the overlay
is up — works for two of the three and is impossible for the third, and the reason is
load-bearing: **the manager that computes every crossing in the window computes them inside the
window's handling of `mouseMoved`**. Disassembled: `-[NSApplication sendEvent:]` routes a
mouse-moved to `-[NSWindow sendEvent:]`, whose `_routeMouseMovedEvent` calls each mouse-moved
listener, and `-[_NSTrackingAreaAKManager _mouseMoved:]` — a listener — runs
`_updateActiveTrackingAreasForWindowLocation:` and delivers `mouseMoved:` to the `.mouseMoved`
owners in one pass. Withholding that event withholds the menu's own row hover with it. Enter,
exit and cursor-update events, by contrast, are separate queued events (`_routeEnterExitEvent:`
routes them by their `trackingArea`), and a monitor sees each one with its area attached.
`NSCursor.set` was disassembled too: the window-server call is deferred to the display cycle
(`___NSCursorSetCursorFromDisplayCycle_block_invoke`), so two sets inside one dispatch coalesce
into the last.

**`CoveredWindowPointer` is the claim, and a covering surface makes exactly one.** It folds in
`CoveredWindowCursor` (the rectangles) and adds the two halves the measurements allow:

- **Arrivals beneath the surface are withheld; leavings pass.** A local monitor for
  `mouseEntered`/`mouseExited`/`cursorUpdate` places each event's tracking-area owner against the
  surface with the same reading `isPointerCovered(at:)` uses — neither contains the other — and
  returns nil for an arrival beneath. An exit always goes through, for the rule `hoverIsStale`
  states: leaving is the direction that goes wrong visibly. An area nobody's view owns (a tooltip's)
  passes, because a menu row's tooltip has to work as much as anything else's.
- **A withheld arrival is owed.** AppKit's book says the pointer is inside that area — it
  generated the crossing — so it will not say so again until the pointer leaves and returns; a
  dropped arrival is a chip that stays dark under a resting pointer after the menu closes. Each
  claim keeps the arrivals it held back (one per area and kind), and on release delivers the ones
  whose area the pointer is still inside — re-derived from the window, not from the event — or
  hands them to the surface still covering that owner. AppKit's own tracking manager carries the
  same idea by its symbol names — `installMenuTrackingObserver`,
  `menuTrackingTrackingAreaEvent:delayedArray:` — for the menus it draws itself.
  Release therefore comes **after** `tearDown` in the menu session: the overlay has stopped
  answering hit tests by then, so a row asked "are you covered" on the delivered arrival is told
  the truth.
- **The application puts the arrow back.** Since the mouse-moved path cannot be withheld, the
  editor beneath still sets its I-beam; `ThreadingApplication` — the app's first `NSApplication`
  subclass, holding this one override — calls `CoveredWindowPointer.applicationDidDispatch` after
  `super.sendEvent`, which re-asserts the arrow for a pointer event in a claimed window whose
  location is over the surface. Over the surface only: a mouse-moved reaches the key window while
  the pointer is over another one, and that window's cursor is its own.

**The rule that follows for everyone else, and the gate that holds it.** A hover that starts
on `mouseEntered` — every `ThemedControl`, every row — needs no line of code for a covering
surface: the surface withholds the arrival and pays it back. A hover that reads its position off
`mouseMoved` cannot be shielded by any cover, so it asks `NSView.uncoveredPointerLocation(in:)`
in its own `mouseMoved` — one helper that answers the local point or nil. The rule was applied by
hand to three views first (the seam, the diff's line action, the minimap's fisheye), and a sweep
then found seven more overrides that read `locationInWindow` bare — the chart's crosshair, the
git card's row hover, the file-activity map, the browser annotation probe, the extension surface's
pointer forwarding, the element inspector, and the terminal's motion reporting. All ten ask now,
and `scripts/check_architecture_boundaries.sh` fails the build on a `mouseMoved` override whose
body does not, unless the file is named in the script's exemption list with its reason (the
dropdown's own overlay is the surface). `isPointerCovered(at:)` itself stays *asked for* rather
than folded into the shared hover, for the reason the toast band established: a partial cover
that claims nothing (the band) still needs it. The chip a menu is open *on* keeps its held look
through `ThemedMenuPresentationObserving`, not through hover, which is what let hover under a
menu be silenced at all — the earlier handoff paragraph's "a chip under an open menu keeps its
hover invitation and even widens" is no longer true; the click handoff between sibling openers
stays, for the menu-bar reason, without the invitation.

**The claim carries a cursor policy, and the modal claims too.** The crossings half is every
covering surface's; the cursor half is the surface's to state. A dropdown claims `.arrow` — cursor
rectangles off, arrow re-asserted. A modal on the `InWindowOverlay` scrim claims `.surfaceOwned`
from `install` and releases from `Presentation.remove()` after both views are out: only the
crossings beneath it are withheld, and its cursor is left to its own content, because its search
field and drag handles register in the same window's list (the boundary recorded on 08-13, which
is unchanged). What `.surfaceOwned` cannot do is answer a listener beneath that sets its cursor
from `mouseMoved` — an editor under a modal can still show its I-beam through the wash — and that
remains the open half on `CoveredWindowCursor`. Do not move the modal to `.arrow` without
measuring cursor-rectangle precedence first.

Tests: `CoveredWindowPointerTests` exercises the decision through the seam that takes a real
`NSTrackingArea` beside a stand-in event (the events AppKit builds cannot be built with their
area attached), the debt through the real pointer — the unshown window is moved under it — and
the release ordering through a live `ThemedMenuPresenter` dismissal and a live
`InWindowOverlay` removal, asserting the delivered arrival saw itself uncovered — plus the three
position hovers under a covering view and both cursor policies, nested.

## 2026-08-17 — a placeholder's rhythm is the system's, and a seam never hangs on a hideable line

The scheduled empty state shipped visibly cramped, and the report ("a bit too compact,
especially vertically") decomposed into one taste call and one bug. The taste call: two
empty-state surfaces had each picked their own vertical rhythm — the plain placeholder a 6pt
base with an off-scale 16 after its icon, the scheduled one a 4pt base — numbers chosen per
surface for a structure both share, a hero glyph over an announcement over content sections.
`Design.Placeholder` now states that rhythm once, each member restating a `Spacing` step by
*role* (`afterIcon` 12, `line` 6, `caption` 4, `group` 20, `section` 32), and both views take
it; the next empty state inherits a rhythm instead of re-deciding one.

The bug: the scheduled surface's one major seam — announcement above, the user's brief below —
was recorded as `setCustomSpacing(after: problemLabel)`, and the problem line is hidden in the
ordinary case. **`NSStackView` detaches a hidden arranged view and the custom spacing recorded
after it leaves with it**, so the 20pt seam collapsed to the 4pt base exactly when nothing was
wrong, and the "Brief" caption read as a stray word glued to the headline. The plain
placeholder had the same trap on its pre-button gap, hung on its hideable detail line. Both now
group the hideable line into a cluster stack and record the seam after the *cluster*, which is
always there — the pattern to reach for wherever a section break follows a sometimes-hidden
member. The collapsed seam is pinned by an assertion on converted frames in
`ScheduledSessionPlaceholderRenderTests`, in the fixture whose warning is nil, because that is
the case that collapsed.

## 2026-08-17 — Settings is one canvas, not a width per destination

Usage needed more horizontal room than the old 620-point form measure: its summary and chart sit
beside each other, and its breakdown is a named table. Making that page alone wider fixed the
content and introduced a navigation defect — the centred Settings canvas changed its visible
edges whenever the reader entered or left Usage.

`SettingsUIDefaults.pageWidth` is now the single shell contract for every built-in, AI-search and
extension-provided Settings destination. The per-page `SettingsPageWidth` choice was removed from
the catalogue rather than merely defaulted differently, so another destination cannot drift by
opting into its own canvas. `Design.Size.settingsContentWidth` keeps the Usage-derived arithmetic
that justified the wide measure; form controls retain their compact fixed or intrinsic widths
inside it. A squeezed pane still narrows the page through the shell's existing edge constraints.

`SettingsRowLayoutTests.testGeneralAndUsageUseTheSameSettingsCanvas` drives the real container and
switches between the former two width classes, pinning both to the one shared value. The Settings
render catalogue then reviews the wide regular state and the existing constrained state across
the affected pages.

## 2026-08-18 — a quiet control still owns the surface it becomes

Reported on Git Review's mode chooser: its resting text lined up with the file cards, but the blue
hover plate began outside their shared margin. That was not a bad inset in Review. The shared
`ControlRowView` deliberately subtracted a control's optical padding at the outside edge, while
`ChipView` deliberately keeps that padding in its stable frame so its plate can appear without
reflow. Both rules held independently and together guaranteed the defect: the resting ink aligned,
then the interaction surface revealed the frame that had been pulled outside the row.

The row now aligns the complete, stable interaction silhouette at its edges. A control that is
ink-only at rest still owns the hover, menu, and keyboard-focus surface it can become; that surface
stays within the declared pane margin in every state. Its title or glyph sits inward by the
component's own padding, the same relationship a card has to its content. This is deliberately the
default for a content control row rather than an option Git Review selects, because any later chip
at a row edge has the same state transition.

The same screenshot exposed a second missing ownership layer: six related icon actions arrived as
six unrelated row siblings. `ControlButtonGroupView` now owns a compact internal run and forwards
the row's live metrics to every button. The row's ordinary spacing remains the gap *between*
navigation, text-size, and overflow decisions; `Spacing.tight` is the gap *inside* a related run.
Icon buttons promoted into a content row also take the row's bare-surface hover tier instead of
retaining `.inline`'s stronger lift for a button nested inside another control. Git Review uses the
same icon-button component for overflow, so every right-side target shares press, menu, focus,
theme, and spacing behavior.

## 2026-08-18 — the dimmed ground ends where the surface begins

Reported in the media inspector's thumbnail rail: clicking the transparent spacing between two
thumbnails dismissed the inspector. `InWindowOverlay` deliberately puts its scrim under the whole
covering surface as well as the window chrome above it, because both have to be dimmed. The scrim
then treated every press it received as outside ground. A gap in a descendant's hit testing could
therefore turn a point visibly inside the inspector into a dismissal.

The scrim now holds a weak reference to the surface it was installed with and dismisses only when
the press lies outside that surface's bounds. This is a geometry decision rather than a second hit
test: the descendant hit test is the mechanism that exposed the gap, so asking it again would
repeat the fault. A press routed through from inside is swallowed and left inert; the genuinely
uncovered strip above the surface remains the ordinary click-outside route. The rule belongs to
`InWindowOverlay`, so the media and comparison inspectors share it.
