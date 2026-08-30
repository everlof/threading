# Workspace navigator extensions

`ui.workspace-navigation` is the first contract slice for user-selectable replacements of the
leading workspace navigator. It describes the complete interior as semantic data; Threading keeps
the split-view shell, resize/collapse behavior, focus and keyboard routing, theme resolution,
entity validation, and an always-available route back to the native navigator.

The name is deliberately not “project sidebar.” A navigator may be a project/thread outline, an
activity inbox, a sectioned lifecycle view, a grid, or a composition containing search, filters,
status, scenes, and one or more collections.

## What the host implements

- `ExtensionWorkspaceNavigator` registration values and the `ui.workspace-navigation`
  capability;
- a compositional `ExtensionWorkspaceNavigatorNode` root which embeds ordinary
  `ExtensionNode` content;
- virtualized list, outline, and grid collection snapshots with stable section/item/parent IDs;
- explicit host destinations for projects and sessions, separate from extension actions;
- validation for structure, item budgets, duplicate IDs, selection, hierarchy, destinations,
  row vocabulary, and preferred width;
- localization of titles and embedded semantic content;
- a persisted user choice under **View → Navigator**, with Native always outside the replaceable
  surface;
- a host-owned localized title band over every extension navigator, with a permanent overflow
  menu route back to Native;
- correlated, value-bearing runtime actions and optional `loadActionID` refreshes;
- optional `eventActionID` delivery of coalesced `session.changed` edges, with bounded
  content-only item patches in reply;
- atomic snapshot replacement while preserving selection, outline expansion, visible position,
  and first responder by stable semantic ID;
- live generation-bound inventory and immediate Native failback when a selected process stops,
  reloads, or produces a document the host cannot render;
- a machine-readable schema at
  [`schema/workspace-navigator.schema.json`](schema/workspace-navigator.schema.json).

The extension owns the navigator document, grouping, labels, filters, and actions. Threading owns
the split-view column, resize/collapse behavior, theme and accessibility semantics, collection
virtualization, focus, user selection, and the authority to navigate to live host entities.

Those host responsibilities are deliberately split in source. `WorkspaceSidebarContainerViewController`
owns selection persistence, process-generation replacement and atomic Native failback;
`WorkspaceNavigatorHostViewController` owns one validated document and its virtualized renderers.
A Native selection from the host-owned overflow menu is persisted before the sidebar swaps. The
container dismisses any open menu before settings override, Native failback, navigator selection,
or process-generation replacement, so the menu session cannot outlive the document which opened
it.
A list or grid item that throws while being realized is a document render failure, not an empty
cell: the renderer escalates it to the container, which replaces that exact process generation
with Native. A stale failure from an old generation cannot evict its replacement.

## Why collections are separate

An `ExtensionNode.stack` eagerly realizes every child. That is correct for panels and compact
component content, but not for thousands of projects or sessions. A navigator collection is a
snapshot the host can diff by stable ID and render with row reuse:

```swift
ExtensionWorkspaceNavigator(
    id: "project-outline",
    title: "Project outline",
    root: .stack(
        axis: .vertical,
        spacing: .small,
        children: [
            .content(.textInput(
                id: "filter",
                value: "",
                placeholder: "Search",
                accessibilityLabel: "Search projects and sessions",
                role: .search,
                isEnabled: true
            )),
            .collection(.init(
                id: "work",
                layout: .outline,
                sections: [],
                items: [
                    .init(
                        id: "project:p1",
                        content: .text("Threading", role: .body),
                        activation: .destination(.project(id: "p1")),
                        isExpanded: true
                    ),
                    .init(
                        id: "session:s1",
                        parentID: "project:p1",
                        content: .text("Navigator contract", role: .body),
                        activation: .destination(
                            .session(id: "s1", projectID: "p1")
                        ),
                        isSelected: true
                    )
                ]
            ))
        ]
    )
)
```

The extension computes domain-specific grouping. Threading only understands layout and
interaction semantics; there is no project-group or thread-row node.

An actionable grid item also supplies `accessibilityLabel`. Its whole cell is a host-owned
button, so the label names that activation independently of whatever visual composition the
cell contains. List and outline rows can derive their semantics from their rendered content,
though an explicit label is available there too.

