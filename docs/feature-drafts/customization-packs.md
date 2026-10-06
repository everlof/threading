# Customization packs and personal effects controls

> Status: **superseded**, 2026-10-05. Appearance packs were retired and the portable
> `.threadingpack` collection was rejected in this form; see the
> [appearance packs decision record](../decisions/appearance-packs.md) for why and for the evidence
> that would reopen it. A pointer remains so links resolve.

This draft (2026-10-03) proposed one sharing flow for a theme, a chrome, an extension or a named
collection such as *Matrix Pack*, carried in a ZIP-based `.threadingpack` with a manifest,
dependency edges and a recommended appearance, plus a personal effects policy that no pack could
override.

- **Personal effects** shipped separately: *React to agent activity* and *Reaction strength* in
  Settings ▸ Motion ▸ Reactions, through `ThemeReactions`, with music reactions still the audio
  opt-in and decorative motion still `playsThemeMotion`. The durable record is in
  [`themes.md`](../architecture/themes.md) (2026-10-04).
- **Local packs** shipped on 2026-10-04 and were removed on 2026-10-05. What remains — the theme
  choice and extension enablement as host commands — is in
  [`appearance-activation.md`](../architecture/appearance-activation.md).
- **The look that outlives its theme** (Matrix Rain still falling after leaving The Matrix) is
  answered by an extension's decorations following its own themes, not by grouping extensions.

The full proposal, including the archive layout, admission limits and review flow, is in the
history at `fb61307ca:docs/feature-drafts/customization-packs.md`.
