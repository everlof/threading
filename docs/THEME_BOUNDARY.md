# AppKit Theme Boundary

This is the canonical rule for application UI. `AGENTS.md`, `CLAUDE.md`, the source checker,
runtime audits, and render tests all enforce or point back to this document.

## The rule

Feature code must not instantiate or subclass an AppKit class that draws a control, surface,
selection, focus treatment, or application-owned chrome. Use a component from
`Sources/Threading/UI/Design/`.

Structural AppKit types remain allowed: `NSView`, `NSStackView`, `NSGridView`, view controllers,
layout objects, frameless `NSImageView`, table columns, delegate parameter types, and similar
types that do not choose visible styling.

System-owned chrome is allowed only behind a named containment boundary. Current examples are
the invisible `NSColorWell` inside `ThemeSwatchView`, the private field editor inside
`ThemedTextField`, AppKit's overlay-scroll effect pockets around `ThemedScroller`, outline
disclosure buttons, the application menu bar, toolbars, and open/save panels. The system object
must not leak out as the component callers build against.

**A save panel's `accessoryView` is inside that boundary, not beside it.** AppKit does not put an
accessory into the panel's content: it hangs the view off the panel in an `NSAccessoryViewWindow`
of its own, exactly as tall as the accessory and clipping at its frame view. An app-owned
dropdown opened from in there has nowhere to open — `ThemedMenuPresenter` lays its overlay out in
`source.window!.contentView!.bounds`, which is that 44-point strip, so a `ThemedPopUp`'s list
arrives clamped to a two-pixel sliver of its own top border and the user can neither read it nor
pick from it. It shipped that way in `CompareExportPanel`. Controls in an accessory are AppKit's
own, down to the label colour the panel gives its own field labels, and each one is a narrow
exception in `scripts/config/theme-boundary.json` naming the panel it belongs to.

