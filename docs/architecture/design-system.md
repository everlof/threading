# Design System

The component vocabulary, the themed controls, and the bugs each rule came from.

Part of the [CLAUDE.md](../../CLAUDE.md) index. The boundary *policy* — what feature code may
construct, and what a new component owes — is [`docs/THEME_BOUNDARY.md`](../THEME_BOUNDARY.md);
this file is the vocabulary and the reasoning behind it.

**New UI is built from `Sources/Skalman/UI/Design/`, not from stock AppKit controls.** This is
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
| `ChipView` | A flat pill that opens a menu. The standard way to offer a choice. |
| `PromptView` | A rounded container holding a growing text view and its submit control, as one input. |
| `ThemedControl` | The base for a control that draws itself from the theme. |
| `ThemedToggle` | A drop-in `NSSwitch` whose on-track is the theme's accent. |
| `ThemedPopUp` | A drop-in `NSPopUpButton`, button included and dropdown excepted. |
| `ThemedButton` | A drop-in `NSButton`: bordered, plain, or accent-filled. |
| `ThemedTextField` | A drop-in editable `NSTextField`, bezel drawn rather than stock. |
| `ThemedSearchField` | The same field with a magnifier, replacing `NSSearchField`. |
| `ThemedSpinner` / `ThemedProgressBar` | `NSProgressIndicator`, in the theme's accent. |
| `ThemedScrollView` | An `NSScrollView` that starts transparent — the stock one paints a system surface. |
| `ThemedTextView` | An `NSTextView` in theme colours; `.scrolling()` replaces `scrollableTextView()`. |
| `ThemedTableView` / `ThemedOutlineView` | Tables that start transparent, replacing the system background. |
| `ThemedTableHeaderView` | A semantic-role table header that retains AppKit resizing and tracking. |
| `SeparatorView` | A hairline rule, replacing `NSBox(boxType: .separator)`. |
| `ThemeSwatchView` | A palette chip; the one place `NSColorWell` still lives. |
| `ThemedSplitView` | An `NSSplitView` whose divider is inked against the window backdrop, not the chrome's ground, and weighed by the theme's rule width rather than AppKit's fixed hairline. |
| `ThemedSurfaceView` | A pane's ground, and the one view that re-resolves its fill on a *system* light/dark switch. |
| `SidebarBackdropView` | The sidebar's ground: the platform's sidebar material under the identity theme, an opaque themed surface under a style. |
| `ToolbarButtonGroupView` | Related toolbar actions as one item, so their spacing is ours rather than `NSToolbar`'s. |
| `WorkingOrbView` | The dotted "working" orb, tinted with the accent — the theme boundary for the `ThinkingOrbs` view. |
| `ThemedTabItemView` | **Every** tab: the display pane's strip, the settings sidebar, and the toolbar's active page. |
| `ThemedIconButton` | **Every** icon-only button: toolbar actions, a tab's `×`, a sidebar row's `⋯`. |
| `PaneFooterView` | The bottom band of a pane: hairline, band height, corner-aware insets, controls aligned by their ink (`OpticalInsetProviding`). |
| `PaneHeaderView` | The footer's mirror at a pane's top. Its height is the content pane's header-strip measure (`PaneHeaderDefaults.height` reads it), so the two panes' hairlines land on one line. |
| `ImageCompareView` | Two images against each other: a draggable wipe seam (either axis), a crossfade, a pixel difference, and side by side, with per-side title tags and a mode chip. One scrubbed fraction serves every mode — there is deliberately no slider control: the seam *is* the control (accent-inked, since it is the one thing on the surface asking to be used), fade held at the middle is the onion skin, and both images draw at one shared scale so a resized asset stays visibly resized rather than being normalised into "looks identical". The canvas is a `ThemedControl`: arrow keys nudge the scrub, Space recentres it, and VoiceOver reads it as a slider. |

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
  "Skalman" the moment it appeared had answered a question nobody asked with the one name the
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
and scrolls past it; Return submits and Shift/Option-Return breaks the line, which is the
shape every chat composer has and is what lets it be multi-line without losing the one-key
send.

Height is re-measured in `layout()`, not only when the text is set. Text height depends on
the width the box was given, which is unknown at assignment — a draft restored before layout
measured against a container of the wrong width and opened at the wrong height, showing the
*tail* of the prompt. Setting text also scrolls back to the top for the same reason.

Drops and pastes both land in `readSelection(from:type:)`, so one implementation serves the
pointer and the keyboard. Files become their own paths; raw image data is written to the
temporary directory first (`PromptAttachment`) — a screenshot on the pasteboard has no path,
and a path is the only form of an image either CLI can act on. This is what the agent CLIs do
with their own pasted images.

The vocabulary these encode, which new work should follow:

- **Flat over bezelled.** Pills and panels with a subtle fill. Stock bezels are heavier than
  anything here and pull attention away from content.
- **Quiet until relevant.** Surfaces rest below full opacity and lift on hover. A control
  offering a single option *hides* rather than showing a dead menu — the composer's account
  and model chips both do this.
- **Content leads.** One element per view carries emphasis, usually what is being typed into
  or read. Everything else is secondary or tertiary label colour.
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

Seven bugs are worth keeping, because each is a trap the next drawn control will walk into:

- **`NSImage.draw` states its own compositing, so a blend mode set on the context beneath it
  is silently overridden.** `ImageCompareView`'s difference mode set
  `CGContext.setBlendMode(.difference)` and then drew the second image — which
  `draw(in:from:operation:fraction:)` composited `.sourceOver` exactly as its `operation:`
  argument said, and the "difference" was the new image, whole. The operation has to ride the
  draw call itself. Found by the render test sampling the composite for black, not by eyes: the
  wrong picture was a perfectly plausible one.

- **`withAlphaComponent` replaces alpha, it does not scale it.** Dimming a disabled button
  against a resting surface that is *already* translucent — Cyberpunk holds its neon at 10% —
  made the disabled controls the loudest things on the page. Resolve, then multiply.
- **`NSString.draw(in:)` wraps.** A title measured a hair too narrow for its own rect breaks at
  the space and draws its second word below the button, with no ellipsis to show for it: the
  sidebar footer read "Add" instead of "Add Project". Measure and draw with the *same*
  attributes, and give the draw a paragraph style that truncates.
- **`NSTextField(string:)` is a class factory method**, free to return a plain `NSTextField`. A
  subclass declares its own or is one only by the annotation at the call site.
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