## Declared options

`ExtensionWorkspaceNavigatorOption` declares a host-rendered toggle or enumerated choice using the
same control vocabulary as extension Settings:

```swift
options: [
    .init(
        id: "group-branches",
        title: "Group by branch",
        control: .toggle(defaultValue: true)
    ),
    .init(
        id: "sort",
        title: "Sort",
        control: .choice(
            defaultValue: "recent",
            options: [
                .init(id: "recent", title: "Recent activity"),
                .init(id: "name", title: "Name")
            ]
        )
    )
]
```

The contract permits at most 16 options and 30 declared menu entries after expanding choice
submenus; Threading reserves the final two entries for the divider and Native route. IDs and
defaults are durable values. Titles and choice titles are localized copy. A complete runtime
navigator replacement must repeat the raw option declaration accepted from that process
generation exactly, so only a new generation can change the meaning of a stored value. Threading
localizes the accepted declaration afterward for presentation.

Option values are host-owned state. Threading hydrates one recoverable file per extension on the
background activation path, then publishes only a generation-matched in-memory snapshot to the
navigator host. The render and menu paths never read the filesystem. Writes are serialized per
extension and revalidated against the active immutable declaration. A lifecycle fence drains user
changes the host already accepted, then retires that process generation without blocking the main
actor on disk; later work from the retired generation cannot write or publish. Invalid stored values
fall back to declaration defaults, while unknown navigator and option IDs are retained so a
temporarily removed declaration does not destroy user state. Corrupt data is quarantined before a
new file is saved, and a newer format is kept byte-for-byte with writes disabled.

These declarations are forward-compatible groundwork for the host-evaluated
`ui.workspace-navigation@2` transform. The v1 materialized-document renderer does not show option
rows which nothing in the host consumes. Declaring an option does not invoke the extension, and
the host does not create a preference file until a user-visible control changes a non-default
value.

### Registered-fact controls

> Contract status, 2026-08-30: the SDK, validation, localization, wire schema and shipping host
> path below are pinned. Declared controls appear in the navigator menu and are evaluated entirely
> by Threading without invoking the extension.

A pipeline may also declare at most one dynamic **Group by** control and one dynamic **Sort by**
control with `registeredFactOptions`. These are host-owned pickers over the live fact registry,
not static setting choices and not extra `consumes` entries:

```swift
registeredFactOptions: [
    .init(
        id: "group-by-fact",
        title: "Group by",
        application: .bucket(direction: .ascending, unknownTitle: "Unknown")
    ),
    .init(
        id: "sort-by-fact",
        title: "Sort by",
        application: .sort(direction: .ascending)
    )
]
```

Each control has a host-localized **None** default. A selected dynamic bucket replaces the active
static bucket clause; choosing None restores the static buckets. Present scalar values follow the
declared direction and missing values stay in the extension-localized unknown bucket at the end.
A selected dynamic sort is the primary sort, missing values follow present values in both
directions, and active static sort clauses remain tie-breakers. If a selected definition is
temporarily unavailable, grouping produces the unknown bucket and sorting becomes a no-op before
those static tie-breakers. It does not invoke `required` / `enhances` degradation.

Threading offers a host-localized None row plus at most 128 fact rows in each control after
filtering the live host and extension registry. Grouping requires `.groupable`; sorting requires
`.sortable`; and format 1 admits definitions applicable to `.session`, `.repositoryBranch`, or
`.repository`. Project-only and terminal-only definitions cannot resolve from the pipeline's
session source and are omitted. For a key with multiple compatible providers, the registry's
winning definition — host first, then source order, extension identifier and process generation —
alone supplies display name, usages and eligibility. Metadata from lower-precedence definitions is
never merged. Choices sort by localized display name, then fact-key ID and version, so provider
startup order cannot reorder the menu.

A selected live eligible key always remains visible inside the 128 fact-row bound. If it moves
outside the sorted prefix after a locale or catalogue change, it replaces the final admitted row.
If it has no live eligible definition, one host-localized unavailable row containing that key
reserves a fact-row slot, leaving at most 127 live rows. None therefore makes the complete submenu
at most 129 rows and always gives the user a way to clear the retained selection.

