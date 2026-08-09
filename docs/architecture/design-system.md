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

**The app and an extension have separate localization domains.** Built-in presentation copy
resolves through `L10n` and `Localizable.xcstrings`; shared `SettingsUI` builders localize their
built-in titles and descriptions by default. Extension Settings renderers explicitly disable
that lookup because their strings have already passed through
`ExtensionLocalizationResolver`. That separation prevents an extension base string such as
“General” from accidentally borrowing Threading's translation. Stable page IDs, setting IDs,
command IDs, values, and schemas are never localized.

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
  stale layer colours as well as stale fonts.

Components so far:

| | |
|---|---|
| `ChipView` | A compact chooser that opens a menu. It is a flat pill by default; a material may request the classic square dropdown anatomy: sunken value well, separate raised arrow button, regular control text, and no SF-symbol decoration. The same authorable choice carries through the shared menu presenter, whose compact rows, flat selection band, etched separators, filled arrows, edge attachment, and hard panel edge complete the control instead of leaving a modern popover under a period button. |
| `CodeContextPreviewView` | The bounded diff-shaped context above a code-comment field. It keeps two neighbouring rendered rows around an ordinary target, preserves additions/removals and line numbers, and marks every target row with the theme's selection surface plus a leading `›` so the distinction survives without colour. The presentation model draws at most ten code rows; a larger selection retains both ends around one counted omission row, while the attachment still carries the complete selected excerpt. |
| `ConversationContextRailView` | The compact reference/comment receipts shared by the Chat composer and sent-message transcript. It groups a large batch into quiet count chips, then uses the themed menu for inspection, removal, re-reference, and comment actions. |
| `ThemedSegmentedControl` | Two or three fixed choices with all of them on screen: a track at `controlResting` with the selected segment lifted to `controlHover`. Built as a container of small `ThemedControl`s, the same shape as `ThemedTabStripView`, so each segment inherits hover, focus and its `.radioButton` role rather than one element re-deriving all three for parts of itself that are not views. An unselected segment answers the pointer in *ink* rather than taking a third fill step, because the scale has two control fills and a third invented here is how a scale stops being a scale. Arrow keys walk the run and take the selection with them; the ends hold rather than wrap. |
| `PromptView` | A rounded container holding a growing text view and its submit control, as one input. |
| `ThemedControl` | The base for a control that draws itself from the theme. |
| `ThemedToggle` | A drop-in `NSSwitch` whose on-track is the theme's accent. `material.toggle_style` may instead select the compact ON/OFF hardware latch; behavior, target/action, keyboard access, and its checkbox accessibility contract stay identical. |
| `ThemedCheckbox` / `ThemedRadioButton` | Binary and mutually-exclusive option marks with their own focus, accessibility, disabled, and period geometry. Win98's named family uses a 13px square tick field and the pinned 98.css 12×12 indexed pixel radio sprite with a separate four-pixel dot, while modern materials retain the standard accent marks. |
| `ThemedPopUp` | A drop-in `NSPopUpButton`, button included and dropdown excepted. |
| `ThemedButton` | A drop-in `NSButton`: bordered, plain, or prominent — `emphasis` names those three as primary/secondary/tertiary, `buttonStyle.primaryTreatment` decides whether a primary is filled, outlined, or a classic raised default action, and `shortcut` draws the chord it answers to on its own face. `buttonStyle.titleRendering: pixel_5x6` selects the clean-room one-bit display alphabet for supported titles; a title containing any unsupported localized character stays whole and falls back to the scalable font. |
| `ThemedTextField` | A drop-in editable `NSTextField`, bezel drawn rather than stock. `Design.Size.fieldHeight`, its own step: it borrowed `chipHeight` for as long as a field was "a chip you can type in", and a chip holds a word at rest where a field holds a caret. With a 2pt rule on each side, 26 left twenty points inside for a 13pt face — about three points of air — and the text read as wedged against the border. The two fields placed by frame rather than by intrinsic size (`TextPromptDefaults.fieldHeight`, `SidebarDefaults.renameFieldHeight`) restate the same token. |
| `ThemedSearchField` | The same field with a magnifier, replacing `NSSearchField`. |
| `SearchMatchLabel` | The other half of a search field: a line of text that says which of its own words the query accounts for. **Two signals, always both** — the matched run takes its role's `emphasized` weight *and* `Design.Surface.searchMatch`, an accent held at `Opacity.searchMatchGround` behind it. Weight alone vanishes in a list where several rows matched; a tint alone is the first thing Differentiate Without Colour takes away. It is a component rather than a call to `NSTextField.label(attributed:)` because an attributed string freezes its fonts and inks and `AppThemeRefresh`'s sweep re-resolves a *recorded role*, which it cannot reach inside — so this rebuilds on `AppThemeDidChange`, the same wiring `ThemedTextField`'s placeholder carries. `SearchTextMatch` is where "a query landed here" is decided, and filters may read its `comparisonOptions` so a result cannot be admitted by a more forgiving spelling than the mark uses. Its second rule is the one to know: **a token containing the whole line marks all of it**, which is what makes a row showing eight characters of a session id answer honestly to a pasted thirty-six-character one. The settings sidebar deliberately stays simpler: it filters its page destinations live and leaves the pane already being read in place until a destination is chosen. |
| `SemanticSceneView` | A bounded semantic visualization drawn from normalized marks. It is intentionally not a named chart or extension-specific tree: rectangles, rounded rectangles, and ellipses cover treemaps, heatmaps, bars, timelines, scatter plots, and bubbles. Each mark is a native accessible element and, when actionable, a `ThemedControl` with pointer, keyboard, hover, focus, enabled, and selected states. Callers supply semantic colour roles; the design system owns every pixel. |
| `ThemedSpinner` / `ThemedProgressBar` | `NSProgressIndicator`, in the theme's accent. A spinner nested in a host-painted emphasized selection takes that ground's label ink instead, so the accent does not draw invisibly on the accent. |
| `ThemedScroller` | AppKit's live scrollbar value and tracking with two authored presentations. `automatic` draws a modern proportional thumb/track from the correct ink source and owns SwiftTerm's otherwise-missing overlay fade; System delegates to AppKit. A named period family owns persistent legacy geometry, arrow hit regions and placement, track relief or stipple, and the era's thumb/grip — including Aqua gel — while continuing to use the normal `NSScroller` action path. |
| `ThemedScrollView` | An `NSScrollView` that starts transparent — the stock one paints a system surface — and installs themed vertical and horizontal scrollers without enabling either. A period scroller forces legacy-width space because its arrows are permanent furniture. A material may move the vertical scroller to the leading edge; layout mirrors AppKit's reservation. The project tree opts into `.sidebarNavigator`, which resolves an authored fill/bevel and insets the document inside its edge; every other call site stays transparent. A nested horizontal-only viewport opts into `forwardsVerticalScrollToAncestor`, so code and tables do not trap a conversation's vertical gesture. |
| `ThemedTextView` | An `NSTextView` in theme colours; `.scrolling()` replaces `scrollableTextView()`. |
| `ThemedTableRowView` | Every list's row, including the lists that never say so (`ThemedTableRowDefaults`). It draws selection — held back to the ink it contains under a style, handed to AppKit under System — and any *other* plate a row needs, today `isDropTarget`. Such a plate takes **the selection's own silhouette**, which is not always ours: under System an inset-style table pads its selection 10 points in from the row (`systemInsetStylePadding`) while our path stops a hairline in, so a wash drawn from `selectionPath` ran the full width of a list whose selection did not, and one drawn from the *cell* — inset further still — stood as tall as the selection and visibly narrower. Neither number is AppKit's to publish, so the pin is a pixel comparison of the two plates as drawn (`testTheDropWashTakesTheSelectionsOwnShape`). |
| `ThemedTableView` / `ThemedOutlineView` | Tables that start transparent, replacing the system background. A row's secondary click — and accessibility's "show menu", its pointerless twin — is *reported* (`onContextMenu`, with the row under the gesture and the anchor it carries) rather than answered with an `NSMenu`, so the host presents an app-owned dropdown; the two classes restate that hook rather than share it, because `NSOutlineView` is already an `NSTableView`. A list that draws its own drop affordance instead of AppKit's also needs `onDraggingExited`: a drag leaving or ending is told to the *view* and to no delegate method, so without it the affordance stays lit on the last row the pointer crossed. |
| `ThemedTableHeaderView` | A semantic-role table header that retains AppKit resizing and tracking. |
| `ThemedTableRowView` | The row a list is *selected* in, handed back from `rowViewForRow:`/`rowViewForItem:`. Fills with `Design.Surface.selection` — the accent held back far enough that the row's own label tiers still read over it, so a themed list needs no second set of inks — at the theme's control corner, inset a hair so two selected rows read as two. Under **System** it defers to `super`, keeping AppKit's own highlight. Not the sidebar's row: `SidebarHoverRowView` fills with the accent at full strength because the selected session is the window's subject. |
| `SeparatorView` | A hairline rule, replacing `NSBox(boxType: .separator)`. |
| `ThemeSwatchView` | A palette chip; the one place `NSColorWell` still lives. |
| `ThemedSplitView` | An `NSSplitView` whose divider is measured against the window backdrop on every ground, stepping up to the theme's border on chrome or neutral ink over an unrelated terminal palette when its rule would disappear, and weighed by the theme's rule width rather than AppKit's fixed hairline. |
| `ThemedSurfaceView` | A pane's ground, and the one view that re-resolves its fill on a *system* light/dark switch. |
| `SidebarBackdropView` | The sidebar's ground: the platform's sidebar material under the identity theme, an opaque themed surface under a style — plus the gradient and image layers a style's `SidebarStyle.Background` states, every frozen layer colour restated per apply. |
| `ThreadingMarkView` | The Threading mark drawn live from `ThreadingMarkGeometry` (the same normalized silhouette the app icon and the SVG state): brand threads under System, the theme's accent held legible under a style, and a one-shot `playDrawIn()` that strokes the shield, stitches the six strands and lands the core. Its opt-in particle presentation samples that same geometry into individually tintable points and offers Weave, Breathe and Orbit cadences; no particle layer is built for passive marks, no cadence runs at rest, and none is constructed under Reduce Motion. Decorative; the brand row beside it carries the accessible name. |
| `SidebarBrandView` | The sidebar's brand row: the mark (or a theme's own logo, or nothing) beside the wordmark, a `MorphingTitleLabel` so a chrome that renames the row morphs it. Self-wired to `AppThemeDidChange` and the appearance flip; one accessibility element carrying the brand's name. |
| `ToolbarButtonGroupView` | Related toolbar actions as one item, so their spacing is ours rather than `NSToolbar`'s. |
| `SplitIconButtonView` | Two actions on **one** plate: a press, and a chevron welded to it that offers the other ways to take it — the pane header's Open in control. Its counterpart above is the right container for buttons that act on different things; this is for two halves of one thing, which read as an icon and an unrelated chevron the moment they are spaced apart. The surface is drawn once, here, and the halves draw none (`ThemedIconButton.drawsSurface`): a raised half fills *inside* the plate's silhouette, clipped to it, so the outer end keeps the plate's corner and the join is a straight edge that exists only under the pointer. Nothing is drawn between them at rest. The halves are deliberately unequal (`Design.Size.splitMenuWidth`) — the press is the point, the chevron the exception. See [`external-apps.md`](external-apps.md). |
| `WorkingOrbView` | The dotted "working" orb, tinted with the accent — the theme boundary for the `ThinkingOrbs` view. |
| `AgentActivityBeamView` | The breathing border ring pinned over both composers — the theme boundary for `BorderBeamKit`, and the whole visual policy: one working agent lights the ring at 30% in mono, each additional agent adds 10% to a cap of 1, and it turns colorful while any working session runs at the top of its provider's reasoning ladder. System theme only — a styled theme (retro chrome especially) states its own idea of glow, so anything else removes the ring outright rather than fading it. Decorative by contract: `hitTest` nil, no accessibility elements, and under Reduce Motion it renders a genuinely static frame (the host's paused mode), not an animation drawing identical frames. Hosts feed it `AgentWorkload` from `AgentWorkloadDidChange`; see [`dependencies.md`](dependencies.md) and [`session-activity.md`](session-activity.md). |
| `ThemedTabItemView` | **Every** tab: the display pane's strip, the settings sidebar, and the toolbar's active page. A middle-button click closes a closable tab on release without selecting it first; dragging away cancels, and other auxiliary buttons keep their own meaning. |
| `ThemedTabStripView` | **Every** horizontal run of those tabs: the scroll-not-shrink overflow, the clipped-edge fade, chip spacing, and drag-to-reorder, stated once. Chips are reused by id — a rename morphs, a drag survives its own re-render. Its live `bandHeight` is `PaneHeaderView.bandHeight`: tab, equal `Spacing.small` margins, then the theme's structural rule, so a heavy Bauhaus separator cannot consume the lower margin. Hosts hand it items and get selection/close/reorder back; a `chipDecorator` lets the display pane keep its extension slot around each chip without this component knowing extensions exist. Every pointer capability has a pointerless twin: the chip's secondary-click menu (also reached via accessibility "show menu") carries the standard closes (`TabHosting.standardTabEntries` — Close Tab / Close Other Tabs / Close Tabs to the Right / Close All Tabs), Move Left/Right, and the cross-pane moves — a rule, not a courtesy, for anything this strip grows next. While the reorder gesture holds a chip it is `isLifted`: its translucent fill flattens over `InkSource.ground` so the neighbour it crosses cannot show through it. A drag can also *leave*: `externalDropTarget`/`onDropOut`/`onDragEnded` let the window offer another strip's band as the drop, the chip dimming to `Design.Opacity.dragAway` while it would land, the receiving strip washing as a drop target (`isDropTarget`), and the slot named by the same midpoint rule as the reorder (`insertionIndex(forWindowPoint:)`) — and a lone chip may begin a drag exactly when that wiring exists, since with one tab there is nothing to reorder but still somewhere to go. A host that pins **both** of the strip's edges says so with `fillsHostWidth`: the default `.defaultHigh` hugging is what lets a control placed *after* the tabs follow them, and in a host that has no such control it is a *maximum on the host* — it capped the display panel at its own tab titles (see [`mcp-and-display.md`](mcp-and-display.md)). |
| `ThemedDisclosureRow` | The header of a collapsible run of rows — the settings kit's folded cards (`SettingsUI.disclosureCard`/`disclosureRow`) are built on it. A real `ThemedControl`: whole-row click with slip-off cancel, Space/Return, focus ring, hover lift, pointing-hand cursor, and a `disclosureTriangle` accessibility role whose value is the expansion state. The chevron leads in a fixed slot so every header's title starts on one line, and it re-tints at draw time so a live theme switch reaches it. The caller's interactive accessory (a toggle, a Remove All button) stays a **sibling**, never a child: the row is one accessibility element, and a control nested inside it would vanish from the accessibility tree. Replaced Storage's hand-rolled click-gesture fold, which no keyboard or assistive technology could operate. Setting `isExpanded` does not fire `onToggle`, so an owner restores state without re-entrancy. |
| `ThemedIconButton` | **Every** icon-only button: toolbar actions, a tab's `×`, a sidebar row's `⋯`. The role states a *slot* (layout: what the padding is measured from) and a *point size* (optics: what the symbol is configured at) — see the 2026-07-31 note for why those are two numbers. `setImage` is its one documented exception to "a symbol": artwork whose silhouette is not ours — an installed application's own icon, which is what the header's Open in control wears (see [`external-apps.md`](external-apps.md)). Foreign artwork is capped to the slot (`GlyphView.slot`); `setSymbol` clears the cap and configures to fit. |
| `GlyphView` | A tinted glyph on the device pixel grid — `NSImageView` minus the fractional placement, inside `ThemedIconButton` and `ThemedTabItemView`. A symbol's natural size is fractional by design, so an image view centres it at a half-point offset: slight softness at 2×, a smeared stroke at 1×. This view centres the same rect and then `backingAlignedRect`s it (inward — nearest can push an edge past `bounds`, and a view clips its own drawing) before handing it to `TemplateImageDrawing`. Decorative; the control around it carries the name. |
| `ThemedFileIconView` | The File pane's one icon renderer. System keeps the path's native Finder artwork; authored themes use a semantic SF Symbol and theme roles, without paying LaunchServices for artwork they will not draw. It classifies from path metadata only, aligns either renderer to the device pixel grid, and switches live between them. |
| `PaneFooterView` | The bottom band of a pane: hairline, band height, corner-aware insets, controls aligned by their ink (`OpticalInsetProviding`). |
| `PaneHeaderView` | The footer's mirror at a pane's top. Its live height is the content pane's header-strip measure (`PaneHeaderDefaults.height` reads it): row, equal top and bottom air, then the theme's rule. It remeasures on a theme change, so the two panes' separators land on one line without using their ink as spacing. |
| `ControlRowView` | Those two bands' rule for a row that belongs to **content** rather than to chrome: a leading run, a trailing run, one shared centreline, and one shared height. The height is the row's to state and the members' to take — every `ControlRowMember` (`ChipView`, `ThemedButton`, `ThemedIconButton`, `ThemedSegmentedControl`) is handed a `ControlRowMetrics` and resizes to it, glyph included, and only a row can make one. `.compact` resolves to the material's `choiceHeight`, so a style switch relevels the whole row rather than half of it. The runs are pinned to opposite edges with a real inequality between them, and the outermost **visible** control on each side is aligned by ink. See [2026-08-05 below](#2026-08-05--a-row-of-controls-had-no-owner). |
| `WindowTitleBandView` | The title band a chrome-takeover theme draws across the window's top (`WindowChromeStyle`, see [`window-chrome.md`](window-chrome.md)): active/inactive gradients and texture, full-width or compact leading-tab shape, optional app icon, leading or centred upright/italic title, trailing/split/bookended authored caption controls, and the titlebar's own gestures — a press drags the window, a double-click performs the user's System Settings choice. Application commands stay in `WindowCommandBandView` below. Not a control (its `interactiveComponent` exception records why); its buttons are. |
| `WindowCommandBandView` | The button-face row beneath an app-drawn title bar, hosting the sidebar/history controls the native toolbar held. It keeps application commands out of title-bar geometry and uses ordinary chrome ink. Collapses with the title band in native dress. |
| `WindowChromeButton` | A takeover window's Window menu/close/minimize/zoom/depth, one component for every role and glyph family (`squares`, `platinum`, `beos`, `openstep`, `irix`, `amiga`, `plain`) — the tab strip's "every" lesson applied to period chrome. Calls the *semantic* window operations, because the `perform*` forms animate a standard button a frameless window does not have and refuse outright; zoom follows the window and becomes Restore while maximized, Window menu opens app-owned `ThemedMenuPresenter` rows, and Workbench Depth orders the window behind its peers. Full `ThemedControl` contract: keyboard, focus ring, AX press. |
| `WindowChromeFrameView` | The border around a takeover window's edges, in the theme's border role with the bevel inside when the material states one. A shaped title tab leaves transparent shoulders and seats the rectangular body beneath it. Draws nothing in native dress, where the terminal-palette backdrop showing through the titlebar strip is load-bearing. |
| `PairingCodeImage` | The Remote Access QR code, drawn rather than scaled up from `CIQRCodeGenerator`: Chromium's geometry (dots at 0.8 of the pitch, rounded finder patterns), a four-module quiet zone Core Image does not supply, and a plate and ink carrying the accent's hue at a stated saturation. The only artwork here a *machine* has to read, so it is tested by decoding the render, not by asserting on the constants that drew it. |
| `ToastView` / `ToastPresenter` | A receipt for something already done, floating above a pane's footer, with the way back on it. The view is one message, one optional detail line, one `ThemedButton` carrying the way back and one `ThemedIconButton` carrying the way out; the presenter owns everything that is about *time* — one band at a time, a six-second dwell (a request may ask for longer, and the one an agent raises does), the clock pausing while the pointer is on it, and the VoiceOver announcement a surface that takes no focus would otherwise never make. The pointer **pauses** the dwell rather than refunding it: the timer's remaining interval is read before it is cancelled and rescheduled when the pointer leaves, because time spent reading a receipt under the pointer is that receipt's time being used — restarting meant a pointer crossing the band en route somewhere else bought it a whole second dwell, and a band leant on twice never had to leave. The dwell is also *drawn*: the band's own bottom border, in the accent, drains as the clock runs, freezes with it under the pointer, and carries on from where it froze — at the same pace, since the line's remainder and the timer's are read at one instant. It is a layer animation for `ThemedSpinner`'s reason, it lives inside the band's existing bottom inset so showing the clock costs no height, and Reduce Motion removes it rather than freezing it full — a still rail is a band claiming a countdown it is not showing. **It rides the edge rather than floating in the padding**: held a step in from three sides it was a rule between nothing and nothing, read as an underline belonging to the way back under it. Pinned flush, masked to the band's own silhouette so its ends follow the corners, and weighed at `Design.Radius.border` like every other rule the theme draws, it is a second edge on top of the first — which is also why it needs no track: what it leaves behind as it drains is the band's own border. A layer draws its border above its sublayers, so the line sits one rule *inside* the edge rather than on it, or the band's own border would paint it out. The band's words argue for **no** width at all (`ToastDefaults.contentWidthPriority`, hugging and compression both): pinned inside a host, a wrapping label's 750 outranked the sidebar's own holding priority, and the column jumped wider as a receipt arrived and back again as it left. The presenter's own fill pin sits *below* every pane's holding priority for the mirror-image jump (`ToastDefaults.fillPriority`): in a sidebar dragged wider than the band's required `maxWidth` cap the pin cannot be satisfied by the band, and at `defaultHigh` the solver satisfied it with the *column* instead — the sidebar snapped in to cap-plus-insets as the receipt arrived and sprang back when it left. Anything **waiting** behind the band is drawn rather than merely queued: one `ToastStackEdgeView` per waiting receipt, capped at two, each the same card a step up and a step in on both sides, pinned to the band's own top *and* bottom so no theme's corner radius becomes a constant here — see the queue paragraph below. The **way out** is a ✕ in the corner and a throw across the band, and the two are one thing: see the paragraph below for why the mark is never hidden until hovered and why the gesture is only ever an accelerator for it. Two layout rules follow the ✕ and both were bugs first: the message stops at the mark while the detail runs the full width beneath it, so each wrapping label is told **its own** width rather than one figure derived from the band (handed the band's, the message believed it had 26 points it did not and a clipped receipt read *Archived “Refactor* with the session's name gone); and each label's height is measured with `cell.cellSize(forBounds:)` rather than taken from `intrinsicContentSize`, because the two disagree about whether a string wraps at a width it very nearly fits — under Claymorphism's rounded face the same receipt reported 175 points on one line inside the 178 it had while the cell typeset two, and the band clipped the second. |
| `ThemedPopover` | Every app-owned anchored transient surface. It owns the themed body and arrow, preferred-edge placement with screen-edge flip and clamp, parent-window movement, live theme changes, transient/semitransient dismissal, Escape, accessibility announcement, and focus return. Content remains an ordinary view controller. Native application and context menus do not use it. The chrome is **one closed outline** — body and arrow walked as a single path, filled once and stroked once (`ThemedPopoverLayout.outline`); drawing them as two paths and repainting their seam erased the tails of the arrow's own sides, a border gap a picture showed and no assertion did (now one does, on drawn pixels). A popover also cannot outlive its owner or its anchor: `deinit` detaches a still-shown panel — a child window its parent *retains*, so a dropped reference otherwise floats forever with its monitors gone — and the next interaction anywhere closes one whose anchor left the window, since a sidebar reload discards rows without a pointer exit. Hover-presented sites drive it through `HoverPopoverScheduler`, whose `Policy` states the site's open dwell, close grace, and whether pointing at the popover itself holds it open — the sidebar's cards dwell and close on exit, the toolbar's usage pill is instant both ways while it shows the native reading and flips to a held policy the moment an extension composes actionable content in, an extension row's detail dwells, grants a grace and holds because it carries actions. Timing is configuration beside the site's other measurements, not four copies of timer code. |
| `ThemedFloatingSurfaceChrome` / `ThemedFloatingGlyphView` | The rectangular and semantic-content halves of that same material grammar for an app-owned card inside another view. The resolver applies the popover style's opaque surface role, edge/bevel, material depth, and density; the glyph view selects SF Symbols or the theme's simple one-bit marks. `GitStatusOverlayView` uses both, so a terminal remains the ground around the card without becoming the card's visual owner. |
| `ThemedAlert` | Every app-owned modal statement, confirmation, choice, error, and text prompt. It owns themed severity, copy, accessory, suppression choice, button hover/press/focus, Return policy, universal Escape, sheet/modal presentation, accessibility, and focus return. `ConfirmationAlert`, `NoticeAlert`, and `TextPromptAlert` remain the semantic policy layer above it. |
| `MediaInspectorView` / `MediaInspectorCanvas` | The in-window inspection surface for visible files. Images use an app-owned renderer with fit/actual/custom zoom, anchored pinch, pan, collection navigation and a thumbnail rail. PDFKit and embedded `QLPreviewView` live only inside `MediaInspectorDocumentView`, a named `SystemChromeBoundary`; System Quick Look is an action-menu fallback rather than the primary route. It installs through `InWindowOverlay`, not by pinning to the content view's top: under a full-size content view that is the top of the window, and this header opened under the traffic lights. It fills with `Design.Surface.elevated`, **not** `ground` — the ground is by definition what the window behind it is already filled with, so in a dark palette the inspector's header simply continued the window's own, and a screenshot of the running app showed the two as one surface. The canvas's focus ring is shown only under keyboard traversal (`KeyboardFocusOrigin`): the inspector hands the canvas focus as it opens, because the arrows, the zoom keys and Escape all belong there, and an unconditional ring drew an accent rectangle around the whole window the moment a thumbnail was clicked. |
| `InWindowOverlay` / `InWindowOverlayHosting` | The one place that decides where a covering surface starts. A window drawing full-size content has no room at `contentView.topAnchor` — the traffic lights float over it — and a takeover dress puts the app's own title and command bands in the same place. The helper asks the window's root for its `overlayArea` guide and falls back to `safeAreaLayoutGuide` for a root that states none (a fixture, the gallery). See [`window-chrome.md`](window-chrome.md); the rule is the panes' "nothing pins to `topAnchor`", arrived at a second time by the transient surfaces. It also installs the **scrim** under that surface, and hands back an `InWindowOverlay.Presentation` owning both: the two views arrive and leave together, where before each session removed its own surface and a wash added beside it would have had to be remembered on the close, the Escape and the replacement path separately. The wash reaches *further* than the surface — `overlayScrimArea`, everything below whatever draws the window's own buttons, which in native dress is the whole content view and in a takeover starts under the app's title band. That difference is the point: the strip the surface has to clear is app-drawn chrome (session tabs, panel toggles, the sidebar's top corner), and left lit it stacked on the surface's own header with a hairline between them and read as one window. A modal may dim a way out of the window; it may not cover one. Clicking the wash runs the same dismissal the close button does — required rather than defaulted at the call site, since a scrim swallows every click it covers. It draws `Design.Surface.overlayScrim`, the one fill here deliberately *not* derived from a theme role: every authored shade in this app is a bevel edge (`#808080` under Windows 98), and a mid-grey wash barely dims a light window while it lifts a dark one. |
| `ImageCompareView` | Two images against each other: a draggable wipe seam (either axis), a crossfade, a pixel difference, and side by side, with per-side captions and a mode chip. The captions are given a band **outside** the images before anything is fitted, never a pill over them: printed on the picture they hid the pixels the comparison exists to show, and at rest they sat exactly where the wipe starts, so reading a label meant scrubbing it out from under. Position carries the mapping — old at the start of the scrub's travel, new at its end, above and below it for the vertical wipe, over each image in side by side — the new side is inked a step darker, and difference names the pair `old → new` centred rather than splitting two titles across edges that mode has no sides for. One scrubbed fraction serves every mode — there is deliberately no slider control: the seam *is* the control (accent-inked, since it is the one thing on the surface asking to be used), fade held at the middle is the onion skin, and both images draw at one shared scale so a resized asset stays visibly resized rather than being normalised into "looks identical". The canvas is a `ThemedControl`: arrow keys nudge the scrub, Space recentres it, and VoiceOver reads it as a slider. The caption's clearance from the surface's edge (`captionMargin`) is a step above the gap under it: equal to the gap, the title sat as close to the border — the focus ring is two points of it — as to the picture it names, and the pair read as one crowded line. The controls row carries one more thing: the button that opens the comparison in `CompareInspectorView`, on wherever the surface is inline, off in the one place it would offer to open what is already open. `hostControls()` hands that row's two controls to a host that will place them itself and stops the surface reserving a row under the canvas — one call rather than two accessors and a flag, because taking the controls and giving up the row are the same act: a host that took them and forgot to detach would leave a chip in two places, and one that detached without placing them would lose the modes entirely. The controls stay wired to the surface they came from; what the host gains is where they sit. The Compare tab uses it to lift them out of its scroll view (see [`mcp-and-display.md`](mcp-and-display.md)). |
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

