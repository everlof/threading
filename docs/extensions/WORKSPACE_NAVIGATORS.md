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
- correlated, value-bearing runtime actions and optional `loadActionID` refreshes;
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
    preferredWidth: 280,
    loadActionID: "refresh"
)
```

The process receives an `ExtensionWorkspaceNavigatorActionRequest` with `navigatorID`,
`actionID`, optional `value`, and the current opaque project/session context. Return an
`ExtensionWorkspaceNavigatorActionResponse` naming the same navigator. A response may contain a
complete replacement navigator and/or a message, or an error by itself.

Replacement is intentionally whole-document rather than imperative mutation. Stable collection
and item IDs let Threading carry presentation state across the swap without exposing AppKit or
locking the API to today's sidebar structure. Out-of-order responses, responses from an older
process generation, mismatched navigator IDs, and invalid replacement documents are rejected.

## Host destinations

Use `.destination(.project(id:))` or `.destination(.session(id:projectID:))` for normal
navigation. Threading resolves the UUID against its current store and sends it through the native
navigation coordinator, so history, selection, archived-session rules, and settings transitions
remain consistent whether Native or an extension navigator is visible.

Use `.action(id:)` for extension-owned behavior such as filters, inbox state, or changing the
document. Host destinations do not grant project/session read access; request the applicable
`host.*.read` capabilities if the extension needs to construct its snapshot from host data.

Continuous search remains intentionally explicit: use a text input action and return snapshots.
The protocol does not expose keystrokes, arbitrary timers, AppKit views, or a private route around
the host renderer.