The selected value is an `ExtensionFactKey`, persisted by Threading under the navigator and option
IDs. Those IDs share the namespace with static navigator options, but registered-fact IDs cannot
be referenced from a static `when` condition. Threading retains a selected key across provider
removal and resumes it when the same key returns; the provider never receives the catalogue,
selection, source subjects, or resolved values. Each control consumes one parent row in the
navigator's 30-entry declared-menu budget. Its bounded dynamic choices live inside that submenu.

## Host-evaluated pipeline declarations

The optional `pipeline` is the additive `ui.workspace-navigation@2` contract revision. The `@2`
names the navigator format, not a second permission: it remains under the existing
`ui.workspace-navigation` capability because it adds no authority beyond occupying the same
user-selected surface. An older host can still decode the navigator and present its required
`root` fallback; requiring an unknown second capability would make that compatibility path
impossible.

Format 1 evaluates the host's session catalogue, realizes a single-select list from one bounded
row template, and routes every generated row to its source session without calling the extension.
An output may add `windowing: .hostVirtualized` to expose the complete evaluated ordering while
still realizing semantic templates only for the collection viewport.
The declaration names every fact it consumes as `required` or `enhances`, and every declared
option must participate in a filter, bucket, or sort condition. `loadActionID` and
`eventActionID` are unavailable on a pipeline navigator: facts and option values invalidate it
inside the host. A runtime action replacement must repeat the raw registered pipeline exactly;
only a new process generation may add, remove, or change it.

Pipeline declarations cross two matched boundaries. Put every pipeline navigator in the
manifest's `workspaceNavigators` array so Threading can inspect the package without launching it,
then register the exact same raw base-language values, in the same order, during the process
handshake. The host validates that complete list before localization. Runtime-only v1 navigators
stay out of the manifest and may coexist in the same registration. An absent manifest member
decodes as `[]` for old packages; explicit `null` is invalid.

The manifest list is inspection metadata, never render inventory. Threading exposes only the
localized navigator values belonging to a currently running generation whose complete raw list
matched the manifest. A mismatch, startup failure, disable, or process termination exposes none
of that generation's navigators and restores the host-owned Native route.

Provider absence and subject absence are different:

- no provider for a `required` key makes the complete navigator unavailable;
- no provider for an `enhances` key removes the smallest unit which uses it: one search field,
  filter clause, sort clause, fact-bucket clause, rule-bucket rule, or conditional template node;
- a fact-bound text/image/status leaf uses its declared fallback when an `enhances` provider is
  absent and omits that leaf if it has no fallback; if removing children empties the row template,
  the host shows the navigator's empty state rather than a blank selectable row;
- if a key has a live provider but one source session has no value, an operand fallback is
  substituted before comparison, relative-date, sort, or fact-bucket evaluation. Without an
  operand fallback, predicates do not match, sort places the subject after present values, and a
  fact bucket uses its unknown path. `isPresent` remains false because it has no operand. Text,
  image, and status bindings independently use their presentation fallback.

Extension-provided values have a host-owned 15-minute freshness ceiling. Threading uses the
earlier of the provider's `observedAt` and the host receipt time, so a future-dated observation
cannot extend that window. At expiry the value follows the same subject-level missing/unknown
rules above; the live definition still counts as a provider, and resolution falls through to the
next fresh provider for the same key when one exists. A provider cannot declare a longer TTL, and
a fresh publication restores the value without restarting either extension.

Nested `all`, `any`, and `not` expressions do not partially simplify when a provider is absent;
the enclosing filter clause, bucket rule, or conditional template node is the degradation unit.
Search stays visible while at least one declared field remains and disappears when none do.
Rule buckets keep their surviving rules and configured unmatched behavior, collapsing only when
no rules survive. Fact buckets collapse as one unit.

Project-scoped lookup is explicit, never implicit inheritance. It follows the current session's
`session.project-id`, so a declaration using it must also consume that join key. A session without
a project ID simply has no project-scoped value and follows the per-subject unknown/fallback rules
above; provider availability is not inferred from whether any particular session joins.

