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
- **A detached tree is in no window, so the sweep never reaches it.** A cached settings page and
  a retained conversation take `AppThemeRefresh.repaint` on attach for that reason — the same
  applies to any surface the app keeps alive off-screen, and it covers stale layer colours as
  well as stale fonts.

Components so far:

| | |
|---|---|
| `ChipView` | A flat pill that opens a menu. The standard way to offer a choice — see the chip/segment rule below. |
| `ThemedSegmentedControl` | Two or three fixed choices with all of them on screen: a track at `controlResting` with the selected segment lifted to `controlHover`. Built as a container of small `ThemedControl`s, the same shape as `ThemedTabStripView`, so each segment inherits hover, focus and its `.radioButton` role rather than one element re-deriving all three for parts of itself that are not views. An unselected segment answers the pointer in *ink* rather than taking a third fill step, because the scale has two control fills and a third invented here is how a scale stops being a scale. Arrow keys walk the run and take the selection with them; the ends hold rather than wrap. |
| `PromptView` | A rounded container holding a growing text view and its submit control, as one input. |
| `ThemedControl` | The base for a control that draws itself from the theme. |
| `ThemedToggle` | A drop-in `NSSwitch` whose on-track is the theme's accent. |
| `ThemedPopUp` | A drop-in `NSPopUpButton`, button included and dropdown excepted. |
| `ThemedButton` | A drop-in `NSButton`: bordered, plain, or accent-filled — `emphasis` names those three as primary/secondary/tertiary, and `shortcut` draws the chord it answers to on its own face. |
| `ThemedTextField` | A drop-in editable `NSTextField`, bezel drawn rather than stock. `Design.Size.fieldHeight`, its own step: it borrowed `chipHeight` for as long as a field was "a chip you can type in", and a chip holds a word at rest where a field holds a caret. With a 2pt rule on each side, 26 left twenty points inside for a 13pt face — about three points of air — and the text read as wedged against the border. The two fields placed by frame rather than by intrinsic size (`TextPromptDefaults.fieldHeight`, `SidebarDefaults.renameFieldHeight`) restate the same token. |
| `ThemedSearchField` | The same field with a magnifier, replacing `NSSearchField`. |
| `SearchMatchLabel` | The other half of a search field: a line of text that says which of its own words the query accounts for. **Two signals, always both** — the matched run takes its role's `emphasized` weight *and* `Design.Surface.searchMatch`, an accent held at `Opacity.searchMatchGround` behind it. Weight alone vanishes in a list where several rows matched; a tint alone is the first thing Differentiate Without Colour takes away. It is a component rather than a call to `NSTextField.label(attributed:)` because an attributed string freezes its fonts and inks and `AppThemeRefresh`'s sweep re-resolves a *recorded role*, which it cannot reach inside — so this rebuilds on `AppThemeDidChange`, the same wiring `ThemedTextField`'s placeholder carries. `SearchTextMatch` is where "a query landed here" is decided, and filters may read its `comparisonOptions` so a result cannot be admitted by a more forgiving spelling than the mark uses. Its second rule is the one to know: **a token containing the whole line marks all of it**, which is what makes a row showing eight characters of a session id answer honestly to a pasted thirty-six-character one. The settings sidebar deliberately stays simpler: it filters its page destinations live and leaves the pane already being read in place until a destination is chosen. |
| `SemanticSceneView` | A bounded semantic visualization drawn from normalized marks. It is intentionally not a named chart or extension-specific tree: rectangles, rounded rectangles, and ellipses cover treemaps, heatmaps, bars, timelines, scatter plots, and bubbles. Each mark is a native accessible element and, when actionable, a `ThemedControl` with pointer, keyboard, hover, focus, enabled, and selected states. Callers supply semantic colour roles; the design system owns every pixel. |
| `ThemedSpinner` / `ThemedProgressBar` | `NSProgressIndicator`, in the theme's accent. |
| `ThemedScroller` | AppKit's scrollbar behavior, geometry, hit testing and overlay/legacy preference, with its thumb and track drawn from the correct ink source under authored themes. System delegates both draw hooks back to AppKit. Outside an `NSScrollView` — SwiftTerm's, which nothing else fades — it owns its own overlay fade. |
| `ThemedScrollView` | An `NSScrollView` that starts transparent — the stock one paints a system surface — and installs themed vertical and horizontal scrollers without enabling either. A nested horizontal-only viewport opts into `forwardsVerticalScrollToAncestor`, so code and tables do not trap a conversation's vertical gesture. |
| `ThemedTextView` | An `NSTextView` in theme colours; `.scrolling()` replaces `scrollableTextView()`. |
| `ThemedTableView` / `ThemedOutlineView` | Tables that start transparent, replacing the system background. |
| `ThemedTableHeaderView` | A semantic-role table header that retains AppKit resizing and tracking. |
| `SeparatorView` | A hairline rule, replacing `NSBox(boxType: .separator)`. |
| `ThemeSwatchView` | A palette chip; the one place `NSColorWell` still lives. |
| `ThemedSplitView` | An `NSSplitView` whose divider is inked against the window backdrop, not the chrome's ground, and weighed by the theme's rule width rather than AppKit's fixed hairline. |
| `ThemedSurfaceView` | A pane's ground, and the one view that re-resolves its fill on a *system* light/dark switch. |
| `SidebarBackdropView` | The sidebar's ground: the platform's sidebar material under the identity theme, an opaque themed surface under a style — plus the gradient and image layers a style's `SidebarStyle.Background` states, every frozen layer colour restated per apply. |
| `ThreadingMarkView` | The Threading mark drawn live from `ThreadingMarkGeometry` (the same normalized silhouette the app icon and the SVG state): brand threads under System, the theme's accent held legible under a style, and a one-shot `playDrawIn()` that strokes the shield, stitches the six strands and lands the core — constructing nothing at all under Reduce Motion. Decorative; the brand row beside it carries the accessible name. |
| `SidebarBrandView` | The sidebar's brand row: the mark (or a theme's own logo, or nothing) beside the wordmark, a `MorphingTitleLabel` so a chrome that renames the row morphs it. Self-wired to `AppThemeDidChange` and the appearance flip; one accessibility element carrying the brand's name. |
| `ToolbarButtonGroupView` | Related toolbar actions as one item, so their spacing is ours rather than `NSToolbar`'s. |
| `WorkingOrbView` | The dotted "working" orb, tinted with the accent — the theme boundary for the `ThinkingOrbs` view. |
| `ThemedTabItemView` | **Every** tab: the display pane's strip, the settings sidebar, and the toolbar's active page. A middle-button click closes a closable tab on release without selecting it first; dragging away cancels, and other auxiliary buttons keep their own meaning. |
| `ThemedTabStripView` | **Every** horizontal run of those tabs: the scroll-not-shrink overflow, the clipped-edge fade, chip spacing, and drag-to-reorder, stated once. Chips are reused by id — a rename morphs, a drag survives its own re-render. Its `bandHeight` is `PaneHeaderView.bandHeight`, so every strip's hairline lands on the panes' shared line. Hosts hand it items and get selection/close/reorder back; a `chipDecorator` lets the display pane keep its extension slot around each chip without this component knowing extensions exist. Every pointer capability has a pointerless twin: the chip's secondary-click menu (also reached via accessibility "show menu") carries the standard closes (`TabHosting.standardTabEntries` — Close Tab / Close Other Tabs / Close Tabs to the Right), Move Left/Right, and the cross-pane moves — a rule, not a courtesy, for anything this strip grows next. While the reorder gesture holds a chip it is `isLifted`: its translucent fill flattens over `InkSource.ground` so the neighbour it crosses cannot show through it. A drag can also *leave*: `externalDropTarget`/`onDropOut`/`onDragEnded` let the window offer another strip's band as the drop, the chip dimming to `Design.Opacity.dragAway` while it would land, the receiving strip washing as a drop target (`isDropTarget`), and the slot named by the same midpoint rule as the reorder (`insertionIndex(forWindowPoint:)`) — and a lone chip may begin a drag exactly when that wiring exists, since with one tab there is nothing to reorder but still somewhere to go. A host that pins **both** of the strip's edges says so with `fillsHostWidth`: the default `.defaultHigh` hugging is what lets a control placed *after* the tabs follow them, and in a host that has no such control it is a *maximum on the host* — it capped the display panel at its own tab titles (see [`mcp-and-display.md`](mcp-and-display.md)). |
| `ThemedIconButton` | **Every** icon-only button: toolbar actions, a tab's `×`, a sidebar row's `⋯`. `setImage` is its one documented exception to "a symbol": artwork whose silhouette is not ours — an installed application's own icon, which is what the header's Open in control wears (see [`external-apps.md`](external-apps.md)). It clears the view's `symbolConfiguration` first, because `NSImageView` applies that to *whatever* image it is handed and a configuration sized for an 11pt glyph draws a rendered app icon as nothing at all; `setSymbol` puts it back. |
| `PaneFooterView` | The bottom band of a pane: hairline, band height, corner-aware insets, controls aligned by their ink (`OpticalInsetProviding`). |
| `PaneHeaderView` | The footer's mirror at a pane's top. Its height is the content pane's header-strip measure (`PaneHeaderDefaults.height` reads it), so the two panes' hairlines land on one line. |
| `PairingCodeImage` | The Remote Access QR code, drawn rather than scaled up from `CIQRCodeGenerator`: Chromium's geometry (dots at 0.8 of the pitch, rounded finder patterns), a four-module quiet zone Core Image does not supply, and a plate and ink carrying the accent's hue at a stated saturation. The only artwork here a *machine* has to read, so it is tested by decoding the render, not by asserting on the constants that drew it. |
| `ToastView` / `ToastPresenter` | A receipt for something already done, floating above a pane's footer, with the way back on it. The view is one message, one optional detail line and one `ThemedButton`; the presenter owns everything that is about *time* — one band at a time, a six-second dwell (a request may ask for longer, and the one an agent raises does), the clock stopping while the pointer is on it, and the VoiceOver announcement a surface that takes no focus would otherwise never make. |
| `ImageCompareView` | Two images against each other: a draggable wipe seam (either axis), a crossfade, a pixel difference, and side by side, with per-side captions and a mode chip. The captions are given a band **outside** the images before anything is fitted, never a pill over them: printed on the picture they hid the pixels the comparison exists to show, and at rest they sat exactly where the wipe starts, so reading a label meant scrubbing it out from under. Position carries the mapping — old at the start of the scrub's travel, new at its end, above and below it for the vertical wipe, over each image in side by side — the new side is inked a step darker, and difference names the pair `old → new` centred rather than splitting two titles across edges that mode has no sides for. One scrubbed fraction serves every mode — there is deliberately no slider control: the seam *is* the control (accent-inked, since it is the one thing on the surface asking to be used), fade held at the middle is the onion skin, and both images draw at one shared scale so a resized asset stays visibly resized rather than being normalised into "looks identical". The canvas is a `ThemedControl`: arrow keys nudge the scrub, Space recentres it, and VoiceOver reads it as a slider. |

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
(`NSView`, `NSStackView`, `NSGridView`), labels, chromeless `NSImageView` and contained system
chrome (`NSMenu`, `NSPopover`, `NSAlert`, the file panels) stay allowed — they draw nothing
the theme owns. `config/theme-boundary.json` owns the list; the build and test suite both run
its SwiftSyntax checker, while `.swiftlint.yml` provides fast editor feedback. A class with no
wrapper yet gets one in `UI/Design/` first.

