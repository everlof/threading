# Customization packs and personal effects controls

> Status: design draft, 2026-10-03. Sharing and pack installation are not implemented.
> Portable files are the proposed first delivery format; public hosting is a separate decision.

Threading should let someone share one theme, one chrome, one extension, or a named collection
such as **Matrix Pack**. The recipient should be able to inspect, install and use the collection
without finding its pieces separately. Their choices about animation, activity reactions,
music and sound must survive installing or switching packs.

The companion [Theme commands and pack activation](appearance-pack-activation.md) specifies
direct palette actions, the recommended appearance recipe, activation ownership and failure
behavior. It uses this draft's pack identity and installed receipts rather than a second format.

## What exists today

The local Matrix setup demonstrates the gap:

- **The Matrix** is a custom adaptive `AppTheme`, with light and dark variants. Its palette,
  material, chrome and character belong to that document. The document is stored in
  `AppThemeStore`; custom artwork and bundled fonts live in the theme's asset folder.
- **Matrix Rain** is the separate WebAssembly extension `local.david.matrix-rain`. Its installed
  manifest declares `ui.components` and `ui.rendering.metal`, with an empty `themes` array.
  Its retained source publishes sidebar and main-window shader hooks using time, workload and
  audio signals. The code does not limit those hooks to the Matrix theme.
- Extension packages can already contribute themes, fonts and resources. They do not provide a
  container for several existing extensions and independent user themes.
- Themes settings offers a terminal-palette export and classic-skin import. Extensions settings
  imports a package after inspection. Neither offers a common Share/Create Pack journey.
- `playsThemeMotion` and `playsThemeSounds` are already global preferences, exposed on Themes.
  `sharesThemeAudio` is already an independent, off-by-default global choice on Motion.
  No corresponding activity-reaction preference exists.
- `ExtensionMetalSurfaceView` currently consults `ThemeParticleHold` only for surfaces declaring
  audio inputs. A time/workload-only shader therefore does not receive the same master motion
  hold. `AgentWorkloadAnalyzerView` has its own timer gate. These owners must converge before a
  new effects switch can promise consistent behavior.

Relevant owners: [themes](../architecture/themes.md),
[audio spectrum](../architecture/audio-spectrum.md),
[extension authoring flow](../extensions/AUTHORING_FLOW.md),
[customization boundary](../extensions/CUSTOMIZATION_SURFACE_AUDIT.md), and
[skin import proposal](skin-and-chrome-imports.md).

## One sharing flow

**Share…** beside a theme, chrome or extension opens the same composer, with that item selected.
**Create Pack…** opens it without an item selected. A single item is a valid pack, so there is
one format, importer and review flow.

The composer has a name, optional description/author, a contents list, and a preview of the
appearance. It includes the selected items' required local assets and extension dependencies.
It identifies dependencies before saving, including resources supplied by another extension.
Related items may be suggested, but a matching name is never proof of ownership or dependency.

For Matrix, the person selects **The Matrix** and **Matrix Rain**, names the collection
**Matrix Pack**, and saves one `Matrix Pack.threadingpack` file. Embedded light/dark palettes,
window chrome, images, fonts and shader/source resources travel with their owning item.

The composer distinguishes required content from optional extras. Unchecking a required
dependency either deselects the dependent item or explains why it is required; it never exports
a knowingly broken selection. It reports missing resources and font substitutions before Save.

Share first creates a local portable file. That same file can later be passed to the platform
share picker or an explicitly requested hosting service. Export must work offline and must not
require an account or publish anything automatically.

Commands, Settings buttons and future agent tools invoke the same host operations. Stable
command identities cover creating, importing and sharing packs; contextual commands supply
the selected item as a typed reference.

## The pack is a container

Proposed layout, carried in a ZIP with the `.threadingpack` extension:

```text
manifest.json
themes/<item-id>/theme.json
themes/<item-id>/assets/...
terminal-themes/<item-id>.json
extensions/<extension-id>.threadingextension/...
previews/cover.png
licenses/...
```

The manifest records a format version, stable pack ID, pack version, name, description,
optional author/provenance, minimum host compatibility, item IDs and versions, required and
optional dependency edges, content digests, and an optional recommended appearance.
Metadata is a claim from the author, not verified publisher identity. Integrity digests are
not signatures. Preserve the existing extension runtime and companion trust disclosures.

