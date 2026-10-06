# Appearance activation

The app-theme choice and extension enablement are host commands over one durable record. Choosing
a theme and switching an extension on or off are independent: neither changes the other, and the
same operations serve Settings, the command palette, shortcuts, MCP and the paired iPhone.

## Packs were retired

From 2026-10-04 to 2026-10-05 a third concept sat between the two: an *appearance pack*, a saved
combination of one app theme and up to sixteen extensions with its own identity, content digests,
editor and activate/deactivate commands. It was removed. An extension that ships a theme is
already the bundle, and the decorations it draws follow its own themes, so choosing the theme is
the whole switch; a separate membership record only gave every extension switch three meanings
(manual, by pack, both). The reasoning, what was removed and what would reopen it are in the
[appearance packs decision record](../decisions/appearance-packs.md).

## Choice ownership

`AppearanceActivationState` is the durable owner of the app-theme choice (`themeID`) and the set
of enabled extensions (`enabledExtensionIDs`). That set is the runtime's desired set: nothing else
adds a reason to run an extension. Content-only refreshes use `AppThemeLibrary.installResolved`
and keep the choice. Theme animations, sounds, audio capture, font overrides and terminal
assignments are never changed by an app-theme choice.

`AppearanceActivationService` admits an operation against an inventory value, reserves the
extension mutation boundary, saves asynchronously through `AppearanceActivationStore`, then
publishes state and reconciles runtime/theme adapters. A failed save leaves the old state and
running generation intact. Overlapping writes and installation/update/removal during a commit
are refused. MCP and remote theme selection await the same commit before reporting success.
UI commands admit synchronously and report any later save failure through the host alert.

Admission is per action. A theme must be in the current inventory. Enabling an extension needs an
installed, valid package that is not mid-update, and is refused while extensions are held back
for the launch; disabling one is always admitted. Runtime startup is separate from saved intent:
an extension that fails to start stays enabled and reports its failure through the Extensions
page and the existing supervisor, and the installed-extension update review still governs a new
version.

## Storage and recovery

The bounded `Customization/appearance.json` record uses the recoverable file envelope and an
actor for file and codec work. On the first normal launch it migrates the existing app-theme ID
and manual extension flags. An initialization marker survives quarantine so subsequent launches
cannot silently reimport stale legacy flags after corruption. The unreadable record remains
preserved and activation is unavailable until the state is recovered.

The file keeps the key names it had while packs existed — `standaloneThemeID` and
`manuallyEnabledExtensionIDs` — through `CodingKeys`. A record written by a build with packs
loads unchanged: `packs` and `activePackID` are ignored, so an active pack's theme and members are
not adopted. Every save still writes an empty `packs` list, because a build from before the
retirement decodes that key unconditionally and would otherwise quarantine the whole record on a
downgrade. `AppearanceActivationTests` reads a fixture shaped exactly like that older record.

Recovery launches read without migration, quarantine, or writes; extensions remain held back and
the existing recovery appearance override stays in force. Explicit subsequent user choices can
still be saved. A confirmed successful inventory scan removes missing extension IDs and repairs a
missing theme with the product default. An inventory read failure and temporary update state are
not removal.

## Installed appearance and bounded work

`ExtensionAppearanceRegistry` exposes every valid installed theme independently of runtime
enablement. Disabling an extension no longer removes its themes or artwork. Removal and invalid
packages withdraw contributions; the existing live-edit watcher and last-good theme behavior
still apply. Inspected byte data is shared with inventory values; opening the catalogue does not
decode artwork. Decoded artwork is retained for at most two recently used themes.

Font family metadata is searchable without registering every file. Registrations follow enabled
runtime consumers, the selected theme and explicit font choices. This includes contributed fonts
named by a custom theme. Theme resource preparation precedes the first themed window and every
resolved switch. The existing custom-theme font store retains its own lifecycle.

The command catalogue is one row per app theme and terminal theme plus two per installed
extension (at most 256). Palette rows already have a bounded viewport and asynchronous search.
Inventory snapshots are cached until inventory/library events, and availability validates the one
action a row names rather than reducing the whole record per row: on 2026-10-04 removing that
repeated whole-state validation took the 5,096-theme Debug fixture from 427 ms to 63 ms. The
fixture still measures command construction and availability over 100 and 5,096 themes, with a
250 ms regression ceiling; these are fixture timings, not Release opening-latency claims.

## Commands and surfaces

`AppearanceCommands` contributes stable, bindable identities to `CommandRegistry`: **Use … Theme**
per app theme, **Use … Terminal Theme…** per terminal theme, and **Enable/Disable … Extension**
per installed extension. Identities are hex-encoded canonical IDs, never names or indices, so a
renamed theme keeps its shortcut. The real `HostCommandPlane` re-resolves commands before
invocation, so a theme that went away is refused rather than selected. None of these rows is
shown in the menu bar — the palette is where they are found — but a command the user has bound a
shortcut to gets a hidden View-menu carrier, the way ⌘1–⌘9 do, because AppKit dispatches key
equivalents through menu items.

Terminal-theme commands name a theme and request typed `terminalThemeScope` input. Each option
names the default, a project, a session or a standalone terminal by canonical identity. The host
validates that selection again and calls the existing `ThemeAssignments` operation. A shortcut
opens the same scope picker rather than taking an ambient session as its target.

The app-theme pickers in Settings ▸ Themes and Current Theme list only themes, grouped by the
library's sections. Shared themed controls own presentation; the host owns identity,
persistence, runtime authority, focus and error reporting. Extensions cannot replace those
decisions.

Coverage belongs in `AppearanceActivationTests`, `ExtensionAppearanceTests`,
`ExtensionPackageStoreTests`, and `CommandPaletteRenderTests`. The latter captures the theme and
extension rows in the native product shell.

## Verification on 2026-10-05 (pack retirement)

Focused runs after removing packs: `AppearanceActivationTests` 13/13 (reducer, admission,
failed commit, ordered projection, migration and corruption, the pack-era fixture, recovery, the
real host menu route with a stale refusal, the theme-only picker, a pack-free catalogue, the
hidden View-menu carriers, terminal scopes and the catalogue stress case),
`ExtensionAppearanceTests` 20, `ExtensionPackageStoreTests` 78 (three skips), `ThemeSystemWorkflowTests` 17,
`ThemePickerSectionTests` 4, `RecoveryModeCommandPolicyTests` 5, `AppDelegateTests` 16 and the
two Component Gallery coverage tests, with no failures. The localization, architecture, theme
and main-actor latency lints are clean. `CommandPaletteRenderTests` renders its five states under
four appearances and passes, but crashed intermittently in fresh processes (4 of 10) inside
`ShortcutRecorderView.drawLabel`, where CoreText's attribute copy meets a nil value; the colour
workaround at that call site predates this change. The full suite was not run.