### Confirmations

`NSAlert` stays allowed as contained system chrome, but *asking the user a question* does not.
Every confirmation goes through `ConfirmationAlert` in `UI/Alerts/`, and every one names a case
in `ConfirmationPrompt`.

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

**How long a receipt holds is a fact about who caused it, so it belongs to the request.** The six
seconds are measured from a click: the hand is on the mouse and the eye is on the row that
changed. An agent archiving its own session (see [`sessions.md`](sessions.md)) puts the same band
in the same pane with none of that — the user asked for it a turn ago, in words, and has been
reading something else since — so `ToastRequest.dwell` overrides the presenter's, and that
receipt takes `ToastDefaults.unattendedDwell`. It also names the agent in its message, because a
row that leaves the sidebar on its own is the one report where "what happened" without "who did
it" is the wrong half of the sentence.

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
decision for prompts already routed through it — it says nothing about the 45th raw `NSAlert`.
Banning `NSAlert` would need an exception per OK-only alert; the precise signal is narrower:
*an informational alert never inspects its response*. So `confirmationResponse` reports any read of
`alertFirstButtonReturn` / `alertSecondButtonReturn` / `alertThirdButtonReturn` outside
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

- **Who moves is per placement, and the previews decide.** Seven orbs run at once because
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

**What Return does follows where the send control is** (`PromptView.SubmitPlacement`), because
the two answer the same question and must not disagree:

- **`.inside`** — the glyph in the box's corner. Return submits, Shift/Option-Return breaks the
  line. The shape every chat composer has, and what lets a reply box be multi-line without
  losing the one-key send. The conversation's reply, the commit message, an inspector note.
- **`.outside`** — no glyph; the owner places a button. Return is an ordinary line break and
  ⌘Return sends. The session composer, whose prompt is a *brief* rather than a message: a task
  worth describing is several lines plus a pasted paragraph of context, and Return-sends turned
  each of those breaks into an accidental launch.

⌘Return sends under **both**, handled in the text view rather than only by a button, because
the chord belongs to the field — a prompt is used with no button beside it at all.

The two halves move together on purpose. A glyph cannot name a chord, so a composer that took
the send away from Return had to put it somewhere with room to say `⌘↩` — which is exactly what
`ThemedButton.shortcut` draws.

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
a keyboard-focusable control: click it, or focus it and press Space/Return, to hand its path to
the system Quick Look panel. Its corner remove button remains a separate action. The context menu
keeps file actions at this boundary too: Quick Look, the default app, Finder reveal, copying the
pixels/name/path, and removal.

The strip adds its height to the text input rather than consuming the text's existing minimum.
That matters most in `SessionComposerViewController`, whose generous empty prompt asks for a
description: attaching a screenshot must not turn that back into a one-line field. More images
scroll horizontally instead of shrinking into unrecognisable tiles. The same `PromptView` serves
the first message and the native conversation reply, so attachment behavior cannot drift between
the two surfaces; a terminal follow-up remains the CLI's own input. Thumbnail mode is an explicit
`showsImageAttachments` capability rather than the component's default, because `PromptView` also
serves commit messages and inspector notes — those are plain text fields where a dropped path must
remain plain text.

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
- **Content leads.** One element per view carries emphasis, usually what is being typed into
  or read. Everything else is secondary or tertiary label colour.