App-theme documents continue to encode the current semantic `AppTheme`. The four appearance
layers remain palette, material, chrome and character; no second renderer is introduced.
Terminal themes retain their own model. Extensions remain ordinary inspected packages with
their rebuildable source and vendored SDK contract.

A chrome is currently a layer of an app theme, not an independent installed object. The first
share flow must say **Includes palette, material, chrome and character** when that is what it
exports. A future **Chrome only** option needs a typed layer preset and an explicit apply/merge
operation. It must not pretend that copying a title-bar block reproduces the entire appearance,
or require an executable extension merely to distribute inert styling.

Only package content and explicitly selected appearance recipes are exported. Exclude projects,
chat history, accounts, secrets, install trust, extension private storage/cache, runtime state,
local filesystem paths, source-device IDs, capture consent and personal effect preferences.
Do not copy system/user font directories to satisfy a missing family. Include only font files
already carried by the selected theme or extension and retain available license material.

## Review, install and use

Opening the file or choosing **Import Pack…** uses the same host-owned review:

1. Stage and inspect the complete file without running package code or registering fonts.
2. Show the pack's name, items, required relationships, compatibility, existing-item conflicts,
   and each extension's runtime, capabilities, network grants, tools and companions.
3. Let the person select optional extras. Resolve that selection into one installation plan.
4. Commit the reviewed content only. A changed digest invalidates the review. Failure restores
   the prior installation and never reports a partial pack as installed.
5. Report **Installed** and offer **Use Pack**. Installing preserves the current appearance,
   global effects choices and extension enablement policy. New executable extensions start
   disabled under the existing contract.

**Use Pack** is an explicit host action: it selects the recommended theme and reviews enabling
the pack's optional executable components. The review can combine those choices into one clear
step, but must not turn a theme switch into implicit code execution or audio consent.

Already installed identical content is reused. An extension with the same ID and different
content uses the existing update plan and capability-delta review; it is never overwritten as
a fresh import. Themes imported as copies get fresh identities, with internal references
remapped consistently. A named installed pack retains a receipt of exact item IDs/digests so it
can be inspected, re-shared and updated without reconstructing membership by display name.

Dependencies shared by packs have independent ownership. Removing one pack must not remove
an extension used by another pack or one the person installed independently. Modified local
themes are user-owned forks; updating the original pack must not silently replace their edits.

Pack activation also needs an explicit scope for decorative extensions. Matrix Rain currently
publishes global hooks as soon as enabled. The host should support a declared relation between
an appearance item and its decorative contribution, so leaving Matrix can remove its decoration
while an unrelated functional extension stays enabled. Do not implement this with Matrix names
or IDs baked into the renderer, or by disabling every extension from the outgoing pack.

For the initial activation model, one appearance recipe is selected at a time. Runtime demand is
the union of manual enablement and that recipe's explicit members; deactivation releases only
the recipe's requests. Whole extensions remain the enablement unit, so a mixed functional and
decorative extension cannot promise independent decoration until a component-level contract exists.
The companion activation draft defines this boundary and the manual-override cases in detail.

## Personal effects policy

Put the controls together in **Settings → Motion**, with a link from Themes and pack review.
Reuse the existing persisted choices when relocating them; do not reset people's settings.

| Control | Meaning when off | Owner |
| --- | --- | --- |
| Decorative motion | Hold decorative backgrounds, particles, logo motion, transitions and extension shaders at a stable frame; stop their recurring work | Existing global motion choice, consistently enforced |
| Activity reactions | Decoration does not change speed, intensity, poses or bursts in response to agent work; ambient animation may continue | New global user choice |
| Music reactions | No audio-driven decoration and no capture demand from it; ambient/activity behavior follows its own settings | Existing audio opt-in |
| Theme sounds | No theme-authored event sounds | Existing global sound choice |

Reduce Motion overrides decorative movement. Visibility, Low Power Mode and frame budgets
remain host-owned runtime gates. The master motion switch overrides both reactive motion
switches without erasing their saved values, so turning it back on restores the person's choices.
Labels and help text must make that dependency clear. There should also be an obvious way to
turn all decorative effects off without changing the chosen appearance.

The theme or extension supplies *how* it reacts. The host supplies *whether* it may react.
No pack includes values for these personal preferences, and selecting a music-aware theme
never enables capture or changes the selected audio source.

