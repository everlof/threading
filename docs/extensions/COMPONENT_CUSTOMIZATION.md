# Component customization implementation plan

This document plans a controlled runtime-override system for Threading's public components. It
builds on [`HOST_SURFACES.md`](HOST_SURFACES.md).

Phases 1 through 12 are implemented in code: the Foundation-only SDK values, compact semantic
renderer nodes, in-memory registry/provider boundary, compositional host/container, validation
and fallback tests, and Component Gallery proofs now exist. The production session and project
rows expose versioned properties and additive `after-title` contracts, and accept constrained
`contentOnly` replacements inside host-owned shells. A capability-gated, per-generation
loopback host service now accepts atomic process publications, and semantic replacement actions
route back to their contributing process. The complete main-window content now exposes a
composable semantic around-hook seam with an extension-defined, host-owned Metal surface as its
first real dogfood case. Project hover, session hover and account usage presentations expose the
same add/wrap/replace model while Threading retains each temporary presentation's behavior. The
session-start and conversation-reply composers expose protected horizontal accessory hooks
around their existing native prompts. Native conversation rows expose four separate protected
annotation contracts without publishing transcript content as component context.

## The intended result

An extension can target a public component instance and either add content to a named slot,
change an allowed property, or replace the component's visual content with a semantic tree:

```swift
ExtensionComponentPatch(
    id: "ci-session-row",
    target: .init(
        component: "sidebar.session-row",
        contractVersion: 1,
        entityID: sessionID
    ),
    replacement: .stack(
        axis: .horizontal,
        spacing: .small,
        children: [
            .image(.hostAsset(providerImageID), role: .identity),
            .text("Deploy production", role: .compactBody),
            .flexibleSpacer,
            .status("CI passed", role: .positive)
        ]
    )
)
```

The extension has effectively replaced the content with an HStack. Threading still owns the table
cell, row selection, disclosure, indentation, drag and drop, hover tracking, contextual menus,
keyboard behavior, accessibility container, reuse, and action routing.

For a contract which declares an around-hook seam, an extension can instead wrap the existing
implementation:

```swift
ExtensionComponentPatch(
    id: "window-wrapper",
    target: .init(component: .applicationMainWindow, contractVersion: 1),
    hook: .overlay(
        base: .proceed,
        overlay: .customSurface(
            .metal(ExtensionMetalSurface(
                shaderResource: "Resources/window-overlay.metal"
            )),
            accessibilityLabel: nil
        )
    )
)
```

This is the controlled equivalent of an around hook in a swizzle library. `.proceed` means
“invoke the next implementation”. The registry orders matching hooks deterministically and the
host builds the chain inside-out:

```text
first enabled hook(
    second enabled hook(
        selected content replacement or native AppKit view
    )
)
```

A hook can use `.stack` to place its own UI beside the next view, or `.overlay` to place it over
the next view. Every accepted main-window hook contains exactly one `.proceed`: it cannot invoke
the native implementation twice and cannot suppress it. This protected contract can be relaxed
only by publishing another explicitly versioned contract whose host-owned behavior permits a
true replacement.

Project and session hover cards are the smaller presentation-shaped form of the same contract:

```swift
ExtensionComponentPatch(
    id: "project-ci-details",
    target: .projectHoverCard(projectID: projectID),
    hook: .stack(
        axis: .vertical,
        spacing: .medium,
        children: [
            .proceed,
            .divider,
            .status("CI passed", role: .positive)
        ]
    )
)
```

Here `.proceed` is Threading's native project-metrics card, or the next extension wrapper. If the
host has no reading yet, it is an empty native body and the extension content still gives the host
a reason to present the card. A full `replacement` suppresses the native metrics visually, but
not hover timing, placement, popover chrome, dismissal, accessibility or extension invalidation.

`sidebar.session-hover-card@1` has the same hook and replacement constraints with
`sessionPresentation` context. Its `.proceed` is the native session identity, checkout and
activity card. Sharing the host proves that the seam is a presentation primitive, while the two
specific component IDs keep their data context and future versioning independent.

`toolbar.account-usage-popover@1` uses `accountPresentation` context. Its host shell additionally
owns usage refresh, active-account switching and hover survival. Pointer tracking sits outside
the replaceable content, so a full replacement cannot accidentally break the gesture that keeps
the popover open while the pointer crosses into it.

