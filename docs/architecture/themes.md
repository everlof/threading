# Themes

Terminal themes, app themes, and the three scopes both resolve through.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

A terminal theme is chosen at one of three scopes — session, project, or the app default —
and `ThemeResolution.resolve` picks the narrowest one that names a theme that exists.

Two rules carry the whole design, and both are pure functions of four arguments precisely so
they could be tested without standing up three singletons and a window:

- **Absent means inherit, not copy.** A session with no `themeName` follows its project, and a
  project with none follows the default, so changing the default still moves everything that
  never opted out. Recording the current theme at creation would have frozen every session
  against the one setting most likely to change.
- **A dangling name is not an error.** Themes are identified by name, so deleting one leaves
  references behind; an unknown name degrades to inheriting from the next scope out, which is
  indistinguishable from never having chosen. A *rename* is the case that must not degrade, so
  `ThemeAssignments.rename` re-points every reference through `ProjectStore.renameTheme` — it
  is the only rename path, and `ThemeManager.renameTheme` alone would silently reset every
  session using the theme.

**The broadcast had to invert.** `TerminalSession` used to observe `.profileDidChange` and
*adopt* whatever profile it carried, which was right while there was one theme for the app and
is exactly what a per-session override must not be overwritten by. Its observer is gone;
`AgentSessionViewController` re-resolves and pushes through `updateProfile`, and
`TerminalContainerViewController` resolves the pane's backdrop from the session id rather than
reading it off the terminal view — two observers of one notification have no defined order, so
reading the view could paint the pane the colour it is leaving.

Only the *theme* is scoped. The rest of a profile — font, cursor, shell, scrollback —
describes how the user works rather than how one conversation looks, and `ThemeAssignments.profile`
returns the global profile carrying a resolved theme.

The assignments live on the records they theme (`AgentSession.themeName`, `Project.themeName`
in `projects.json`) rather than in a side table, so each is deleted with the thing it applies
to instead of outliving it and re-theming whatever reuses the identifier.

`ThemeColorKey` names the palette's twenty colours once, as key paths with a `displayName` and
a snake-case `wireName`. The settings editor previously kept a `[String: NSColorWell]` and a
twenty-case `switch` to put a changed colour back, and the MCP schema needs the same mapping —
generating the tool's schema from the enum is what stops a colour being added to the model and
left out of the schema an agent reads.

**Scope is chosen where it applies**, which is a session's or a project's own `⋯` menu — the
same placement as the surface switch and the project icon. Only the default lives in Settings,
being the scope with no row to hang from. Each menu's "Inherit" item names what it inherits,
since that is the one choice in the list whose result cannot otherwise be seen, and every item
carries a `ThemeMenuChoice` naming its own target rather than reading "whichever row was last
clicked" — the submenu is built from three places and that ambient state goes stale between
them.

Agents reach the same three scopes over MCP (`list_themes`, `set_theme`, `create_theme`). The
call already arrives attributed, so `set_theme` needs no argument saying which terminal and
defaults to the session that asked — which is what makes "make this one darker" work in the
conversation it was said in. Three things the tools do that a thinner wrapper would not:

- **`set_theme` reports what the session actually draws with afterwards**, which is not always
  what was just set: a project-wide change is invisible in a session that named its own theme,
  and saying so is the difference between a tool that worked and one the agent believes worked.
- **`create_theme` merges onto a base** — the session's current theme unless told otherwise —
  so "warmer background" is one colour rather than twenty, and it refuses to overwrite an
  existing name, because a clobbered custom theme is unrecoverable and the caller most likely
  to collide is an agent inventing one.
- **A palette whose text fails `ThemeContrast` is refused.** A theme is the one setting that
  can make the app's *input* surface unusable, and the terminal is where the user would have to
  type to undo it. Only text-against-ground is checked: an ANSI colour close to the background
  is ordinary — a dark `black` on a dark ground is how most themes are built — and the floor is
  WCAG's large-text 3:1 rather than 4.5, which would reject Solarized Dark and stop being a
  safety net and start being a taste.

**A terminal palette can follow the app theme.** `AppTheme.terminalPalette` states the palette
that belongs with each style — from Cyberpunk neon and Bauhaus primaries to Art Deco brass and
Botanical greens — and the terminal theme list offers `TerminalThemeNames.followsAppTheme`
("Follow App Theme") as its first entry. System pairs a palette per appearance
(`TerminalTheme.systemLight`/`.systemDark`): Terminal.app's Basic ramp over black-on-white in
light mode and over a near-window dark ground in dark mode, so a following terminal moves with
macOS the way every System role does.

Three decisions carry it:

- **It is a reserved stable ID, not a fourth setting.** `TerminalThemeID.followsAppTheme`
  participates in the same three scoped assignments as every other terminal theme, so a session
  can follow the chrome while its project names Solarized and the narrowest scope still wins.
  The display name is only presentation; persisted assignments do not break if a theme is
  renamed. `ThemeManager` refuses to create a theme with the reserved identity or display name.
