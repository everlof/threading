# Theme commands and pack activation

> Status: local activation implemented, 2026-10-04. See the current
> [appearance activation architecture](../architecture/appearance-activation.md).
> This document retains the original proposal below; archive import/export remains proposed.
> Companion to [Customization packs](customization-packs.md), which owns the portable file,
> import, sharing and personal effects policy. This draft owns command discovery and activation.

The command palette should apply a theme by name and activate or deactivate a theme with its
companion extensions as one pack. Keep **installed content**, **user choices**, and **running
extensions** separate. A pack selects existing contributions through a host operation; its off
switch must remain available when an extension is stopped or broken.

Start with one active appearance recipe for the application. Independent extensions remain
independent. Switching packs changes the selected look and only the extension requests owned by
that selection. It never restores a snapshot of all settings over later user choices.

## Existing implementation and the gap

| Owner | Current behavior |
| --- | --- |
| [`AppThemeLibrary`](../../Sources/Threading/Core/Theme/AppThemeLibrary.swift) | Combines stock, contributed and custom themes under stable IDs. `apply` both records a selection and repaints. |
| [`ExtensionAppearanceRegistry`](../../Sources/Threading/Core/Extensions/ExtensionAppearanceRegistry.swift) | Holds inspected themes, fonts and artwork without requiring running code. Membership still depends on extension enablement. |
| [`ExtensionManager`](../../Sources/Threading/Core/Extensions/ExtensionManager.swift) | `setEnabled` writes a Boolean, starts or stops the runtime, and rebuilds appearance contributions. Disabling a runtime can remove the selected theme. |
| [`ExtensionPackageStore`](../../Sources/Threading/Core/Extensions/ExtensionPackageStore.swift) | Retains installed packages and recoverable enablement state, without recording whether a user or pack requested enablement. |
| [`CommandRegistry`](../../Sources/Threading/Core/Settings/CommandRegistry.swift) and [`HostCommandPlane`](../../Sources/Threading/Core/Control/HostCommandContract.swift) | Supply stable commands and fresh invocation admission. Runtime-contributed commands disappear when their extension stops. |
| [`AppDelegate.hostCommandCatalog`](../../Sources/Threading/App/AppDelegate.swift) | Includes commands and Settings destinations. Finding Themes reaches settings; it does not expose an apply action for each theme. |

The repository's
[`StormThemeExtension`](../../Packages/ThreadingExtensionKit/Examples/StormThemeExtension)
declares a theme and icon; its executable publishes an empty registration.
[`RainWindowExtension`](../../Packages/ThreadingExtensionKit/Examples/RainWindowExtension)
supplies Usage Rain separately. A pack could pair them without merging their implementations.
The sharing draft's Matrix theme plus Matrix Rain is the same activation problem with a custom
theme rather than an extension-contributed theme.

The [theme architecture](../architecture/themes.md) records the original enabled-package rule.
Current code falls back to `AppThemeLibrary.defaultTheme` when a selected contribution disappears;
the older subsection's reference to System predates the product default. This proposal changes
runtime-disable behavior, while retaining fallback for actually removed or invalid assets.

## Commands people can use

Typing a theme or pack name offers an action, with provenance and current state in its detail.
Using Matrix as the example:

| Action | Effect |
| --- | --- |
| Use The Matrix Theme | Apply the theme alone. Leave any active pack and release its extension requests. |
| Activate Matrix Pack | Apply its appearance recipe and request its explicitly selected extensions. |
| Deactivate Matrix Pack | Return to the standalone theme and release only this pack's requests. |
| Retry Matrix Pack | Retry failed members through existing extension lifecycle policy. |
| Enable Matrix Rain / Disable Matrix Rain | Change manual enablement, subject to the required-member rule below. |

Theme rows include stock, custom and validated installed contributions, even when an associated
runtime is stopped. Pack rows come from installed pack receipts and remain discoverable when
inactive. Neither catalogue requires executing extension code. A missing member leaves its pack
visible with a specific unavailable reason; activation does not install missing dependencies.

Activate and Deactivate have separate stable command identities. A bindable Toggle action can
reuse the same operations, but a visible Activate row must never become a Deactivate request if
state changes between search and invocation. Repeated Activate is idempotent. An active or degraded
pack always offers Deactivate; progress or a failed guest must not strand its off switch.

These actions change application appearance. Terminal themes retain their session, standalone
terminal, project and default scopes. Follow App Theme follows the pack through the existing
resolver. Explicit terminal assignments and font choices remain untouched. A separate
**Set Terminal Theme…** command should collect an explicit scope/target and theme; an unqualified
theme name must not unexpectedly change only the selected session.

