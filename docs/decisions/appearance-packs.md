# Appearance packs

> Status: **decision record** (2026-10-05). **Retired** — the local appearance packs that shipped on
> 2026-10-04 were removed the next day, and the portable `.threadingpack` collection they were the
> first slice of is **rejected** in that form. An extension that ships a theme is the bundle, and
> the decorations it draws follow that theme. Reopen only on the evidence in §7.

Part of the [decisions index](README.md). Read alongside
[`appearance-activation.md`](../architecture/appearance-activation.md), which describes what
remains, [`themes.md`](../architecture/themes.md) and the
[customization surface audit](../extensions/CUSTOMIZATION_SURFACE_AUDIT.md). It supersedes the
two drafts that proposed packs, `docs/feature-drafts/customization-packs.md` and
`docs/feature-drafts/appearance-pack-activation.md`; both are now pointers, and their full text is
in the history at `fb61307ca`.

**The one-sentence version.** A pack was a third concept — one app theme plus up to sixteen
extensions, with its own identity, digests, editor and commands — built to answer "switching away
from Matrix should take Matrix Rain with it"; once an extension's decorations follow its own
themes, choosing the theme answers that question, and the third concept has nothing left to own.

---

## 1. User problem and concrete cases

1. **The look that outlives its theme.** The owner's Matrix setup is a custom adaptive theme,
   *The Matrix*, plus a separate WebAssembly extension, *Matrix Rain*, whose sidebar and
   main-window shader hooks are not limited to that theme. Choose another theme and the rain
   keeps falling.
2. **Two halves by two authors.** `StormThemeExtension` declares a theme; `RainWindowExtension`
   supplies Usage Rain. Someone wants them switched together without merging the code.
3. **Handing a look to someone else** as one file rather than a list of things to find.
4. **Switching looks from the keyboard** without opening Settings.

Case 1 is the one that motivated the work, and it is a *decoration scope* problem, not a grouping
problem: the drafts said so themselves ("pack activation also needs an explicit scope for
decorative extensions … so leaving Matrix can remove its decoration while an unrelated functional
extension stays enabled").

## 2. What shipped on 2026-10-04, and what it cost

- **The record.** `AppearancePack`: a UUID, a recipe revision, a name, one theme ID and at most
  sixteen members, each pinned by the executable package's content digest; at most 256 packs and
  one active. Effective enablement was *manual ∪ active pack*, and the standalone theme stayed
  stored underneath an active pack's theme.
- **The surfaces.** An editor sheet with a member table (`AppearancePackEditor`,
  `AppearancePackMemberCell`); **Create Pack…** in Settings ▸ Themes; an *Appearance packs* group
  and a *Packs for “…”* offer in both app-theme pickers; palette commands to activate,
  deactivate, toggle, retry, edit and remove each pack; **Keep … Enabled Without Pack** and
  **Also deactivates … Pack** on every member's switch; *Needs attention* with **Retry**; a
  View ▸ Appearance submenu; a Recovery Mode exception for deactivation.
- **The runtime rules.** A pack-owned start re-checked digests and declared service prerequisites
  (`appearanceRuntimeAdmission`); updating a member required editing the pack before it could run
  again; disabling a member deactivated the pack; choosing any theme, even the pack's own,
  released it.
- **The cost.** Retiring it removed about 630 lines of production code net, 42 localized
  strings, a gallery story, an eight-row state-transition table that every extension switch had
  to honour, and an XCUITest journey that never got past launch in the two attempts recorded.
- **The use.** On 2026-10-05 the owner had saved no packs (`appearance.json`: `"packs": []`).

## 3. Why it was retired

**One switch had three meanings.** An extension could be on manually, on because of the active
pack, or both. Every surface that showed a switch had to say which, and two commands
(**Keep … Enabled Without Pack**, **Also deactivates … Pack**) existed only to make the
difference reachable. The membership lived in neither the theme nor the extension, so neither
could explain it.

**It could not solve its own motivating case at the right granularity.** A pack enabled and
disabled *whole* extensions. An extension that mixes a tool with a decoration would lose the tool
when the pack was switched off, and the drafts deferred per-component enablement to "a separate
host contract". That contract is the real fix: an extension declares decorations scoped to its
own themes, so the decoration appears exactly while one of those themes is chosen and the
extension's other contributions are unaffected. With it, the theme choice is the switch for
cases 1 and 2, and there is no second activation state to persist, review, recover or explain.

**The bundle already exists.** An extension package carries themes, fonts, artwork and shader
sources, travels as one inspected file, and installs through the existing capability review and
update plan. A look that pairs a theme with decoration ships as one extension. A
`.threadingpack` container around several extensions would have needed its own archive admission,
dependency ownership, conflict resolution and review — a second package system for the cases an
extension does not already cover.

**Case 4 survives without packs.** Every theme has a stable, bindable **Use … Theme** command, and
every extension has **Enable/Disable … Extension**.

## 4. What remains, and what the record keeps

The standalone theme choice and manual enablement became the whole model:
`AppearanceActivationState` holds `themeID` and `enabledExtensionIDs`, with the same service,
asynchronous commit, store, migration, recovery and inventory reconciliation; see
[`appearance-activation.md`](../architecture/appearance-activation.md). No user data needed
migration. The file keeps its on-disk key names, ignores `packs` and `activePackID` when it reads a
record written by a build with packs, and still writes `"packs": []` so a downgraded build reads
the file instead of quarantining it.

Removed with packs: the pack record and actions, digest/prerequisite validation that only packs
used, `ExtensionManager.appearanceRuntimeAdmission`, the editor and its gallery story, the picker
groups, the Settings row, the palette commands, the View ▸ Appearance submenu (bound theme and
extension shortcuts now ride hidden View-menu carriers), the Recovery Mode exception, the UI
journey and the strings. The ordinary installed-extension digest and update review is untouched;
it never depended on packs.

## 5. Security, privacy and scaling

- **Fewer ways to start code.** Activating a pack enabled up to sixteen executables in one action,
  gated by digests the pack had recorded. Now an executable starts only through its own switch,
  under the existing install/update review, and choosing a theme does not itself enable an
  extension.
- **No new stored authority.** A pack's digests were a second, pack-local trust record beside the
  package store's. Removing it leaves one.
- **Scaling.** The palette catalogue lost up to 256 × 6 pack rows and per-row recipe validation;
  the 5,096-theme stress fixture remains as the ceiling.

## 6. Non-goals

- Grouping several independent extensions under one theme, or one name, as a switchable unit.
- Per-look shortcuts other than the theme's own **Use … Theme** command.
- A portable multi-item archive. Sharing a custom theme on its own remains an open question that
  does not need packs to answer.

## 7. What should reopen this

- **Repeated demand to combine independent work.** People asking — more than once, unprompted —
  to switch an unrelated theme together with several extensions by *different* authors, where
  merging them into one extension is not an option.
- **Decoration scope proving insufficient.** A decoration that must follow a theme its extension
  does not ship, and cannot reasonably ship.
- **A sharing need an extension cannot express**, such as a custom theme plus extensions handed
  over as one file where the recipient should not have to trust a wrapper executable.

If any of these arrives, start from the 2026-10-04 implementation at `fb61307ca` — its activation
reducer, the digest-pinned membership and the catalogue measurement are reusable — and from the
two drafts in that commit, but design membership so that one extension switch keeps one meaning.