**Status says whether an agent is working; Activity says where the work has landed.** Sidebar rows
carry status only: the former 3pt repository strip and its expanded hover card were too compressed
for the information and duplicated a surface with more room. The display panel's Activity tab now
places the bounded repository atlas, recent action ribbon, and counts above the real filesystem
tree. Every visible file row states exact reads and edits; a directory states the touched-file and
read/edit totals below it. New paths retain one stable overflow cell in the overview rather than
resorting the map under the pointer.

The implementation stays inside the design boundary: `FileActivityMapView` is the drawing
primitive and `AgentWorkSummaryView` composes only `Design/` controls. The detailed map is one
accessible image with a summarized file count, and its directory/path hover label is supplementary.
The filesystem rows expose spoken read/edit totals as well as their compact labels. Colour is never
the only encoding because reads, edits, overlap and activity categories also differ in shape,
position, or text.

**A translucent glyph tint composites over the ground, not into the artwork.**
`TemplateImageDrawing` filled the symbol `.sourceAtop` inside its transparency layer, which is
right for an opaque tint and wrong for every other one: a template's own artwork is black, so atop
blended the tint *into that black* and a tint below full opacity could never reach the colour it
asked for — white at 70% came out an opaque 70% grey whatever it stood on. Every ink tier below
`label` is an alpha, so that was every secondary glyph in the window quietly drawn dark. `.sourceIn`
keeps the silhouette and replaces its colour, alpha included, leaving the layer to composite it
over the ground the ink was measured against.