`composer.session-start@1` and `composer.conversation-reply@1` use the same generic around-hook
machinery with stricter constraints. A hook must be a horizontal stack, must contain exactly one
`.proceed`, and may contain only compact status, text, image, fixed spacer and standard button
nodes. There is no replacement or overlay. `.proceed` remains the exact existing `PromptView`;
Threading owns text input, submission, keyboard routing, drafts, stream availability, permission
state and accessibility. The two IDs remain separate because one has project context and
pre-session draft state, while the other has session context and a live stream.

## Why one base class is the wrong boundary

Threading's components do not share one viable superclass:

- sidebar rows inherit `NSTableCellView`;
- ordinary components inherit `NSView`;
- interactive design components often inherit `NSControl`;
- larger surfaces are owned by `NSViewController`;
- toolbar content already has its own backdrop superclass.

Swift has single inheritance. Making all of these inherit one new extension base would either be
impossible or force unrelated components through parallel subclasses that duplicate behavior.

Use composition instead:

```swift
protocol ExtensionCustomizableComponent: AnyObject {
    var customizationHost: ComponentCustomizationHost { get }
}
```

Each public component owns one small host object. New plain `NSView` components may use an
optional `CustomizableComponentView` convenience superclass, but the runtime contract cannot
depend on it.

## The host and shell

The AppKit shape is:

```text
SessionRowView (host-owned behavioral shell)
├── ComponentContentContainer
│   ├── defaultContent             current AppKit content
│   └── replacementContent         host-rendered ExtensionNode tree
├── named ComponentSlotViews       additive extension content
└── host interaction/state views   activity, actions, selection behavior
```

`ComponentCustomizationHost` is not itself the row. It coordinates:

- the stable component contract and current entity context;
- a default-content container;
- zero or more named slot containers;
- lookup in the customization registry;
- rendering and swapping replacement content;
- action routing;
- fallback when a patch is absent or invalid.

The default subtree remains the component's current AppKit implementation. Migration does not
require rewriting every default UI as `ExtensionNode`. When a valid replacement exists, the
container hides default content and installs the rendered tree. Removing or disabling the
extension reveals the already-owned default subtree again.

This makes adoption a one-time layout refactor per public component, not a rewrite of the app.

## Public component contract

Every exposed component has one versioned, machine-readable contract:

```swift
ExtensionComponentContract(
    id: "sidebar.session-row",
    version: 1,
    context: .sessionPresentation,
    properties: [.title, .identityImage, .toolTip],
    slots: [
        .init(id: "after-title", maximumInlineItems: 2)
    ],
    replacement: .contentOnly,
    hostOwnedBehavior: [
        .selection,
        .dragAndDrop,
        .rowActions,
        .activityState,
        .accessibilityContainer
    ]
)
```

Customization levels are explicit per component:

1. `properties` — replace allowed semantic values.
2. `slots` — add host-rendered children to stable named regions.
3. `contentOnly` replacement — replace everything inside the behavioral shell.
4. around hook — wrap exactly one `.proceed` with a constrained semantic tree.
5. `none` — inspectable but intentionally not customizable.

There is no view-hierarchy selector, class-name matcher, child index, Auto Layout constraint
access, or arbitrary key path. Extensions target component IDs, entity IDs, and declared slots.

## SDK values

The first SDK layer needs:

```text
ExtensionComponentID
ExtensionComponentContract
ExtensionComponentTarget
ExtensionComponentContext
ExtensionComponentPatch
ExtensionComponentPropertyPatch
ExtensionComponentSlotPatch
ExtensionImageReference
ExtensionIdentityComposition
```

`ExtensionNode` renders horizontal and vertical stacks, text, status, buttons, dividers, fixed
spacers, native value controls, and bounded semantic scenes. Inputs, pickers, and scenes are
enabled for full panels; compact contracts keep them disabled unless `allowsTextInput`,
`maximumPickerOptions`, or `maximumSceneItems` explicitly opt in. See
[`DECLARATIVE_UI.md`](DECLARATIVE_UI.md). Full row replacement additionally needs:

- `image(reference, role, accessibilityLabel)`;
- `flexibleSpacer`;
- single-line/truncating text roles suitable for compact components;
- compact status/accessory nodes;
- an optional visibility condition resolved before publication, not evaluated inside AppKit.

The renderer continues to choose fonts, theme colors, symbol sizing, focus treatment, and
accessibility. A compact component contract may reject nodes that are legal in a panel; for
example, `sidebar.session-row` should not accept a multiline heading or a large primary button.