## One pack identity and an explicit recipe

Use the sharing draft's pack format and installed receipt. Do not introduce a competing extension
bundle or infer a pack from names, installation proximity, or the first theme in a package.
An ordinary extension continues to declare its existing themes and capabilities. A standalone
custom theme does not need an executable wrapper to participate.

Make the pack manifest's recommended appearance a typed recipe. Illustrative proposed data:

```json
{
  "recommendedAppearance": {
    "themeItemID": "matrix-theme",
    "extensionItemIDs": ["matrix-rain"]
  }
}
```

These are pack-local item references. Installation resolves them through the receipt to the
actual `AppThemeID` and extension identifiers, including IDs remapped on import. For an extension
item supplying several themes, the theme reference also names its local contribution ID. Display
names are never identity. The pack ID remains stable across updates; the receipt records exact
resolved membership and the reviewed recipe revision.

An imported pack may contain optional content. Resolve the user's choices into a concrete
activation recipe before committing activation. An optional omitted decoration is not a failed
member. Once selected for the recipe, each runtime is required for that recipe to report Active.
A pack with no recommended appearance can still be shared, installed and inspected; v1 does not
invent a “Use Pack” action for a collection whose intended behavior is unspecified.

For the first version, the unit of enablement is the **whole extension**. Show all its capabilities
and contributions; do not claim to enable one shader while silently enabling its tools and services.
Authors needing independent effects use independently enabled extensions. Per-component activation
requires a separate host contract before an extension mixing unrelated functions and decoration
can promise that only its decoration follows the pack. Existing component conflicts retain the
host's existing resolution; pack membership grants no new replacement priority.

Proposed activation limit: sixteen distinct runtime members, within the sharing draft's 32-item
pack limit. No nested activation recipes or transitive auto-enablement. Declared service
dependencies must be satisfied by the explicit recipe or manual set; otherwise admission explains
the missing prerequisite. A recipe revision adding members participates in review even when those
members are already installed. Updating a pack must not expand its active runtime set silently.

## Installed assets have a separate lifetime

The appearance catalogue should describe all validated installed assets, independently of running
code. Runtime disable stops a package's executable contributions but no longer withdraws its
themes, artwork or fonts. Removal, quarantine or a confirmed invalid asset withdraws them. The
extension switch must communicate runtime enablement where that distinction matters.

Theme selection uses inspected data without starting its owner's runtime. Existing theme-only
extension packages remain compatible, including their current executable field; selecting their
theme need not start their empty executable. The pack importer remains the owner of distributing
inert custom themes without that wrapper.

Catalogue visibility does not mean eager activation of every resource. Resolve artwork and fonts
for the selected theme, explicit font choices, visible preview or live extension consumer. Keep
resource demand and catalogue metadata separate, and retain existing validation and live-edit
behavior. A stopped runtime is not an invalid theme; a failed inventory scan is not package removal.

## Activation state and ownership

One durable state holds the user's choices:

```text
CustomizationState
  revision
  standaloneAppThemeID
  manuallyEnabledExtensionIDs
  activePack: optional { packID, reviewedRecipeRevision, resolvedRecipe }

effectiveTheme = activePack.theme ?? standaloneAppTheme
desiredExtensions = manuallyEnabledExtensionIDs union activePack.extensionIDs
```

The equations apply to a valid admitted recipe. Observed runtime status and launch suppression
are separate: desired does not mean running. `resolvedRecipe` records the chosen optional members
and installed identities from the reviewed receipt so an update cannot change the meaning of
the saved selection. It is activation consent, not a second package inventory.

The standalone theme stays stored while a pack is active. Switching A to B preserves that choice;
deactivating B returns to it, not to A. There is no stack of old packs or whole-settings snapshot.

| Event | State transition |
| --- | --- |
| Activate A | Preserve manual choices and select A's admitted recipe. |
| Switch A to B | Replace A with B. Retain shared members without a stop/start cycle. |
| Deactivate A | Clear A. Stop only members absent from the manual set. |
| Manually enable a member of A | Add a manual reason so it survives deactivation. |
| Manually disable a required member of A | Clear A and remove that member's manual reason in one change. State “Also deactivates Matrix Pack” before invocation. |
| Use a standalone theme | Set the standalone choice and clear the pack in one change, even if selecting the same theme the pack uses. |
| Disable an unrelated extension | Change only its manual reason. |
| Remove the selected pack or a required item | Clear the pack and release its reasons. Preserve unrelated manual choices and shared installed content. |

