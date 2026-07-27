# Chrome Typeface Plan

Status legend: `[ ]` open · `[x]` done · `[~]` in progress. Update the boxes as you land work —
this document is the handoff between sessions (started by Fable, may be continued by Opus).

## Goal

Themes state a **typeface** the way they already state radii and glow, and the user can
**override** it with a font family of their own. The style briefs the stock themes originate
from (designprompts.dev) carry a first-class `fontType` per style — `serif` / `sans-serif` /
`mono` — which the themes currently ignore; every chrome is set in SF Sans.

Verified from the site's own style definitions (extracted from its JS bundle 2026-07-27):
Cyberpunk + Vaporwave are `mono`; Art Deco + Newsprint + Botanical are `serif`; Swiss, Bauhaus,
Neo Brutalism, Claymorphism, Industrial are `sans-serif`.

## Design decisions (already taken — do not relitigate)

- **No bundled fonts.** macOS system designs via `NSFontDescriptor.SystemDesign`: `.default`
  (SF Sans), `.serif` (New York), `.rounded` (SF Rounded), `.monospaced` (SF Mono). No
  licensing, correct rendering, every weight.
- **The spec lives in `AppTheme.Material`** (`Sources/Skalman/Core/Theme/AppTheme.swift`):
  `var typeface: Typeface = .standard`, `enum Typeface: String, Codable` with raw values
  `"default" | "serif" | "rounded" | "monospaced"` (case names `standard, serif, rounded,
  monospaced` — `default` is a keyword).
- **The interpreter is `Design.Typography`** (`Sources/Skalman/UI/Design/Design.swift`) — the
  app's single font factory, enforced by the fontFactory boundary. One private transform; no
  feature code changes. Feature code never `if`s on a theme.
- **Four layers, nearest first** (settled in Tier 3): the surface's own override
  (`conversationFontFamily`), the app-wide override (`chromeFontFamily`), the theme's named
  family (`Material.fontFamily`), the theme's typeface class (`Material.typeface`). Each failure
  falls exactly **one** rung, never straight to SF. UI in Settings ▸ Themes ▸ Fonts, two
  `ThemedPopUp`s over `NSFontManager.shared.availableFontFamilies`; `AppSettingsDidChange` on
  change, which `AppThemeRefresh` turns into the ordinary theme sweep.
- **Code stays code.** `Typography.code()/inlineCode()/compactCode()/compactToolName()/
  previewCode()` remain monospaced under every typeface (they may adopt the *override family*
  only if that family is itself monospaced — simplest: never; code is always SF Mono unless the
  theme is `.monospaced`, which changes nothing visibly). `numericBody/Control/Detail` keep
  monospaced *digits* (apply design first, then `.monospacedDigit` trait). The **terminal**
  font is untouched — it is the user's `TerminalProfile`.
- **Stock mapping:** Cyberpunk, Vaporwave → `.monospaced`; Art Deco, Newsprint, Botanical →
  `.serif`; Claymorphism → `.rounded`; Swiss, Bauhaus, Neo Brutalism, Industrial, and every
  other style → `.standard`. System stays `.standard` (the identity promise). Christmas: leave
  `.standard` — another agent owns that file (`AppThemeStyles+Christmas.swift`); suggest
  `.rounded` to them rather than editing it.

## Known traps (each cost a bug already in this codebase)

