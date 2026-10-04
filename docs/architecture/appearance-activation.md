# Appearance activation

App themes and saved appearance packs are host commands. A pack is a locally saved combination
of one existing app theme and up to sixteen explicitly selected installed extensions. The editor
records a stable UUID, a recipe revision, resolved theme/extension IDs and each executable
package's inspected content digest. It never infers membership from names. Renaming preserves
the identity and shortcuts; changing the recipe releases an active pack until it is activated
again. There is one active appearance pack at a time.

The portable `.threadingpack` archive and importer remain a separate
[sharing proposal](../feature-drafts/customization-packs.md). Local recipes are resolved activation
receipts, not a new distributable package format. A future importer must populate these same
identities and reviewed members rather than inventing another runtime enablement store.

## Choice ownership

`AppearanceActivationState` is the durable owner of the standalone app theme, manually enabled
extensions, saved recipes and active pack. Effective extension intent is the union of manual
enablement and the active recipe. Switching A → B changes only that union; a shared member keeps
its supervised generation. Off restores the standalone theme and removes only pack ownership.

Choosing any app theme explicitly releases the active pack, including choosing its current
theme. Content-only refreshes use `AppThemeLibrary.installResolved` and retain ownership.
Disabling a required member also deactivates the pack and removes that member's manual reason.
**Keep Enabled Without Pack** adds the manual reason without changing the active recipe.
Theme animations, sounds, audio capture, font overrides and terminal assignments are never
snapshotted or changed by pack activation.

`AppearanceActivationService` admits an operation against an inventory value, reserves the
extension mutation boundary, saves asynchronously through `AppearanceActivationStore`, then
publishes state and reconciles runtime/theme adapters. A failed save leaves the old state and
running generation intact. Overlapping writes and installation/update/removal during a commit
are refused. MCP and remote theme selection await the same commit before reporting success.
UI commands admit synchronously and report any later save failure through the host alert.

Runtime startup is separate from saved intent. A failed member leaves the pack selected with
**Needs attention**, **Retry** and **Deactivate** commands. Before starting a pack-owned runtime,
the manager checks its reviewed digests and prerequisites again. Updating a member cannot use
an old receipt to start the new executable; edit/review the pack before reactivating it. Manual
enablement remains governed by the existing installed-extension update review.

## Storage and recovery

The bounded `Customization/appearance.json` record uses the recoverable file envelope and an
actor for file and codec work. On the first normal launch it migrates the existing app-theme ID
and manual extension flags. An initialization marker survives quarantine so subsequent launches
cannot silently reimport stale legacy flags after corruption. The unreadable record remains
preserved and activation is unavailable until the state is recovered.

Recovery launches read without migration, quarantine, or writes; extensions remain held back and
the existing recovery appearance override stays in force. Explicit subsequent user choices can
still be saved. A confirmed successful inventory scan removes missing manual IDs, clears a pack
whose required content disappeared and repairs a missing standalone theme. Saved recipes remain
available for editing. An inventory read failure and temporary update state are not removal.

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

The receipt limit is 256 packs and sixteen members each, inside a 1 MiB file budget. The editor
uses reusable table rows over inspected values. Palette rows already have a bounded viewport and
asynchronous search. Inventory snapshots are cached until inventory/library events; availability
checks validate one action instead of reducing and validating every saved recipe per row.

The Debug catalogue fixture measures both command construction and availability over 100 themes /
100 packs and 5,096 themes / 256 packs. On 2026-10-04 the larger case fell from 427 ms to 63 ms
after removing repeated whole-state validation, repeated active-pack scans and locale-based ID
formatting. The matched smaller runs were 12 ms and 28 ms. Search took 110 ms for the larger
case on its existing worker; these are fixture timings, not Release opening-latency claims.
The catalogue regression ceiling is 250 ms at the admitted inventory limit.

## Commands and surfaces

`AppearanceCommands` contributes stable, bindable theme, activate, deactivate, toggle, retry,
edit, remove and extension enable/disable identities to `CommandRegistry`. Explicit actions keep
their identity when state changes. Menus carry the user-bound shortcuts even for inactive packs.
The real `HostCommandPlane` re-resolves commands before invocation. An extension does not have to
be running to expose its pack's off switch.

Terminal-theme commands name a theme and request typed `terminalThemeScope` input. Each option
names the default, a project, a session or a standalone terminal by canonical identity. The host
validates that selection again and calls the existing `ThemeAssignments` operation. A shortcut
opens the same scope picker rather than taking an ambient session as its target.

The pack editor and activation controls are deliberately host-only. Shared themed controls own
presentation; the host owns receipt review, capability disclosure, identity, persistence,
runtime authority, focus and error reporting. Extensions cannot replace those decisions.

Coverage belongs in `AppearanceActivationTests`, `ExtensionAppearanceTests`,
`ExtensionPackageStoreTests`, and `CommandPaletteRenderTests`. The latter captures themes,
active/degraded packs and the actual attached editor in the native product shell.

## Verification on 2026-10-04

Focused unit/integration runs completed with no failures: 285 tests (three environment/opt-in
skips), 129 tests, and a final 14-test activation/focus rerun. These cover persisted ownership,
failure and recovery, real host menu dispatch, supervised runtime generation, theme tools and
remote theme selection. The final palette render also exercises invalid-name refusal, member
toggle clicks and a saved rename through the actual editor controls.

The palette/editor's 36 captures passed and were inspected under System light/dark, Cyberpunk
and Swiss. Themes Settings was inspected at constrained and regular widths, and the Extensions
page was rendered under the same representative appearances. No baseline approvals were applied.
The sheet's table width is explicitly tied to its clip view: autoresizing alone retained a
larger initial fitting width and put the member toggles outside the visible sheet.

`AppearancePackJourneyUITests` adds the full create → activate → relaunch → deactivate journey.
It compiled, but two attempts failed in `UIScenarioSandbox.launch` because XCUITest could not
activate the app (reported `Running Background`), before any feature interaction. App launch
logs reached normal startup completion; the complete application-level journey remains
unverified. The full repository test suite was not run for this change.
