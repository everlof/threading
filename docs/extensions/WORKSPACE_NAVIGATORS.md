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
navigator replacement must repeat the original localized declaration exactly, so only a new
process generation can change the meaning of a stored value.

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
