# AppKit Theme Boundary

This is the canonical rule for application UI. `AGENTS.md`, `CLAUDE.md`, the source checker,
runtime audits, and render tests all enforce or point back to this document.

## The rule

Feature code must not instantiate or subclass an AppKit class that draws a control, surface,
selection, focus treatment, or application-owned chrome. Use a component from
`Sources/Skalman/UI/Design/`.

Structural AppKit types remain allowed: `NSView`, `NSStackView`, `NSGridView`, view controllers,
layout objects, frameless `NSImageView`, table columns, delegate parameter types, and similar
types that do not choose visible styling.

System-owned chrome is allowed only behind a named containment boundary. Current examples are
the invisible `NSColorWell` inside `ThemeSwatchView`, overlay scrollers owned by
`ThemedScrollView`, the private field editor inside `ThemedTextField`, outline disclosure
buttons, application/context menus, alerts, toolbars, and open/save panels. The system object
must not leak out as the component callers build against.

Containment includes API shape, not only where construction happens. `ChipView` and
`ThemedPopUp` accept `ThemedMenuEntry` values and present them through the app-owned
`ThemedMenuPresenter`; neither their contracts nor their visible dropdowns contain `NSMenu`.
A provider returning `NSMenu`, or a callback exposing `NSMenuItem`, is still a theme-boundary
violation even if the system object is ultimately displayed beside a themed view.

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
   it through `OpticalInsetProviding`, and the container subtracts it, so a titled button and
   a bare glyph land on the same visual margin. Equal frame margins are not equal visual
   margins.
10. Never assign a theme-derived `CGColor` directly to a layer. Draw at display time, use
   `applySurface`, or use the refresh-aware layer-colour helpers.
11. Preserve accessibility. A custom-drawn control must expose its role, title/value, enabled
   state, and action. Status, selection, additions/removals, and errors must remain identifiable
   without colour alone.
12. A component in `UI/Design/` that handles pointer input must inherit `ThemedControl`, so
   keyboard activation, visible focus, enabled state, and accessibility cannot be omitted
   accidentally. Every concrete subclass still states its semantic accessibility role and
   primary action; the source checker rejects one that does not.
13. Read transition durations from `Design.Motion`; it collapses them under Reduce Motion.
   Indeterminate status views may stay visible, but must stop perpetual animation.
14. Read contrast-sensitive colours and focus geometry through `Design.Surface`, `Design.Text`,
   and `Design.Accessibility`. Increase Contrast must strengthen faint borders, dividers,
   controls, secondary ink, and focus without replacing the active theme.
15. Add behavior tests and render the component under at least System plus two deliberately
   different app themes. Include focus, selection and disabled states when applicable. A claim
   about balance, alignment or legibility is checked by looking at a render, not by asserting
   about the constraints that were meant to produce it.
16. Top-level app windows subclass `ThemedWindowController`. It audits the app-owned content
    root after AppKit expands it; never opt a window out or start the audit at the system frame
    view.

Do not fix a violation with a directory exclusion or a blanket lint disable. Add a narrow,
documented policy exception only for genuinely system-owned chrome.

## Enforcement

`config/theme-boundary.json` is the machine-readable policy. `scripts/check_theme_boundaries.sh`
compiles the SwiftSyntax checker shipped with the active Xcode toolchain and runs it over every
Swift source file. The Skalman target executes it before compilation, and the test suite invokes
the same command rather than maintaining a second regular-expression implementation.

Static checking proves that feature code entered through the right boundary. Runtime view-tree
audits catch factories and framework-created view trees, while render and live-theme-switch
tests prove that a boundary actually paints every state correctly. No one layer replaces the
others.

The source checker also rejects pointer-handling classes in `UI/Design/` unless they inherit a
configured interactive base type. This is a contract lint, not merely a ban on stock AppKit:
custom drawing does not excuse a mouse-only control. Direct `ThemedControl` subclasses are also
required to implement `accessibilityRole` and `accessibilityPerformPress`.

Animation-context durations in application UI must resolve through `Design.Motion`. A literal
or feature-owned duration fails the checker, making Reduce Motion the default for new
transitions instead of a review-time convention. A perpetual animation needs a narrow exception
and an explicit branch that removes it when Reduce Motion is active.

Direct `NSFont` system factories are rejected outside `Design.Typography` and the small set of
documented variable-font/artwork boundaries. This keeps new screens on the same type scale
without forbidding the terminal profile from honoring an explicitly selected font and size.

Public and module-internal `UI/Design/` contracts are checked for system-chrome types such as
`NSMenu`, `NSMenuItem`, `NSPopover`, panels, and toolbars. Private implementation may contain
them only at a documented system-owned boundary. Dropdown controls have no exception:
`ChipView` and `ThemedPopUp` use the shared semantic `ThemedMenuItem` model and the custom
`ThemedMenuPresenter`, whose rows, selection, scrolling, focus, and elevation all come from
`Design`.

Every class in `UI/Windows/` that directly owns an `NSWindowController` must inherit
`ThemedWindowController`. Debug builds then audit that window after showing, resizing, and live
theme changes. The audit begins at `contentViewController.view`, keeping AppKit's frame,
title-bar, and toolbar chrome outside the app-owned boundary while still checking framework
wrappers created underneath the content root.

`AppThemeRefresh` observes macOS accessibility display-option changes alongside app-theme
changes. It reapplies recorded layer surfaces and redraws the window tree, so Increase Contrast
and Reduce Motion changes take effect live rather than only after reopening a window.
