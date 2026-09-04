# Icons

Agent marks, account chips, project icons, file-tree marks and their discovery.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

Two kinds of icon, resolved differently on purpose.

**Agent marks** (`AgentBrandIcons`): a session row's icon slot shows the agent's own
favicon — Claude's coral starburst, OpenAI's knot — instead of an SF Symbol. Loose PNGs under
`Resources/Icons`, loaded via `Bundle.main` (the folder is an explicit-folder resource, so it
lands under `Contents/Resources/Icons/`), *not* the asset catalogue. The OpenAI knot is monochrome by design, so it
ships as a **template image** and tints with its context like the symbols beside it — which
is what makes it work in dark mode and dim for dormancy. Claude's mark keeps its brand
colour; tinting cannot dim a non-template image, so dormancy dims it through the view's
alpha instead (`SessionRowView.applyAgentIcon`).

Grok and OpenCode currently use `bolt.circle` and `curlybraces.square` SF Symbol fallbacks.
`AgentKind.icon` is the
shared seam, so adding a vetted bundled brand mark later changes neither rows nor menus.

A mark that keeps its own colour can also *vanish* — coral on a holly-red selected row — so
the row re-decides an `IconBackplate` against the ground it is actually drawn on, per
selection change. **The plate never resizes the ink**: the mark draws at 13pt (`iconSize`,
the same size as the symbols beside it) plated or not, and the plate spans the full 16pt
slot behind it — the slot is wider than its ink already, for the emoji margin. Two earlier
accidents conspired here: the brand PNGs' nominal 15pt relied on "a smaller slot scales the
mark down" in a slot that is 16, and the first plate composed the ink at a ratio of the
plate — so a selected row's mark visibly shrank as its plate arrived. `SessionRowView.slotSized`
now states the ink size once, and `IconBackplate.compose` draws the plate around it.

**Account chips** (`AccountBadge`): the mark keeps the slot and an *alternate* account rides
its bottom-trailing corner as a 9pt chip — the account's emoji, else its discovered avatar,
else an initial on a hashed disc. The two facts a row carries, which agent and which account,
had been competing for one 16pt slot and the account was winning: an alternate account
replaced the mark with a flat `c.circle.fill`, so a sidebar of alternate accounts showed no
agent at all. The chip is laid out as an **overlay** rather than a second arranged view, so
rows with and without one still align, and it hangs `cornerOverhang` past the slot because
flush inside it covered the middle of a 13pt mark.

The initial comes from the **login email**, not the alias: aliases are named after the agent
and collide on it (`claude-nhartley` and `claude-ikeller` are both `c`), while the addresses
give `N` and `K`. Its disc hashes the whole address through `GeneratedProjectIcon.stableHash`,
so two accounts sharing an initial still differ by colour, on a brighter ramp than the project
tiles — a 9pt disc has far less area to carry a hue than a 16pt tile. The **default account
gets no chip**: its agent's mark already says everything the row knows.

`AccountAvatarStore.cachedEmail` memoizes the address, hit or miss. The badge asks on every
row configure and rows reconfigure constantly while an agent works, where the uncached answer
is a file read and a JWT decode for a value that cannot change while the app runs.