- **The palette is stated per theme, not derived from the roles.** Sixteen ANSI colours have to
  stay legible against the ground *and* apart from each other, which eleven roles cannot answer —
  derivation gives eight near-hues. Writing it out is what makes the pairing a decision taken
  while the theme is designed.
- **Swiss's greys break with convention deliberately.** A light palette normally leaves `white`
  and `brightWhite` near-white, because there those indices are meant as *backgrounds* — but a
  CLI that dims its status line to index 7 then writes pale grey on paper. The four neutrals are
  a monotone ramp dark enough to read on white, still ordered black → brightBlack → white →
  brightWhite so nothing that picks one of them vanishes.

**Truecolor is not the palette's, and backgrounds get normalised anyway.** Claude Code writes
its status line and its diff in 24-bit SGR rather than ANSI indices, so those colours are the
CLI's own under every palette — a limit of the protocol, not of the theme. Measured out of a
Christmas night pane, its diff washes arrived as `#0E3203` and `#470802`, at Oklab chroma
**0.084 and 0.094**, on a terminal ground of `#082019` at 0.033: two bands three times more
colourful than anything else in the window, and both of them background.

`TerminalBackgroundHarmony` (installed on SwiftTerm's `trueColorBackgroundTransform` from
`TerminalSession.applyProfile`, `AppSettings.harmonizesTerminalBackgrounds`, on by default)
eases those into the palette's register. Three rules, and the first is the one everything else
hangs off:

- **Lightness is never touched.** The app's own diff views own both halves of the picture and
  can move a wash and then re-derive an ink to sit on it. Here we own neither — the program
  chose its text colour against the background it also chose, and is still choosing them while
  this runs. Holding lightness means whatever contrast it arranged survives exactly, so the
  transform cannot make anything less readable than it arrived.
- **Chroma is soft clipped**, identity below a knee and asymptotic to a ceiling above it.
  Scaling the excess by a fraction is unbounded and so guarantees nothing; a flat clip is
  bounded but collapses every loud background onto one value and turns a program's gradient
  into a stripe. The soft clip is monotonic *and* bounded.
- **Hue is drawn toward the nearest colour the palette actually contains**, by a fraction of
  the distance and never past a cap. A contraction toward attractors cannot fold the circle, so
  eight background blocks stay eight distinct readable categories — which snapping to a small
  set of anchors would not.

None of it knows what a diff is, deliberately: a rule that fired only on colours it guessed
were diffs would guess wrong on somebody's progress bar. Foregrounds are never offered to the
transform — a program's syntax highlighting is its own — and indexed colours never reach it,
being the palette already. `TerminalBackgroundHarmonyTests` pins the three guarantees.

A live app-theme switch is a terminal-theme switch for any session following it, which is why
`AgentSessionViewController` observes `AppThemeDidChange` alongside the assignment events.

**The palette is only half of it: the program has to be *told* what it is drawing on.** Claude
Code ships `"theme": "auto"`, which is not "follow macOS" — it sends `OSC 11 ; ? ST`, reads the
background out of the reply, and assumes a **dark** terminal when nothing answers. SwiftTerm
answered nothing (see [`dependencies.md`](dependencies.md) for the off-by-one that swallowed
every OSC 11), so on a light theme the agent drew its dark palette: a diff's unchanged lines
arrived as near-white text on Bauhaus's paper, invisible, while its changed lines carried
Claude's own near-black washes — which the harmony transform then correctly left alone, because
holding lightness is exactly what keeps a program's chosen contrast intact. Nothing in the app's
own rendering was wrong; the terminal had simply never said what colour it was.