- **Three tiers of button, one primary per screen.** `ThemedButton.Emphasis` names the shapes
  the control always had: **primary** is the accent fill (`isProminent`), **secondary** the
  surface-and-hairline (`isBordered`), **tertiary** the mark with no surface until the pointer
  reaches it. There is deliberately no destructive colour — a destructive button says so in its
  *title*, and red on a theme whose accent is already red says nothing. A second primary makes
  both of them ordinary: the composer's action row is one primary ("Start session") beside one
  secondary ("Import 90 conversations"), which is what tells you which of the two the screen is
  about. A button that owns a chord names it on its own face through `shortcut` — one
  `KeyboardShortcut` drives both the drawing and the match, so a button cannot answer a chord it
  does not name or name one it does not answer. That match is modifier-exact, unlike
  `keyEquivalent`, which matches the character whatever is held with it: a `"\r"` key equivalent
  on a pane holding a text field claims the Return meant for the field, since AppKit offers every
  key-down to the view tree before the first responder sees it.
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

  `ThemedTabItemView` is the same rule at the other end of a much shorter row, and was the last
  container not following it: a 12pt × inside a 20pt target put the "10pt after the title" at 14
  and the "12pt from the tab's edge" at 16, while the leading icon — a 14pt symbol in a 16pt slot
  — sat on the 12 it was given. A tab is four things in 180 points, so 4pt at one end is the
  difference between a row that reads as spaced and one that reads as shoved left.

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

A tab's icon takes the **label's** colour, never the accent. The accent means "this wants you"
here — the sidebar's attention dot is the same colour — and spending it on whichever tab happens
to be open says that about nothing. The info panel's process dots follow the same rule and draw
in the positive status role, which is what a running process actually is.

`SessionComposerViewController` is the reference implementation, and **the only way a session
is created**. Reading down its column is the decision in order: the project, the choices
(agent, account, model, checkout), what those choices have left to spend, then the task.

Every shortcut that created a session outright is gone — the project row's `+`, the per-agent
and per-account items in the Project menu and the sidebar, `⌘N`'s old behaviour, and the
session a newly added project used to get. Each answered four decisions with defaults the
user never saw. `⌘N` and selecting a project now both land here. The composer is replaced by
the conversation the moment it is used, so it costs a click and nothing else — which is also
why it is laid out generously rather than compactly, and why its column is
`ComposerDefaults.contentWidth` (720) rather than `Design.Size.readableWidth`: that measure
paces prose, and squeezing a row of chips into it collapsed every one of them to an
unlabelled icon.

**The send is a button, not a glyph, and Return is a line break.** A composer's prompt is the
one place in the app where the text is a *brief*: several lines, usually a pasted paragraph of
context, written before anything runs. Return-sends spent that on an accidental launch every
time a line was broken, and the glyph in the corner of the box had nowhere to say otherwise. The
prompt therefore takes `SubmitPlacement.outside` and the row underneath carries the send —
primary, titled, naming `⌘↩` on its face — with **Import _n_ conversations** beside it as the
secondary. Two buttons, one loud: which of them the screen is about is now visible rather than
inferred. The chord is a `ThemedButton.shortcut` rather than a `keyEquivalent`, since a bare
`"\r"` equivalent in this pane would take the Return back off the prompt it was just given to.

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

Two things are contained rather than replaced, and both are drawn by the window server where no
amount of our drawing reaches: the **`NSMenu` a `ThemedPopUp` opens**, and the **system colour
panel behind `ThemeSwatchView`**. Callers depend on the wrapper, not on the system part, so
replacing either with something custom later is a change to one file.

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