**The phone draws the same two facts, from the same decisions.** `MobileSessionMark` is the iOS
tile: the runtime's mark from `MobileAgentIdentity`, with `MobileAccountChip` on its corner. The
marks are the same PNGs, added to the iOS asset catalogue as universal image sets (the Codex knot
keeps its template rendering intent, so SwiftUI tints it and it survives a light theme). Nothing
about the *account* is decided there: `RemoteAccountBridge` resolves the chip on the Mac and sends
`RemoteSessionAccountDTO` — glyph, whether it is an emoji, and the hue — because every input is here
(the account directories, the login address, the user's chosen emoji, the hash). `AccountBadge.hue`
exists for that reason: one hash, used by the drawn chip and the wire, rather than two that agree
until one is edited. A discovered avatar is deliberately not carried; it would be image bytes per
row, and per the coverage note above the hashed initial is the working case anyway. The default
login sends no chip, matching the sidebar rule and keeping the projection off the account
directories for most rows.

`AgentKind.symbolName` and its iOS twin must stay in step; the phone keeps its own table rather than
waiting on bytes it would have to draw an empty slot for. What the phone must never do is take a
*surface* glyph as an identity — every chat row drew `terminal` before this, so no row named its
provider (see [`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md)).

**Project icons** (`ProjectIcon` on `Project`; files owned by `ProjectIconStore`): the
project row shows the project's own mark, else a folder symbol. Every stored icon is
normalised through ImageIO — largest frame (`.ico` carries several), capped at 64px,
re-encoded PNG — so the sidebar never holds a 1024px app icon per row, and an HTML error
page served with a 200 fails the same decode gate that admits real images.

`ProjectIconDiscovery` fills empty slots free of any agent, and **probes known paths rather
than walking the tree**: a recursive scan would surface `node_modules/<lib>/favicon.ico` as
the project's mark. Only the `AppIcon.appiconset` search enumerates, bounded and skipping
dependency directories. Then it may fetch the GitHub owner avatar (read from the *shared* git
config via `GitInfo.remoteOriginURL` — remotes belong to the repository, not a checkout).
`automaticSources` is the closed unattended policy: checkout files and the GitHub organisation
implied by an origin remote. A `package.json` homepage is repository-controlled metadata and is
never followed automatically. **Use Website Favicon…** remains the explicit gesture that may
contact another origin. Automatic discovery only ever fills an **empty** slot; a user's explicit
choice (`.custom`) is never displaced.

The avatar is admitted **only for organisation owners** (`isOrganization`, via
`api.github.com/users/<owner>`): a person's avatar puts the same face on every repo they
own, which distinguishes nothing — and any doubt (API error, rate limit) refuses rather
than guesses, because the failure mode of guessing is a face on every project. A project
with no discovered mark renders `GeneratedProjectIcon` at *draw time* — its initial on a
colour from a stable djb2 hash of the name (`hashValue` is process-salted and would
recolour the sidebar per launch) — never persisted, so the slot stays genuinely empty for
later discovery.

`SingleInstanceLock` (`flock`, held for the process lifetime) refuses a second instance at
launch, before anything touches the stores: two live instances share `projects.json`
last-writer-wins, and even *instantiating* `ProjectStore` writes it once — a relaunch
handoff between overlapping instances is how three projects lost their icon records. The
losing instance's quit path skips store teardown for the same reason.

The sidebar draws the *composed* rendition (`ProjectIconStore.displayImage`): rounded-rect
clipped, and set on a small **backplate** of the opposing tone when the icon's own
alpha-weighted mean luminance would vanish against the ground it is drawn on — a dark mark on
a dark sidebar gets a light plate, measured from the icon's pixels rather than guessed
from its source. The plate colours are fixed neutrals *on purpose*, an exception to the
system-colours rule: a plate exists to oppose its ground, and every system colour follows it.

**The ground is handed over, never inferred** (`IconBackplate.Ground`, constructible only from
an `NSColor`). This took a `darkAppearance: Bool` and turned it into one of two constants — the
tones of the *system* light and dark sidebars, 0.97 and 0.13 — which is the right answer for
exactly one of the app's twenty-one themes. Windows 98's sidebar is `#C0C0C0`, tone 0.75;
Claude's coral starburst measures 0.53. Against the constant the separation came out 0.44 and
against the surface actually painted 0.22, on either side of the 0.24 threshold — so every
favicon whose own tone fell roughly between 0.51 and 0.73 lost its plate under half the themes
in the app. The constants are deleted rather than deprecated, and the rendition cache is keyed
on the ground's quantized tone (`Ground.cacheKey`) instead of on a light/dark flag. Both the
project tile and the agent mark beside it now go through one rule; `ProjectIconStore` used to
carry its own luminance thresholds and its own copy of the two plate colours.

**A plate is baked, so it has to be baked again.** Rows retain the `ProjectIcon` and the
unplated mark and re-compose on `viewDidChangeEffectiveAppearance`, on selection — the ground
moves when a row is filled with accent — and on an app-theme change, through
`ThemeDerivedContent`. That last one was missing, and it hid behind the first: `AppThemeLibrary
.apply` pins `NSApp.appearance` to the theme's mode, so a light→dark switch re-derives every row
by accident and only a **light→light or dark→dark** switch left the plates deciding against the
previous theme's surface. It surfaced as *"the icon only fixes itself once you click the row"*,
because clicking it is the other thing that re-derives.

**The clip rounds a tile, and only a tile** (`fillsItsBounds`: the mean alpha around the
border of a small render, against `tileEdgeOpacity`). A mark that arrives on transparency
has no corners to round, so running the clip over it can only take ink — `sonda`'s wordmark
runs the full width of its canvas along the bottom, and the corner arcs bit the outer edge
off the `s` and the `a`, about 0.8pt each in the 16pt slot, which on a 2pt-wide letter is
most of a stem. An undecodable image reports "not a tile" for the same reason the backplate
rule refuses one: a mark we cannot measure is one we decline to change.

`ProjectIconResearch` asks Codex to identify the mark — headless `codex exec`, read-only
sandbox, low reasoning effort, default account. Codex-only for the *sandbox*, not for policy:
the run reads an unfamiliar project's files and `--sandbox read-only` bounds it in one flag,
where Claude's headless mode — permitted, see `supportsNativeUI` — would need its tool surface
constrained explicitly for no gain here. A Threading project is a folder, not necessarily a Git
repository, so the helper also passes `--skip-git-repo-check`; that skips Codex's repository
preflight, not the read-only sandbox or the host's later project-containment check.
It is **manual-only** because it spends the user's own usage: each run is one explicit
"Research Icon with Codex" menu click, never a background default. A file path in its
answer is admitted only from inside the project's own folder — the run is sandboxed, but
our read of its answer is not.

**A headless child is invisible by construction, so every run leaves a record**: the
child's stdout and stderr — merged into one pipe, so a single reader can never deadlock
and the record holds the whole story — land in `IconResearch/<projectID>.jsonl` under
Application Support, written *before* the verdict so failed runs are exactly the ones
whose record survives. Stages log through `ThreadingLogger.agent`, and the sidebar exposes
the record as "Open Last Research Log". An abnormal exit also surfaces the last plain CLI
diagnostic (or structured error message), stripped of controls and capped at 400 characters;
provider JSONL remains in the record instead of spilling into an alert. This observability exists
because the first real run failed silently and nothing could say where.

Agents can set the icon from inside a session via the `set_project_icon` MCP tool, its own
group on the Tools page.

**Account avatars** (`AccountAvatarStore`): a chip resolves emoji → discovered avatar →
hashed initial. The avatar comes from the account's login
email — Claude's `.claude.json` `oauthAccount.emailAddress`, the `email` claim of Codex's
`id_token` (decoded locally; the token itself is never used) — probed against Gravatar
(SHA-256, `d=404` so a miss is a status code) and then GitHub's public-email user search.
The person-avatar ban on project rows *inverts* here on purpose: an account is a person,
and different logins carry different faces, so the avatar distinguishes. Hits land in
`AccountAvatars/` and refresh the sidebar through the same notification an emoji edit posts;
behind `AppSettings.discoversAccountAvatars`, which is the only thing that lets an email hash
leave the machine.

Coverage is honestly thin — of five logins on this machine only one resolved, so the hashed
initial is the chip's working case rather than its fallback. The chip's cache key carries
`hasAvatar`, so one landing later replaces a drawn initial instead of being ignored.

## File-tree icons

`ThemedFileIconView` makes the File pane follow the same ownership boundary as the rest of the
chrome without pretending Finder artwork is tintable. Under **System**, the view asks
`NSWorkspace` for the path's real icon and draws that finished artwork unchanged. Under an
authored theme it classifies the path into a small semantic vocabulary — folder, source, text,
data, image, audio, video, archive, package, executable, or generic document — and draws an SF
Symbol in `Design.Text.secondary`; folders also carry a quiet `Design.Surface.controlResting`
fill. Classification reads only the name and directory fact, never file contents.

The split is also a performance rule. A materialized row in an authored theme does no
LaunchServices icon lookup. Switching from an authored theme to System loads Finder artwork
lazily, while the reverse switch keeps it cached for a later return. One design-system view owns
both renderers, pixel alignment, and live theme changes, so feature code does not construct a
parallel `NSImageView` path or recolour a foreign bitmap.

## The app's own icon

Three icons for one app, and they answer three different questions.

**The bundle icon** is `Sources/Threading/AppIcon.icon` — an Icon Composer document, layered, with
the glass and depth treatment the platform draws for a real app icon. It is what Finder,
Spotlight, Launchpad and the Dock-while-not-running show, and it is what the **System theme**
asks for. (`Resources/Assets.xcassets/AppIcon.appiconset` is empty and vestigial: both are named
`AppIcon`, `actool` resolves to the `.icon`, and the appiconset should be deleted.)

**The Dock icon follows the app theme** (`GeneratedAppIcon`, installed by `AppIconPresenter`).
Ground plate from `.ground`, Threading mark from `.accent`, and the theme's own `material.glow` behind
the mark — which is not a recolour, because that glow is a soft halo for Cyberpunk and a hard
offset printed shadow for Bauhaus and Neo Brutalism. Without it a beige Bauhaus tile and a beige
Newsprint tile are the same picture.

Four decisions carry it:

- **`applicationIconImage` only.** macOS offers three tiers of runtime icon. This is the first:
  Dock tile, ⌘-Tab switcher and About panel, for the lifetime of the process, at no cost. The
  tier that persists past quit — `NSWorkspace.setIcon(_:forFile:)` on our own bundle, plus an
  `NSDockTilePlugin` loaded into the Dock's process, plus a private call to drop the Dock's icon
  cache — buys a themed Finder icon in exchange for writing into a bundle built with
  `ENABLE_HARDENED_RUNTIME`, which invalidates its signature. The premise does not survive that
  trade: the icon matches the chrome the user is looking at, and there is no chrome to match when
  the app is not running. `dockTile.contentView` is the other half of tier one and is not used
  with this — set both and the tile flickers between them.
- **The plate and its shadow are drawn, not inherited.** The Dock draws a runtime bitmap
  unmasked: none of the rounding, and on macOS 26 none of the squircle, a bundle icon gets free.
  Hence Apple's own grid in `Layout` — an 824pt body on a 1024 canvas, leaving the 100pt margin
  the platform reserves for the shadow it is not adding here.
- **The silhouette never changes.** Only ground, ink and shadow follow the theme; the Threading mark's
  geometry is fixed. An icon's first job is to be found in ⌘-Tab by its shape, and a mark that
  redrew itself per theme would trade the whole point of an icon for a colour match. The only
  geometry a theme moves is the outline's join, from `material.controlRadius` — a small element
  follows the radius the theme gives its small elements. The join only, never the strands'
  caps: the strands end round on every theme, because their ends meet in the knot, and a
  square-cut end is a slanted cut whose corners poke out of the knot on one side and notch it
  on the other. Eighteen themes are mitred, and all eighteen had that junction until 2026-09-04.
- **The cache is keyed by the colours drawn, not by the theme's id.** A custom theme keeps its
  identity across an edit, so an id-keyed cache serves the palette the user just changed away
  from. `Recipe.cacheKey` is the resolved ground, ink, corner and shadow.

Four things about the shadows here were measured rather than reasoned, and all four were wrong first.
Its **scale is matched to the weight of the mark, not to the canvas** — the mark's stroke
against a chrome control's ink, about 4×. Scaling by canvas size instead (an 824pt plate against
a ~96pt element, 8.6×) put Bauhaus's 4pt printed offset at 34pt behind a 115pt stroke, which
stops reading as a lift and becomes a second silhouette; all four zero-radius styles failed the same
way. And its **vertical sign was measured twice**: a theme states its shadow for
`CALayer.shadowOffset`, which `Design.applyThemeGlow` passes through in the layer's y-up space,
so `offsetY: -4` casts *downward*. Drawn through an `NSImage` drawing handler, `NSShadow`
resolved the same number the other way — the first render put every printed style's lift above
its mark — so the renderer negated it. Drawn into a bitmap context (next paragraph but one),
`NSShadow` agrees with the layer, and the negation had to go again;
`testAPrintedStyleCastsItsLiftDownAndRight` caught it both times.

**The plate's own shadow was stated in the layer's sign and never negated**, so through the
handler it was cast upward, and nothing noticed, because on the Mac the margin it falls into is
transparent. The phone's copy composited it over the ground and showed a ring darker along its
top edge than its bottom — the Dock tile had been lit from below since it was first drawn.
`testThePlateShadowFallsBelowTheDockIcon` reads the alpha in the margin above and below the
plate.

**And a Core Graphics shadow is stated in device space.** Drawn through an `NSImage` drawing
handler into a 256px raster, a 40pt offset is still 40 pixels — four times the lift the same
picture carries at 1024. Every rendered-state test here rasterizes at 256, so the contact sheet
the shadow scale was judged on showed every lift and halo at four times its shipped size, and the
first phone-grid edge test failed on Neo Brutalism's lift reaching an edge it does not reach at
1024. `GeneratedAppIcon.draw` therefore rasterizes once, at the canvas size, into a bitmap the
image carries; the Dock, the switcher, a preview and a test all scale the same pixels.

The accent is floored through `NSColor.legible(on:)` rather than trusted: a theme whose accent
sits near its own ground would draw an invisible mark. No stock theme is touched by it —
`AppIconRenderTests` checks the floor against the pixels actually drawn, not the colour asked
for, alongside a 16pt rendition where a mark stops being a mark.

**A contributed theme may ship its own mark** — `ExtensionThemeContribution.iconMark`, a
package-relative PNG beside the theme document. It replaces the default mark; it never replaces the
plate, which stays the theme's own `ground` drawn by `GeneratedAppIcon`.

That split is the whole design, and it is enforced where it cannot be argued with:
`ExtensionBundleLoader.inspectThemeIconMark` refuses a mark that **fills its own bounds**,
reusing `ProjectIconStore.fillsItsBounds` — the same measurement that tells a favicon tile from
a loose wordmark in the sidebar. An opaque rectangle is a package trying to supply the entire
icon, which is the shape you would use to make Threading's Dock tile look like some other
application's. The refusal happens at **inspection**, before the package can be enabled and
before any of its code exists as a process, and it fails the whole package rather than dropping
the artwork quietly: a theme whose icon the host will not draw is a disagreement its author has
to see. The bytes go through `ProjectIconStore.normalizedPNGData` first — the same ImageIO gate
every untrusted image passes — which is why that function grew a `maxPixelSize` parameter rather
than a second copy at icon scale.

`Packages/ThreadingExtensionKit/Examples/StormThemeExtension` is the worked example, and
`ExtensionAppearanceTests.testTheShippedStormExampleIsValid` pins it: the manifest validates, the
theme document decodes and passes `AppThemeEditing.validate`, and the mark clears both gates
`inspectThemeIconMark` applies. It cannot be inspected as a package — the examples ship source
with no built `bin/` — so the test checks everything that could actually be wrong instead. A
broken example is worse than none, because it is copied before it is read.

The install disclosure names it. `ExtensionInstallProposal` counts the themes that carry a
mark and says what can change and what cannot — the glyph moves, the plate stays Threading's — so
the reader approving an unsigned local import is told about the one contribution that changes how
the app looks *outside its own window*, and is not left to assume either the worst or the best.

The mark is held as **bytes** on the contribution, not as an image: the appearance registry
diffs contributions wholesale to converge install, enable, disable, update and uninstall through
one idempotent path, and `NSImage` is not `Equatable`. Decoding is memoized in the registry and
dropped on every replace, because an update that keeps a theme's identity and changes its artwork
is exactly what an id-keyed cache serves stale. The same diff posts `AppThemeDidChange`, since
new artwork under an unchanged theme id is invisible to the id comparison the registry already
made.

**The phone cannot generate an icon at runtime.** iOS has no API that accepts an image:
`setAlternateIconName` selects from icons compiled into the bundle. The primary icon therefore
starts from the canonical full-bleed `Brand/ThreadingMark-Navy-1024.png`.
`scripts/generate_mobile_app_icon.swift` fits that exact mark and plate into the iOS safe zone
before writing both the app-icon and Settings-preview assets; `AppIconRenderTests` pins the
opaque canonical ground at the safe-zone edges and the canonical ink at the centre. The runtime
mark and web export remain the unmodified brand assets.

The built-in Mac styles are also compiled as **manually selected alternate icons**, drawn by the
same renderer on its **phone grid** (`GeneratedAppIcon.Grid.phone`): the theme's ground to every
edge, no rounding and no shadow, and the mark on the 840pt safe zone the primary icon fits the
brand mark into — so a theme's mark is the brand mark's size, and choosing an icon on the phone
changes the paint and nothing else. Run `scripts/generate_mobile_theme_icons.sh`:
`AppIconRenderTests.testRendersThePhoneIconUnderEveryStockStyle` writes every stock style at
1024, and `package_mobile_app_icons.swift` copies those bytes into the app-icon sets and
downsamples the Settings previews from them. The iOS target registers those names with
`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`; **Settings → App icon** calls
`setAlternateIconName` only when the user taps one. The picker can recommend the connected Mac's
current stock style, but it never follows automatically because every change presents an
unsuppressible system confirmation.

The grid exists because the first version packaged the *Dock* render — plate, margin and drop
shadow, at contact-sheet size — over a full-bleed fill of the ground, on the theory that iOS
would supply the mask. It does, and it also draws nothing under the tile, so everything the Dock
form puts in its margin ends up *inside* the squircle. On Pure's white ground the plate's shadow
was a grey ring around a smaller plate; on every theme the mark was a quarter smaller than the
primary icon's, which the picker was hiding by scaling the primary preview down to match; and
the 256px render was being upscaled four times. `testThePhoneIconIsItsGroundToEveryEdge`
measures the drawn form and `testEveryStockStyleHasASelectablePhoneIcon` the shipped bytes: the
outer six percent of every tile is its ground within a colour-space round trip, the ink lands
where the primary icon's does, and every compiled icon is offered by `MobileAppIconChoice` —
Aqua and Tiger had been compiled and never listed.

This intentionally covers only the stock library. A custom or extension-contributed Mac theme
can contain arbitrary colours and marks that were not available when the phone bundle was built.
An adaptive stock theme may ship light and dark luminosity assets in one alternate set; Home
Screen tint remains the user's separate system treatment rather than another Threading setting.