The compatibility fields remain required: `itemLimit` is in `1...1000` and `overflow` is
`.truncateWithNotice`. Without `windowing`, the host emits that prefix after filtering,
bucketing, and sorting and appends a localized, nonselectable notice with the omitted count. With
`windowing: .hostVirtualized`, a capable host keeps every lightweight row identity in the final
ordering, reports no omitted rows, and asks the template renderer only for the visible range.
Older format-1 hosts ignore the additive field and safely retain the bounded notice behavior, so
the compatibility fields remain valid even though a windowing-aware host does not apply their
truncation. The complete machine-readable contract is
[`schema/workspace-navigator-pipeline.schema.json`](schema/workspace-navigator-pipeline.schema.json).

[`ActivityInboxExtension`](../../Packages/ThreadingExtensionKit/Examples/ActivityInboxExtension)
is the complete safe-extension example. Its manifest requests only `ui.workspace-navigation`; its
static pipeline produces Priority, Today, Yesterday and Last 7 days sections from published
host facts, shows working state from the detailed activity fact, and lets the host own search,
sorting, the clock, row realization and source-session activation. There is no session snapshot
read and no extension callback on a fact or calendar edge.

[`T3SidebarExtension`](../../Packages/ThreadingExtensionKit/Examples/T3SidebarExtension) is the
matching host-intent example. Its static pipeline presents a flat session list with project
subtitles, a Pinned section, host search, and a persisted sort option. It declares `pin`, `unpin`,
and `archive`, conditionally shows the applicable controls, and omits them for scheduled-start
rows which Threading would refuse. The extension still receives no session snapshot or callback.

`session.activity.detailed@1` currently publishes six named raw values through
`ExtensionSessionDetailedActivity`: `dormant`, `idle`, `working`, `awaiting-user`,
`needs-attention`, and `limit-reached`. Use those constants instead of reproducing private host
model strings. The raw-value type deliberately keeps unknown future values decodable.

## Host-owned row intents

A pipeline navigator may place a bounded product action directly in its visible-row template.
The initial vocabulary is deliberately small:

```swift
ExtensionWorkspaceNavigator(
    id: "focused-work",
    title: "Focused work",
    root: .content(.text("Requires a pipeline-capable host", role: .body)),
    intents: [.pin, .unpin, .archive],
    pipeline: .init(
        // ...
        output: .init(
            collectionID: "sessions",
            rowTemplate: .stack(
                axis: .horizontal,
                spacing: .small,
                children: [
                    .text(.fact(title), role: .compactBody),
                    .flexibleSpacer,
                    .intent(.pin),
                    .intent(.archive),
                ]
            )
        )
    )
)
```

`pin`, `unpin`, and `archive` are the only supported values. A navigator may declare at most eight
unique intents. Its manifest and startup registration must repeat the exact raw navigator
declaration, including `intents`. Every declared intent must occur in its template and every
`.intent` leaf must be declared; explicit `null` is not a legacy spelling for an absent list.

These are host product intents, not extension callbacks or a session-write permission. Threading
renders the buttons, keeps them keyboard- and accessibility-reachable while revealing their
chrome on row hover or keyboard focus, and dispatches the gesture without sending the extension a
session ID, press event, or result. The host revalidates the selected process generation, the
structural pipeline revision, and the current source session at the press edge. A missing,
archived, or scheduled session is refused without mutation. Pin and unpin use the native project
store persistence path. Archive uses the native lifecycle coordinator, including duplicate-press
fencing, provider coordination, a receipt, and Undo.

Presentation-only fact patches do not invalidate a still-visible row action; a structural
evaluation does. A stale action can therefore never be retargeted to a reused row or a replacement
process generation. Install and update confirmation copy and the installed extension's Settings
summary list the declared verbs before the navigator can be enabled or updated.

## Runtime snapshots and actions

Set `loadActionID` when the static registration is only a useful initial or loading document.
Threading sends that action after the selected host is installed and again when the project store
changes. Controls inside `.content` nodes send their native value; collection action activations
send the stable item ID:

```swift
ExtensionWorkspaceNavigator(
    id: "project-outline",
    title: "Project outline",
    root: .content(.status("Loading projects…", role: .neutral)),
    loadActionID: "refresh",
    preferredWidth: 280
)
```