Settings and palette details state **Enabled by Matrix Pack**, **Enabled manually**, or both.
An extension enabled manually before activation stays enabled afterwards. If the effective switch
is already on solely because of a pack, **Keep Enabled Without Pack** adds the manual reason;
otherwise that transition would be unreachable through a Boolean switch.

For a missing standalone theme, use the product-default fallback and persist the repair only
after confirmed removal or invalidity. Selection through Settings, shortcuts and MCP uses the
same operation, so an explicit theme pick cannot leave an old pack recorded. Editing the selected
theme's document is a content refresh and preserves the pack selection.

Install ownership remains in the pack receipt and package store, as specified by the sharing
draft. Releasing an activation reason never uninstalls content or deletes private extension data.

## Application service and command projection

Add `AppearanceActivationService` under `Application/Customization`, with Foundation-only typed
values and injected persistence, inventory, runtime and theme adapters. It owns admission and
state transitions. Keep its reducer testable without AppKit, processes or disk. The composition
root connects it to the existing renderer and extension supervisor.

```text
Settings / palette / shortcut / authorized host API
                         |
               AppearanceActivationService
                         |
              durable CustomizationState
                         |
          theme projection + runtime reconciliation
```

Separate recording a theme choice from installing a resolved theme. `AppThemeLibrary` retains
resolution and painting; background content refresh and Recovery Mode install without writing
user intent. `ExtensionManager` remains the process owner and reconciles a derived desired set;
it does not persist an independent competing enablement choice.

Project inspected appearance metadata and pack receipts into host commands with typed targets.
Do not use `.extensionCommand` origin: it invokes a guest and disappears when the guest stops.
Add a host appearance origin carrying provenance. Register actual actions with stable IDs,
an Appearance group and editable, initially unbound shortcuts. Encode canonical identities
unambiguously; names and array indices must never be shortcut keys. Settings destinations retain
their existing non-bindable navigation treatment.

Cache the command projection and refresh it on catalogue, recipe, selection and runtime-status
changes. An open palette updates state and unavailable reasons. Keep fresh admission through
`HostCommandPlane`, then recheck inventory and receipt revisions at commit. Settings and menus
call the same typed operations. Pack knowledge does not belong in palette row closures.

## Persistence and failure behavior

Do not implement activation as repeated `setEnabled` calls followed by `apply`. That gives
multiple durable writes, intermediate fallback and no ownership record. Use one versioned
`RecoverableFileStore` record for customization intent. Migrate the saved theme to the standalone
choice and existing enabled identifiers to manual reasons; start with no active pack. After a
successful migration, this record is authoritative and legacy preferences stop receiving writes.
Retain legacy data for recovery, not as a second mutable owner. Migration must be restartable;
corrupt new state follows quarantine/recovery policy instead of reimporting stale legacy values.
Hosted tests inject scratch persistence and preferences.

Activation has three stages:

1. **Prepare.** Validate the recipe, exact members, reviewed content, runtime eligibility,
   prerequisites and assets on bounded workers. Missing items, unresolved consent or a concurrent
   update refuse without changing the current selection.
2. **Commit intent.** Serialize customization operations, recheck revisions and durably replace
   the complete desired state once. Failed persistence leaves the old choice in force. File,
   codec and process work stay off the main actor.
3. **Reconcile.** Install resolved appearance and start/stop only changed runtimes through the
   supervisor. Publish coherent intent, then observed progress: **Starting**, **Active**, or
   **Needs attention**. A theme-only recipe is active once its appearance/resources are installed.

Pin the reviewed receipt and package generations across preparation and commit. Install, update
and uninstall must coordinate through that admission boundary, cancelling an obsolete preparation
or waiting for its commit; a version check followed by an unprotected file write is insufficient.

The intent change is atomic; arbitrary extension side effects are not reversible transactions.
A failure after commit leaves the pack selected with Needs attention, names the failed member or
asset, and offers Retry and Deactivate. Persisted selection alone is never reported as completed
activation. Retry uses existing bounded supervision. Restart reconciles the durable intent,
including a crash between commit and startup. Deactivation revokes departing generations and
their published surfaces immediately, while bounded process termination completes separately.

The command plane currently dispatches synchronously. Admit and enqueue a serialized operation
with a receipt; the existing `invoked` outcome means accepted for execution. Later completion or
failure updates host-owned status and a visible notice even after the palette closes. Do not
block the invoker on preparation/persistence or silently drop asynchronous errors.