**A menu opens on the press; an action fires on the release.** Which of the two a button does is
`ThemedIconButton.presentsMenu`, and the split is not a preference — press-drag-release onto an
item is the platform's menu gesture (`ChipView` and `ThemedPopUp` already present theirs on the
press, and `NSMenu.popUp` is modal, so the button reads as held for exactly as long as its menu is
up). It is also the only *reliable* half. A press that waits for its release depends on AppKit
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

**The click that dismisses a menu lands on a sibling that opens one.** The dropdown's overlay
swallows its dismissing click the way `NSMenu` does — a click on the terminal to let a menu go
must not also type into it — with one exception it owes to hover. Hit testing is what the overlay
takes over; hover is driven by tracking areas, which it cannot silence, so a chip under an open
menu keeps its hover invitation and even widens to its full label. A control that invites the
click must honour it: with the composer's account menu open, clicking the model chip closed one
menu and opened nothing, a dead click on a control that was actively lit. The overlay therefore
resolves what its dismissing click landed on, and when that is a `ThemedMenuOpening` control
(`ChipView`, `ThemedPopUp`, a menu-presenting `ThemedIconButton`) — and not the very control whose
menu is open, whose click stays a toggle-close — it hands the press over, drag and release
included, so the menu moves between siblings the way menu-bar titles have always traded one click.

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

