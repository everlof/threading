# Skin and Chrome Imports

> Status: feature draft — research and candidate import order recorded for future evaluation; no
> additional format support is scheduled or committed.

## Summary

Extend Threading's theme import beyond the classic Winamp `.wsz` title-band slice by translating
useful parts of established skin and window-decoration formats into the existing `AppTheme` and
`WindowChromeStyle` model.

External formats should be **inputs**, not new runtime theme engines. An importer resolves an
external package once, stores bounded local assets through `ThemeAssetStore`, and produces an
ordinary authorable Threading theme. The application continues to render its own semantic
components; it does not emulate another program's widget tree or carry foreign behavior forward.

The strongest next candidate is Openbox 3. Its theme vocabulary closely matches Threading's
existing primitives: active and inactive window chrome, border geometry, solid and gradient
textures, flat/raised/sunken surfaces, pressed/hover/toggled button states, text shadows, and
one-bit caption-button masks.

## Existing foundation

This proposal extends rather than replaces:

- `AppTheme` and `AppTheme.Material`, which remain the normalized semantic theme model;
- `WindowChromeStyle`, which owns title-band shape, texture, active/inactive presentation, visible
  caption buttons, and classic-skin assets;
- `ThemeAssetStore`, which gives imported local artwork a bounded, theme-owned home;
- `ClassicSkinImporter`, whose archive ceilings, path checks, image validation, and resolved-asset
  flow establish the security pattern for future importers;
- the Themes settings surface, which should preview the resolved Threading result rather than a
  promise of perfect foreign-engine compatibility.

Classic `.wsz` support is deliberately a window-chrome slice today. It reads `TITLEBAR.BMP`, stores
one resolved local image, and lets shared Threading components provide the rest of the interface.
New importers should preserve that boundary.

## Product contract

An **Import Theme…** flow may eventually recognize multiple formats. Before saving anything, its
preview should state which capabilities were found and which were translated:

| Capability | Example result |
| --- | --- |
| Palette | App surfaces, text, selection, focus, accent, and terminal ANSI colors |
| Window chrome | Active/inactive title band, borders, title treatment, caption glyphs |
| Controls | Surface treatment and supported rest/hover/pressed/toggled states |
| Icons | Bounded local masks or images assigned to known semantic roles |
| Unsupported behavior | Explicitly ignored and never executed |

“Imported” means a safe semantic translation, not pixel-perfect emulation of the source
application. The preview must not imply that an Openbox menu, VLC playlist, browser toolbar, or
Winamp media control will become a new Threading feature.

## Candidate formats

### 1. Openbox 3 themes (`.obt` or an extracted theme folder)

**Recommendation: first full chrome importer.**

Openbox themes use an X-resource-style `openbox-3/themerc` plus optional one-bit XBM masks for
caption buttons. Its documented roles include active/inactive window title and border colors,
window and menu geometry, solid and several gradient textures, borders, interlacing,
flat/raised/sunken bevels, and distinct button states.

Likely mapping:

| Openbox concept | Threading destination |
| --- | --- |
| `window.active/inactive.title.bg` | `WindowChromeStyle.TitleBar` textures |
| Active/inactive border and separator colors | Window border and divider roles |
| `Flat`, `Raised`, `Sunken` | `ThemedSurface`/material bevel treatment |
| Solid, vertical and split gradients | Authored surface fills or resolved title textures |
| Button unpressed/hover/pressed/toggled roles | Shared caption and control state styles |
| `close.xbm`, `max.xbm`, `iconify.xbm`, variants | Bounded one-bit caption glyph artwork |
| Menu item and OSD colors | Popover/menu/selection roles where the semantics agree |

Do not silently invent unsupported geometry or map every Openbox property merely because it
exists. Preserve the source theme name and author metadata when present, and report ignored keys in
an optional import summary.

Primary references:

- [Openbox theme specification](https://openbox.org/help/Themes)
- [Openbox `.obt` packaging through ObConf](https://openbox.org/obconf)
- [Bundled Openbox theme sources](https://github.com/danakj/openbox/tree/main/themes)

### 2. Browser theme manifests

**Recommendation: early palette and header-texture importer.**

Chrome and Firefox theme manifests are declarative and already describe browser-like chrome:
frames, toolbars, tabs, text, focus, buttons, tints, header images, image alignment, and tiling.
They are a natural source for Threading's title band, tab strip, sidebar/header palette, and related
semantic colors.

Parse only the static `theme` object. Ignore every extension capability outside it. Never install
the package as an extension or load HTML, JavaScript, content scripts, remote resources, or browser
permissions.

Primary references:

- [Chrome theme format](https://developer.chrome.com/docs/extensions/develop/ui/themes)
- [Firefox `theme` manifest](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/theme)

### 3. Editor and terminal color formats

**Recommendation: inexpensive palette importers, clearly labeled as color-only.**

These sources carry little or no control geometry, but map well to Threading's semantic surfaces
and terminal:

- VS Code color-theme JSON: workbench, sidebar, title bar, tabs, buttons, inputs, lists, focus,
  syntax tokens, and terminal roles;
- Windows Terminal `schemes` JSON: foreground/background, cursor, selection, and the ANSI 16;
- iTerm2 `.itermcolors`: an established macOS terminal color-preset package.

VS Code token colors may feed terminal/transcript syntax roles only where Threading has a stable
semantic equivalent. Do not expose arbitrary VS Code identifiers as permanent `AppTheme` fields.

Primary references:

- [VS Code theming](https://code.visualstudio.com/api/extension-capabilities/theming)
- [Windows Terminal color schemes](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/color-schemes)
- [iTerm2 color presets](https://iterm2.com/documentation-preferences-profiles-colors.html)

### 4. KDE Aurorae SVG window decorations

**Recommendation: later, SVG/config subset only.**

Aurorae's declarative variant packages SVG frame parts, active/inactive/maximized states, inner
borders, masks, and separate SVG caption buttons with their own states. Its edge/corner/center
construction is the strongest candidate for scalable, high-fidelity window chrome.

Accept only the documented SVG and configuration subset. Aurorae can also use QML; Threading must
not load or execute it. Imported SVG must be sanitized or rendered through a deliberately narrow
image pipeline with byte, pixel, nesting, filter, reference, and expansion limits. External URLs,
scripts, animation, embedded foreign objects, and fonts are out of scope.

Primary reference:

- [KDE Aurorae SVG decorations](https://develop.kde.org/docs/plasma/aurorae/)

### 5. VLC skins2 (`.vlt`)

**Recommendation: research source or restricted component importer, not a full UI engine.**

VLC skins can describe bitmap resources, fonts, positioned layouts, buttons, sliders, text, and
media-player actions. The asset/state vocabulary could enrich Threading's component model, but the
source layouts assume a fixed media-player interface rather than a resizable agent workspace.

A future importer could recognize safe artwork and supported state images. It should not recreate
arbitrary source layouts or actions.

Primary reference:

- [VLC skins2 format documentation](https://code.videolan.org/videolan/vlc/-/blob/master/doc/skins/skins2-howto.xml)

### 6. Winamp Modern (`.wal`)

**Recommendation: no general compatibility promise; consider assets and declarative XML only if
there is demonstrated demand.**

Modern skins combine freeform XML groups and PNG resources with compiled MAKI scripts. Full
support would mean implementing another layout/runtime system and accepting behavior-rich skin
packages—the opposite of Threading's semantic theme boundary.

Never execute MAKI, plugins, or package-provided code. A possible future subset may translate
colors, images, and a small set of declarative state sprites, with the import preview explicitly
calling the result partial.

Primary references:

- [Winamp developer wiki](https://wiki.winamp.com/wiki/Main_Page)
- [Open Winamp source](https://github.com/alexfreud/winamp)

## Openbox evaluation corpus

Use real themes for research and visual comparison, but create clean synthetic fixtures for
automated parser tests unless a theme's license is deliberately adopted and recorded.

### Canonical bundled themes

- [Clearlooks](https://github.com/danakj/openbox/tree/main/themes/Clearlooks/openbox-3) — baseline
  gradients, menus, borders, and conventional active/inactive chrome.
- [Natura](https://github.com/danakj/openbox/tree/main/themes/Natura/openbox-3) — custom caption
  masks and hover/toggled state variants.
- [Mikachu](https://github.com/danakj/openbox/tree/main/themes/Mikachu/openbox-3) — compact chrome
  and custom one-bit button glyphs.
- [Onyx-Citrus](https://github.com/danakj/openbox/tree/main/themes/Onyx-Citrus/openbox-3) — dark,
  higher-contrast palette and texture choices.

### Community range

- [Addy's Openbox collection](https://github.com/addy-dclxvi/openbox-theme-collections) includes
  preview images and a GPL-3.0 license. Initial visual references:
  [Blocks](https://github.com/addy-dclxvi/openbox-theme-collections/tree/master/Blocks/openbox-3),
  [Numix-Clone](https://github.com/addy-dclxvi/openbox-theme-collections/tree/master/Numix-Clone/openbox-3),
  [Leve-Cyan](https://github.com/addy-dclxvi/openbox-theme-collections/tree/master/Leve-Cyan/openbox-3),
  [Umbra](https://github.com/addy-dclxvi/openbox-theme-collections/tree/master/Umbra), and
  [Penumbra](https://github.com/addy-dclxvi/openbox-theme-collections/tree/master/Penumbra).
- [BunsenLabs themes](https://github.com/BunsenLabs/bunsen-themes) provide polished minimal/dark
  descendants of the CrunchBang visual language.
- [Lubuntu Arc Round](https://github.com/the-zero885/Lubuntu-Arc-Round-Openbox-Theme) is a useful
  contemporary rounded case.
- [Greylooks](https://github.com/vbrand1984/greylooks-openbox) exercises a more classical,
  industrial treatment.
- [Openbox Themes gallery](https://store.kde.org/browse?cat=140&ord=latest-creator&page=1) provides
  downloadable community `.obt` packages; each item's provenance and license must be evaluated
  independently.

The initial manual compatibility set should be **Clearlooks, Natura, Mikachu, Onyx-Citrus, Blocks,
and Umbra**. Together they cover gradients, bevels, active/inactive presentation, one-bit caption
masks, hover/toggled states, dark chrome, and non-default geometry.

## Native package direction

Do not adopt an external format as Threading's authoring contract. If sharing themes becomes a
product feature, introduce a deliberately small native package, tentatively:

```text
Example.threadingtheme/
  manifest.json
  theme.json
  assets/
  preview.png
  LICENSE
```

The name and exact structure are unresolved. The durable requirements are:

- `theme.json` remains an encoded form of the current semantic theme model;
- assets are local, content-addressed or otherwise collision-safe, and bounded;
- the manifest records format version, author, provenance, license, and supported capabilities;
- the preview is inert artwork, not rendered web content;
- the package carries no executable code, scripts, plugins, commands, or network references;
- importers for external formats resolve into this model instead of retaining a second live
  engine.

## Security and licensing boundary

Every new importer must begin from the same hostile-file assumption as `ClassicSkinImporter`:

- limit archive bytes, entries, individual expansion, total expansion, image dimensions, decoded
  memory, text length, nesting, and parse time;
- reject encrypted entries, absolute paths, parent traversal, symlinks, device files, duplicate
  normalized names, unsupported compression, and ambiguous encodings;
- do not follow local or remote references outside the package;
- never execute WAL/MAKI, Aurorae QML, browser extension code, VLC actions, shell commands, or
  plugins;
- copy only validated resolved assets into `ThemeAssetStore`;
- preserve accessibility contrast overrides and system Increase Contrast behavior even when the
  source theme does not;
- keep localized application text in Threading's renderer; imported bitmap fonts or finite glyph
  sheets may be used only where a complete safe fallback exists;
- treat import support as format interoperability, not permission to redistribute themes.

User-imported artwork remains the user's local choice. Any theme bundled with Threading requires a
compatible license, attribution, and a recorded provenance decision. A repository license does not
automatically cover third-party images linked or collected by that repository.

## Rejected directions

- **Run a foreign skin engine inside Threading.** It duplicates layout, accessibility, event,
  localization, and lifecycle systems and lets foreign semantics displace application behavior.
- **Execute theme scripts for fidelity.** Appearance packages should not gain application-level
  authority.
- **Promise pixel-perfect full-application conversion.** External roles are not one-to-one with an
  agent workspace; honest partial translation is preferable to invented controls.
- **Make Openbox, browser, VS Code, VLC, or WAL fields part of the native schema.** Import adapters
  absorb source-specific names and produce stable Threading roles.
- **Import proprietary system theme engines such as `.msstyles` or WindowBlinds first.** Their
  undocumented or behavior-rich assumptions offer less interoperability and a worse security and
  maintenance boundary than the declarative candidates above.

## Proposed implementation order

### 1. Import framework and report

- Define format detection separate from parsing.
- Define a common resolved import result: metadata, `AppTheme`, validated assets, capability list,
  warnings, and unsupported features.
- Add a preview-before-save flow and deterministic conflict naming.
- Generalize archive/image limits without weakening the classic-skin ceilings.

### 2. Openbox importer

- Parse a strict documented subset of `themerc` with duplicate-key and numeric-range validation.
- Add a bounded XBM mask reader for known caption roles and states.
- Resolve active/inactive chrome, surface textures, borders, buttons, menus, and semantic colors.
- Compare the six-theme manual corpus and maintain clean synthetic parser fixtures.

### 3. Declarative color imports

- Add browser static-theme, VS Code color-theme, Windows Terminal scheme, and `.itermcolors`
  adapters.
- Label results as palette-only or palette-plus-header in the preview.
- Use perceptual fallback generation only for missing Threading roles, never to overwrite supplied
  values silently.

### 4. Aurorae SVG subset

- Specify the accepted SVG/config subset before implementing it.
- Add active/inactive/maximized nine-slice frame resolution and known caption states.
- Render and store inert resolved assets; do not preserve live SVG behavior unnecessarily.

### 5. Reassess VLC and WAL demand

- Collect real user packages and desired outcomes.
- Decide whether component artwork provides enough value without layout or scripts.
- Do not begin general compatibility work without a narrow product contract.

## Verification

Tests and manual references should prove that:

- malformed, oversized, nested, traversing, encrypted, duplicated, and unsupported packages fail
  before assets are persisted;
- failure is atomic and leaves no partial theme or orphaned asset directory;
- importing the same package twice is deterministic;
- supplied active/inactive and button states do not collapse into one state accidentally;
- unsupported fields are reported consistently and do not alter unrelated theme roles;
- local assets survive relaunch and theme export without retaining access to the source archive;
- Increase Contrast, Reduce Transparency, accessibility names, keyboard focus, localization, and
  Dynamic Type-equivalent app scaling remain Threading-owned;
- imported theme lists and previews apply the scaling gate and do not eagerly decode every package
  or image;
- the compatibility corpus renders consistently at 1x and 2x without fractional seams;
- no imported package can initiate code execution, process launch, file reads outside its staging
  directory, or network access.

## Durable documentation when implementation begins

- Record the normalized import boundary and package lifecycle in `docs/architecture/themes.md`.
- Record any new title-band asset or nine-slice behavior in
  `docs/architecture/window-chrome.md`.
- Record design-system primitives only after they exist in
  `docs/architecture/design-system.md`.
- Keep format-specific compatibility notes beside importer tests rather than turning this draft
  into a second live specification.
- Remove this draft or replace it with a short pointer once durable implementation documentation
  owns the decisions.
