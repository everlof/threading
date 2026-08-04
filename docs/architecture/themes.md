# Themes

Terminal themes, app themes, and the three scopes both resolve through.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

A terminal theme is chosen at one of three scopes — the selected chat or standalone terminal,
its project, or the app default — and `ThemeResolution.resolve` picks the narrowest one that
names a theme that exists.

Two rules carry the whole design, and both are pure functions of four arguments precisely so
they could be tested without standing up three singletons and a window:

- **Absent means inherit, not copy.** A chat or standalone terminal with no assignment follows
  its project, and a project with none follows the default, so changing the default still moves everything that
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

The assignments live on the records they theme (`AgentSession.themeID`,
`ProjectTerminal.themeID`, `Project.themeID`) rather than in a side table, so each is deleted
with the thing it applies to instead of outliving it and re-theming whatever reuses the
identifier. A standalone terminal inherits from the project at its **current cwd**, so moving
under another already-added project updates the palette with the sidebar placement.

`ThemeColorKey` names the palette's twenty colours once, as key paths with a `displayName` and
a snake-case `wireName`. The settings editor previously kept a `[String: NSColorWell]` and a
twenty-case `switch` to put a changed colour back, and the MCP schema needs the same mapping —
generating the tool's schema from the enum is what stops a colour being added to the model and
left out of the schema an agent reads.

**Scope is chosen where it applies**, which is a chat's, standalone terminal's or project's
own `⋯` menu — the same placement as the surface switch and the project icon. Only the default lives in Settings,
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

- **It is what the app ships with.** `TerminalProfile.default.theme` is
  `TerminalTheme.followsAppTheme`, the entry in stored form. It was `.basic` — white on black
  whatever the chrome did — and since every session and project ships on Inherit, the chain's last
  answer was the one scope that could not move: switching app theme changed the window and left the
  terminal inside it alone, which reads as one thing broken rather than two settings. It also left a
  light-mode window holding a black terminal, the case `WindowBackdrop` and the OSC 11 reply exist
  to keep coherent, and it hid every theme's designed pairing behind a submenu. **There is no
  migration**: `defaultTheme` is an embedded copy, so anyone with a saved profile — one
  `ProfileStorage.save` is enough — keeps the palette already on disk and changes it in Settings if
  they want the new behaviour. The same shadowing bites the test suite, because
  `PreferenceStore.hostedTestSuiteName` is a *named* suite: a default written by
  `ThemeToolTests` outlives its run, so a test asserting the shipped value must state its own
  starting point rather than read one off disk (`FollowsAppThemeTests`).
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
  set of anchors would not. The pull **ramps in with the chroma being compressed**: a colour
  quiet enough to be left at its own chroma has not asked for anything, and is not realigned
  either. Without that tie the transform was not the identity on quiet colours — a region
  filled with the terminal's own background had its chroma correctly left alone and its hue
  rotated anyway, so `#082019` came back `#06201C` and the block seamed against the real ground.
- **Below the knee the original colour is returned**, not a rebuilt one. The trip through Oklab
  and back is not bit-exact, so reconstructing a colour nothing is being done to still moves it
  a step — which is the same seam by another route. Returning the input is the only way to mean
  *unchanged*.
- **A colour the palette already states is left alone at any chroma.** A program can emit a
  palette entry as truecolor rather than as an index — anything echoing an OSC 4 query does —
  and the two spellings of one colour have to render identically. The palette is in tune with
  the theme by definition.

None of it knows what a diff is, deliberately: a rule that fired only on colours it guessed
were diffs would guess wrong on somebody's progress bar. Foregrounds are never offered to the
transform — a program's syntax highlighting is its own — and indexed colours never reach it,
being the palette already. `TerminalBackgroundHarmonyTests` pins the three guarantees.

A live app-theme switch is a terminal-theme switch for any chat or standalone terminal
following it, which is why `AgentSessionViewController` and `ProjectTerminalViewController`
observe `AppThemeDidChange` alongside the assignment events.

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
switched under a running agent does not reach it, and Claude's `/theme` does.