**A surface role is translucent on purpose, and that purpose ends where live content begins.**
`surface` is the base tone at 14%, which is what makes a pill read as a lift off the backdrop
rather than as a patch stuck on it — right for a control on an empty stretch of chrome, wrong for
anything floating over text. The git status card is the one thing in the app that does float over
the pane's own content, and at 14% over a native conversation the agent's answer ran straight
through the branch name; a view-level `alphaValue` for "quiet at rest" thinned the fill along with
it. `WindowBackdrop.opaque(_:)` flattens a role against the ground it will sit on — identical
colour over bare backdrop, no see-through over anything else — and quiet-at-rest belongs on the
card's *contents*, never on the card. A new floating surface takes the same two rules.

Two guards keep it: `MainWindowToolbar.makeOverlayItem` asserts that anything placed in the
toolbar inks from `.backdrop` (the protocol can only say a view *can* be inked, not which ink it
took, now that one component serves both), and `ToolbarChromeRenderTests` pins that the page tab
and the pane tab are the same type rather than comparing two classes' measurements — a test that
could only ever catch drift after it happened, and which passed for a long time over two tabs
that visibly differed.

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
constant. Two edges at most (`ToastDefaults.stackDepth`), whatever the queue's depth: the stack
answers *is this the only one* rather than *how many*, and a count is the one thing it could not
honestly report — the bound drops from the front of the queue when a burst overruns it. It says
nothing to VoiceOver, which is read each receipt as it arrives.

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

