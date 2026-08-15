# Archived extension appearance plan — chromes and fonts as package data

Status legend: `[ ]` open · `[x]` done · `[~]` in progress. Started and landed by Fable
2026-07-27, after the chrome-typeface work (see `TYPEFACE_PLAN.md`) made the resolution
side of this nearly free. `docs/architecture/themes.md` §2026-07-27 holds the architecture
summary; this file records the decisions and what remains.

## Goal

An extension bundles **app themes** ("chromes") and **fonts**. While it is enabled its themes
are pickable in Settings ▸ Themes and its font families are choosable in the font pickers —
and nameable by its own theme documents (`Material.fontFamily`), which is how a theme pack
styles the whole app in its own face (the rain extension's storm theme + rain overlay + rain
font, one package).

## Design decisions (taken — do not relitigate without new evidence)

- **Data-plane, manifest-declared.** `themes:` and `fonts:` are manifest fields naming
  package-relative resources, gated by two new capabilities in the existing `appearance.*`
  namespace (`appearance.themes`, `appearance.fonts`). Everything is read by the inspector
  before any extension code runs — the same posture as a Metal `shaderResource` — so the
  install proposal can name every theme and font family, and the running guest gains **no**
  new broker operation. Both capabilities are in `safeCapabilities` for that reason.
- **The theme document is the host's own vocabulary** — the JSON `AppThemeStore` persists for
  a custom theme, not the MCP patch language and not a kit-modelled type. The kit stays thin
  (id + resource path), and the vocabulary grows (a new material field) without an SDK
  release. Authoring flow: build the theme in-app via the MCP tools, then copy the stored
  document.
- **Namespaced ids, host-assigned**: `ext.<extension identifier>.<contribution id>`. Whatever
  the document states, it cannot impersonate a stock or custom theme, and two extensions may
  both ship `storm`.
- **Same gates as a custom theme**: `AppThemeEditing.validate` runs at inspection —
  a contributed theme with unreadable labels is refused at the door, with the resource path
  in the error.
- **Fonts register process-scoped** (`CTFontManagerRegisterFontsForURL`, `.process`) on
  enable, unregister on disable, re-register at launch — never installed to the user's
  system. Family names come from the file, not the manifest (stating them twice invites
  drift). Licensing is the package author's responsibility; the install disclosure says so.
- **Selection semantics**: disable while active → fall back to System *recorded as the
  choice* (no snap-back later); the launch-time fallback (stored choice unresolvable because
  its extension had not enabled yet) heals when it resolves again. Safe because
  `AppThemeLibrary.apply` now records a pick even when it changes nothing on screen.
- **No SDK_VERSION bump.** Additive manifest fields decode as `[]` on older packages, and an
  unknown capability on an older host is refused at inspection with the name in the message —
  the compatibility behaviour API_V1 already specifies. `safeCapabilities` is normative by
  reference and carries the addition.

## Measured (probe scripts, macOS 26, 2026-07-27)

The third and fourth font assumptions in this codebase that were wrong until measured:

1. A `.process` registration **is** visible to descriptor matching (`Typography.inFamily`),
   live in both directions — resolution, degradation and the sweep needed zero changes.
2. `NSFontManager.availableFontFamilies` **snapshots on first access** and never sees a later
   registration (probe 1 read it before registering and it stayed stale; probe 2's first-ever
   read after registering saw the family). Hence `Design.Typography.availableFamilies`
   (CoreText, live) now feeds the pickers and the MCP authoring gate.

## Landed 2026-07-27

- [x] Kit: `ExtensionThemeContribution`, `ExtensionFontContribution`, `themes`/`fonts`
      manifest fields (decodeIfPresent), capability constants + `safeCapabilities`, `validate()`
      rules (counts ≤16, safe relative paths, unique ids/resources, capability pairing, font
      file extensions otf/ttf/ttc).
- [x] Inspector: `inspectThemes` (read ≤256 KiB, decode `AppTheme`, namespace id, editing
      gates) and `inspectFonts` (≤16 MiB, must parse; families captured for disclosure);
      symlink-escape refused via the shared `resolveResource`. New error cases
      `themeResourceInvalid`/`fontResourceInvalid` carry the resource path.
- [x] `ExtensionAppearanceRegistry` (new file): derived from enablement in the
      `syncSettingsRegistry` shape; font activation behind a test seam; failed registrations
      not bookkept; font-set changes answered with `repaintEverything` + `AppThemeDidChange`.
- [x] `AppThemeLibrary`: `contributed` tier in `all`, `isContributed`, `contributorName(of:)`,
      `contributedThemesDidChange` (fallback + healing), `apply` records no-op picks,
      contributed-specific update refusal message.
- [x] `ExtensionManager.prepareAppearanceContributions()` before `AppThemeLibrary.restore()`
      in `AppDelegate`; `syncAppearanceRegistry()` in `notifyChange()` and
      `startEnabledExtensions()`.
- [x] Surfaces: install proposal names themes and font families; theme picker labels
      contributed themes by extension name; MCP `list_app_themes`/`get_app_theme` report
      origin `extension “<name>”`; MCP `font_family` authoring gate and the Settings font
      pickers enumerate via `Design.Typography.availableFamilies`.
- [x] Tests: `Tests/ThreadingTests/ExtensionAppearanceTests.swift` — inspection (namespace,
      capability pairing, editing gates, symlink escape, font parse + families), library tier,
      the full selection-lifecycle arc, font bookkeeping with the seam, MCP origin, proposal
      disclosure. New file: the Tests group is filesystem-synchronized (see the obsolete-trap
      note in `TYPEFACE_PLAN.md`), so no pbxproj edits.
- [x] Docs: `docs/extensions/README.md` (profile row + data-plane section), manifest schema,
      `AGENT_AUTHORING.md` forbidden-list amendment (node UI vs. sanctioned data plane),
      `USER_GUIDE.md` (Themes + Fonts), `docs/architecture/themes.md` dated subsection.

## Open

- [ ] A packaged reference example (rule 5: examples are normative) — extend
      `RainWindowExtension` with a storm theme + an OFL font, or a dedicated
      `StormThemeExtension` example. Needs an OFL-licensed font file committed with its
      license text.
- [ ] Settings ▸ Extensions "Provides" row: surface theme/font contribution kinds beside
      commands/panels (`contributionKinds` derivation).
- [ ] A real-registration integration test: needs a committed fixture font (same OFL work as
      the example); until then registration semantics rest on the recorded probes and the
      stubbed-seam tests.
- [ ] Update-flow test: package update that renames a theme id or drops a font, asserting the
      registry diff and the active-theme fallback across `ExtensionManager.update`.