Those limits are values in the contract, not prose known only to Threading.
`ExtensionComponentNodeConstraints` describes maximum depth, node count and text length, the
required root axis, allowed stack axes and semantic roles, and whether dividers or fixed/flexible
spacers are available. An extension can therefore validate generated content with the same
machine-readable rules before publication.

A vocabulary may also describe a **second** one. `disclosureDetail` is the vocabulary a
`disclosure` node's revealed level may use — absent, and summaries on that surface have no
second level. It is a full constraint set rather than a flag because the revealed level is a
different room: Threading opens it on a surface of its own, so it can be wider than the compact
row that summarises it, and the corner card uses exactly that to keep controls out of its line
while allowing them behind a reveal. The recursion is boxed
(`ExtensionComponentDetailConstraints`), which is the only reason that indirect enum exists; it
encodes as the nested vocabulary itself.

`session.corner-card@1` accepts up to three compact horizontal rows. Each may combine icon or
decoration images with compact text, semantic status and spacing. Controls remain forbidden in
that line. A `disclosure` is the NSMenu-like route for more: its summary uses the compact
vocabulary, while its bounded detail may use horizontal/vertical groups, dividers and standard
buttons. Threading owns both levels' pixels, reveal gesture and accessibility.

The current `sidebar.session-row` v1 replacement contract requires one horizontal root stack,
allows at most eight nodes and one nested level, caps each text value at 80 characters, and
accepts only compact text, identity/icon/decoration images, standard buttons, statuses, and
spacers. Its `after-title` slot is narrower still: one status node, at most 24 characters.

## Runtime registry, not runtime IPC

AppKit can reconfigure sidebar rows many times per second. It must never synchronously call an
extension process from `configure`, layout, drawing, or accessibility methods.

Extensions publish patches through `ExtensionHostService`. Threading validates them and stores
accepted values in a main-actor `ComponentCustomizationRegistry`, keyed by:

```text
extension ID
process generation
component ID + contract version
entity ID or declared global scope
patch ID
```

Views perform a synchronous in-memory lookup. Registry changes post a targeted notification
containing component and entity IDs, so only visible affected components reconfigure.

Disable, crash, reload, or token revocation removes that process generation's patches atomically.
The default subtree becomes visible without waiting for the old extension.

The customization UI layer depends on a small `ComponentCustomizationProvider` protocol.
`ExtensionManager` supplies an adapter at the app composition root, matching the separation used
for extension-contributed MCP tools. With no provider installed, every lookup returns no patch
and all components render exactly as they do today.

## Conflicts and ordering

Rules differ by patch kind:

- slot additions compose in the user's extension order, then patch identifier;
- property changes apply in that order, so the last enabled change wins and Settings can explain
  the chain;
- full content replacement is exclusive: one active renderer is selected for that component
  family;
- around-hooks compose in the user's extension order. Each hook receives the already composed
  next view, so disabling one generation removes only that layer and reconnects the chain;
- host-owned behavior and protected properties cannot be replaced;
- user per-entity presentation choices retain the precedence defined in `HOST_SURFACES.md`.

Settings must show conflicts before activation. Enabling a second full renderer offers to make it
active; install order never silently changes the winner.

## Incremental migration

### Phase 1 — contract and in-memory proof

- [x] Add SDK contract/patch/image values.
- [x] Add renderer nodes required for a compact HStack.
- [x] Implement registry and provider boundary with no process transport.
- [x] Add Component Gallery stories for default, slot-added, fully replaced, invalid, and fallback
  states.

This phase proves the abstraction without changing a product component.

### Phase 2 — session row shell and CI slot

- [x] Wrap `SessionRowView`'s current icon/title content in `ComponentContentContainer`.
- [x] Keep its existing activity/actions trailing slot outside replacement content.
- [x] Add the `after-title` slot.
- [x] Drive a fake CI accessory from the in-memory registry.
- [x] Verify the slot is entity-scoped and cleared on row reuse, default restoration, property
  restoration, host-owned activity/actions, theme safety, side-chat/account/dormancy code paths,
  and the existing hover/selection shell.

Phase 2 deliberately kept `replacement: .none`, so the generic renderer could not accidentally
admit a full production renderer before compact-node validation and real-shell tests existed.
Phase 3 has now changed the v1 declaration to `.contentOnly`.

### Phase 3 — full session-row replacement

- [x] Enable `.contentOnly` for `sidebar.session-row`.
- [x] Render the HStack example through the real row shell.
- [x] Route replacement actions using semantic action IDs.
- [x] Add size and node-vocabulary validation for the compact row.