How a band leaves is the request of the departure rather than of the presenter (`ToastDeparture`):
a receipt that was pushed sideways must not then drop back down the way it arrived, since the
throw is half an animation the hand already performed and the departure owes it the other half.
Only the band travels; the deck of waiting edges behind it was not thrown and fades where it
stands. The queue is untouched by *how* a band went — throwing one hands the pane to whatever was
waiting exactly as running out of time does, so a burst can be walked through card by card.

**A card floating over a list takes the pointer, not only the press.** The band swallows its own
`mouseDown` so a click cannot fall through to the row it is covering, and the pointer needed the
same rule for a reason that is not visible in either file: `NSTrackingArea` reports crossings of a
*rectangle* and knows nothing about what is drawn over that rectangle, so both views are sent
`mouseEntered` whichever one a click would reach. Resting on a receipt therefore lit the sidebar
row hidden behind it — and because the row's highlight and the band happen to be inset from the
column by the same 10 points (`SidebarRowDefaults.hoverHighlightInsetX`, which follows the stock
source list's selection, and `ToastDefaults.hostInset`, which is `Design.Spacing.medium`), that 6%
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
  its 12pt status mark, then expands the trailing slot to two targets before the `...` and archive
  actions fade in. On exit it collapses only after they have faded out, so a visible target never
  overhangs the parent that hit-tests it. The title yielding while two controls are on screen is
  honest; permanently truncating every title for an invisible second target was not. The hover
  transition re-lays out only the recycled row under the pointer, so session cardinality never
  reaches that path.

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
  indent. Where the room is genuinely the host's — the toolbar holds the page tab to
  `SessionTitleDefaults.minWidth` — the title is the view that absorbs it (`.fill` distribution,
  lowest hugging), so the × keeps the trailing inset instead of the slack landing after it.

**One silhouette per strip.** `TabAppearance` states a tab's geometry and type scale in one
place, because the app draws tabs in two views that cannot share a class: the pane's strip reads
the chrome's roles, while the toolbar's active-page tab sits on the terminal backdrop and inks
itself from there (`BackdropOverlay`). They differ by that alone and had drifted in everything
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
pointer is anywhere in the chain. Callers still depend on a named boundary rather than
constructing their chrome.

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

- **`withAlphaComponent` replaces alpha, it does not scale it.** Dimming a disabled button
  against a resting surface that is *already* translucent — Cyberpunk holds its neon at 10% —
  made the disabled controls the loudest things on the page. Resolve, then multiply.
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

**Under System it hands the highlight straight back**, the same rule `SidebarHoverRowView`
follows — the stock accent, its emphasized and unemphasized strengths and its vibrancy are worth
more than consistency with a theme that is trying to look like the platform.

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
- **The margins align by ink, and only to what is on screen.** `PaneHeaderView`'s
  `OpticalInsetProviding` rule, plus the correction Git Review had written by hand in
  `setBackVisible`: a hidden member is not on the margin, so the inset comes from the outermost
  *visible* control. Aligning to a hidden five-point inset indents the chip beside it five points
  past the cards below — which is exactly the bug the one pane that had thought about it was
  patching locally.
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

**And `ListSelectionStrengthTests` had never run.** `Tests/ThreadingTests` is not a synchronized
folder, and the file was never registered in `project.pbxproj` — so the suite guarding this rule
compiled nowhere and reported nothing, for both of the sightings it was written after. That is the
silent failure CLAUDE.md warns about, and it is why "the tests pass" was not evidence here.
`ThemedTableRowSelectionTests` was in the same state and is now registered too. Fourteen other
test files are still missing from the target.

The new test is the one that fails on the old code: demote every row and assert the strength
*immediately*, with no draw of any kind in between — which is the only form of the rule the
running app ever exercises.