The process receives an `ExtensionWorkspaceNavigatorActionRequest` with `navigatorID`,
`actionID`, optional `value`, and the current opaque project/session context. Return an
`ExtensionWorkspaceNavigatorActionResponse` naming the same navigator. A response may contain a
complete replacement navigator or bounded content-only item patches, and/or a message; an error is
exclusive. Complete replacement and patches are mutually exclusive.

Structural replacement is intentionally whole-document rather than imperative mutation. Stable
collection and item IDs let Threading carry presentation state across a replacement or patch
without exposing AppKit or locking the API to today's sidebar structure. Out-of-order responses,
responses from an older process generation, mismatched navigator IDs, and invalid output are
rejected.

### Live session edges

Set `eventActionID` when existing rows expose live session state such as an activity spinner.
This opt-in also requires the `host.events` capability because the request identifies sessions
whose host-observed state changed:

```swift
ExtensionWorkspaceNavigator(
    id: "activity",
    title: "Activity",
    root: .collection(.init(
        id: "sessions",
        layout: .list,
        items: [
            .init(
                id: "session:s1",
                content: .status("Idle", role: .neutral),
                activation: .destination(.session(id: "s1", projectID: nil))
            )
        ]
    )),
    eventActionID: "session-event"
)
```

While that navigator is selected, Threading coalesces `SessionActivityDidChange` edges by session
ID and sends at most 64 IDs in one `ExtensionWorkspaceNavigatorHostEvent`. Decode the action's
`value`, refresh the affected presentation facts, and return at most 64
`ExtensionWorkspaceNavigatorItemPatch` values. For example, using the stable session-to-item map
that produced the current document:

```swift
let event = try ExtensionWorkspaceNavigatorHostEvent(
    actionValue: request.value ?? .emptyObject
)
let patches = event.sessionIDs.compactMap { sessionID in
    itemIDBySessionID[sessionID].map { itemID in
        ExtensionWorkspaceNavigatorItemPatch(
            collectionID: "sessions",
            itemID: itemID,
            content: .status("Running", role: .positive)
        )
    }
}
let response = ExtensionWorkspaceNavigatorActionResponse(
    requestID: request.requestID,
    navigatorID: request.navigatorID,
    itemPatches: patches.isEmpty ? nil : patches
)
```

An item patch replaces only `content` on an existing item. It cannot insert, remove, reorder,
reparent, select, enable, or change activation. Threading validates every target before applying
any patch, then reloads only affected virtual rows. An unknown collection or item fails the
selected process generation back to Native; structural change still requires a complete navigator
replacement. Only one event action is in flight, later edges remain coalesced, and a response
overtaken by newer document or action content is retried against the current document. Settings
pauses process dispatch and retains a bounded, container-owned catch-up set even if the process is
replaced. When the navigator returns, Threading performs its initial load or a document refresh
deferred under Settings before draining that catch-up set. A project refresh observed while
Settings is visible is latched without waking the extension process. The host retains at most 256
pending IDs beyond the in-flight batch; overflow or any event-action failure returns to Native
rather than presenting content which may be stale.

Call `validateForHostEvent()` on the response before encoding it. The shared response wire type
also serves ordinary actions, so its general `validate()` method permits a complete replacement;
the event-specific validator deliberately does not.

An event can name a session that the current document does not show, so return patches only for
IDs mapped to existing items. Declare `host.sessions.read` as well when the action reads sanitized
session snapshots to derive the new content; `host.events` alone grants the edge, not session data.

## Host destinations

Use `.destination(.project(id:))` or `.destination(.session(id:projectID:))` for normal
navigation. Threading resolves the UUID against its current store and sends it through the native
navigation coordinator, so history, selection, archived-session rules, and settings transitions
remain consistent whether Native or an extension navigator is visible.

Use `.action(id:)` for extension-owned behavior such as filters, inbox state, or changing the
document. Host destinations do not grant project/session read access; request the applicable
`host.*.read` capabilities if the extension needs to construct its snapshot from host data.

### Search and privacy

Continuous search remains intentionally explicit: use a text input action and return snapshots.
The protocol does not expose keystrokes, arbitrary timers, AppKit views, or a private route around
the host renderer.
