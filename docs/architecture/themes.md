# Themes

Terminal themes, app themes, and the three scopes both resolve through.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

Historical frame takeovers additionally carry a component-by-component evidence ledger under
[`docs/references/chrome/`](../references/chrome/README.md). A chrome is not considered
reference-complete merely because its title band exists: every manifest must account for the
window frame, window buttons, toolbar, form controls, menus, popovers, scrollbars, lists,
progress, transients, typography, and icons. Third-party screenshots remain at their recorded
origin; checksums and top-left pixel crop recipes make their exact extractions reproducible in a
gitignored local cache. `scripts/check_theme_boundaries.sh` validates the ledger on every build.

**Cheetah and Tiger are separate Aqua materials.** Cheetah keeps the first public release's
pinstriped title band, saturated ribbed scroller family, and bookended arrow layout. Tiger
(`aqua-tiger`) uses Finder's brushed-metal title surface, a slimmer blue gel thumb, neutral
silver line buttons grouped at the trailing end, and a rounded pop-up with a blue up/down
segment. Those differences are authorable enum values (`brushed_metal`, `aqua_tiger`, and
`aqua_popup`), never checks against a stock theme ID, so a custom theme can reuse the same
historical parts.

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
identifier. A standalone terminal inherits from the project that owns its durable record. A
`cd` changes the shell's runtime context, not its palette or project identity.