Replacement button events carry the component target, contributing extension identifier, and
semantic action ID. They never expose an `NSButton`, row view, or other AppKit object. Slot
actions remain unavailable in v1 because the only production slot is status-only; a future
interactive slot must preserve per-slot contribution provenance before it can admit buttons.

### Phase 4 — project row

- [x] Give `ProjectRowView` the same container and `after-title` slot.
- [x] Keep its count/actions hover slot host-owned.
- [x] Exercise one CI extension publishing both project and session state.

`sidebar.project-row` uses the same compact node constraints as the session row and adds
`aggregate-count` to its declared host-owned behavior. Only real project entities participate:
repository and branch headings explicitly deactivate their customization host, so a family-wide
project patch cannot restyle structural sidebar headings.

### Phase 5 — real extension transport

- [x] Implement the tokenized `ExtensionHostService` independently of the JSONL action stream.
- [x] Publish complete patch sets atomically into the existing registry/provider.
- [x] Route replacement actions back to the contributing process.
- [x] Revoke tokens and remove a process generation on disable, reload, crash, uninstall, or
  shutdown.
- [x] Exercise the production path from the Hello Status reference extension.

Fixtures remain in the Component Gallery and tests because they make visual and failure states
deterministic; production composition no longer writes fake patches.

### Phase 6 — brokered host data

- [x] Add versioned project, session, and sanitized repository snapshots.
- [x] Gate each read surface independently from `ui.components`.
- [x] Add atomic snapshot cursors and a bounded project/session change journal.
- [x] Make the reference extension resolve real entity IDs before publishing patches.

### Phase 7 — identity pipeline and catalog

- [x] Implement provider and account presentation snapshots and primitive resolvers.
- [x] Preserve user account-image precedence, side-chat lineage, and native fallback.
- [x] Revoke primitive publications with the extension generation.
- [x] Implement the selectable full session identity renderer on the same patch pipeline.
- [x] Generate component documentation and schemas from the contract registry.
- [x] Expose MCP tools to list, describe, validate, and preview component patches.

`ThreadingComponentCatalog` now lives in the Foundation-only SDK and is the one declaration used
by app registration, runtime validation, generated JSON/Markdown, per-component schemas and the
authoring tools. `ThreadingComponentCatalogGenerator --check` catches stale committed output.

The built-in MCP names are `extension_list_components`, `extension_describe_component`,
`extension_validate_component_patch`, and `extension_preview_component_patch`. Patch arguments
are complete JSON strings so the generic MCP schema remains independent of extension types.
Preview uses the native semantic-node renderer with representative host assets and writes only
an image tab; it never publishes a generation, changes the active replacement, or installs code.

### Phase 8 — sandbox

- [x] Enforce the capabilities already exercised by real CI and identity extensions.

`ExtensionSandboxPolicy` maps the manifest to one generated Seatbelt profile. Component and
identity extensions receive only their generation's host loopback port; a CI client adds
`network.client`. Package reads, private storage writes, networking, and process launch are
separate rules, and launch fails closed if containment cannot be applied.

### Phase 9 — composable component hooks

- [x] Add `.proceed`, `.overlay`, and custom-surface nodes to the value-only SDK.
- [x] Give component contracts separate hook constraints without changing existing exclusive
  replacement semantics.
- [x] Compose multiple hooks deterministically around one native view and revoke them by process
  generation.
- [x] Publish `application.main-window@1` with exactly-one-proceed validation.
- [x] Add the separately approved `ui.rendering.metal` capability and host-owned Metal renderer.
- [x] Expose the bounded `active-account.usage-remaining` scalar signal.
- [x] Package project-root resources beside retained source.
- [x] Build the Usage Rain example only from public SDK declarations.
- [ ] Exercise the packaged Wasm extension in a clean running app and inspect the complete window
  at runtime.

The rain behavior is deliberately not an app feature or a rain-specific API. It is one extension
using the same general hook, custom-surface, resource, and host-signal contracts available to
other extensions. The host controls the `MTKView`, device, command queue, fullscreen geometry,
frame-rate ceiling, uniform buffer, input mapping, hit testing, reduced-motion behavior, source
size, and lifecycle. The extension supplies one fragment function and at most eight ordered
scalar inputs. Failure to resolve or compile any required surface rejects that hook layer
atomically and leaves the remaining chain and native view intact.

### Phase 10 — customizable temporary presentations