**Answering the question was not enough, so the answer is also stated up front.** The handshake
is the problem: the agent asks in its first few bytes, waits, and falls back to dark. Sessions
launched from a build that answers correctly still came up in the dark palette — the same
white-on-cream diff. Driven against Claude Code 2.1.220 in a bare PTY, the reply this app sends
is byte-for-byte one it accepts and switches on, so the sequence is right and the *timing* is
what cannot be relied on.

`TerminalTheme.colorFGBG` states the same fact where nothing can race it, and
`TerminalSession.buildEnvironment` writes it on every launch:

- `COLORFGBG=0;15` on paper, `15;0` on ink — rxvt's convention, `<foreground>;<background>` as
  ANSI indices. Only the background is ever read, and only for the one bit it carries.
- It is Claude's **fallback** behind its own query, not an override: `"theme": "auto"` consults
  it, an explicitly chosen theme still wins. Threading describes the terminal; it does not pick
  for the program. vim, less and delta read the same variable.
- Written from `profile`, not inherited. Threading is launched by launchd, so an inherited value
  describes whichever terminal started the app — and two sessions side by side need not agree.
- Reporting the palette's own nearest ANSI index would be worse than it looks: Bauhaus's slot 7
  is a dark grey-brown, so warm paper would have described itself with a colour nothing on
  screen is.

**The third leg: a switch under a running agent is announced.** The first two answers are both
given at startup, and Claude keeps whatever it heard — so a theme switched later repainted the
terminal and moved nothing on the agent's side. That is the white-on-white diff surviving a
correct handshake *and* a correct environment: a session that launched while the app was
briefly wearing another palette (a startup restore, 13 seconds in, was the reproduced case),
or the user switching themes with agents running, kept an agent painting the old page's ink
onto the new page forever.

Claude enables `DECSET 2031` (colour-scheme reports) at startup, and the report it subscribes
to — `CSI ? 997 ; 1 n` on ink, `; 2 n` on paper — is a **prompt to re-ask, not the news
itself**: on hearing it the agent sends a fresh `OSC 11 ; ?` and adopts that answer. This is
why feeding it `CSI ? 997 ; 2 n` by hand once read as "not wired up in 2.1.220": the terminal
behind the experiment kept giving the *old* answer to the re-ask, so nothing visibly moved.
The fork now tracks the 2031 subscription (`Terminal.colorSchemeReportingEnabled`, honoured by
`reportColorSchemeChange`), and `TerminalSession.applyProfile` reports through it whenever an
applied profile actually changes the emulator's background — palette first, report second, so
the re-ask hears the new page; font tweaks and re-applies of the same palette stay silent.
Driven against Claude Code 2.1.220 in a PTY: dark ink, report, re-ask, light ink, live.

`TerminalColorQueryTests` pins all three — the bytes on the wire, the environment the child is
launched into, and the announce → re-ask → new-answer exchange.

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

`Material.textScale` is the theme's companion multiplier (0.65–1.5), interpreted in the same
one transform and then composed with the user's scale. It lets a dense visual language such as
Windows 98 state period-sized chrome throughout instead of hard-coding an eight-point exception
in one title label. Absence is 1, so every older document is byte-for-byte the previous geometry;
the user remains the final multiplier. The app-theme tools and remote material DTO expose it.

The conversation gets its own slot for the reason the terminal always had one: it is the surface
that is *read*. `Typography.FontSurface` is a parameter on that single transform rather than a
second namespace — twenty factories in two copies would have to keep agreeing — and the composer
carries `.conversation` too, since what is typed becomes a bubble in the thread and a composer
in SF feeding a bubble in Baskerville changes font at the one moment the user is watching.

Three things no *font-family* setting reaches, and each is a rule rather than an oversight:
**code** is
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

Scrollbars follow that same identity rule without taking over scrolling. `ThemedScroller`
subclasses AppKit's control so geometry, hit testing, dragging, fades and the user's
overlay/legacy preference remain the platform's; under System its thumb and track draw methods
call AppKit unchanged. An authored theme draws only those two parts: secondary ink for the thumb
and a quiet surface role for the track, with the theme's radius. Ordinary scroll views resolve
against chrome ink. SwiftTerm keeps its legacy column but installs the same component with
backdrop ink, because the terminal palette — not the app theme — owns the ground beneath it.