App-owned alerts and anchored popovers are not system-owned chrome: callers use `ThemedAlert`
and `ThemedPopover`, which own their visible surfaces, focus return, Escape handling, and live
theme response. **Menus inside the window — dropdowns and right-click/context menus alike — are
app-owned**: `ThemedMenuPresenter` carries type-to-select, keyboard navigation (arrows walk
submenus in and out), press-drag-release tracking, hover-safe submenu travel, and pointer
anchoring for secondary clicks, so converting a menu gives none of that up. Only the menu *bar*
remains native (`AppDelegate` is the named boundary and the source checker's one exception):
its menus carry Services, responder-chain command routing, and system key equivalents that
cannot be reproduced in-window. Open/save panels, the colour panel, and the `NSWindow` frame
remain system workflows behind their named boundaries — the frame with one stated exception:
a theme carrying a `WindowChromeStyle` opts the main window into an **app-drawn frame**
(`WindowChromeCoordinator`, `docs/architecture/window-chrome.md`), whose band, buttons and
command row, and border are ordinary `UI/Design/` components inside the content root, fully subject to this
policy and to `ThemeBoundaryAudit`. Under every other theme the native frame stays exactly the
system workflow it always was.

Containment includes API shape, not only where construction happens. `ChipView` and
`ThemedPopUp` accept `ThemedMenuEntry` values and present them through the app-owned
`ThemedMenuPresenter`; neither their contracts nor their visible dropdowns contain `NSMenu`.
A provider returning `NSMenu`, or a callback exposing `NSMenuItem`, is still a theme-boundary
violation even if the system object is ultimately displayed beside a themed view.

**The pointer is part of the boundary too, and it is the one answer a view gives by default
whether it means to or not.** Cursor rectangles are a *window's* list, so a view that registers
none does not fall back to the arrow — it inherits whatever is registered behind it, which over a
terminal, a transcript, or inside a text field is an I-beam offering to select text the view is
covering. A view therefore *declares* what it tells the pointer: `PointerClaiming`'s
`restingPointer` (the cursor over everything it covers, `nil` only where the view is genuinely
see-through) and `pointerClaims` (the parts that answer differently). `ThemedControl` and
`BackdropOverlay` default to the arrow, so a control is correct the day it is written.
`addCursorRect` and `NSCursor.…set()` are checker errors outside
`UI/Design/PointerClaims.swift`, and a `resetCursorRects` override may be exactly
`registerPointerClaims()` and nothing else — a claim decided inside that method is a claim no
reviewer and no test can read.

`UI/Design/` is not an exception zone. Composite components such as `PromptView` use the same
lower-level themed controls and surfaces as feature code. Only the exact file implementing an
AppKit boundary may receive a source-checker exception, and each exception names one symbol and
records why it cannot be removed.

## Adding UI

1. Look for an existing component in `UI/Design/`.
2. If no component exists, add the boundary there before writing the feature call site.
3. The component owns all visible states: resting, hover, pressed, disabled, focused, selected,
   emphasized, and live theme changes.
4. Read colours, typography, spacing, radii and motion through `Design` roles. Feature code never
   reads an `NSColor` system role directly.
5. Choose fonts through `Design.Typography`. A feature names the role (`body`, `caption`,
   `code`, `numericDetail`, and so on), never an AppKit point size or font factory. User-selected
   terminal fonts and fonts used to draw generated artwork are narrow documented exceptions.
6. Pass a semantic `SurfaceRadius` (`.panel`, `.control`, `.pill`, or an intentional `.fixed`)
   to `applySurface`. Never resolve a role to a `CGFloat` first: two roles can share a number in
   one theme and diverge after a live theme switch.
7. Geometry that a second pane could repeat — a footer band, a tab strip, a slot beside a
   title — is a component's to own. State the height, the hairline, the insets and the
   centring once in `UI/Design/`; a host pins edges and contributes content. A feature call
   site doing constraint arithmetic with shared constants is the same erosion as a hardcoded
   colour, one step slower.
8. Margins that meet a window edge are measured from the corner-adapted layout region
   (`layoutGuide(for: .safeArea(cornerAdaptation:))` on macOS 26; the view's own edge
   earlier), never widened by hand to clear the curve. The platform states what each corner
   needs — and states zero for an edge that meets another pane — so "equal spacing" is
   measured from the region the eye reads as usable, not from the frame. Probe
   platform-dependent geometry in a real window rather than transcribing a measured value
   into a constant that goes stale. `PaneFooterView` is the reference.
9. Containers place controls by their ink, not their frames. A control whose frame carries
   invisible padding — a plain button's hover surface, an icon button's click target — states
   it on **both axes** through `OpticalInsetProviding`, and the container subtracts it. Both
   requirements are intentional: a new padded control must answer horizontal and vertical
   layout before it compiles, rather than only the first call site's axis. `SeparatorView`
   translates an authored ink gap into the stack or constraint gap beside a rule; feature code
   never branches on the adjacent control type or repeats its padding. Equal frame margins and
   gaps are not equal visual ones.

   The same rule applies *inside* a component: what a view draws is centred by its ink, through
   `NSBezierPath.centringInk(in:)`, never by the geometry it was built from. A rounded corner is
   a tangent arc and eats the vertex it replaces, a stroke puts half its width outside the path,
   and artwork carries whatever margin it was exported with — so a shape centred on its
   construction points draws off the line while every container above it places its frame
   correctly. The optical part is measured, not asserted: `OpticalCentring` weighs the shape's
   own centre of mass, so a symmetric mark is left alone and a lopsided one (an upward triangle,
   a mark that points) is corrected without the component claiming anything about itself. Ink
   that cannot be weighed — a template image, a glyph run, a layer's contents — states an
   `InkMass` instead, and never a number invented at the call site.

   Hover detail follows the same single-owner rule. A `ThemedControl` anchor reports through its
   shared `onHoverChange`; feature code does not install a second tracking area over it. Feed that
   state through `HoverPopoverScheduler`, build bounded preview content only from the presentation
   callback, and use `ThemedActionPopoverViewController` for preview-plus-command anatomy. A
   menu-like anchor uses `ThemedButton.showsSubmenuIndicator`, not a Unicode arrow appended to its
   title.
10. Never assign a theme-derived `CGColor` directly to a layer. Draw at display time, use
   `applySurface`, or use the refresh-aware layer-colour helpers.
11. Preserve accessibility. A custom-drawn control must expose its role, title/value, enabled
   state, and action. Status, selection, additions/removals, and errors must remain identifiable
   without colour alone.
12. A component in `UI/Design/` that handles pointer input must inherit `ThemedControl`, so
   keyboard activation, visible focus, enabled state, and accessibility cannot be omitted
   accidentally. Every concrete subclass still states its semantic accessibility role and
   primary action; the source checker rejects one that does not.
13. Every pointer action has a keyboard and accessibility equivalent. Space/Return activates a
   focused control, arrows move inside ordered choices, and a custom gesture (drag, pinch, swipe,
   secondary click) exposes an ordinary control, menu command, key, or accessibility action that
   reaches the same semantic operation.
14. Every transient surface states its complete dismissal and focus lifecycle. Escape closes an
   alert, inspector, menu, or popover (one nested layer per press); Cancel owns Escape where a
   choice is being made; closing restores the source or previous first responder. Tab cannot
   strand focus behind an app-owned modal surface, and opening one produces the appropriate
   accessibility announcement or layout change.
15. A pointer target visibly answers hover and press, accepts the first click when appropriate,
   uses a cursor consistent with its action, and clears stale hover when layout moves it. Its hit
   target and focus shape belong to the component rather than being recreated by callers.
16. Test a control inside the ordinary AppKit host it will inhabit, not only in a plain `NSView`:
   table selection, key-view traversal, menus/popovers, text editing, window activation, and
   nested scrolling can all consume an event before an isolated control sees it.
17. Read transition durations from `Design.Motion`; it collapses them under Reduce Motion.
   Indeterminate status views may stay visible, but must stop perpetual animation.
18. Read contrast-sensitive colours and focus geometry through `Design.Surface`, `Design.Text`,
   and `Design.Accessibility`. Increase Contrast must strengthen faint borders, dividers,
   controls, secondary ink, and focus without replacing the active theme.
19. Add behavior tests and render the component under at least System plus two deliberately
   different app themes. Include focus, selection and disabled states when applicable. A claim
   about balance, alignment or legibility is checked by looking at a render, not by asserting
   about the constraints that were meant to produce it.
20. Top-level app windows subclass `ThemedWindowController`. It audits the app-owned content
   root after AppKit expands it; never opt a window out or start the audit at the system frame
   view.

Do not fix a violation with a directory exclusion or a blanket lint disable. Add a narrow,
documented policy exception only for genuinely system-owned chrome.

## Enforcement

`scripts/config/theme-boundary.json` is the machine-readable policy. `scripts/check_theme_boundaries.sh`
compiles the SwiftSyntax checker shipped with the active Xcode toolchain and runs it over every
Swift source file. The Threading target executes it before compilation, and the test suite invokes
the same command rather than maintaining a second regular-expression implementation.

Static checking proves that feature code entered through the right boundary. Runtime view-tree
audits catch factories and framework-created view trees, while render and live-theme-switch
tests prove that a boundary actually paints every state correctly. No one layer replaces the
others.

**A fourth case the first three cannot see: the code nobody wrote.** Where AppKit supplies a
default, an omission is a decision, and there is no call site to lint, no wrong class in the tree,
and nothing for a reviewer to read. A list's row is the worked example — a delegate that declines
to supply one gets a plain `NSTableRowView`, which fills its selection with the *system* accent —
and it shipped in four panes at once. Three rules follow from it, and they are the ones to reach
for whenever a framework default would be visible:

- **Answer it in the component, not at the call sites.** `ThemedTableView`/`ThemedOutlineView`
  create the themed row themselves, through the same `makeView(withIdentifier:)` AppKit uses, so a
  list gets the right answer by existing. A delegate that states its own row still wins.
- **Give the audit something to see.** `ThemeBoundaryAudit` treats a row view that is not a
  `ThemedComponent` as a violation, which turns the absence into a class it can name — and a list
  must be *rendered with rows* for that to mean anything, which is what `ThemeLeakSweepTests`
  does per screen.
- **Sweep the pixels for what no rule anticipated.** Under a theme whose accent is nowhere near
  the system's, a fill's worth of system accent anywhere in a screen is a framework default
  drawing itself. That check needs no prior knowledge of the mechanism, which is the point: it is
  the layer that catches the next one — within a bound that is stated on
  `ThemeLeakSweepTests` and was measured, not assumed: AppKit draws a list's selection only in a
  **key** window, which no test in this target can produce, so that particular fill is invisible to
  any pixel sweep here and is held by the three layers above instead.

Break the code on purpose and watch each layer fail before trusting it. Two of the four written
here passed against the regressed build for reasons that had nothing to do with the defect.

The source checker also rejects pointer-handling classes in `UI/Design/` unless they inherit a
configured interactive base type. This is a contract lint, not merely a ban on stock AppKit:
custom drawing does not excuse a mouse-only control. Direct `ThemedControl` subclasses are also
required to implement `accessibilityRole` and `accessibilityPerformPress`.

Animation-context durations in application UI must resolve through `Design.Motion`. A literal
or feature-owned duration fails the checker, making Reduce Motion the default for new
transitions instead of a review-time convention. A perpetual animation needs a narrow exception
and an explicit branch that removes it when Reduce Motion is active.

Reading `alertFirstButtonReturn`, `alertSecondButtonReturn`, `alertThirdButtonReturn`, or
`ThemedAlert.firstButtonResponse` outside
`confirmationGateDirectories` (`Sources/Threading/UI/Alerts`) fails the checker as
`confirmationResponse`. An informational alert never inspects its response, so that read is the
precise signal that an alert is asking a question — and a question must be built through
`ConfirmationAlert`, which requires a case in `ConfirmationPrompt` stating whether the user may
switch it off. See `docs/architecture/design-system.md` for the rules that register encodes.

Direct `NSFont` system factories are rejected outside `Design.Typography` and the small set of
documented variable-font/artwork boundaries. This keeps new screens on the same type scale
without forbidding the terminal profile from honoring an explicitly selected font and size.

Public and module-internal `UI/Design/` contracts are checked for system-chrome types such as
`NSMenu`, `NSMenuItem`, panels, and toolbars. Private implementation may contain
them only at a documented system-owned boundary. Dropdown controls have no exception:
`ChipView` and `ThemedPopUp` use the shared semantic `ThemedMenuItem` model and the custom
`ThemedMenuPresenter`, whose rows, selection, scrolling, focus, and elevation all come from
`Design`.

Construction of `NSAlert` and `NSPopover` is rejected everywhere in application source. Their
app-owned replacements contain an `NSPanel` only as the AppKit transport for window ordering,
sheet attachment, focus, and accessibility; the visible chrome is drawn from `Design` roles.

Every class in `UI/Windows/` that directly owns an `NSWindowController` must inherit
`ThemedWindowController`. Debug builds then audit that window after showing, resizing, and live
theme changes. The audit begins at `contentViewController.view`, keeping AppKit's frame,
title-bar, and toolbar chrome outside the app-owned boundary while still checking framework
wrappers created underneath the content root.

`AppThemeRefresh` observes macOS accessibility display-option changes alongside app-theme
changes. It reapplies recorded layer surfaces and redraws the window tree, so Increase Contrast
and Reduce Motion changes take effect live rather than only after reopening a window.

## The phone's half

`ThreadingMobile` is SwiftUI, so it fails differently: nothing is constructed wrongly, a
framework simply keeps painting the parts a view did not claim. A `List` hands out its own row
plate and hairlines, and a sheet is a separate hosting scene that inherits neither the palette
nor the presentation values read from it. Both are the "code nobody wrote" case above, on a
platform where the audit and pixel-sweep layers do not exist.

`scripts/check_mobile_theme_boundaries.py` therefore holds the mechanical half — one owner for
row chrome, one way to hand the theme across a presentation boundary — and runs from
`check_theme_boundaries.sh` beside the AppKit checker. The rules, the surfaces they were written
against, and what a theme may say about the system keyboard are in
[`IOS_THEMED_DIALOGS.md`](IOS_THEMED_DIALOGS.md).