- [x] Publish `sidebar.project-hover-card@1` with project context.
- [x] Publish `sidebar.session-hover-card@1` with session context using the same host.
- [x] Publish `toolbar.account-usage-popover@1` while retaining refresh, account selection and
  hover survival in the host shell.
- [x] Reuse the generic controller composition host with host-owned width and insets.
- [x] Let native content, extension-only content, multiple hooks and exclusive replacement share
  one presentation shell.
- [x] Keep hover trigger, delay, placement, dismissal and popover chrome host-owned.
- [x] Route interactive hook/replacement nodes using their contributing extension provenance.
- [x] Close an extension-only popover when its final contributing generation disappears.
- [x] Make Hello Status add project, session and account detail using only public contracts.
- [ ] Run the packaged extension in the app and visually inspect native-plus-extension,
  extension-only, replacement, disable and reload states.

This is the template for adopting more UI: publish a specific semantic component contract,
retain behavior in the product shell, and reuse the general composition host. Do not publish
`NSPopover`, view-controller, or arbitrary hierarchy access.

### Phase 11 — protected composer accessories

- [x] Publish separate project-context `composer.session-start@1` and session-context
  `composer.conversation-reply@1` contracts.
- [x] Permit compact leading and trailing controls through horizontal around-hooks.
- [x] Require exactly one `.proceed`; reject replacement, overlays, vertical stacks and
  expanded content.
- [x] Wrap the real native `PromptView` instances without recreating them on publication,
  disable, or reload.
- [x] Preserve action provenance and route each semantic button to its contributing extension.
- [x] Keep text entry, submission, keyboard routing, draft persistence, stream availability,
  permission state and accessibility host-owned.
- [x] Exercise both real composer shells and removal fallback in hosted AppKit tests.
- [x] Make Hello Status publish a sample control for each composer.

Full composer replacement is intentionally not pending work for v1. It should be reconsidered
only if the input and permission machinery gains a separate host-owned shell that remains
present under replacement.

### Phase 12 — protected conversation-row annotations

- [x] Publish separate `conversation.user-message@1`,
  `conversation.assistant-message@1`, `conversation.tool-call@1`, and
  `conversation.permission-card@1` contracts.
- [x] Scope family patches optionally by known session ID; do not expose message text, tool
  arguments/output, or approval details through component context.
- [x] Require one vertical root and exactly one `.proceed`; reject replacement, overlay and
  horizontal-root hooks.
- [x] Retain the exact native row object so late tool results, expansion state, selectable
  message content and permission resolution continue in place.
- [x] Keep transcript order, turn boundaries, streaming finalization, tool result attachment,
  approval queue/state/decision and remote mirroring host-owned.
- [x] Make permission-card annotations display-only so extension controls cannot resemble an
  approval decision.
- [x] Preserve action provenance for the other three row contracts.
- [x] Dogfood user-message and tool-call annotations in Hello Status.
- [x] Exercise native-state continuation, action routing, removal fallback and permission
  authority in the real conversation controller.

Thinking, notice and streaming-placeholder rows remain host-only. They are transient rendering
states rather than stable product concepts, and the finished assistant-message contract covers
the durable extension surface.

### Phase 13 — protected display-pane chrome

- [x] Publish session-scoped `display.pane-header@1` and `display.tab-header@1` contracts.
- [x] Give the shared pane header a compact horizontal command/status hook around an empty
  protected `.proceed` anchor, not around the native tab strip.
- [x] Give each native tab one display-only `after-title` status slot.
- [x] Keep internal tab UUIDs out of the public target model; a session patch applies to all of
  that session's tab headers.
- [x] Retain tab identity, selection, close, order, active state, overflow, persistence, pane
  visibility, accessibility and the native `+` menu in Threading.
- [x] Preserve component-action provenance for pane-header buttons.
- [x] Dogfood both surfaces and a real component action in Hello Status.
- [x] Exercise selection, close, action routing and extension-removal fallback in the real
  display-pane controller.

### Phase 14 — corner-card placement slots

- [x] Publish a session-scoped `session.corner-card@1` contract for the floating card over the
  session's content pane. The ID deliberately names the surface, not its current content — the
  card carries the checkout's branch and counters today and may carry agents or attachments
  tomorrow.
- [x] Encode **placement as the slot ID**: `top-trailing` is the only corner with a card today;
  a future leading card arrives as an additive `top-leading` slot on the same contract rather
  than a rename or a second component.