**A scroller standing outside a scroll view fades itself.** "Fades remain the platform's" holds
only where a scroll view owns the scroller: it animates its scrollers, and while they are faded
it does not call their drawing parts at all, so an authored thumb costs nothing at rest.
SwiftTerm's scroller has no such owner — it is a bare `NSScroller` the terminal positions, sizes
and drives itself — so `draw(_:)` runs on every display pass and calls both parts
unconditionally. AppKit's own parts answer by painting nothing whatsoever: measured, a standalone
`NSScroller` covers zero pixels in either style, whatever the user's scroll-bar preference. That
is why the terminal had no visible scrollbar at all until the theme drew one, and why the one it
drew then stayed up through every session. `ThemedScroller` therefore owns the fade wherever its
superview is not an `NSScrollView`: down at rest, up when the *position* moves, held while the
pointer is on it, and gone `Design.Motion.scrollerHold` later. Deliberately not on
`knobProportion` — a terminal pinned to the bottom of a growing buffer reports the same position
while its thumb shrinks on every line an agent prints, so revealing on the thumb would hold the
bar up for the whole of a streaming answer. "Always show scroll bars" is honoured by never
hiding, since for a standalone scroller this component is the only thing that reads it.

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

**A theme states sizes as well as colours, so following one is a redraw *and* a remeasure.** Fixing
the seam left the mismatch in place from the other side, and this is why: `dividerThickness` is
computed per read, so the seam was right the moment the palette moved, while every `SeparatorView`
in the window — a pane header's rule, a footer's, the drawer's, the display panel's — is placed
against the size the constraint system last *asked* for, and `intrinsicContentSize` reading the
token live does not make AppKit re-ask. Repainting alone left every rule ruling for the theme that
had just left while anything built after the switch took the new weight, so arriving at Editorial
(1) from Neo Brutalism (3) drew hairlines, 3-point rules and a 1-point seam at once — and the three
styles the seam's own fix was checked against all happened to be entered from themselves.
`ThemeRedraw` now invalidates the intrinsic size beside asking for the redraw, which is the one
place that already knows a theme changed; a view that states no intrinsic size is unaffected, and
the sweep across the whole catalogue is `ThemedIndicatorsTests`
(`testEveryStockThemeRulesAtOneWeightThroughoutTheWindow`), entering each style from the heaviest
one so a stale rule has somewhere to show.