Turning activity reactions off does not hide actual working counts, status, permission requests,
progress, failures or notification behavior. Keep the raw host workload and session models true.
Apply the policy at the decorative signal/presentation boundary, not in `AgentWorkloadMonitor`
or the ordinary extension host-data API. The workload analyzer can keep a truthful static count
without its moving spectrum. A mascot holds an appropriate static pose without activity-driven
motion; required status remains in the host's ordinary status presentation.

For decorative Metal inputs, unavailable activity signals use the binding's documented idle
fallback. Stopping motion also freezes the host clock; neutralizing workload alone does not
stop a shader that animates on time. Music-off publishes unavailable audio, clears old readings
and releases demand. Every renderer receives setting changes immediately, including already
mounted extension surfaces and previews. A static state must not retain a display-link/timer
just to redraw the same frame.

## Host boundary and scaling gate

The pack composer, content review, conflict resolution, install/activation actions and effects
controls are deliberately **host-only**. Themes style their shared Design components.
Threading owns item identity, selection, validation, file destinations, install authority,
provenance, rollback, dependency lifetime, personal choices and capture consent. Extensions
cannot replace these controls, relabel authority or approve themselves.

Expected packs contain 1–10 top-level items. Proposed v1 ceilings are 32 items, 20,000 archive
entries, 256 MiB compressed input and 512 MiB total expansion, with existing stricter per-theme,
image, font, shader, manifest, companion and extension limits still enforced. These are admission
limits, not permission to allocate the entire expansion in memory. Tune only with measurements.

The installed extension inventory is already capped at 256 packages; the custom-theme list is
externally sized. Composer/review lists keep value models and build O(visible rows) views. Only
the selected preview is decoded/rendered. Selecting one item updates changed identities and
their dependency closure, without rebuilding every preview or row.

Archive I/O, compression, hashing, enumeration, decoding, validation and staged copying run on
one cancellable bounded worker per operation. Bound entries examined and bytes actually read,
including retained source and nesting. Reject traversal, ambiguous/colliding names, symlinks,
special files, encryption and unsupported archive features before extraction. Check all entries,
not only the manifest's named files. Prefer the existing archive/storage primitives, but verify
they meet extraction requirements: a read-only reader used to fetch one image is not an installer.

The main actor mounts a reviewed immutable result and performs the small presentation mutation.
No file work occurs in row construction, layout, hover or frame callbacks. The effects policy
is an O(1) cached decision at render time, with O(live consumers) invalidation on a settings change.

## Implementation order and acceptance

1. **Shared effects policy.** Consolidate existing controls and add the activity choice. Route
   native animation, analyzers, mascots, moments and all decorative Metal surfaces through it.
   Test immediate changes, clock freezing, input fallback and frame/capture shutdown independently.
2. **Portable content and planning.** Specify the versioned manifest; snapshot selected themes,
   palettes, assets and packages; inspect archives and derive dependency/conflict plans. Add a
   Matrix-shaped fixture with an adaptive theme, chrome, fonts/artwork and a Wasm extension.
3. **Transactional install and membership.** Reuse package inspection/update review, preserve
   exact reviewed content, persist pack receipts and exercise rollback, duplicate imports,
   shared dependencies, edited copies, unavailable dependencies and interrupted installation.
4. **Share/Create/Import UI.** Add contextual Share, the common virtualized composer, file-open
   registration and content review through the command registry. Capture and inspect rendered
   evidence from the real Settings/pack shell, including System and contrasting chrome themes.
5. **Use Pack and scoped decoration.** Make the recommended look and required decorative
   contributions easy to activate together while respecting executable approval and every
   personal effects choice. Switching away from Matrix must remove Matrix-only decoration.

Completion requires a fresh isolated-profile round trip through the shipping UI: create Matrix
Pack, export it, open it, inspect all contents, install, explicitly use it, restart and re-share it.
Verify light/dark appearance, artwork, fonts, terminal colors and live extension decoration.
Repeat with activity, music, motion and sounds independently off before import; none may change.
Corrupt, oversized, traversing, duplicate and changed-after-review packages must leave the old
installation intact. Run a stress composer with thousands of theme choices and a maximum-size
accepted archive; measure worker time, main-thread mount/selection tails, live views, memory,
cancellation and progress responsiveness.

Public download links, discovery/gallery services and publisher accounts follow only after the
portable file contract works. Native in-process plugins retain their separate signing/trust
boundary and are not admitted through this safe-extension sharing flow.