Recovery Mode and “next launch without extensions” suppress contributions in memory without
clearing saved theme, pack or manual reasons. Report suppression separately from failure. Keep
Recovery Mode's System appearance and no-extension-start rule; activation cannot bypass it.
The next ordinary launch reconciles the retained intent.

## Host boundary and scaling gate

Pack selection, membership disclosure, enablement reasons, status and errors are **host-only**
control surfaces under the customization-surface gate. Themes style existing Design components.
Threading retains identity, admission, persistence, runtime isolation, companion trust, focus,
accessibility, recovery and the off switch. A pack grants no audio-capture, microphone, network
or native-plugin authority. Use existing review/consent flows where needed; already-reviewed
ordinary activation adds no new confirmation. All personal effects preferences from the sharing
draft remain authoritative and unchanged.

These are proposed workloads and requirements, not performance measurements:

| Work | Bound |
| --- | --- |
| Catalogue | Typical 50–100 themes and fewer than 20 packs. Stress 256 installed extensions × 16 themes, plus 1,000 custom themes and 1,000 installed pack receipts; receipt inventory needs an explicit admission bound. |
| Search | Immutable values, off-main cancellation and the existing bounded-result virtual table. Exercise 25,000 descriptors including queries with no matches. |
| Refresh | Inventory changes refresh affected metadata; selection/status changes affect stable IDs. No directory scan, artwork decode or process startup on opening or typing in the palette. |
| Activation | At most 16 runtime members. Set-diff work is O(changed members), with bounded concurrency/timeouts. Shared running generations survive a switch. |
| Assets | Existing resource validation plus bounded decoded caches. Catalogue visibility does not eagerly decode every theme or register every font. |

Inspection currently retains theme asset bytes and reconciliation registers enabled-package
fonts. Extending that eagerly to all installed packages would increase resident work. Measure
inventory preparation, metadata memory, first activation, main-thread mutation, view count and
retained resources separately; introduce bounded asset handles/caches where needed. A per-file
or returned-row cap does not bound aggregate decoding or scan work.

## Implementation sequence and acceptance

1. **Direct theme commands.** Register actions for themes in the current library and one host
   selection operation shared by Settings, MCP and commands. Cover identity, rename, shortcuts,
   live refresh and stale refusal. This independently useful slice retains current contribution
   lifetime; it must not claim discovery of disabled packages yet.
2. **Asset and intent ownership.** Separate installed appearance from running code, migrate the
   durable state, and reconcile runtime reasons. Verify disable, uninstall, live editing, font
   overrides, launch order and Recovery Mode before adding packs.
3. **Pack activation.** Consume the sharing draft's inspected installed receipts and explicit
   recipe, then add commands, membership disclosure, progress and retry. The sharing draft owns
   the prerequisite installer/receipt work; do not ship a second pack identity in the interim.

The separate terminal-theme command follows existing scoped assignment operations. It needs typed
scope/target/theme input and fresh target validation; the current command input supports session
and project selection only, so implement the additional input contract rather than encoding UI
objects or ambient selection into command IDs.

Behavioral acceptance covers A → B → off, shared members without restart, manual enablement
surviving off, Keep Enabled Without Pack, disabling a required member, theme-only selection,
missing prerequisites, stale invocation, failed persistence/startup, update/removal during an
operation, unchanged membership until reviewed, restart after commit and recovery without mutation.
Pack round trips and personal effects policy retain the sharing draft's additional acceptance.

Extend `AppCommandTests` / `CommandRegistryTests`, `ExtensionAppearanceTests`,
`ExtensionPackageStoreTests`, `CommandPaletteRenderTests` and focus coverage where they own the
behavior. Add reducer/migration tests and integration tests through the real host invoker and
supervisor seam. Descriptor-only tests cannot prove activation. Run focused tests, relevant
boundary checks and the repository's required shipping gates. Before altering any extension,
read [AGENT_AUTHORING.md](../extensions/AGENT_AUTHORING.md) completely.

Inspect rendered evidence in the real product shell for theme results, active/degraded rows,
membership disclosure and live switching under System and an authored theme. Verify keyboard
invocation and Escape focus restoration. Record matched performance results for catalogue and
activation workloads. Implementation and measured catalogue results now live in the
[appearance activation architecture](../architecture/appearance-activation.md).

Multiple simultaneous appearance recipes, project-scoped packs, arbitrary settings presets,
automatic dependency installation and per-component enablement are deferred. Reopen them with
a concrete composition case and explicit ownership rules for conflicting contributions.