1. **`Material` decodes with synthesized `Codable` today.** Adding a non-optional field breaks
   decoding of every stored custom theme (missing key throws, and the `?? .system` fallback in
   `Variant.init(from:)` silently discards the user's authored radii). Give `Material` a
   hand-written `init(from:)` using `decodeIfPresent` with the current defaults for **every**
   field. Pin with a test that decodes a pre-typeface JSON fixture.
2. **Fonts freeze like `CGColor`s.** A label keeps the `NSFont` it was given; the theme sweep
   re-resolves colors, not fonts. Fixed in Tier 2 by recording the *role* on the view, the way
   `RecordedSurface` records a fill. Drawn controls (`ThemedControl` subclasses, tabs, chips)
   re-ask Typography in `draw(_:)` and follow for free — **except where a call site overrides
   their `font`**, which is a stored property and freezes like any other.
3. **Ambient appearance is not involved here** (fonts are appearance-independent) — but the
   attribute cache in SwiftTerm and `NSAttributedString` builders that captured a font at
   build time will keep it; same rebuild story as Tier 2.
4. **Concurrent agent:** `AppThemeStyles+Christmas.swift` and `Sources/SkalmanMobile/*` are
   another live session's files. Do not edit them. `Tests/SkalmanTests` files are shared —
   anchor Edits on stable text.
5. **New test files need manual `project.pbxproj` registration** (silent 0-test failure mode) —
   extend existing files: `AppThemeTests.swift`, `ThemeToolTests.swift`.
6. `.swiftlint.yml` + `scripts/check_theme_boundaries.sh` run at build; `NSFont` construction
   outside `Design.Typography`/`TerminalProfile` trips the fontFactory rule — keep everything
   inside the existing factories. `Design.FontRole.resolved()` obeys this by *calling* the
   factories rather than reconstructing what they build.
7. **A font cannot carry metadata, and this plan assumed it could.** See Tier 2 — three
   measurements, each of which independently rules out any design where the sweep classifies a
   font by looking at it. Probe before building on a descriptor attribute: a `swiftc` script
   against AppKit answers in under a minute, and this one was wrong.
8. **`FontRoleApplying` is deliberately not `@MainActor`.** The assignment it replaces was not,
   and `PreferencesFormBuilder` builds labels from nonisolated methods — annotating the protocol
   pushes the isolation out to those call sites, which is a concurrency change wearing a
   typeface change's clothes.

## Tier 1 — the spec and the interpreter

- [x] `AppTheme.Material`: `Typeface` enum + `typeface` field + hand-written `init(from:)`
      (decodeIfPresent everything, incl. the pre-existing fields; encode stays synthesized) +
      explicit memberwise init (a custom decoder suppresses the implicit one, and the style
      files call it). `Material.system` stays `Material()`.
- [x] `Design.Typography`: private `prose(_:)` transform — theme design via
      `fontDescriptor.withDesign`, input-fallback on descriptor failure. All prose factories
      routed (incl. `markdownHeading`); code factories untouched; **decision change:** numeric
      factories stay SF monospaced-digit entirely (design + digit-feature stacking is fragile,
      and aligned columns outrank a serif digit).
- [x] Stock mappings: cyberpunk + vaporwave → `.monospaced`; artDeco, newsprint, botanical →
      `.serif`; claymorphism → `.rounded`; the rest untouched (= `.standard`).
- [x] Tests in `AppThemeTests.swift`: `testTheThemeTypefaceReachesProseAndSparesCode`,
      `testPreTypefaceMaterialDocumentsDecodeWithDefaults`.
- [x] Run: build + AppThemeTests, ThemeToolTests, ThemeSettingsRenderTests,
      ToolbarChromeRenderTests, ThemedControlTests — all green 2026-07-27. **Tier 1 complete;
      continue from Tier 2.** (Trap discovered en route: scripted regex edits on the style
      files put `typeface:` inside the nested `Glow(...)` literal — if you batch-edit
      materials, verify the argument landed on `Material`, not `Glow`.)

## Tier 2 — live switch moves the whole window

**The tag does not exist and cannot.** The plan assumed `Design.Typography` could stamp each
font with a `skalmanFontRole` descriptor attribute and let the sweep read it back. Measured on
macOS 26 (`Tests/SkalmanTests/AppThemeTests.swift`, `testAFontCannotBeMadeToCarryItsOwnRole`):

- **`NSFont` strips unknown descriptor attributes.** Every read after
  `NSFont(descriptor:size:)` came back `nil` — before *and* after `withDesign`, and through an
  `NSTextField`. A font cannot carry its own role.
- **Under a `.monospaced` theme, prose and code are byte-identical.**
  `.systemFont(13).withDesign(.monospaced) == .monospacedSystemFont(13)` is `true`, same
  `fontName`. So nothing recoverable from the font distinguishes them either. (Prose *is*
  separable from numeric — numeric carries a monospaced-digit `featureSettings` — which is one
  clue short of enough.)
- **Tier 3 would kill inference anyway.** With `chromeFontFamily = "Helvetica"` every prose font
  is Helvetica, so classifying by family classifies nothing.

So the role is recorded **on the view**, which is what `RecordedSurface` already does for the
`CGColor` freeze — same bug, same answer. Cost: the assignment changes at the call site.

- [x] `Design.FontRole` (`Sources/Skalman/UI/Design/FontRole.swift`): the *recipe*, not a
      category — `.detail(weight: .medium)` has to come back medium. `resolved()` routes every
      branch through `Design.Typography`, so it names calls rather than making fonts and the
      fontFactory boundary is untouched. `followsTheme` marks prose.
- [x] `FontRoleApplying` + `applyFont(_:)`: the protocol is what the sweep looks for, so a view
      type joins by declaring how it takes a font rather than by remembering to observe.
      Conformed: `NSTextField`, `NSTextView`, `MorphingTitleLabel`, and `ThemedButton` — the last
      because a drawn control still freezes a font a call site *overrides* (4 sites do).
- [x] Sweep: `AppThemeRefresh.repaint(_:)` calls `reapplyRecordedFont()`, which re-resolves and
      assigns only if the answer moved, then invalidates the intrinsic size.
- [x] Call sites migrated: 173 of 174 `x.font = Design.Typography.y()` → `x.applyFont(.y)`
      (`scripts`-free, one scripted pass, whole-statement anchored — the trap below — plus two by
      hand: a `$0.font =` in a `forEach` and `ThemedTextField`'s implicit-self assignment). A
      missed site still compiles and still looks right; it simply stops following the theme.
- [x] Detached trees: a **cached settings page** and a **retained conversation** are in no
      window, so the sweep never reached them — they now take `AppThemeRefresh.repaint` on
      attach. Better than dropping the cache, which would cost the page its scroll position to
      fix what one walk can take again. The sidebar needed nothing: its rows are in the window
      and its `MorphingTitleLabel`s conform.
- [x] Built attributed strings do not follow, because their font freezes *into the string*:
      `GitReviewViewController` re-reads on `AppThemeDidChange` (it already keeps scroll offset
      and hand-expansion across a reload, so the switch costs a git read and nothing visible),
      and `ThemedTextField` rebuilds its placeholder. `PromptView`'s placeholder is drawn in
      `draw(_:)` and follows for free; the rest of the `.font:` sites are measurement-only.
- [x] Render check: `ThemeSettingsRenderTests.testALiveTypefaceSwitchMovesAPageThatWasAlreadyBuilt`
      builds the page under one theme, switches to a **typeface-only twin** (same roles, same
      palette, same radii — so a pixel that moves moved because of the typeface; two stock styles
      would only have proved their colours differ), sweeps, and asserts every prose label changed
      family, no code label did, and the PNG differs. Verified to fail with the sweep removed:
      8+ labels named, by role.
- [x] Intrinsic sizes: `invalidateIntrinsicContentSize()` in both `applyFont` and
      `reapplyRecordedFont`.
- [x] Run: build + AppThemeTests (57), ThemeSettingsRenderTests, ThemedControlTests,
      ToolbarChromeRenderTests, ThemeToolTests — all green 2026-07-27. **Tier 2 complete;
      continue from Tier 3.**

## Tier 3 — the user override

David's addition (mid-flight): it should also be possible to give the **conversation surface**
(native Claude/Codex rendering) a different font from the rest of the chrome — the same idea as
the terminal already having its own font via `TerminalProfile`. Model it as **two** override
slots resolved per surface: `chromeFontFamily` (whole app) and `conversationFontFamily`
(falls back to the chrome override, then the theme). The conversation row views must then ask a
conversation-scoped factory (`Typography.conversation…` namespace or a `FontSurface` parameter)
instead of the plain prose factories — keep it one transform with a surface argument, not a
second copy of Typography.

**Arbitrary families, not just the four classes** (David, after Tier 2): the predefined set is
`AppTheme.Material.Typeface`, and a *theme* should be able to name any installed family too —
not only the user's override. So `Material.fontFamily: String?` sits above `typeface`, and the
four resolution layers below are what both halves share.

- [x] `AppSettings`: `chromeFontFamily` + `conversationFontFamily`, `nonisolated static` like the
      readers `Design.Typography` needs. **No `registerDefaults` entry**, deliberately — an
      absent key already reads as `nil`, which *is* the documented default, so the seeding the
      `Bool` settings need would only restate it. `setOrRemove` keeps "no override" the absence
      of the key rather than an empty string, which would resolve no font.
- [x] `AppTheme.Material.fontFamily`, `decodeIfPresent` like every other field, wins over
      `typeface` where it resolves and degrades where it does not — the dangling-name rule.
- [x] `Design.Typography` resolves four layers, nearest first: surface override → app override →
      theme family → theme design. **Each failure falls exactly one rung**, so a removed
      conversation font leaves the thread on the app's choice rather than resetting to SF.
      `FontSurface` is a parameter on the one private transform; `FontRole.resolved(in:)` and
      `applyFont(_:in:)` carry and record it.
- [x] The conversation surface: `MarkdownStyle.assistant`, `ConversationRowView`,
      `ConversationTurnPreview`, `PermissionRequestView`, `ToolCallView` — and `PromptView`
      gained `fontSurface`, because what is typed becomes a bubble in the thread and a composer
      in SF feeding a bubble in Baskerville changes font at the one moment the user is watching.
      `ToolCallView.makeLabel` took an `NSFont` and so froze four labels out of the Tier 2 sweep
      entirely; it takes a role now.
- [x] Settings ▸ Themes ▸ **Fonts**: two `ThemedPopUp`s, "Follow Theme" / "Follow App Font" plus
      every installed family. A family the user has since uninstalled lands the picker back on
      the inherit row rather than claiming a font that is not there.
- [x] `AppThemeRefresh.startObservingFontOverrides` reuses `AppThemeDidChange` rather than
      teaching a dozen consumers a second event — everything that must happen for a font change
      is what already happens for a theme change. Guarded on the values, or toggling branch
      grouping would repaint every window and re-read git in every open review pane.
- [x] Tests in `AppThemeTests`: the four layers in order, uninstalled family degrades (override
      *and* theme), a theme names its own family, code and numerics spared, weight survives the
      swap, the sweep remembers the surface, pre-`fontFamily` documents decode.

**The obvious implementation was silently broken twice, both measured on macOS 26:**
`fontDescriptor.withFamily(_:)` on a *system* font does nothing at all — the `NSCTFontUIUsage`
attribute outranks the family, so asking for Baskerville returns `.AppleSystemUIFont` — and an
unknown family through that route hands back a **fallback rather than `nil`**, so there is
nothing to detect and nothing to fall through from. A descriptor built from `.family` + `.traits`
does both correctly. `Typography.inFamily` is that, and italic is tried and then dropped, since a
family with no italic face is a reason to lose the slant rather than the family.


## Tier 4 — surfaces beyond the window

- [x] MCP: `typeface`, `font_family` and `remove_font_family` in the material vocabulary, both
      directions. An unknown typeface is refused **with the accepted list in the message**, since
      an agent reading a style brief that says "sans-serif" has no other way to learn this
      vocabulary calls it `default`. `font_family` is checked against the installed families at
      *authoring* time — a theme that merely arrives naming an absent family still degrades.
- [x] `RemoteThemeBridge` + `RemoteWireDTO`: `typeface` and `fontFamily` optional in both
      directions, so an older client ignores them and a newer one still decodes an older Mac's
      payload. Mobile consumes when ready; `Sources/SkalmanMobile` untouched.
- [x] `USER_GUIDE.md` (Themes ▸ Fonts), `docs/architecture/themes.md` (a theme states a
      typeface, the four layers, what never follows), `docs/architecture/design-system.md`
      (the `.conversation` surface alongside the `applyFont` rule).
- [x] Component gallery: nothing to add. Its theme pop-up goes through `AppThemeLibrary.apply`,
      whose `repaintEverything()` reaches the gallery window like any other, and its own
      appearance toggle already calls `AppThemeRefresh.repaint(view)`. Every prose story
      (`.heading`, `.subheading`, `.body` at lines 209/213/545/1559) migrated to `applyFont` in
      Tier 2, so all of them follow a live switch. **Tier 4 complete.**

## Verification (every tier)

Full suite before installing: `xcodebuild … test` — known pre-existing flakes:
`BrowserAgentBridgeIntegrationTests` (SEGV in AppKit teardown, passes on retry) and one
`ExtensionBundleLoaderTests` case in full-suite runs only.

**As of 2026-07-27 those two are no longer intermittent on this machine — they fail every run**,
taking the host down 5 times and cutting the reported total from 1210 to 902 with *zero*
assertion failures. The crash is a ~21s hang in a `WebContent` process during browser
automation, and it reproduces in a run containing only those two suites. So the honest way to
verify a change is:

```bash
xcodebuild … test -skip-testing:SkalmanTests/BrowserAgentBridgeIntegrationTests \
                  -skip-testing:SkalmanTests/ExtensionBundleLoaderTests
```

which is **1158 tests, 0 failures, exit 0**. Do not read a bare `** TEST FAILED **` with 0 case
failures as a regression without checking which suites restarted — and do not read it as "fine"
either. Worth noting for whoever picks this up: a Skalman instance was *running* during these
runs, which is a plausible cause (a live app holding WebKit processes and the shared website
data store) and is untested — quitting it before a full run is the first thing to try.

Install:
Release build (`ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`), `ditto` to `/Applications`,
checksum-verify, `codesign --verify`. Another session may build concurrently — on
`database is locked`, wait ~20s and retry rather than switching DerivedData.

## 2026-07-27 — independent verification and fixes (post-run, Fable)

An independent audit of the finished run confirmed every tier's claims and found the
following, all fixed the same day. Corrections to this document's own record first:

- **The migration is complete, not 173/174** — the one remaining
  `\.font = Design.Typography` grep hit is a doc comment in `FontRole.swift`.
- **Trap 5 is obsolete**: the project now uses `PBXFileSystemSynchronizedRootGroup`, so new
  source/test files under a synchronized folder build without pbxproj edits. `FontRole.swift`
  itself ships with zero pbxproj references.

Bugs found and fixed (none were visible to the suite — the conversation surface had no
end-to-end font test; it does now, in `AppThemeTests`):

1. **Three conversation rows never migrated** — `ConversationRowView.thinking/notice/streaming`
   assigned a chrome-surface font with no recorded role, so a streaming reply changed face the
   moment it finished (the exact failure `PromptView.fontSurface` exists to prevent), and all
   three sat out live switches. Now `label(_:role:color:)` + `applyFont(_:in: .conversation)`.
   The `frozen_theme_font` lint rule cannot see this shape (the font arrived as an argument).
2. **Markdown headings resolved as chrome** — `MarkdownInline.headingFont` re-entered the four
   layers with the default surface, so under a conversation font a `# Heading` could answer in
   a different family than its own paragraph. `MarkdownStyle` now carries `fontSurface`.
3. **The typeface was read through the ambient drawing appearance** — same trap this run fixed
   for `terminalPalette`, same fix: `prose` resolves `material(for:)` anchored to the
   application's appearance. Radii/glow deliberately stay ambient (draw-time reads).
4. **The font tests deleted the developer's real overrides** — app-hosted tests share the
   shipping defaults domain; `removeObject` in `tearDown` wiped a real chosen font every run.
   `setUp` now sets the two keys aside and `tearDown` restores them.
5. `Typography.resolve` gained a positive-only cache — family matching ran per `draw(_:)`
   under an override; (family, weight, slant, size) depends only on installed fonts, so hits
   never invalidate, and misses are deliberately not cached so a font installed mid-run is
   found on the next ask.
6. The Fonts pickers reload on `AppThemeDidChange` — the settings page is cached, so an
   override changed via MCP or another window left them stale.
7. `overrideFamilies` screens `""` — nothing writes one today, but a hand-edited default would
   have gone to the descriptor matcher, whose answer for `""` is not a documented `nil`.
8. USER_GUIDE: Botanical added to the serif list; the uninstalled-font paragraph now names
   each picker's own inherit row (the conversation picker says "Follow App Font").