**A rule's *ink* is budgeted, and the budget is the text stem (2026-07-31).** Weight agreeing
everywhere made the loud themes uniformly loud: Neo Brutalism states `divider` at full label ink
under a 3pt rule weight, so every rule in the window drew as a black bar ~2.5× the stem of the
text beside it (SF 13 regular's stem is ~1.25pt, measured off a raster). Perceived heaviness is
thickness × ink, so the invariant is a *budget* — `AppTheme.Material.ruleInkBudget`, 1.3pt of
fully-opaque ink — and the ceiling it implies for a given weight is `Material.ruleInkCeiling`.
Enforcement lives in the one interpreter, `Design.Surface.divider`: authored alpha is capped at
the ceiling, never raised (eight of twelve stock themes already attenuate by hand and keep their
own values; Industrial's hand-authored 2pt × 33% is almost exactly what the cap derives for
Neo Brutalism), and Increase Contrast bypasses the cap for its floor. Because it is derived at
draw time, a custom or contributed theme cannot state its way past it — the gates still clamp
`borderWidth` to 0.5–4, and within that range the capped ink always clears the seam's visibility
floor. Three consequences to know about: the split seam now draws `Surface.divider` rather than
`Surface.border` (it is a rule between panes, and in the eight hand-attenuated themes the seam
was stepping in *ink* at the same crossing it once stepped in weight); `Design.Ink` gained
`rule` beside `border` so backdrop-drawn rules (the shell drawer's strip) state the same
decision; and `RemoteThemeBridge` applies the ceiling to the `divider` it projects, so remote
clients inherit the discipline instead of re-learning it. The catalogue sweep is
`ThemedIndicatorsTests.testEveryStockThemeKeepsItsRuleInkWithinTheBudget`, both appearances,
asserting the cap *and* that a quiet theme is never re-inked.

## 2026-07-31 — the active app theme is a living workspace document

**Current Theme** is an app-wide workspace surface, separate from both Settings and the
terminal-theme editor. That split follows the model rather than the word “theme”: the app chrome
has one active value for the whole window, while a terminal palette resolves through session,
project, and default scopes. Basic app-theme selection remains in Settings ▸ Appearance; the
living document is for inspecting, editing, and collaborating with an agent on the active theme.

The direct entry is in the display panel's `+` menu, below that chat's own surfaces and behind its
own separator, while at least one built-in theme MCP tool is enabled. **View ▸ Current Theme**
exposes the same command; it does not live under Window because it is a surface inside the main
window rather than another window. The document opens in the trailing display panel beside the
conversation, and the door is there because that is the pane it opens into: the entry was first a
standing row in the *leading* sidebar, above Settings, which made a permanent fixture out of a
pointer to something that column never shows — and left the panel with no way in at all. Being in
the `+` does not make it a session tab: it persists in neither per-session tab list, joins no
strip, and does not move between panels. Choosing it takes the whole panel. Selecting another
conversation keeps the app-wide document open so the user can compare or discuss it without losing
context; explicitly opening a session surface restores that session's ordinary tabs.

The `+` route goes through the window (`DisplayPaneController.onShowCurrentTheme`) rather than
calling `showCurrentTheme` directly, because opening it also has to uncollapse the panel and step
out of Settings — neither of which the panel can see. Unset, the entry falls back to showing the
document in place, which is what a standalone pane in a test does.

The page reads `AppThemeLibrary.current` every time it refreshes and exposes the theme's source,
available appearance variants, material, sidebar treatment, paired terminal colours, and the
thirteen authored semantic colour roles. Stock and contributed themes keep their swatches at full
strength but hide the contained colour wells; their direct **Duplicate to Edit** action goes
through `AppThemeLibrary.duplicate`, applies the copy, and leaves the same page unlocked. A custom
swatch change rebuilds only that variant, then goes through `AppThemeEditing.assemble` and
`AppThemeLibrary.update`, so the ordinary contrast gates, persistence, repaint, and notifications
remain the only write path.

The inverse flow is equally important. The document observes both `AppThemeDidChange` and
`AppThemeLibraryDidChange`, so an active document replaced through `update_app_theme`, or a
contributed document replaced by `ExtensionThemeWatcher`, re-reads into the open controls. An
appearance-observing root handles the one change with no library event: macOS moving an adaptive
theme between its light and dark variants. The short agent note in the document names the same
`get_app_theme` → `duplicate_app_theme (apply: true)` → `update_app_theme` vocabulary the tools
advertise; it teaches the door without adding a second authoring protocol.

The exception, and it is structural: the browser's device toolbar and find bar hide by dropping
their rule's height to **zero**, so those two weights are constraint constants rather than
intrinsic sizes — an intrinsic size cannot also mean "nothing". A constant is whatever it was last
set to, so `BrowserViewController` reapplies both (`applyRuleWeights`) on a theme change. Anything
else that collapses a rule this way owes the same reapplication.

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

## 2026-07-30 — the sidebar belongs to the theme

`SidebarStyle` is the one place a theme reaches past colours-and-material into a *region* of
the window: background layers under the project list (a gradient, then an image — tiled,
fitted or filled, at stated opacity), an optional navigator work area (opaque fill plus
raised/sunken/flat edge), and the brand row at the top (the logo slot, the
wordmark's text, family, size and weight). It is **variant-owned**, like the material and for
the same reason: a wash authored for a dark ground is wrong on a pale one. Everything is
optional, and absent means the sidebar exactly as it was — a document written before the
block existed decodes to a variant without one.

The sidebar and not the panes, deliberately. The sidebar's content is entirely ours (rows of
names), so a background can sit under it without any feature view knowing; the content pane's
ground is the terminal's or the conversation's, and painting behind another program's output
is not a theme, it is vandalism with a schema.

**Bytes never enter the document.** A theme document lives in `PreferenceStore` as JSON and
stays hand-writable, so the block references assets by name and the bytes live where the
theme's tier keeps them: a custom theme's in `ThemeAssetStore` (one folder per theme under
Application Support, fixed slot names — `light-logo.png`, `dark-background.png` — so
replacing overwrites and deleting the theme is one folder removal), a contributed theme's in
its package, read at **inspection time** by `ExtensionBundleLoader.inspectSidebarAssets` and
held in `ExtensionAppearanceRegistry` beside the icon marks. Nothing changed in the manifest:
the theme document *is* the contribution, so a package states sidebar images the way it
states any other part of the vocabulary, and old packages keep validating. Every image passes
the same `ProjectIconStore.normalizedPNGData` gate as every untrusted image in the app; the
`fillsItsBounds` anti-impersonation rule deliberately does **not** apply, because a sidebar
background is an opaque rectangle by design. A name that resolves to nothing degrades to the
default treatment — the dangling-reference rule everything here follows.

Four rules that were decisions rather than defaults:

- **The gradient faces the terminal palette's gate.** The sidebar is where every session is
  *found*, so a wash that swallows its labels locks the user out of the app as surely as an
  unreadable terminal. Each stop is composited over the variant's surface and must keep the
  label at the same 3:1 floor. An image is not gated — its pixels are arbitrary, so its gates
  are bounds (bytes, opacity) and legibility stays the author's to check by looking; the tool
  description says a photograph usually wants opacity well below 0.4.
- **The navigator well is regional, not another surface role.** Explorer's white, sunken tree
  sits inside silver chrome; making `surface` white would also repaint every panel. An absent
  well preserves the historical transparent list. A stated fill must be opaque and keep the
  variant's label at 3:1, and its edge only appears when the material supplies a bevel. The
  project scroll view opts into this semantic role; other `ThemedScrollView`s remain transparent.
- **An update says what happens to the block, not merely a new value.**
  `AppThemeEditing.SidebarChange` is inherit/remove/set, because a plain optional cannot tell
  "leave it alone" from "take it away" — and losing that difference means an update that
  changed one colour silently strips a theme's brand. The companion trap: `assemble` rebuilds
  every variant for its rename pass, and a `sidebar` dropped there vanishes on every create
  while looking untouched in the patch. `SidebarStyleTests` pins both.
- **The brand's stated family outranks the user's font override** — the one deliberate
  exception to "the user outranks the theme". The wordmark is identity, not prose: a chrome
  that ships its own name in its own face should not read in Iowan because body text does.
  It still degrades like every family (absent from the machine → the theme's typeface), and
  it rides the ordinary sweep because the recipe is a `FontRole` payload
  (`.wordmark(family:size:weight:)`) recorded on the label.
- **A duplicate owns its images.** `AppThemeLibrary.duplicate` (now the one duplicate path
  for the settings page and the MCP tool alike) copies a custom source's asset folder and
  *materialises* a contributed source's bytes out of the registry into the store, rewriting
  the document's names to slot names — otherwise disabling the extension would strip the
  sidebar off a theme the user now owns.

Resolution is `SidebarAppearance` — stated style in, drawable values out (decoded images,
sorted gradient stops, the wordmark's text and font recipe) — so the two consuming views
never touch stores or registries. `SidebarBackdropView` draws the layers (and restates every
frozen `CGColor` on each apply); `SidebarBrandView` wears the brand. Both re-resolve on
`AppThemeDidChange` *and* on `viewDidChangeEffectiveAppearance`, because an adaptive theme's
light/dark flip is a variant change no theme notification fires for.

Over MCP the block rides the existing app-theme tools as `variants.<kind>.sidebar` — same
snake-case vocabulary in `create_app_theme`/`update_app_theme` and back out of
`get_app_theme` (asset names, never bytes). Images arrive as `{path}` or `{base64}`;
`remove_gradient`/`remove_image`/`remove_title`/`remove` take stated halves back, refusing a
patch that sets and removes the same thing. The create path mints its id before building
variants so assets have somewhere to land, and removes the folder on any failure; the update
path snapshots the slot files it is about to overwrite and puts them back if validation
refuses the document that references them.

## 2026-07-30 — a contributed theme is a living document

An enabled extension's theme data now reloads **live**: `ExtensionThemeWatcher` (FSEvents,
one stream per enabled theme-contributing package, the `GitCheckoutWatcher` idiom) reports a
coalesced change, and `ExtensionManager.refreshContributedThemes` re-runs
`ExtensionBundleLoader.inspectThemes` — the same decode, the same validation, the same asset
gates as install — and replaces the registry contribution wholesale. This is what lets a
chrome *follow* something: an extension that rewrites its own theme document with the
weather, the hour, or a build's state, and an author iterating on a style with the app open,
both land as a repaint moments after the write.

Three decisions carry it:

- **Only theme data reloads.** The watcher feeds nothing but `inspectThemes`; a manifest
  edit still requires the update flow, because capabilities changed is a question the user
  answers, not a file event. Everything code-bearing keeps the values install validated
  (`ThreadingExtensionBundle.replacingThemes` replaces the one field).
- **A failed re-inspection keeps the last good version.** A watcher fires mid-write by
  design — a torn JSON is the ordinary case, not an attack — so runtime refusal logs and
  waits where install-time refusal fails the package loudly. A persistently broken edit is
  discoverable in the log rather than punished with a vanished theme.
- **The registry diffs values, not ids.** `replace` used to compare theme *ids*, so a theme
  that kept its identity and changed its answers repainted nothing — the active chrome held
  a stale value copy until the next manual switch, and a package *update* had the same
  latent bug. `contributedThemesDidChange` now re-applies the current theme when its
  resolvable value changed, which is the one line the whole feature hangs off.

The watchers reconcile in `syncAppearanceRegistry` — the same wholesale pass as the
registries, keyed by identifier *and root*, because an update swaps the package directory
aside and a stream on the old path reports nothing about the new one.

## 2026-07-30 — the standing choice is written where a hosted test cannot reach it

Reported as **"theme selection doesn't persist between app launches."** Nothing in the restore
path was wrong: `apply` records `appThemeID` on its first line, `restore()` reads it back, and
both were doing exactly that. What changed the answer was the **test suite**.

`ThreadingTests` is hosted in the app target, so `UserDefaults.standard` inside a test *is* the
developer's own preferences — the ones the app they are running launches into. Three test classes
apply a theme in `setUp` (`ThemedControlTests`, `DiffInkTests`, `ThemeResolutionTests`) and
exactly one of them put the old value back. So the last test to run answered the question, and
the next launch honoured that answer. Measured: a stored `swiss-minimalist` came back as `system`
after a single `-only-testing:ThreadingTests/ThemedControlTests` run. The same leak had already
left a palette named *Reserved Name Probe* standing in the real terminal-theme list.

So the store is decided **once**, in `PreferenceStore`: `.standard` in the app, a named scratch
suite when `NSClassFromString("XCTestCase")` answers — the signal `AppDelegate` already skips its
whole startup on, for the same reason. Everything that records a theme *choice* goes through it:

| Store | Key |
|---|---|
| `AppThemeLibrary` | `appThemeID` |
| `AppThemeStore` | `customAppThemes` |
| `ThemeManager` | `customTerminalThemes` |
| `ProfileStorage` | `terminalProfiles`, `defaultProfileName` (the profile carries the default palette) |

**Behavioural settings deliberately stay on `.standard`.** Several tests set an `AppSettings` key
and then assert the app read it; a seam under those would break the thing they are testing. The
line is *recorded choice* versus *behaviour under test*, not "everything in `UserDefaults`".

A test that needs to read a choice back reads it through `PreferenceStore.shared` too —
`ExtensionAppearanceTests` does, because reaching past the seam would assert against a key the
app no longer writes. `PreferenceStore.isRedirected` exists so the redirect is asserted rather
than assumed: a full 1868-test run now leaves the stored choice untouched, which is the
regression this is really guarding.

## 2026-08-02 — the window frame belongs to the theme (opt-in), and surfaces learn to bevel

Two additions arrived together for the stock **Windows 98** theme (`retro-98`), and both are
vocabulary rather than components: the theme states data, one interpreter draws it.

**`WindowChromeStyle` — the `chrome:` block.** The second and last regional block after
`SidebarStyle`, following all of its rules (variant-owned, optional, hex on the wire,
`decodeIfPresent` everywhere, an `inherit`/`remove`/`set` patch idiom in
`AppThemeEditing.ChromeChange`, carried by hand through `assemble`'s rename pass). Its
*presence* is an opt-in with teeth: while the theme is worn, the main window gives up its
native frame — titled mask, traffic lights, rounded corners, toolbar — and wears an app-drawn
title band, window buttons and border. The mechanics live in
[`window-chrome.md`](window-chrome.md); the block itself carries the band's active and
inactive gradients, its ink, alignment, height (18–44), the button glyph style, and a frame
width (1–6). Gates: the active band's ink holds the label's
3:1 against every stop — the band carries the window's own close button — while the inactive
band gets the softer 2:1 "tellable" floor, because inactive title text signals inactivity by
carrying less ink (the authentic 1998 inactive pair sits at 2.6:1). An adaptive theme states
chrome in both variants or neither: band colours may differ by appearance, whether the window
wears its own frame may not.

**`Material.bevel` and the two edge roles.** A bevel material
(`bevel: {width: 1...3}`, square radii required by validation) turns every applied or drawn
surface's flat border into the classic two-tone edge: `bevelHighlight` on top and leading,
`bevelShadow` on bottom and trailing, mitred diagonally, swapped for surfaces that state
`SurfaceBevel.sunken` (text wells: `ThemedTextField`, the composer's `PromptView`). The two
roles are *roles* — not `.authored`, deriving from `surface` at ±0.45 — precisely so
`applySurface` records participation rather than colours and the theme sweep re-resolves both
directions of a live switch: arriving raises every automatic surface, leaving strips every
edge (the glow's "cleared rather than skipped" rule). The layer path hangs a nine-part
stretched bitmap (`BevelArtwork`) so resizing never rebuilds a path; the draw path
(`ThemedSurface.draw`) draws the same construction live. A rounded shape under a bevel
material keeps its flat border — a rectilinear edge has no honest offset curve — which is the
rule that lets discs and pills coexist with the material. `SurfaceBevelTests` pins all of it,
including that every pre-existing stock theme draws byte-identically.

Both blocks have full MCP parity (`create_app_theme`/`update_app_theme`/`get_app_theme`
round-trip them; `chrome.remove` hands the frame back live) and are deliberately **not**
projected to iOS by `RemoteThemeBridge` — no window frame there, no bevel interpreter, and the
two roles ride the resolved colour map anyway. `ThemeToolTests` holds the tool loop.

## 2026-08-04 — title chrome becomes a reusable period vocabulary

The stock **Mac OS 9 Platinum** theme (`platinum-9`) is the second frame-takeover user and the
first proof that `WindowChromeStyle` is not a Windows-shaped switch. `TitleBar` now states
button placement (`trailing` or `split`), whether the application icon appears, and optional
active/inactive textures. The first texture kind, `pinstripes`, draws hard horizontal rules and
interrupts them behind a centred title; the first non-Windows glyph family, `platinum`, draws
the classic inset Close, WindowShade, and Zoom boxes. These are data read by the same
`WindowTitleBandView` and `WindowChromeButton`, not checks for `platinum-9`.

The full vocabulary is writable through `create_app_theme` and `update_app_theme`, including
removal of optional ink, height, and texture choices and partial texture updates. This is a
load-bearing custom-theme rule: a prompt discovered outside the stock catalogue can reproduce
the same layout and material without adding Swift code. `get_app_theme` returns those choices
in the same snake-case document.
