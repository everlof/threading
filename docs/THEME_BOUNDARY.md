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
the `NSMenu` opened by `ThemedPopUp`, the invisible `NSColorWell` inside `ThemeSwatchView`,
overlay scrollers owned by `ThemedScrollView`, alerts, popovers, toolbars, and open/save panels.
The system object must not leak out as the component callers build against.

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
5. Never assign a theme-derived `CGColor` directly to a layer. Draw at display time, use
   `applySurface`, or use the refresh-aware layer-colour helpers.
6. Preserve accessibility. A custom-drawn control must expose its role, title/value, enabled
   state, and action.
7. Add behavior tests and render the component under at least System plus two deliberately
   different app themes. Include focus, selection and disabled states when applicable.

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