`ThemeColorKey` names the palette's twenty-one colours once, as key paths with a `displayName` and
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
  they want the new behaviour. The same shadowing used to bite the test suite, because
  `PreferenceStore.hostedTestSuiteName` is a *named* suite and a default written by
  `ThemeToolTests` outlived its run. The name now carries the test host's pid, so it does not —
  but a test asserting the shipped value should still state its own starting point rather than
  read one off disk (`FollowsAppThemeTests`), because within one process the shadowing is real.
  Why the pid is there at all is a different failure, and it is in
  [`persistence.md`](persistence.md#2026-08-15--the-same-race-one-domain-further-out): the shared
  name let two concurrent suite runs read each other's recorded theme choices.
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

**A program-selected foreground is diagnosed, never corrected.** An ANSI or 24-bit foreground
can still equal the final background — `SGR 97` over System Light is the concrete failure, where
bright white and the page are both `#FFFFFF`. Rewriting it would corrupt program output and hide
the actual configuration error, so SwiftTerm measures the final rendered pair only while a
meaningful run is visible and reports ratios below 1.25:1. Default foreground is excluded: ANSI
39 is the safe way for a prompt to delegate legibility to the terminal. Whitespace, ornament and
SGR concealment are excluded too, and both renderer caches are bounded against arbitrary
truecolor output.

`TerminalTextVisibilityIssue` carries the exact source roles, resolved RGB values, ratio,
terminal identity and theme. The pane names the program/theme conflict, says Threading shows the
colour as sent, offers ANSI 39 and a direct route to Theme Settings, and can be dismissed. A
dismissal is durable for that exact theme/source/RGB signature rather than for the terminal
instance, so the same prompt does not nag once per tab while a different palette remains a new
context. Applying a profile invalidates the old finding before SwiftTerm clears its measurements:
if the new palette is still bad the next visible draw reports it again; if it fixed the pair, no
stale explanation survives.

**The notice also says what went missing, and shows the pair.** Two hex values are a true
statement about a screen the reader has already looked at and found nothing wrong with, because
the evidence is the part they cannot see: `#505050` on `#464646` reads as two colours in a
sentence and as one flat field on the terminal. So the conflict carries a **sample of the run
itself** — the words the band then quotes, which is what turns the notice into a place to look —
and the band carries a `ColorPairSpecimenView` showing the two colours touching under an "As
drawn" caption, where a pair four steps apart is visibly one block. The sample is program output and is treated as such:
SwiftTerm strips control characters, collapses whitespace, and caps it at
`TerminalContrastSample.characterLimit` with the cut declared by an ellipsis. Only the *character*
bound claims a cut — a row is padded to its width, so a short label inside a long run reaches the
scan bound having kept everything there was to keep, and `hello…` would say the opposite. An
empty sample falls the copy back to the colours alone.

Deduplication stays keyed on the **colour pair**, not on the reported conflict, so a program
printing a second unreadable word is still one collision rather than a second notice. The sample
stays out of `signature` for the same reason from the other end: a quote must never turn a
dismissed finding back into a new one.

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

**A runtime that does not subscribe hears none of that, and Codex is one.** `strings` on the
0.147.0 binary contains no 2031 anywhere, so the announcement above is sent into a program with
nothing to receive it. What it does have is a re-read hung off *focus*, which makes a focus
report the only prompt it can hear. Measured in a bare PTY that answers `OSC 10/11` in
microseconds, so none of the timeout stories apply: told the background is `#101060` it derives
a `#2C2C73` composer plate, so the startup probe succeeds and the cached palette is correct. It
then never asks again. 0.146.0 answers a synthetic focus report with a fresh `OSC 10 ; ?` /
`OSC 11 ; ?` pair and repaints to `#F4F4F4` when the answer becomes white; 0.147.0 removed that
path and ignores it, while still enabling `DECSET 1004` and still parsing the event (a control
keystroke written straight after the `CSI I` comes back echoed). This is what a user sees as a
`#393939` composer plate with `#CFCFCF` ink sitting inside a white Tiger terminal, with quitting
and resuming the session the only recovery.

So `applyProfile` sends a second prompt in the only dialect that runtime speaks:
`promptColorRereadThroughFocus` re-states this terminal's focus after the palette lands.
`setTerminalFocus` emits nothing unless the program asked for focus reports, so a program that
never opted in is sent no stray input — the guard that makes this safe to do for every session
rather than for a named runtime. It is only sent while the terminal really *is* focused, because
a focus report is a statement about where the user is looking and this one has to stay true; a
theme that moves behind the app's back, macOS going dark at sunset under an adaptive theme, is
carried on a one-shot key-window observer and delivered when the user is looking again. SwiftTerm
reports focus from the responder hooks alone, so a window merely becoming key emits nothing by
itself and the carried prompt is the only thing that covers that case.

**This is a workaround with an expiry date.** It is inert on current Codex, works on older ones,
and starts working again if the re-query returns. Filed both halves upstream:
[openai/codex#18942](https://github.com/openai/codex/issues/18942) for the removed re-query, with
the measurement and a standalone repro harness, and
[openai/codex#38575](https://github.com/openai/codex/issues/38575) asking for 2031, which is the
only mechanism that covers a theme changing in a window that never loses focus. **Delete
`promptColorRereadThroughFocus` when those are answered** rather than leaving a synthetic focus
report in the stream forever.

**The fourth leg is a claim the app has to *stop* passing on.** `NO_COLOR` describes a stream,
and the stream a session hands its child is a PTY that Threading paints — so an inherited one is
always a statement about somewhere else. It arrives whenever the app is opened from a pipe, a CI
shell, or another agent's tool call, all of which set it alongside `TERM=dumb`; `buildEnvironment`
already restated `TERM`, so the claim outlived everything that made it true and nothing
contradicted it. Every agent in that app instance then drew its whole TUI unstyled.

What that costs first is not a hue but a **rank**. The agent CLIs mark their own chrome with bare
SGR 2 (faint) and no colour of its own — the composer's `Try "…"` hint, a proposed prompt, the
status footer's rules — so under `NO_COLOR` a suggestion reaches the terminal at exactly the
strength of text the user typed. That is
[`dependencies.md`](dependencies.md)'s faint bug arriving from the far side, where no renderer fix
can reach it, and it reads identically on screen: the renderer was measured correct against the
CLI's own captured bytes while the app was still handing every session the reason there were none.
The tell was the rest of the same frame — Claude Code paints `⏵⏵ auto mode on` amber and the line
after it `#999999`, and a screenshot with *zero* saturated pixels anywhere in that footer is not a
faint regression.

`NO_COLOR` is cleared outright, because absence is the only way to say "colour is fine".
`CLICOLOR` and `FORCE_COLOR` are cleared only when spelled `0`: any other value is the user asking
*for* colour, and this is the same rule as `COLORFGBG` — describe the terminal, do not choose for
the program. `PAGER`/`GIT_PAGER`/`GH_PAGER` set to `cat` go the same way and for the same reason,
a caller that cannot page saying so; a real pager is a choice and stays. All of it is scoped to
`TerminalSession.buildEnvironment`, never `AgentEnvironment.launchEnvironment`, because on the
headless path there is no PTY and every one of these claims is simply true.

The rest of what a launcher leaves behind — `CODEX_SANDBOX_NETWORK_DISABLED` and the runner
identity families it travels with — is not about the stream and is filtered a step earlier; see
[`sessions.md`](sessions.md).

`TerminalColorQueryTests` pins all four — the bytes on the wire, the environment the child is
launched into, the announce → re-ask → new-answer exchange, and what the environment must not
carry — plus the focus prompt: sent to a program that asked for focus reports, withheld from one
that did not, withheld on a font tweak, carried across an unfocused switch, and sent once rather
than on every window activation.

## A theme states a typeface

`AppTheme.Material.typeface` is the other half of a style brief. The styles these themes come
from (designprompts.dev) carry a `fontType` per style as plainly as they carry a palette —
Newsprint and Art Deco are serif, Cyberpunk and Vaporwave mono, Claymorphism rounded — and a
theme that recolours SF Sans is typographically still System. The four values are macOS's own
font designs (`NSFontDescriptor.SystemDesign`), so **nothing is bundled**, every weight exists,
and rendering is the platform's.

`material.fontFamily` sits above it for a theme whose identity is a *particular face* rather
than a class: "Newsprint, set in Baskerville" is not one of four. `fontFallbacks` is the ordered
chain behind it. The first installed family wins, then the recipe degrades to `typeface`; this
lets a retro theme preserve Charcoal, MS Sans Serif, Swis721 BT, or Topaz as its real answer
without redistributing a proprietary face or pretending a modern substitute is historically
exact. Installing the preferred face later promotes it automatically. The narrow open
exceptions are scoped to the historical chrome that needs their raster rules: Windows 98 ships
the OFL W95FA recreation behind the two real Microsoft family names; Platinum's title and menu
painter ports Systemless 0.2.1's independently hand-drawn OFL Jarrah 12 bitmap artwork; and
Workbench ships dMG's GPL-FE Topaz 2.x recreation as a separate font resource behind the real
Topaz family. Each includes its complete notice and provenance. A legitimately installed
preferred face remains first in the ordinary family chain. Custom-theme tools expose that chain
as `font_family` and `font_fallbacks`, and require at least one authored family to resolve on the
machine doing the authoring so a misspelled chain cannot silently ship.

`Material.headingStyle` is the semantic exception inside that prose answer. The source styles
often pair faces rather than choosing one globally: Botanical's display type is serif over a
sans reading face, Newsprint's display serif is much heavier than its body, and Art Deco's
headings are lighter than its controls. The optional block can state a heading-only `typeface`,
`fontFamily`, `fontWeight`, and italic flag; every unstated field inherits the ordinary material
recipe and a missing named family falls through in the same order. It reaches `.heading` and
`.markdownHeading`, not body, controls, code, numerics, or the terminal. The user family override
still wins — the theme authors the display grammar, not the reader's installed-face choice.
Custom and contributed themes get the identical vocabulary through
`material.heading_style`/`remove_heading_style` in create, update, and get; stock themes do not
receive private branches in `Design.Typography`.

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
The stock Windows 98 material deliberately stops at `0.80`, rather than mathematically reducing
every role to the shell's eight-point default: title, menu, and control copy stay compact while
the project tree and longer application text remain readable on a modern high-resolution display.

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
subclasses AppKit's control, and under System its geometry and drawing go straight back to
AppKit. `scroller_appearance: automatic` retains the modern proportional thumb, the user's
overlay/legacy preference, and the ink-source split: ordinary scroll views resolve against
chrome while SwiftTerm resolves against its terminal backdrop. A named period appearance is a
different contract because the control's anatomy is the style: `windows_98`, `platinum`, `beos`,
`openstep`, `irix`, `amiga`, and `aqua` each supply square track space, line-arrow hit regions,
era-specific thumb relief and grip, and the correct bookended or paired arrow placement. Those
controls force persistent legacy-width space; an overlay pill cannot truthfully contain end
arrows. AppKit still owns the value and invokes the control's normal tracking machinery, while
the subclass's `rect(for:)` and `testPart` give that machinery the authored geometry.

**A scroller standing outside a scroll view fades itself.** "Fades remain the platform's" holds
only where a scroll view owns the scroller: it animates its scrollers, and while they are faded
it does not call their drawing parts at all, so an authored thumb costs nothing at rest.
SwiftTerm's scroller has no such owner — it is a bare `NSScroller` the terminal positions, sizes
and drives itself — so `draw(_:)` runs on every display pass and calls both parts
unconditionally. AppKit's own parts answer by painting nothing whatsoever: measured, a standalone
`NSScroller` covers zero pixels in either style, whatever the user's scroll-bar preference. That
is why the terminal had no visible scrollbar at all until the theme drew one, and why the one it
drew then stayed up through every session. An automatic `ThemedScroller` therefore owns the fade
wherever its superview is not an `NSScrollView`: down at rest, up when the *position* moves, held
while the pointer is on it, and gone `Design.Motion.scrollerHold` later. Named period controls
stay visible, as their occupied track and arrows are permanent window furniture. Deliberately not on
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

**A theme's glow is one or two layer shadows, and a shadow spills past the panel that casts it** — so a
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

The optional `glow.highlight` is the second outer shadow, not another halo blended into the
first. It has its own role, radius, opacity and offset, is subject to the same gutter gate, and
is drawn by an expanded exterior-only companion layer. A transparent Core Animation layer with
only a `shadowPath` is not exterior-only: as a sublayer its shadow composites above the parent's
background, so Cyberpunk's centred opaque highlight painted its entire dark card lime. The
companion now draws into a canvas large enough for the blur and offset, with the caster's exact
rounded face clipped away; the authored fill and its text remain untouched while both shadows
survive outside it. This keeps the primary lower-right shade diffuse while the upper-left light
travels the other way — the paired construction the Claymorphism source actually uses. Documents
without it decode exactly as before; theme tools can set it, remove it independently, and read
it back.

**The face is removed by a clip, not by a `.clear` pass over it.** Erasing the opaque caster
afterwards looks equivalent and is not: `.clear` removes the coverage it is *given*, so an
antialiased edge pixel that took `α` of the caster gives back `α` of what it then holds and
keeps `α(1 − α)` — a quarter of a black shape at half coverage, and half of one where a material
states a highlight companion too, since both casters stack. A square material hid that residue
under its hairline border. Clay wore it as a dark line tracing the corner of every chip, button
and card that haloes, most visible on a pill's long arcs and on the composer card's 32-point
corners; it read as a broken border, and on a chip whose resting fill is clear there was nothing
drawn over it at all. The caster is now confined to the outside by an even-odd clip and stops one
device pixel short of it, for the same reason `SoftBevelArtwork` keeps its own caster one pixel
*beyond* its silhouette: two antialiased curves on the same line multiply instead of cancelling.
`SurfaceBevelTests` holds a halo to its own role — it may darken what is under it as far as the
authored colour goes and no further.

**Clearing a halo removes every caster on the view, not the ones the clearing call can name.**
The two entry points name their companions differently (`threading.controlGlow.*` for the tight
control depth, `threading.glow.*` for the broad panel one) and a control crosses between them:
`ChipView` raised under the pointer asks for the control pair, and at rest is restyled through
the panel path with no halo at all. Clearing by name meant that second call looked for casters
that had never been installed, found none, and left the pair in place — so one pass of the
pointer put a violet halo on a chip for the rest of the session, with the caster's edge showing
as a ring around a plate that was no longer drawn. Casters are collected by type instead, and
anything the call is not about to keep is discarded.

`material.controlGlow` is the same paired vocabulary at control scale. It is separate rather
than an automatic fraction of `glow` because the live Clay source makes a semantic distinction:
white cards cast broad neutral-lavender depth, while buttons cast a tighter violet shadow. Drawn
controls opt into that spec without freezing their state; applied control surfaces record the
same participation for the theme sweep. A compact control that is pressed drops its outer lift,
and tertiary marks cast nothing. Custom-theme tools expose `control_glow`,
`remove_control_glow`, and the nested highlight with the same partial-update and validation rules
as panel glow. Older documents decode it as nil and keep flat controls.

Buttons choose that depth semantically rather than by size. A primary action uses `controlGlow`;
`buttonStyle.secondaryShadow` tells an ordinary bordered action to reuse the compact `control`
shadow, the broader neutral `panel` shadow, or `none`. Industrial needs this split exactly: the
live reference gives coral CTAs a tight coral pair, while grey secondary actions keep the
grey/white neumorphic panel pair. The authoring wire spells the field `secondary_shadow`, and
older documents default to `control`.

`material.popoverStyle` is the floating-surface grammar shared by every product popover. It
states whether the anchor has a triangle stem, which semantic role fills it, whether its edge is
flat, absent, or interpreted through `material.bevel`, whether depth is the native window shadow,
the authored panel shadow, automatic, or absent, and whether geometry and semantic glyphs are
regular/System or compact/classic. The default is the historical modern speech bubble; automatic
depth uses `glow` when the material authors one and the native shadow otherwise. A material edge
requires a stemless surface, because the bevel interpreter owns one coherent silhouette rather
than guessing how a hard or soft edge turns around a speech-bubble junction. Authored shadows get
the same 48-point gutter as panels, now inside the popover's transparent child window, so hard
Neo Brutalist offsets and Claymorphism's paired soft light are not clipped to the card. The full
block round-trips through `popover_style`/`remove_popover_style` in the app-theme tools.

`floatingSurface` is the colour role paired with that grammar. It derives from `elevated`, so old
and sparse documents keep their previous surface exactly; a theme can state it independently when
the period component genuinely differs. Windows 98 does: its compact, square, stemless,
shadowless infotip uses pale information yellow (`#FFFFE1`) behind a thin dark rule and classic
folder/branch/status marks. Platinum does too: its floating surface is the gray button face
(`#DDDDDD`), not the white that the period reserved for writable and list wells. That distinction
is invisible over the theme's ordinary gray chrome but load-bearing over its white terminal,
where a white status card became a border around apparent empty space. Platinum, BeOS, OPENSTEP,
IRIX, and Amiga use the same stemless compact language and consume their hard material bevels.
Claymorphism and Neo Brutalism use stemless material edges and their authored shadow construction
instead of the unconditional macOS one.

`tooltipSurface` is the narrower role for a hover/help tag when a period's information plate is
not the same object as its modal or floating card. Aqua Cheetah and Aqua Tiger use a pale-yellow
ground with a compact, stemless, near-square plate (`corner_radius: 1`) and native-looking dark
Lucida copy. Tiger's 2005 HIG figure supplies measured plate geometry (about 125 x 18 points,
one-pixel warm edge and a soft lower/right shadow); Cheetah's surviving figure is from the later
2001 HIG, so that material is explicitly source-shaped rather than claimed as a measured 10.0.x
pixel match. Alerts continue to consume `floatingSurface`, so a Help Tag's yellow role cannot
leak into a modal requester. Custom themes may author both the role and the optional
`popover_style.corner_radius`; older documents decode to the existing panel radius and the
existing `floatingSurface` fallback.

`material.buttonStyle` carries the action language that palette and geometry cannot express:
title transform, weight, a button-only typeface class or installed family, and tracking; filled
versus outlined primary actions; the semantic roles for their fill and optional border; ordinary
button resting/hover surface roles; and the small hover/press translation used by hard-shadow
styles. Separate ordinary-button roles let tactile themes put raised white actions beside
recessed coloured inputs without changing the global control palette. The face is sparse: nil inherits prose,
a missing named family falls through to its class and then prose, and the user's chrome-family
override still wins. This is what lets Art Deco and Newsprint pair their action labels with their
display face without refonting every field and toggle. `ThemedButton` is the sole interpreter, so
the visible title may be uppercase while the authored and accessibility title remains unchanged.
Every field is available through the custom theme tools and older documents decode to `.system`,
preserving the historical control behavior.

`material.borderWidth` remains the structural weight for cards, separators and pane rules.
`material.controlBorderWidth` optionally gives compact controls their own edge weight; nil inherits
the structural value, so older and sparse custom documents preserve their existing appearance.
This is the measured Bauhaus split: four-point structural ink around cards and two-point ink around
buttons, with the control's four-point lift remaining independent in `controlGlow`.

`material.backdropPattern` carries the repeating ink used by the source styles' broad page
surfaces: dots, an orthogonal grid, a diagonal grid, or the converging perspective grid used by
Vaporwave, each with a semantic colour role, opacity, spacing and mark width. Participation is
explicit at the component seam
(`pattern: .backdrop`); it is never inferred from a ground colour or a zero radius, because a
compact find bar can legitimately share both and must not become wallpaper. The pattern is a
resizing layer below child content rather than a raster baked into the fill, so it does not
stretch and it re-resolves on theme and appearance changes. Custom-theme tools can set, remove,
partially update and read the full block; older documents decode it as nil and remain flat.

**`material.borderWidth` is a rule weight, and every rule in the window obeys it — including the
one AppKit draws.** `SeparatorView`, the shell drawer's grab strip and a table's column rules all
take `Design.Radius.border`; `NSSplitView.dividerStyle = .thin` is a fixed point and does not.
Under heavily ruled Bauhaus and Neo Brutalism, the window therefore drew pane-header rules meeting
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
from Neo Brutalism drew hairlines, heavy rules and a hairline seam at once — and the three
styles the seam's own fix was checked against all happened to be entered from themselves.
`ThemeRedraw` now invalidates the intrinsic size beside asking for the redraw, which is the one
place that already knows a theme changed; a view that states no intrinsic size is unaffected, and
the sweep across the whole catalogue is `ThemedIndicatorsTests`
(`testEveryStockThemeRulesAtOneWeightThroughoutTheWindow`), entering each style from the heaviest
one so a stale rule has somewhere to show.

The same rule applies to a band's *budget*. A pane header used to be `tabHeight + 2 × small`
while its separator was pinned inside that fixed height. That happened to look balanced with a
hairline, but Bauhaus's four-point rule took four of the six points below the selected tab and
left all six above it. `PaneHeaderView.bandHeight` now includes the current rule *after* both
content margins, and both `PaneHeaderView` and `ThemedTabStripView` centre their row in the area
above it. The height constraints remeasure on `AppThemeDidChange`; `PaneNoticeView`, which shares
the header's floor, does the same rather than caching the first theme's answer.

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
floor. Three consequences to know about: the split seam starts from `Surface.divider` rather than
`Surface.border` (it is a rule between panes, and in the eight hand-attenuated themes the seam
was stepping in *ink* at the same crossing it once stepped in weight), then steps up to the
theme's border — and past that to the least neutral ink measured from the backdrop that still
clears the floor — only when the authored rule falls below the seam's visibility floor. That
ladder is measured, not owned: it used to ask whether the chrome or a terminal palette had
painted the ground, which under System dark is the same `#1E1E1E` either way, so the same pixels
carried a 9.8% seam and a 30% one depending on whether a session was selected (see
[`window-chrome.md`](window-chrome.md)). `Design.Ink` gained
`rule` beside `border` so backdrop-drawn rules (the shell drawer's strip) state the same
decision; and `RemoteThemeBridge` applies the ceiling to the `divider` it projects, so remote
clients inherit the discipline instead of re-learning it. The catalogue sweep is
`ThemedIndicatorsTests.testEveryStockThemeKeepsItsRuleInkWithinTheBudget`, both appearances,
asserting the cap *and* that a quiet theme is never re-inked.

**The backdrop pattern is budgeted the same way, and it is the same theme caught twice
(2026-08-17).** `backdropPattern` documents itself as "a restrained repeating treatment", but
nothing held a theme to that word: the editing gates check that `opacity` is within 0...1,
`spacing` within 8...64 and `lineWidth` within 0.5...6, and every one of those passed while
Neo Brutalism stated `role: .label, opacity: 1` — its dot field in the body text's own ink, 3pt
marks every 20pt, on the ground that body text sits on. Reported from use, against the About
window's version pair, and visible in nothing but a picture: no assertion anywhere was wrong.

A mark's weight is its size times its ink exactly as a rule's is, so the invariant has the same
shape: `AppTheme.Material.backdropInkBudget` is 0.8pt of fully-opaque mark, and
`Material.backdropInkCeiling` is the ceiling it implies for a given `lineWidth`. Enforcement lives
in the one interpreter, `Design.applyThemeBackdropPattern`. Three details are load-bearing:

- **Authored strength is the role's alpha *times* the stated opacity.** Both are folded into the
  layer's opacity and the ink goes on at full alpha; capping `opacity` alone would let a
  translucent role multiply past the cap after it was applied.
- **Increase Contrast does not lift it**, which is where it parts company with `ruleInkCeiling`. A
  rule is content beside content, so contrast asked for is contrast given; a pattern is *behind*
  text, where more ink is strictly less legible.
- **It is the loosest cap that fixes the report.** Of the six stock themes authoring a pattern it
  attenuates one — Neo Brutalism, to 0.267, next door to the 0.325 the rule budget already derives
  for it — and leaves the other five at exactly what they state, Bauhaus's 4pt dots at 0.20
  included (0.80, level with the budget). 0.267 came off a rendered ladder, not a guess: the words
  win from about 0.27 down and the dot field is still unmistakably the theme's.

The sweep is `BackdropPatternRenderTests`, which holds the budget, the "quiet themes are never
re-inked" half, the exact landing point, and the Increase Contrast rule — plus the renders that are
how the *next* one gets noticed: body and detail text over each patterned theme's ground, which is
the pair nobody had ever looked at.

**The same sweep found a second one, and it was not an ink problem at all.** Vaporwave's
perspective grid drew a solid accent plate across the bottom two-thirds of every ground it was on,
and text crossing it was unreadable — worse than the dots that started this. No ink budget can
reach that: its marks are *inside* the budget (2pt × 0.30 = 0.60), and the plate is made of
**crowding**, not ink. Lines converging on a vanishing point have unbounded density near it, so at
any opacity a uniform stroke stops being a grid and becomes a fill; capping it further would only
dim the foreground while the plate stayed.

So the fix is in the drawing: the family is clipped through a one-column DeviceGray ramp
(`ThemeBackdropPatternLayer.convergenceMask`) that takes its ink to nothing as it closes on the
vanishing point. That is also what distance does to contrast, so the grid *recedes* rather than
ending, and Vaporwave still reads as Vaporwave. The ramp is `pow(depth, 2.2)` rather than linear
because crowding accelerates faster than distance does — a linear falloff still filled in over the
last stretch. Two things worth knowing if you touch it: row zero of the mask lands at the **near**
edge in this context (the first attempt drew it upside down, fading the foreground and leaving the
band sitting on the horizon — the render is what said so), and the ramp is cached and stretched
into whatever field a pane gives it, since only the shape of the falloff matters.

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

**A recovery launch wears System without recording it.** `restore(_:)` pins `.system` under
`.recovery`, in memory: nothing in `restore` writes, so the whole guarantee is bought by taking that
path and never `apply`, which records even a pick that changes nothing on screen. It is System
rather than "the stored choice if it happens to be stock", because a stock theme carrying a
`WindowChromeStyle` opts the window into the app-drawn frame — a great deal of launch-time
machinery and a plausible place to die. The Appearance page therefore selects
`AppThemeLibrary.storedThemeID` rather than what is in force, or clicking the entry that already
looks selected would record System over the user's theme; a pick made there still records, because
what recovery forbids is the *launch* writing a choice nobody made. See
[`crash-recovery.md`](crash-recovery.md).

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
inactive gradients, its ink, alignment, height (18–44), the button glyph style, whether the
window's own commands take a row of their own or share the caption (`commands`, default
`own_row`), and a frame width (1–6). Gates: the active band's ink holds the label's
3:1 against every stop — the band carries the window's own close button — while the inactive
band gets the softer 2:1 "tellable" floor, because inactive title text signals inactivity by
carrying less ink (the authentic 1998 inactive pair sits at 2.6:1). An adaptive theme states
chrome in both variants or neither: band colours may differ by appearance, whether the window
wears its own frame may not.

**`Material.bevel` and the two edge roles.** A hard bevel material
(`bevel: {width: 1...3, style: "hard"}`, square radii required by validation) turns every
applied or drawn surface's flat border into the classic two-tone edge: `bevelHighlight` on top
and leading, `bevelShadow` on bottom and trailing, swapped for surfaces that state
`SurfaceBevel.sunken` (text wells: `ThemedTextField`, the composer's `PromptView`). The two
roles are *roles* — not `.authored`, deriving from `surface` at ±0.45 — precisely so
`applySurface` records participation rather than colours and the theme sweep re-resolves both
directions of a live switch: arriving raises every automatic surface, leaving strips every
edge (the glow's "cleared rather than skipped" rule). The layer path hangs a nine-part
stretched bitmap (`BevelArtwork`) so resizing never rebuilds a path; the draw path
(`ThemedSurface.draw`) draws the same construction live. A rounded shape under a hard bevel
material keeps its flat border — a rectilinear edge has no honest offset curve — which is the
rule that lets discs and pills coexist with that construction. `SurfaceBevelTests` pins all of
it, including that every pre-existing stock theme draws byte-identically.

The later Claymorphism pass added the second construction without adding a theme branch:
`bevel.style` is `hard` by default, preserving that entire contract, while `soft` follows the
rounded silhouette with two blurred inset shadows. A narrow antialiased ring was still a border:
at 32-point corners it made a continuous lavender outline the live reference does not have. The
inverse rounded caster now sits outside the clipped surface, so only its diffuse shadow enters
and naturally fades around the offset curve. Raised controls put light at top-leading and shade
at bottom-trailing; wells and broad panels reverse that inner pair, matching the source's mixed
button/card recipes while their outer shadow still raises them. The same nine-patch/live-draw
split keeps layer-backed panels and drawn controls identical. Soft relief may therefore coexist
with rounded radii. The finished clay construction combines all three depths measured from the
live source rendering: the primary `glow` supplies the neutral-
lavender lower-right shade (16-point travel and a 16-point Core Animation radius, matching the
source's `16px 16px 32px` CSS shadow), `glow.highlight` supplies the opposing white
`-10px -10px 24px` lift, and the soft bevel supplies the much quieter inset white-facing edge
and violet shade. `controlGlow` carries the source's violet button depth, scaled from its
56-point web buttons to Threading's 26-point controls. The larger source-faithful panel shadow
is why `glowGutter` is 48 rather than an
ordinary spacing token; the settings and onboarding hosts budget it explicitly, while general
page spacing remains unchanged. On a large-radius toast the countdown strokes the lower half of
each bottom corner and the edge between them, so it follows the panel without climbing far enough
up either side to read as a partial border. That choice follows panel geometry rather than the
bevel capability: radii at the `large` spacing threshold or above get the contour; ordinary and
square corners keep the compact straight edge rail.

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

**BeOS R5** (`beos-r5`) extends that vocabulary structurally rather than adding a theme-ID
branch. `TitleBar.shape` is `full_width` or `leading_tab`; a tab states an optional 120–360pt
width. `visible_buttons` is an ordered, non-empty set of semantic operations, so BeOS can state
Close and Zoom without inventing a disabled Minimize box. Its `beos` glyph family draws raised
boxes from the title-tab ground. `WindowTitleBandView` constrains all furniture to a layout
guide matching that tab, draws and hit-tests no yellow shoulder, and exposes the same shape to
`WindowChromeFrameView`. The coordinator makes only a shaped takeover nonopaque and restores
the native backing (including on a takeover-to-takeover switch), allowing AppKit's shadow to
follow the tab plus body instead of a hidden rectangular title strip. Shape, width, and button
set have the same create/update/get parity as the earlier fields.

Its check gadget cannot be inferred from the same hard bevel. Haiku's pinned MIT
`BeControlLook::DrawCheckBox` preserves R5's construction: a compact white nested well followed
by a two-pixel X in the system control-mark colour. Workbench uses the same broad square/bevel
material facts but a gray recessed field and tick, so `material.checkbox_style` names the
independent anatomy (`automatic`, `recessed_tick`, or `beos_cross`). Old documents retain the
former square-bevel inference; BeOS and Workbench state their source-backed recipes explicitly,
and create/update/get round-trip the field for custom historical themes.

**OPENSTEP 4.2** (`openstep-42`) adds two more period primitives, again without a stock-ID
branch. `button_placement: bookends` puts the first authored visible operation at the leading
edge and the remaining operations at the trailing edge, so `[minimize, close]` reproduces the
NeXT frame instead of inheriting the classic Mac meaning of `split`. Its `openstep` glyph family
draws the nested miniaturize window and diagonal close mark on hard gray plates. The material
now also states `scroller_placement` (`trailing` or `leading`) and `scroller_track_style`
(`solid` or `stippled`). `ThemedScrollView` mirrors AppKit's already-sized legacy reservation
to the leading edge; repeated layout begins from `super.tile()` so it cannot drift. The later
scrollbar audit expanded that first texture field into authored period anatomy: OPENSTEP now
owns the left-side arrows, slider grip, stippled trough, and hit regions while AppKit remains
responsible for the live value. Both original material fields round-trip through
create/update/get and decode old documents to trailing/solid. They are macOS chrome and are
deliberately not projected by `RemoteThemeBridge`.

**Determinate progress is its own material decision.** A hard bevel is not synonymous with
Windows: BeOS, Platinum, and several workstation themes use hard relief with different progress
languages. `progress_style` is therefore `continuous` by default and `segmented` only when the
theme asks. Windows 98 does, producing a sunken trough with discrete accent blocks in both shared
progress indicators, usage meters, and the toast dwell clock; old documents decode to continuous. The field
round-trips through create/update/get so a custom nineties theme can opt in without a stock-theme
identity check.

Workbench additionally states `progress_style: amiga`: a hard horizontal gauge filled from the
active title blue. The manual confirms the percentage-gauge grammar but preserves no native pixels,
so its thickness and relief remain explicitly source-inferred rather than measured. Its DiskCopy
requester also carries the documented left-Amiga+V and left-Amiga+B Continue/Cancel accelerators;
the requester panel consumes those only for the Amiga material.

IRIX additionally states `progress_style: irix`: the Indigo Magic scale is a square recessed well
with an eight-pixel slanted leading edge, measured from SGI's Figure 9-7 and repeated in the
Figure 10-6 Working dialog. Its figure is grayscale, so the construction is measured while fill
colour continues to come from the theme's authored accent rather than from a guessed screenshot
colour. The same interpreter is used by determinate bars and usage gauges; old documents decode to
the continuous modern rail. Its measured logout requester is the classic exception to the
icon-free period alert: a 30px bright-green question field sits beside the message well, and the
IRIX title strip uses the authored 13px italic caption rather than the Workbench one-bit title.

**Compact controls carry period anatomy and measure, not only period colours.** `fieldSurface` is
an optional semantic role that derives from `panel` for every older theme, while Windows 98 states
the white edit/value well used on its `#C0C0C0` button face. `choice_height` is the closed
chooser's authored height (14–44 points, 26 by default): Platinum states the sixteen-pixel
specimen in Apple's HIG, BeOS and OPENSTEP state eighteen, IRIX twenty, Win98 twenty-one, and
Amiga eighteen. This is separate from `text_scale`; putting a smaller face in a modern 26-point
box was the exact mismatch the metric fixes.

`choice_style` defaults to `chip`. `dropdown` is the Win32 anatomy: a square sunken value well
with a separately raised filled-triangle arrow. `popup` is a unified raised face with a down-arrow
segment, `double_arrow_popup` is Platinum's paired up/down indicator, `aqua_popup` is Tiger's
rounded silver well with a blue gel up/down segment, and `cycle` is Amiga's
cycling mark. Every classic value removes SF-symbol ornament from the composer's closed control
and gives the shared popup menu the matching period grammar: compact regular-text rows, an
edge-attached panel, flat selection ink, etched separators, filled submenu arrows, and no
floating-card glow. `ChipView` and `ThemedPopUp` consume the same material pair, so extension and
settings choices cannot disagree with the composer. Both fields are authorable rather than stock
theme identity checks, so a contributed retro theme can opt into the complete chooser.
Checkboxes have their own axis because the source implementations disagree even when their
chooser is also classic: Win98's 98.css field is white while enabled and changes to button-face
gray when disabled, so `checkbox_style: windows_98_tick` preserves that state instead of letting
the generic recessed field stay white. Workbench and BeOS state their separate recipes above.
`ThemedRadioButton` shares that material family for its surrounding field colours but keeps its
own native metric: Win98's radio well is the pinned 98.css twelve-by-twelve indexed sprite with a
four-pixel dot, rather than the
checkbox's thirteen-pixel square and tick. This is why a radio is not inferred by changing a
checkbox's mark after layout — the source control has a different silhouette and hit target.
`button_style.primary_treatment` adds
`raised`: the primary keeps the ordinary gray face, gains the default-action outer frame, and
uses the inset dotted focus indicator instead of a modern accent ring. The period recipes source
that outer frame from `border`, not `accent`; period captures consistently use the window's dark
structural ink there. The prompt, chooser, and button consume these roles and recipes without
identifying Windows 98, and create/update/get round-trip both enum choices so a contributed retro
theme can use the same control grammar.

Hard bevels are drawn at the destination size rather than stretching a nine-patch. The sampled
cap had expanded its fixed one-pixel edge into broad gray side bands across large wells, creating
an inset fade that belonged to none of the pixel-era systems. Soft bevel materials retain their
linearly sampled blur; the crisp hard-edge correction therefore benefits Windows 98, Platinum,
BeOS, OPENSTEP, IRIX, and Amiga without giving them Windows-specific dropdowns or button
hierarchy.

**IRIX Indigo Magic** (`irix-indigo-magic`) adds the pieces 4Dwm actually needs rather than
approximating it as purple Motif. `title_font_style` is `upright` or `italic`; texture kind
`dither` draws a one-bit checker stipple; glyph family `irix` draws the black-outlined SGI
caption plates. The ordered button set gains `window_menu`, a semantic frame role whose press
opens the app-owned `ThemedMenuPresenter` with Restore, Minimize, Maximize, and Close. Adding
the role did not change old documents: their absent `visible_buttons` still decodes to the
original three standard operations, and `reset_visible_buttons` restores that same historical
default. IRIX states `[window_menu, minimize, zoom]` with `bookends`, reproducing the real
leading menu box and trailing pair. Every added field and enum value round-trips through the
same create/update/get tool surface, so an agent can author this combination without knowing
the stock theme id.

**Amiga Workbench 3.1** (`amiga-workbench-31`) is based on the unmodified Workbench 3.1
palette, not the more colourful MagicWB setup commonly shown in retrospectives. The frame uses
the screenshot's exact `#6688BB` active title, `#AAAAAA` application gray, black rules and
white highlights. Topaz is the preferred UI face. The pinned GPL-FE multi-platform recreation
of the Kickstart 2.x/3.1 face is bundled with its source location and full notices; CoreText
reports its actual family as `Topaz a600a1200a400` (despite the upstream prose's A4000 spelling),
so that embedded spelling precedes common installed-port names and Monaco in the fallback chain.
Workbench captions retain the face's native regular weight rather than synthesising bold. A
stippled legacy scroller carries the pixel-era rhythm through the application panes. Its
proportional gadget follows the active title blue (`#6688BB` in stock Workbench), while the
general action accent stays darker for modern app actions. Its paired arrows resolve against the
scroller's coordinate orientation: AppKit's
standalone scrollers are unflipped while the instances hosted by `NSScrollView` are flipped, but
both must place Up/Down at the visual bottom and value zero at the visual top. Workbench menus
use `ThemedMenuItem.keyEquivalent` for a shared trailing shortcut column; the surface draws the
Amiga-key cap from indexed geometry and the following key in Topaz, rather than embedding spaces
and a platform-specific modifier in the title; menu titles and key equivalents keep the same
unsmoothed historical raster path. Requester controls stay inside the same stock
four-colour construction: string gadgets use the application gray (`#AAAAAA`) between black and
white recessed rules, and the hard-material checkbox is a compact thirteen-pixel recessed field
with a one-bit ink mark. It therefore never acquires the current accent fill, hover-row wash, or
an SF-symbol checkmark. Text fields and title captions use the material's unsmoothed rasterization
as well as its font family, so Topaz does not turn into antialiased modern text as soon as it
enters a well or the title strip. The shared alert surface consumes the same period popover
grammar: Workbench requesters use the floating application gray, hard relief, compact Topaz
copy, the source title strip with its depth gadget, and no modern status symbol. Their action row
keeps Continue leading and Cancel trailing, as in the manual figure. The manual describes the
progress gauge but does not preserve its native pixels, so determinate progress remains explicitly
source-inferred rather than pretending to be a measured bar. Glyph
family `amiga` renders the original
Intuition Close, Zoom, and overlapping-window Depth figures; semantic operation `depth`
orders the window behind its peers. `[close, zoom, depth]` plus `split` reproduces the
historical left/right gadget order without teaching the stock theme a private code path. Both
additions are accepted and returned by the public theme tools, so a custom prompt can build
the same chrome from data.

## 2026-08-05 — period scrollbars and Cheetah Aqua

The first scrollbar theming pass recoloured a current macOS pill; reference captures showed why
that cannot represent a desktop era. The seven period families now state `scroller_appearance`
independently of palette and track texture. Windows 98 has a dithered COLOR_SCROLLBAR trough and
bookended bevel buttons; Platinum has its blue proportional box and paired lower arrows; BeOS,
OPENSTEP, and IRIX have distinct raised grips and bookended arrows; Workbench combines a one-bit
track with blue Intuition furniture and paired lower arrows. The geometry is authorable rather
than selected by stock-theme id, so an imported prompt can reuse any of those anatomies.

**Mac OS X 10.0 Cheetah** (`aqua-cheetah`) is its own chrome, not an update to Mac OS 9. Aqua
keeps arrows at the two ends and uses a ribbed translucent blue gel for both arrows and the
proportional thumb over a pale recessed trough. Its frame adds a centred pinstriped silver band,
Lucida Grande, and leading red/yellow/green glass controls. The chrome vocabulary therefore gains
`button_glyph_style: aqua`, `button_placement: leading`, and `chrome.frame.corner_radius`;
custom themes can reproduce the same lineage or recolour its gel through semantic accent roles.
Old theme documents decode to
`scroller_appearance: automatic`, so adding the family does not silently turn an existing custom
theme into a persistent legacy scrollbar.

The Aqua popover evidence has an important confidence boundary. The Cheetah reference set confirms
Help Tags in the period HIG family but its available figure postdates the 10.0 release; the Cheetah
recipe therefore records the shared Aqua plate grammar as source-shaped. The Tiger reference is a
measured 10.4-era Help Tag. Both are represented by the dedicated `tooltipSurface` role and the
stemless compact popover style, while the alert path remains on the ordinary floating surface.

Menus are a separate material axis for the same reason. A popup field can share a downward
arrow across several systems while the panel it opens differs in frame construction, row
rhythm, separators, selection, submenu overlap, shadow, and glyph placement. The authorable
`menu_appearance` values are `automatic`, `windows_98`, `platinum`, `beos`, `openstep`, `irix`,
`amiga`, `aqua`, and `aqua_tiger`; old theme documents decode to `automatic`. The historical
values remove the modern floating-card gap and diffuse shadow. Platinum additionally uses the
measured black/white/#999/#222 menu frame and two-pixel etched separators from Apple's Help-menu
reference. Production-reference fixtures enter through `ThemedMenuReferenceFixture`, which
instantiates the same private surface used by `ThemedMenuPresenter`; the archive never compares
a separately painted HTML imitation to the historical crop.

## 2026-08-05 — a variant is rebuilt by copying, never by construction

`AppTheme.Variant(...)` at an edit site is the trap `assemble`'s comment warned about, and it
shipped once more before the rule became structural: the Current Theme page rebuilt a variant to
change one colour and left `chrome:` off the call — the memberwise initializer defaults every
regional block to nil, so the call kept compiling — and recolouring a custom takeover theme
silently handed the window frame back to AppKit. Every rebuild now goes through
`Variant.replacing` (roles, palette, material) or `replacingSidebar`/`replacingChrome` (the
regional blocks, whose "set it to nil" must stay sayable — the `SidebarChange` distinction): a
copy carries every stored field by construction, so a future regional block rides through edit
sites that have never heard of it. `assemble`'s rename pass takes the same copy, which retires
its hand-carry list. `WindowChromeStyleTests` holds `replacing()` to the identity across every
stock variant — the guard with a future: a stored property added to `Variant` and adopted by
any stock theme fails that sweep the moment `replacing` forgets to carry it.

The same pass gave BeOS, OPENSTEP, IRIX and Workbench the `floatingSurface` Platinum documents:
the fix had reached only half the period family, which is what a rule stated in one theme file
invites. Each now states its period face gray — a white floating card over OPENSTEP's white
period terminal was the Platinum failure verbatim, waiting to be reported.

## 2026-08-07 — a theme that reproduces nothing

**TUI** (`tui`) is the tenth stock style and the ninth to take over the window frame, and it is
the first to do either without a system to point at. Everything else in the takeover family is a
reconstruction; this one is drawn in the idiom the full-screen terminal programs share. It cost
one texture kind (`rule`, one point along the band's bottom edge, spacing ignored) and one glyph
family (`tui`, hairline one-bit cells that invert under the pointer) — see
[`window-chrome.md`](window-chrome.md), *An authored takeover*, for both and for why its archive
entry is `not_applicable` throughout.

What it changes about *this* file's subject is smaller and worth stating: it is the first stock
theme whose terminal background is its own `ground` rather than a darker rectangle inside the
application. Every other theme here draws a terminal that is visibly a pane; this one is
pretending to be the terminal, so a darker pane would draw exactly the seam the design spends
its effort hiding. `TerminalBackgroundHarmony` has nothing to reconcile as a result, which is
the degenerate case of what it exists for rather than a special case in it.

It is also the first `typeface: .monospaced` theme to also state `textScale` below 1. The two
travel together: monospaced glyphs are wider than the proportional ones every measurement in
`Design` was chosen against, so the same words need more room, and 0.94 buys that width back
inside the panes. Widening the panes would have been the wrong lever — pane widths are the
window's, not a theme's, which is the line `AppThemeStyles` draws in its own header.

## 2026-08-08 — classic player chrome and local `.wsz` assets

**Classic Player** (`classic-player`) is the tenth takeover and the first whose window band can
be supplied by the user. The stock theme is clean-room: its palette, bevels, and one-bit caption
figures are authored here, and the app ships no Winamp logo, screenshot, bitmap, or skin. The
fourteen-point band and nine-point caption slots follow the public Winamp 2.x-compatible `.wsz`
format as independently implemented by Webamp and Audacious.

Importing a `.wsz` creates an ordinary custom dark theme derived from Classic Player, then stores
one normalized `classic-titlebar.png` in that theme's `ThemeAssetStore` folder. The theme document
contains only that local asset name in `chrome.titleBar.classicSkin`; it contains neither archive
bytes nor an absolute path. Duplication copies the folder, deletion removes it, and a missing file
falls back to the stock clean-room band. The public theme tools may author
`button_glyph_style: classic_player`, but they cannot name or ingest local skin assets: importing
user-selected bytes remains a Settings-only trust boundary.

The import is intentionally the window-chrome slice of the format. It consumes `TITLEBAR.BMP`
(or PNG), including its active/inactive bands and options/minimize/shade/close state sprites. It
does not apply playlist, equalizer, transport, font, cursor, or logo resources to unrelated app
controls. On a resizable window the two hardware ends remain at native size and only the centre
groove expands. The sprite semantics remain native to Threading: Options opens the app-owned
window menu, Shade means Zoom/Restore, and Close still follows the window delegate.

The stock fallback uses the same shared theme vocabulary to evoke the original player's
material hierarchy without copying its pixels: violet gunmetal structural planes, black sunken
display wells, green display ink, hard bevels, and pale raised `caption_rails` on either side of
the title. `caption_rails` derives its endpoints from the live title and button stacks, so it is
an authorable texture rather than a `classic-player` drawing branch. Imported title-bar pixels
still replace that clean-room fallback completely.

The second fidelity pass makes binary toggles part of that vocabulary too.
`material.toggle_style: on_off_button` replaces the modern travelling knob with a compact
hardware latch: OFF is a raised face, ON is a black sunken well, and both states carry one-bit
words plus a small status lamp. `ThemedToggle` still owns the same Boolean value, target/action,
keyboard activation, and accessibility role; only its theme-selected drawing and measure change.
Classic Player also states uppercase `button_style.title_rendering: pixel_5x6`. This follows the
construction of the source skin's five-by-six `TEXT` sprite cells instead of disabling smoothing
on a small scalable font—the latter malformed letters rather than creating bitmap type. The
stock alphabet is clean-room and ships no Winamp pixels. A title containing any unsupported
localized character falls back as a whole to the ordinary antialiased font, preserving the copy
instead of mixing alphabets or drawing a missing glyph.

The same material's `chart_style: spectrum` now selects the sidebar brand row's workload
presentation as well. `SidebarBrandView` replaces the logo and wordmark with a clean-room,
seven-band analyzer drawn from ordinary theme roles and the existing five-by-six alphabet. It
shows exact app-wide working count, a decaying semantic-output envelope, and `MAX` when any worker
is at provider-relative top effort. The gate names the material rather than this theme, so imported
Classic Player skins inherit it and a future authored spectrum theme can do the same. The host
continues to own activity truth, accessibility, bounded geometry, and motion policy.

## 2026-08-12: the product has its own stock theme

**Threading** (`threading`) is the adaptive stock product theme and the fresh-profile default. An
absent `appThemeID` resolves to Threading without writing one: inheritance remains distinguishable
from a choice the user made. A stored choice still wins, an unavailable or deleted choice falls
back to Threading, and Recovery Mode remains the deliberate exception that wears System in memory
without touching the stored answer.

The dark variant uses navy ground and panel roles, warm text, and orange accents. The light
variant is warm paper seated in pale navy surfaces, with the orange lowered in perceptual
lightness so it keeps the same emphasis and clears the contrast floor on paper. Both terminal
palettes use the same family of colours, so a provider TUI does not look like a separate skin
placed inside the app. The adaptive theme leaves `NSApp.appearance` unpinned and follows macOS.

The theme uses the normal Threading layout and control vocabulary. Selected rows use navy rather
than diluted orange, leaving orange for actions, focus, and the app mark. The sidebar has a
restrained depth shift and a flat navigator well in both appearances. Both variants deliberately
omit `WindowChromeStyle`: Threading owns the app surfaces inside the window while AppKit owns the
standard macOS titlebar, traffic lights, rounded frame, resizing, sheets, and full-screen
integration. The old authored takeover ledger was removed with the takeover; the historical
frame mechanism and its stock examples remain unchanged.

Threading's authored colours are stated in **OKLCH** (`AppThemeStyles.oklch`), which makes
perceptual lightness, chroma, and hue the reviewed decisions and gamut-maps by reducing chroma
only. This is the default for colours designed in this repository. Hex remains correct at exact
source boundaries — historical pixels, published community palettes, persisted theme documents,
and agent/user input — where changing an encoded source value would be a fidelity bug rather than
an improvement. Runtime derivation continues in Oklab, the Cartesian form of the same space.

System and other stock themes remain available, but ordinary product evidence uses Threading.
The theme matrix renders both Threading appearances automatically because it is adaptive.

## 2026-08-14 — the palette-first family

Five stock styles — **Pure Black**, **Cappuccino**, **Solarized**, **Nord**, **Dracula**
(`AppThemeStyles+Palettes.swift`) — are themes in the sense most terminal users mean the word: a
colour language, not a chrome. Everything before them changes the window's material somewhere —
a takeover frame, a printed rule system, a glow, a typeface. These keep the app's modern
silhouette and spend their whole identity on the ground, the ink, one accent, and the sixteen
ANSI colours that agree with them.

They still author geometry, because the silhouette gate
(`testEveryStyleHasItsOwnSilhouette`) refuses a material equal to System's — a theme that is
only a tint is the failure the first design-movement pass already made once. The differences are
deliberately small: a few points of panel radius (Cappuccino rounder than the default, Solarized
squarer), never new furniture, no glow, no backdrop pattern, no chrome takeover.

**Provenance is split, and the split is stated where the styles live.** The catalogue's standing
rule — palettes are our own values, authored against public aesthetics — gained its one
carve-out here: Solarized, Nord, and Dracula are community schemes whose identity *is* their
exact published values, so approximating them would ship a theme wearing a name it does not
match. Their values are reproduced from the MIT-licensed definitions and credited in the file
(Schoonover, Greb, the Dracula contributors). Pure Black and Cappuccino are ours, authored like
every other style. Where a scheme states fewer surfaces than the app has roles — none of the
three defines a third panel tone — the missing steps are interpolated inside the scheme's own
ramp and commented as ours at the definition.

Decisions worth knowing before touching one:

- **Pure Black's chrome is achromatic on purpose**, down to a white accent and a grey syntax
  ramp: the style is absence, and colour belongs to the programs in the terminal. Its ANSI hues
  are slightly muted because saturated primaries bloom against a true `#000000` ground. This is
  the theme for the "not the system grey" ask — the ground is the one macOS's elevated dark
  surfaces never give you.
- **Pure Black's `selection` is stated opaque (`#292929`)** — the colour its natural
  white-at-16% wash renders to over this chrome. The wash form failed
  `ThemedTableRowSelectionTests` by painting literally nothing on that fixture's white ground,
  which is the honest reading of a translucent *white* selection: it only exists over dark
  pixels. Stating the rendered value keeps the appearance and makes it true everywhere.
- **Cappuccino and Solarized are adaptive**, the second and third stock styles after Christmas
  to author both appearances — for Christmas's reason: the identity is a pairing (milk and
  espresso; one hue set over two grounds), and pinning either appearance would make half the
  users wrong. Cappuccino's light terminal follows the Swiss monotone-neutral-ramp rule; its
  palette is ours, so it obeys the house rules.
- **Solarized ships one ANSI table for both variants, exactly as published.** The bright slots
  carry the base tones — `brightBlack` *is* the dark variant's ground — so sharing the table is
  the scheme's design, not a shortcut, and the light variant's near-invisible index 7 on paper
  is canon this theme deliberately does not "fix". The 3:1 contrast floor was chosen, back when
  the gate was designed, precisely so this palette passes as authored.
- **Solarized's chrome label is the palette's own ANSI ink, not its body tone.** The first pass
  used the published base00/base0 body text for `label`, and two sweeps refused it:
  `SelectionSurface` holds the app's own chrome to AA on selected rows, which base0 over a
  selection wash on base02 cannot reach (3.11:1), and the sidebar's 6% hover wash of the label
  vanished on the hover fixture's mid-grey — Solarized's base tones *are* mid-grey, the one lean
  that fixture's "works whichever way the label leans" premise never met. The latitude the 3:1
  floor extends to Solarized is for the *terminal*, where the canonical base00/base0 foregrounds
  stay exactly as published; the chrome label is base02 on light and base2 on dark — the tones
  the scheme itself uses as ANSI black and white, i.e. its own inks.
- **Dracula's `selection` is opaque `#44475A`**, the one departure from this family's
  translucent accent washes: "current line" is how Dracula marks the selected thing, and a
  purple wash would be a different theme wearing the name.

The catalogue count pinned in `testStockThemesHaveUniqueStableIdentifiers` moved 24 → 29. Every
existing sweep — contrast on own surfaces, the agent-theme validation contract, unique palette
ids, rule-ink budget, the settings-page renders — picked the five up by their membership in
`AppThemeStyles.all`; nothing needed a per-theme carve-out.

## 2026-08-14 — a period control ends where its own silhouette does

Five reports against Tiger, one shape between them: a drawing that belonged to a control took some
other rectangle for the control's outline — its own box, or AppKit's idea of it — and every one of
them was plainly visible in a screenshot while every assertion around it passed.

**A scrollbar with nothing left to scroll shows an empty trough.** AppKit disables a legacy
scroller once its scroll view has nowhere to go, but it keeps the `knobProportion` that view last
needed. `rect(for: .knob)` read that stale proportion and produced a thumb for content that is no
longer there — in the Settings sidebar, two-thirds of the trough, parked at the top, immovable.
Reported as a scrollbar that "doesn't move when I scroll" and "shows scroll space that isn't
there", and it was never Tiger's: the drawing is shared, so Platinum, OPENSTEP, BeOS, Workbench,
IRIX, Windows 98 and Cheetah all had it. `ThemedScroller.hasScrollableRange` — `isEnabled &&
knobProportion > 0` — is now the single gate on the thumb, replacing the Windows-only
`knobProportion <= 0` special case that had been the one appearance to get this right. The
proportion is read alongside `isEnabled` because a scroll view states the empty case that way
first, and because the terminal's standalone scroller is driven by hand: SwiftTerm sets
`isEnabled` from its own `canScroll`, so one rule covers both. The arrows stay and go quiet: a
vector glyph through `DisabledControlDrawing`, a measured plate by lifting its ink toward the
plate (`quieted`), because a bitmap whose glyph is part of the sample table cannot be faded
without taking the furniture with it. Either way the plate stays lit — dimming it would leave the
trough's end brighter than the trough.

**And a period scrollbar declines the layer path.** Modern `NSScroller` is layer-backed: it
repaints by calling the old part hooks — and *only* those, never `draw(_:)` — each behind a clip
of AppKit's own idea of that part. Ours are deliberately different rectangles: the slot runs to
the ends because the arrows are furniture this component places, and the thumb carries a period
minimum length. Everything of ours outside AppKit's rectangles was therefore cut. Parked at the
top of its travel the gel lost the entire curve of its cap and started mid-capsule at full width —
the flat-topped thumb this was reported as — while the trough and arrow plates stopped three
points short of the control's own edges, and the gel's trailing column was shaved. Nothing in the
geometry was wrong, which is why `rect(for:)` looked innocent and the archived reference
reproductions (drawn straight through `draw(_:)` into a bitmap) looked perfect the whole time.
`ThemedScroller.wantsUpdateLayer` returns false under any period appearance, which puts that
single pass back in the loop with the whole view as its clip.

**The Aqua pop-up's gel well is clipped to the button's face.** `drawAquaArrowWell` filled a
rectangle from the arrow rect to `bounds.maxX`, which painted over both trailing corners and the
border joining them: the control ended in a hard blue block and read as *cut off* at the right
edge. It now clips to `ClassicChoiceDrawing.aquaFace(in:)` — the silhouette inside the border,
one measure (`aquaCornerRadius`) shared by `ChipView` and `ThemedPopUp` rather than a `5` written
in each — so the curve at that end belongs to the button, the border survives, and the only edge
the well draws for itself is the seam against the value. `indicatorInk(for:)` came out of the
same pass: the arrows sit on an accent plate, so they take `Text.selected`, the ink this app
already measures against its own accent, instead of the label colour that a dark authored accent
would have swallowed.

**Aqua's default button is the blue one.** Both Aqua materials asked for `primary_treatment:
raised`, which is the *classic desktop* default — the ordinary control face plus an extra outer
frame — and is right for Platinum, Workbench and Win32, all of which square their corners. On a
material with a control radius that frame was `bounds.fill()` behind a rounded face, so a blue
square showed at each corner of "Start session" like a tab behind the button. Cheetah and Tiger
now state `filled`, which is what those releases shipped; separately, the raised frame follows
the silhouette it frames, so the authored pairing a custom theme can still make — a rounded
material asking for the classic frame — draws an edge rather than a backing plate.

**And the chooser's own corner is stroked, not applied.** A `CALayer` border follows the
*continuous* corner this app rounds everything with, and a continuous curve's inner offset is not
concentric: at the pop-up's five-point radius under a one-point border the stroke thickens through
the arc and leaves a ledge where it meets the straight run — an extra edge in the corner, on a
`ChipView` sitting a row above a `ThemedPopUp` that stroked a clean circular one. Both now go
through `ClassicChoiceDrawing.drawAquaSurface(in:)` and the chip's layer keeps nothing but the
silhouette, so the two cannot diverge again; `testTheTwoAquaChoosersDrawTheSameCorner` compares the
drawn corner of one against the other, untitled so the block holds no glyph edges. The artifact is
general to a layer border on a small continuous corner — it is simply invisible at panel radii,
which is where the rest of this app's applied borders live.

`AquaChromeTests` holds the geometry, the drawn state (corner pixels of the well and of the
frame, accent ink anywhere in a spent trough, one chooser's corner against the other's) and one
specimen sheet per Aqua material.

## 2026-08-14 — a view in the reuse queue misses the sweep

Reported as two sidebar rows in different fonts under Tiger, and the screenshot named the bug
without any instrumentation: the ink extents measure Lucida Grande 10.8 on one row and SF Pro 12
on the other, which are `.controlRegular` under Tiger (`fontFamily: "Lucida Grande"`,
`textScale: 0.90`) and under System. One row was a theme behind.

**A live switch reaches views through two different mechanisms, and only one of them survives
being detached.** A colour is held as a *rule*: `MorphingTitleLabel` keeps an `inkProvider` and
re-asks it from its own `AppThemeDidChange` observer, which a view receives whether or not it is
in a window. A font is pushed as a *value*: `applyFont` records the role, and
`AppThemeRefresh.repaintEverything` re-resolves it by walking `NSApp.windows`. A view in an
`NSTableView` reuse queue is in no window, so the sweep never reaches it, and nothing re-applies
the role afterwards — `applyFont` runs once, where the cell is built. The row therefore came back
out of the queue with the previous theme's typeface and the current theme's ink, which is exactly
what the pixels showed.

Settled in `ThemedTableRowDefaults.vendedView(for:recycling:)`, which both `ThemedTableView` and
`ThemedOutlineView` already funnelled `makeView(withIdentifier:owner:)` through to default a row
view. A recycled view now goes through `AppThemeRefresh.repaintIfNeeded` on its way out. That is
generation-stamped, so a view already current costs one associated-object read per vend and the
repaint runs once per view per theme change; and it covers surfaces and layer colours as well as
fonts, which a pooled view had been holding stale for the same reason. Taking the answer away
from the call sites is the same move the row-view default made, for the same reason: no list can
forget, and `scripts/config/theme-boundary.json` maps `NSTableView`/`NSOutlineView` to these two
classes, so there is nowhere else for a list to be.

Two ways to park a cell that look like they should work and do not, recorded because both were
written and watched to prove nothing: **scrolling** hands each departing cell straight to a row
arriving at the other end, so the queue is empty again by the time you look, and **`reloadData`
over an emptied source** releases the cells outright rather than queueing them. `removeItems` /
`removeRows` — the sidebar's own incremental update, and where a collapsed project's rows go — is
what leaves a cell in the queue with nothing to take it. `ThemeLeakSweepTests` covers the seam
directly and both list classes end to end; the end-to-end case asserts the parked cell really
left the window and that no fresh cell was built, since either would make it pass for free.

## 2026-08-15 — the picker files the catalogue

The app-theme picker had grown to twenty-nine rows in one undifferentiated column, and the list
said nothing about why any two of them were next to each other. Four different kinds of thing
were in it — a design movement, a colour language, a reproduction of a shipped desktop, a
novelty — chosen for entirely different reasons, and the only structure a row could carry was a
suffix in its own title: `Aurora — Custom`, `Storm — Usage Rain`. That suffix is the longest
segment on the line, and it repeats identically down a whole group.

`ThemedMenuEntry.header` already existed for the composer's identity menu, so the fix was a
filing system rather than a new control: `AppThemeSection` (a title and its themes),
`AppThemeStyles.families`, and `ThemedPopUp.addHeader`. Sections, deliberately, not submenus —
a head costs no trip through the menu, so a theme is still one press from the closed control,
which is the property the identity menu flattened two sections to buy.

The families, and why the two odd ones are their own group:

| Head | What is in it |
|---|---|
| *(none)* | System and Threading — a head over the two entries the app ships with would name a group nobody browses to |
| Design styles | The eleven movements and genres |
| Palettes | The palette-first family: Pure Black, Cappuccino, Solarized, Nord, Dracula |
| Classic desktops | The eight shipped desktops with a reference ledger under `docs/references/chrome/` |
| Classic software | Classic Player and TUI, which reproduce *software* of the same period rather than a desktop — which is why Classic Player moved out from between Workbench and Windows 98 |
| Seasonal | Christmas |
| *extension name* | One section per contributing extension: where a user goes to update or remove it, and what tells two extensions shipping a "Storm" apart |
| Custom | The user's own copies, the only editable tier |

**`AppThemeStyles.all` is now the families flattened**, exactly as `takeovers` is `all` filtered:
a style that is filed under no family does not exist, so the picker cannot drift from the
catalogue the way the third hand-maintained copy of the stock list did (Aqua and Tiger were
missing from the gallery within weeks of it being written).
`AppThemeLibrary.sections` adds System, the contributed groups and the custom tier, in the same
order `all` reports — `testSectionsAreTheWholeCatalogueInOrder` holds the two together.

Two things a head breaks that had to be fixed with it, both in `ThemedPopUp`:

- **A pop-up selects the first entry it is given**, which in a list that opens with a head was
  the head: a button drawing an empty title and reporting no selection at all. It now records
  the entry it just appended, which is the first *item* by construction.
- **An entry index is not an item index.** Every caller looked its selection up in the model
  list it had built the pop-up from — `AppThemeLibrary.all.firstIndex { … }` — which lands one
  row lower per head above it, or on a head, and a picker showing the wrong theme is exactly
  the failure the recovery-mode rule above exists to prevent. `indexOfItem(where:)` asks the
  control instead, so the two lists no longer have to agree; the Component Gallery's picker,
  which indexed `AppThemeLibrary.stock` positionally in two places, moved to the same lookup.

Section titles are localized where they are stated (`L10n.string`), and `AppThemeSection.title`
is therefore presentation-ready rather than a key — a section may be named after an extension,
and an extension called "Custom" must not come out of a string table as something else.


## 2026-08-17 — a palette states its bold text

A palette now names a **twenty-first** colour, `boldForeground`, and it answers one question:
what does SGR 1 draw in when the text carries no colour of its own? Terminal.app has asked that
question since it shipped, under the name "Bold Text", and every profile it bundles answers it:
Pro sets text `#F2F2F2` against bold `#FFFFFF`, Homebrew `#28FE14` against `#00FF00`, Grass
`#FFF0A5` against an amber `#FFB03B`, Novel `#3B2322` against a red-brown `#802A19`, Red Sands
`#D7C9A7` against `#DFBD22`, Silver Aerogel `#000000` against `#FFFFFF`. Basic, Man Page and the
Solid Colors set answer "the same as the text", which is a decision too.

**Weight alone could not carry it.** Claude Code writes body copy in the terminal's default
foreground and writes its headings as bold in that same default foreground, so the only thing
separating a heading from a paragraph was the bold face. Our SwiftTerm fork resolved that pair
through one branch of `mapColor`: `.defaultColor` with `isFg` returned `nativeForegroundColor`,
and only ANSI 0 through 7 shifted to 8 through 15 when bold. On the stock Threading palette the
foreground was `#F7EFE6`, which is also its `brightWhite` and already the brightest tone it
states, so a heading and a paragraph came off the screen as the same pixels. Sampled from a
screenshot, both were `#F7EFE6`.

The fix is one property in three places, and each of them is deliberately narrow:

- **`TerminalTheme.boldForeground`** sits next to `foreground`, is non-optional in memory, and
  is `decodeIfPresent` on the wire. **An absent key means the foreground**, so every palette
  already on disk keeps drawing exactly as it did: bold text takes the text colour, which is
  what SwiftTerm did for it anyway. A key that is present but unparseable takes the same
  role-shaped fallback as every other colour, `TerminalTheme.basic`'s value for that role,
  because a palette that names the role and gets it wrong has said something and we should not
  silently read it as silence. It is always encoded.
- **`TerminalView.nativeBoldForegroundColor`** in the fork, optional, where nil means "the same
  as the foreground". `mapColor` consults it in exactly one case: default foreground, `isFg`,
  `isBold`. `.defaultInvertedColor`, the ANSI paths and truecolor are untouched, so **bold text
  that names a colour keeps its bright shift**. That rule is Terminal.app's too, and it is the
  right one: a program that wrote `SGR 1;31` asked for an emphatic *red*, and answering with the
  palette's heading ink would throw away what it said. Setting the property clears the attribute
  caches, which key on the style flags and therefore hold a resolved answer per bold state, and
  queues a redraw.
- **`TerminalSession.applyProfile`** sets it beside `nativeForegroundColor`, and
  `RemoteThemeBridge` puts it on the wire as an optional `bold_foreground` so a phone built
  before the role decodes a host that has it.

**Every stock palette states one, and three gates hold them to it.**
`TerminalBoldTextSweepTests` walks the four built-ins, the System pair and all thirty-one
app-theme palettes:

- **Distinctness.** CIE76 ΔE between the bold colour and the foreground is at least 15. That is
  the number below which the two read as the same ink: `#F7EFE6` against `#FFFFFF` is 7.5 and
  fails, `#D9D1C8` against `#FFFFFF` is 16.7 and passes.
- **Legibility.** The bold colour clears `ThemeContrast.minimumRatio` against the palette's own
  ground, and clears 4.5:1 wherever the body already does. Bold is never allowed to be the
  reason a palette stops being readable.
- **Ownership.** The bold colour is at least ΔE 15 from each of the palette's own `red`,
  `green`, `yellow`, `blue`, `magenta` and `cyan`, in both weights. The four neutral slots are
  exempt, because bold equal to `brightWhite` is the oldest pairing a terminal has and nothing
  prints "white" to mean something.

**The third gate came out of the first authoring round**, which put eight headings exactly on
one of their palette's own coloured slots and two more within ΔE 15 of one: Christmas took its
`red` by day and its `brightYellow` by night, Dracula its `yellow`, Cyberpunk its `green`,
Vaporwave its `cyan`, Nord its `cyan`, Editorial its `brightYellow`, Bauhaus its `red`, Amiga
came 12.6 from its `blue` and Botanical 13.2 from its `green`. Every one of those cleared the
other two gates, and every one was wrong the same way: a heading in the palette's red is an
error, in its yellow a warning, in its cyan or green any tool's coloured output, so a reader
cannot tell what the agent emphasised from what a program coloured. The contact sheet said it
without an assertion, with "Bold heading", "red" and "bold red" coming out of Bauhaus as one
colour. Terminal.app's hue-shifted profiles never do this: Grass's amber `#FFB03B` is not its
yellow, and Novel's `#802A19` is not its red.

The gates are deliberately silent about whether bold out-contrasts body, because the precedent
they are modelled on is not: Terminal.app's Grass draws body at 4.9:1 and bold at 3.1:1, and
Novel does the same shape. A heading can be louder by hue instead of by luminance, and eleven
palettes here take that route.

**Choosing the colour is the authoring rule**, in preference order: a neutral extreme, white or
black, when it clears ΔE 15 from the body; a colour from the theme's own family that no ANSI
slot has spent, the chrome accent included; a tint or shade of a family colour, kept clear of
the nearest slot; and only then a step of the body, which a published scheme never takes.
Neutral dark palettes land on pure white and neutral light palettes on their deepest ink. A
palette with a hue identity takes that hue at a tone no slot holds: Art Deco its brass,
Cyberpunk a hazard yellow beside its neon green, Christmas a holly red deeper than its own `red`
by day and candlelight rather than the candle by night, Vaporwave the violet between its magenta
and its blue, Bauhaus the blue primary rather than the red one, Editorial the cognac its chrome
already uses, Botanical the clay its own summary names beside the green, Amiga the Intuition
title blue at ink depth.

**The published schemes take a colour their own set states.** Solarized light and dark take
base02 and base2, which are that scheme's ANSI `black` and `white` and therefore exempt from the
third gate. Dracula takes Orange `#FFB86C`, the one published Dracula colour its ANSI mapping
does not spend. Nord takes nord12, the one Aurora tone its published mapping leaves unspent, and
it is the sweep's single stated exception: nord12 is 4.4:1 on nord0, above the floor every
palette's text is held to and under the 4.5:1 the second gate would otherwise ask of a palette
whose body clears AA. There is no alternative inside the scheme, because every Nord colour
bright enough for AA is either an ANSI slot or a Snow Storm tone the body cannot be told from,
and pure white is ΔE 13.2 from nord4, which is the original defect wearing a different number.
The exception is keyed by palette id, carries that reason as its text, and
`testEveryStatedExceptionIsStillNeeded` deletes it the moment it stops being load-bearing.

**Fifteen palettes moved their body one step to make room**, and the move is always in the same
direction: the heading keeps the extreme, the body steps back. On a dark palette the body takes
the ramp's own `white` (index 7), which is what Threading, Basic, System dark, Pure Black, BeOS,
IRIX and Cappuccino dark now do, and the relationship that leaves is Terminal.app's Pro exactly.
On a light palette whose foreground already *was* the ramp's black there is nothing below it, so
the body steps to `#333333`, which in every one of those palettes sits strictly between the
stated `black` and the stated `brightBlack`. That last point is the constraint, not a
preference: had the body landed on `brightBlack`, text a program dims to index 8 would have
become indistinguishable from body copy, which is the bug this whole change exists to fix,
pointed at a different pair. No palette's headings got quieter, and no body dropped below 7:1
where it was above it.

**The caret moved with the body**, in fourteen of the fifteen palettes that moved one.
`testEveryPairedTerminalCursorIsThePalettesOwnInk` holds every paired palette's cursor to its
own text colour, and it is the rule that keeps a block caret from drawing a theme's loudest hue
over queued input. Body text is what the caret sits on, so it follows the body rather than the
heading. Basic and System dark are not in that sweep and moved anyway, so that neither is left
carrying a caret colour its palette no longer states. System light is the fifteenth: its caret
was already a grey of its own rather than its text colour, and it stays that.

Two palettes are worth knowing about individually. **Amiga Workbench** has a mid-grey ground, so
there is no room under black for a legible body step and no room over it for a heading: white is
1.9:1 on the gray, black is already the body, and the theme's own `#31577F` is this palette's
`blue`. Its heading takes the Intuition title blue at ink depth instead, `#102A50`, and it is
the one palette whose bold is a step *lighter* than its body. **Homebrew** could not use
Terminal.app's own answer, whose `#28FE14` and `#00FF00` are ΔE 6.6 apart; it takes a phosphor
bloom at the top of the tube instead.

**The role is editable, visible and gated everywhere a colour is.** `ThemeColorKey.main` carries
it, so the settings editor shows a "Bold Text" well beside Text, Background, Cursor and
Selection, and `ThemePreviewView` draws the sample's typed command in it, in the bold face of
the sample's own font, which is what makes moving that well change something the reader can
see. `create_theme` and the app-theme variant validator both measure it against the background
exactly as they measure `foreground`, and name `bold_foreground` and the ratio when they refuse:
a caller may state bold and nothing else, so a gate that only measured the body would pass an
unreadable heading on a palette it never touched. Nothing that passed before changes, because an
unstated bold is the foreground.

| palette | body before | body | bold | ΔE(bold, body) | nearest coloured slot | bold/bg | body/bg |
|---|---|---|---|---|---|---|---|
| Basic | #FFFFFF | #C7C7C7 | #FFFFFF | 19.8 | bright cyan 43.1 | 21.0:1 | 12.4:1 |
| Pro | (unchanged) | #5ADB57 | #FFFFFF | 83.7 | bright cyan 41.7 | 15.8:1 | 8.8:1 |
| Homebrew | (unchanged) | #00FF00 | #CCFFCC | 88.5 | bright cyan 39.4 | 18.7:1 | 15.3:1 |
| Ocean | (unchanged) | #C0C5CE | #EFF1F5 | 16.0 | bright cyan 26.0 | 11.7:1 | 7.6:1 |
| System (light) | #000000 | #333333 | #000000 | 21.2 | cyan 83.1 | 21.0:1 | 12.6:1 |
| System (dark) | #E8E8E8 | #C7C7C7 | #FFFFFF | 19.8 | bright cyan 43.1 | 16.7:1 | 9.9:1 |
| amiga-workbench-31 | (unchanged) | #000000 | #102A50 | 31.8 | blue 19.7 | 6.2:1 | 9.0:1 |
| beos-r5 | #F0F0F0 | #C8C8C8 | #FFFFFF | 19.4 | bright cyan 39.9 | 19.0:1 | 11.4:1 |
| christmas-light | (unchanged) | #0F2419 | #7A0A12 | 62.8 | red 27.9 | 10.3:1 | 15.1:1 |
| christmas-dark | (unchanged) | #EAF4EC | #FFEFC2 | 21.3 | bright yellow 32.6 | 14.9:1 | 15.2:1 |
| classic-player | (unchanged) | #54F269 | #F1F1E5 | 81.9 | bright cyan 30.9 | 17.5:1 | 13.6:1 |
| bauhaus | (unchanged) | #121212 | #0B2C7A | 54.3 | magenta 27.8 | 11.1:1 | 16.4:1 |
| art-deco | (unchanged) | #F2F0E4 | #D4AF37 | 61.0 | yellow 16.2 | 9.4:1 | 17.3:1 |
| neo-brutalism | #000000 | #333333 | #000000 | 21.2 | cyan 54.6 | 20.6:1 | 12.4:1 |
| claymorphism | (unchanged) | #332F3A | #5B21B6 | 81.2 | magenta 18.7 | 8.2:1 | 11.9:1 |
| vaporwave | (unchanged) | #E0E0E0 | #C77DFF | 78.5 | bright magenta 32.2 | 7.6:1 | 15.6:1 |
| newsprint | #111111 | #333333 | #111111 | 16.2 | blue 38.1 | 17.9:1 | 12.0:1 |
| botanical | (unchanged) | #2D3A31 | #6B4030 | 29.4 | red 26.6 | 8.2:1 | 11.2:1 |
| editorial | (unchanged) | #F3E7D3 | #D47842 | 55.6 | yellow 18.0 | 6.2:1 | 16.1:1 |
| industrial | (unchanged) | #2D3436 | #0B1113 | 16.5 | magenta 46.5 | 15.0:1 | 10.0:1 |
| irix-indigo-magic | #E8E8E8 | #BDBDBD | #FFFFFF | 23.4 | bright cyan 37.3 | 19.0:1 | 10.1:1 |
| openstep-42 | #101010 | #333333 | #101010 | 16.6 | cyan 39.2 | 19.0:1 | 12.6:1 |
| pure-black | #F2F2F2 | #B3B3B3 | #FFFFFF | 27.1 | bright cyan 33.2 | 21.0:1 | 10.0:1 |
| cappuccino-light | (unchanged) | #3B2E25 | #120D09 | 17.5 | magenta 48.1 | 16.4:1 | 11.1:1 |
| cappuccino-dark | #EFE3D5 | #CFC0B0 | #FFF7EC | 19.5 | bright cyan 28.1 | 17.5:1 | 10.5:1 |
| solarized-light | (unchanged) | #657B83 | #073642 | 30.5 | bright green 25.4 | 12.1:1 | 4.1:1 |
| solarized-dark | (unchanged) | #839496 | #EEE8D5 | 34.8 | bright cyan 29.5 | 12.3:1 | 4.7:1 |
| nord | (unchanged) | #D8DEE9 | #D08770 | 46.6 | bright red 20.5 | 4.4:1 | 9.2:1 |
| dracula | (unchanged) | #F8F8F2 | #FFB86C | 52.2 | bright yellow 36.2 | 8.4:1 | 13.4:1 |
| platinum-9 | #111111 | #333333 | #111111 | 16.2 | cyan 44.8 | 18.9:1 | 12.6:1 |
| aqua-cheetah | #111111 | #333333 | #111111 | 16.2 | cyan 48.4 | 18.9:1 | 12.6:1 |
| tui | (unchanged) | #C8D2DE | #FFFFFF | 17.7 | bright blue 34.9 | 18.5:1 | 12.1:1 |
| aqua-tiger | #111111 | #333333 | #111111 | 16.2 | cyan 48.4 | 18.9:1 | 12.6:1 |
| retro-98 | (unchanged) | #C0C0C0 | #FFFFFF | 22.3 | bright cyan 45.0 | 21.0:1 | 11.5:1 |
| threading | #F7EFE6 | #D9D1C8 | #FFFFFF | 16.7 | bright cyan 26.4 | 19.9:1 | 13.2:1 |
| cyberpunk | (unchanged) | #E0E0E0 | #FCEE0A | 91.5 | yellow 37.3 | 16.3:1 | 15.0:1 |
| swiss-minimalist | #111111 | #333333 | #111111 | 16.2 | cyan 42.8 | 18.9:1 | 12.6:1 |