`TerminalSession.applyProfile` runs before the child launches, so the answer is the session's own
palette rather than SwiftTerm's default black. The question is asked **once, at startup**: a theme
switched under a running agent does not reach it (Claude's `/theme` does), and Claude subscribes to
no live colour-scheme notification — it parses `CSI ? 997 ; 1|2 n` but never enables the mode.

## A theme states a typeface

`AppTheme.Material.typeface` is the other half of a style brief. The styles these themes come
from (designprompts.dev) carry a `fontType` per style as plainly as they carry a palette —
Newsprint and Art Deco are serif, Cyberpunk and Vaporwave mono, Claymorphism rounded — and a
theme that recolours SF Sans is typographically still System. The four values are macOS's own
font designs (`NSFontDescriptor.SystemDesign`), so **nothing is bundled**, every weight exists,
and rendering is the platform's.

`material.fontFamily` sits above it for a theme whose identity is a *particular face* rather
than a class: "Newsprint, set in Baskerville" is not one of four. It wins where it resolves and
degrades to `typeface` where it does not, which is the same rule a dangling terminal-theme name
already follows — a family lives on the machine, not in the document, so a theme authored
elsewhere names something this machine may not have, and that is not an error.

**The user outranks the theme**, through two slots in `AppSettings`: `chromeFontFamily` for the
app and `conversationFontFamily` for the thread. Four layers resolve in `Design.Typography`'s
one private transform, nearest first — surface override, app override, theme family, theme
design — and each failure falls exactly one rung rather than to SF, so a removed conversation
font leaves the thread wearing the app's choice instead of resetting two levels.

`AppSettings.appTextSize` is orthogonal to those family layers. Its four bounded semantic
scales are applied to every `Design.Typography` role before family resolution, so headings,
body, detail, code, numerics, conversations, Settings, and host-rendered extension UI grow
together without flattening their hierarchy. The terminal remains outside that scale because
its profile owns an explicit point size.

The conversation gets its own slot for the reason the terminal always had one: it is the surface
that is *read*. `Typography.FontSurface` is a parameter on that single transform rather than a
second namespace — twenty factories in two copies would have to keep agreeing — and the composer
carries `.conversation` too, since what is typed becomes a bubble in the thread and a composer
in SF feeding a bubble in Baskerville changes font at the one moment the user is watching.

Three things no font setting reaches, and each is a rule rather than an oversight: **code** is
monospaced under every style (a serif diff is a defect), **numerics** keep SF's aligned digits
(a usage column that stops aligning costs more than a serif digit is worth), and the **terminal**
takes its font from `TerminalProfile`, which is the user's. `TerminalSession.applyProfile`
therefore resolves `profile.font` — including that model's missing-family fallback — directly;
it must not route through `Design.Typography`. The scrollback limit is applied after the font
because SwiftTerm rebuilds its terminal options when the font changes.

`AppThemeRefresh.startObservingFontOverrides` makes an override change do everything a theme
change does — the sweep, the redraws, the attributed-string rebuilds — by reusing
`AppThemeDidChange` rather than teaching a dozen consumers a second event. It is guarded on the
values, because `AppSettingsDidChange` fires for every setting in the app.

How a font actually reaches a label, and why the role is recorded on the view rather than tagged
onto the font, is in [`design-system.md`](design-system.md).

An app theme has one identity and one or two complete `AppTheme.Variant`s. A variant owns its
roles, material and paired terminal palette — all three may need to change across appearance,
not merely the ground colour. A theme with one variant pins Aqua or Dark Aqua. A theme with both
may still pin either one, or use `AppTheme.Mode.system` to leave `NSApp.appearance` unset and
follow macOS automatically. The second variant is optional and can be added later; validation
requires both only when the theme becomes adaptive.

**Christmas is the only stock style that authors both**, and the reason is what separates a
season from a movement: every other style is named after one and a movement has a single look,
while a season is snow in daylight and fir after dark. Picking one of those would have made half
the year's users wrong, so it states a light variant and a dark one and leaves `mode` adaptive.
Its identity is a *pairing* rather than a hue — red alone is Swiss Minimalist's accent already —
which is why the two colours are split across roles seen together: holly accent, a fir
`controlResting`, candlelight gold on the warning and string roles. A control that rests green
and lifts red is the whole style in one hover.

**System** is the identity case: it stores no literal variants and resolves AppKit's dynamic
colours under each appearance. Duplicating it materialises editable light and dark variants.
Legacy custom documents with top-level `roles`/`material`/`terminalPalette` decode into one
equivalent variant, while new documents write a `variants` map.

Built-ins are immutable and use stable IDs. MCP exposes list/get/set/create/duplicate/update.
`get_app_theme` returns `appearance` plus `variants.light`/`variants.dark` in the same snake-case
`roles`, `material`, and `terminal_colors` vocabulary create/update accept, with resolved roles
alongside them for inspection. One variant is a complete fixed theme; both plus
`appearance: "adaptive"` follow macOS. Tool descriptions state the merge and fallback rules, so
duplicate-then-update is available explicitly without a prescriptive workflow paragraph.

A natively-rendered session records an assignment but shows almost none of it: the conversation
is drawn in system colours per the design system, so the theme reaches only the pane's backdrop.
The tools say so rather than reporting a success nothing visible followed.

The settings page was rebuilt around `ThemeColorEditor` and `ThemePreviewView`, and both
changes came from looking at a render rather than from reasoning about a control:

- **The palette is a grid.** Sixteen chips four points apart in two rows that did not line up
  read as one undifferentiated field of circles — `bright blue` could not be found in it. At
  `Design.Spacing.medium`, index-aligned so a colour sits above its bright variant, they are a
  grid with columns. There are deliberately no column headings: a red chip says "red" better
  than the word does, and eight headings wide enough for "Magenta" would set the grid's pitch
  for it. The name and hex live in each chip's tooltip.
- **A swatch is ringed, and the ring is a layer border** — which Core Animation paints *above*
  sublayers, so it survives the colour well filling the chip underneath. A theme's `black` on
  the settings card's own dark ground is otherwise a hole rather than a value.
- **A built-in theme shows its colours rather than disabling them.** Disabled wells dim, which
  misreports the palette they exist to display; the read-only state says why and offers
  Duplicate instead.

`ThemeSettingsRenderTests` draws the page at the width the pane actually gives it
(`SettingsUIDefaults.pageWidth`, which `showSettingsPage` caps it at) and at a squeezed one,
light and dark — the same fixture-to-PNG idea as the conversation and git-review renders, for
the same reason: no assertion anyone would write catches "these twenty chips read as a smear".

**A theme's glow is a layer shadow, and a shadow spills past the panel that casts it** — so a
clipping ancestor whose edge coincides with a panel's edge cuts the halo off flat on that
side, invisibly to the code that set the shadow. Found on the settings pages, where the scroll
view's edges sat exactly at the cards': the halo faded vertically (the spill landed in the
section spacing, inside the clip) and not sideways at all. The contract is
`Design.Size.glowGutter` — the room a clipping host holds clear around glowing panels,
constant across themes because layout never moves with the theme; `SettingsUI.page` budgets
it, `AppThemeTests` pins it to the widest stock glow or directed shadow, and a Cyberpunk render assertion in
`ThemeSettingsRenderTests` samples pixels on all four sides of a card so a new clipping host
cannot silently reintroduce the flat edge. Theme-specific issues get general fixes at this
seam: themes state specs (`AppTheme.Material`), one interpreter draws them
(`applySurface`/`applyThemeGlow`), and feature code says only what a surface *is* — never
`if` on a theme's identity.

**`material.borderWidth` is a rule weight, and every rule in the window obeys it — including the
one AppKit draws.** `SeparatorView`, the shell drawer's grab strip and a table's column rules all
take `Design.Radius.border`; `NSSplitView.dividerStyle = .thin` is a fixed point and does not.
Under Bauhaus (2) and Neo Brutalism (3) the window therefore drew heavy pane-header rules meeting
a hairline seam between the very same panes, and the sidebar's rule visibly stepped down where it
crossed the split — one stated decision rendered at two weights. `ThemedSplitView` overrides
`dividerThickness` (floored at a point, because that seam is also the drag handle) and invalidates
its constraints on `AppThemeDidChange`: the split reads the thickness while placing its panes and
never asks again, so repainting alone left them spaced for the theme that just left.

## 2026-07-27 — extension-contributed themes and fonts (the third tier)

`AppThemeLibrary.all` is now `stock + contributed + custom`. The contributed tier is
`ExtensionAppearanceRegistry` — derived state in the `ExtensionSettingsRegistry` shape,
replaced wholesale from the manager's enabled-and-valid packages on every inventory or
enablement change. Everything in it is **package data the inspector read before any extension
code ran**: theme documents (the same JSON `AppThemeStore` persists, held to the same
`AppThemeEditing.validate` gates, id namespaced `ext.<extension>.<contribution>`) and font
files (parsed for family names at inspection, registered **process-scoped** with
`CTFontManager` while the extension is enabled).

Ordering at launch matters and is deliberate:
`ExtensionManager.prepareAppearanceContributions()` runs *before* `AppThemeLibrary.restore()`
in `AppDelegate` — contributions are sync disk reads, so a stored contributed theme (and any
font it names) is in force when the first window is built rather than repainted in later.

Selection semantics, all in `contributedThemesDidChange`: a vanished theme falls back to
System *recorded as the choice* (no snap-back on re-enable); the one divergence `restore()`
can leave — stored choice unresolvable because its extension had not enabled yet — heals when
the choice becomes resolvable. That healing is safe because `apply` records a pick even when
it changes nothing on screen (the guard used to swallow a deliberate System pick made while
fallen back).

**Two probed facts carry the font half** (scratchpad probe, measured on macOS 26 — the third
time a font assumption here was wrong until measured):

- A `.process`-scoped `CTFontManager` registration is visible to the **descriptor matching**
  `Typography.inFamily` does, live in both directions — so the four-layer resolution, the
  dangling-name degradation, and the sweep all work on extension fonts with zero changes.
- `NSFontManager.availableFontFamilies` **snapshots on first access** and never sees a later
  registration. Every enumeration for pickers and the MCP authoring gate therefore goes
  through `Design.Typography.availableFamilies`
  (`CTFontManagerCopyAvailableFontFamilyNames`, dot-families filtered), which is live.

A registered family changes what recorded roles resolve to, so the registry answers a font-set
change the way `startObservingFontOverrides` answers an override change: `repaintEverything()`
plus `AppThemeDidChange` — one event, the consumers it already has.