- [x] Keep the slot display-only (compact text/status rows, no buttons): built-in Git and
  Subagents segments own the card's navigation, alongside visibility, the idle/working activity
  presentation, and the data-refresh cadence.
- [x] Extension rows ride the native card's visibility. Git or child-agent status can present
  the card, but extension content alone cannot — the card is session state, not a blank easel.
- [x] Preserve the card's occlusion decisions: slot rows render inside the flattened
  `WindowBackdrop.opaque` fill and share the contents' resting alpha and hover lift.

### Phase 15 — a second level behind a summary

- [x] Add `ExtensionNode.disclosure(id:summary:detail:)`: an extension states that a reading has
  more behind it and what that more says. The reveal gesture, its dwell, the surface, placement,
  growth limit, pointer bridge and dismissal stay host-owned, presented through the named
  `extension.node-detail` popover.
- [x] Give a vocabulary a second vocabulary (`disclosureDetail`) rather than a Boolean, so the
  revealed level's own budget, roles and axes are machine-readable and validated by the SDK
  before publication — with one budget shared across the whole revealed level, not one per row.
- [x] Amend the corner card's display-only rule at the *row*, not at the surface: the row still
  refuses controls that would fight the card's own hit targets; the revealed level accepts
  `standard` buttons and refuses `primary`/`destructive`, which do not belong behind a hover.
- [x] Render both levels in one renderer pass, so a button in the detail keeps the host view's
  action bridge — AppKit's `target` is weak, and a lazily built detail hands back dead buttons.

### Phase 16 — a surface beneath the host's content

- [x] Add `ExtensionComponentNodeConstraints.proceedPlacement` (`anywhere` | `overlayTop`) and
  `maximumCustomSurfaceFramesPerSecond`, so a contract can state "your content goes under mine"
  and "no faster than this" as machine-readable rules the SDK refuses against.
- [x] Add the `backdrop` image role — a fill with no intrinsic size and a nil hit test — and
  list `ExtensionImageRole.inline` in every earlier contract so the role is opt-in per surface.
- [x] Publish `sidebar.backdrop@1`: an under-content hook admitting the fill role and a Metal
  surface at ≤ 30 fps, hosted on a passive plane between the theme's sidebar ground and the
  list with an empty `.proceed`, composited below a host-owned 60% ceiling.
- [x] Give host signals one owner (`ExtensionHostSignals`), add `workload.intensity`,
  `workload.working-count` and `time.day-fraction`, refuse unknown signals at publication, and
  share the custom-surface renderer between the window hook and the plane.
- [x] Hold a Metal surface's frames while its window is occluded, miniaturized or the view
  hidden, and clamp its cadence to the host's ceiling.

## Expected intrusion

Core extension machinery is additive and removable:

```text
Core/Extensions/ComponentCustomizationRegistry.swift
UI/Extensions/ComponentCustomizationHost.swift
UI/Extensions/ComponentContentContainer.swift
```

Each adopted component needs a deliberate local refactor:

- move its replaceable visual subtree into one container;
- declare its contract;
- supply a safe context value;
- place any named slots;
- refresh when the registry says its entity changed.

For the first session row this is meaningful layout work, because icon, account badge, title,
status, and hover actions currently share constraints. Later compact rows can reuse the proven
container and slot views. Components not opted into the public catalog remain untouched.

## Safety and fallback invariants

- Rendering never waits for an extension process.
- Invalid patches are rejected before reaching a view.
- Node, depth, byte, image, and layout limits are component-specific.
- A replacement cannot remove host selection, permissions, security controls, or row actions.
- A protected around-hook contains exactly one `.proceed`; one extension cannot erase or
  duplicate the next implementation.
- A failed hook is skipped atomically, and the rest of the chain remains connected.
- Extension-supplied Metal source requires its own visible capability and never receives a
  Metal or AppKit object.
- Extension actions never receive AppKit objects.
- Crashes and disable restore default content immediately.
- Theme and accessibility audits run against default and replaced fixtures.
- Every public component contract has a version and a compatibility policy.

## Acceptance criteria for the first vertical slice

The first slice is complete when a fixture extension can:

1. add a CI light after a session title;
2. replace the session content with an image/text/flexible-spacer/status HStack;
3. click a semantic action in that replacement;
4. be disabled while the row is visible and restore the native row immediately;
5. fail validation without disturbing the native row;
6. preserve selection, activity indication, hover actions, reuse, theme switching, and
   accessibility;
7. appear in generated component documentation with a machine-readable schema.
