---
title: Extensions
description: Add commands, panels, tools, services, themes, and fonts through declared capabilities.
group: Customize
order: 80
---

# Extensions

Extensions add focused capabilities to the app. A standard extension is a
WebAssembly module that declares its permissions, calls only the host
functions it declared, and describes its interface as semantic components
that the app draws.

## Extension points

An extension can contribute one or more declared capabilities:

- **Commands** add focused actions to the command palette.
- **Panels** present project information in native host surfaces, including
  a workspace navigator beside the sidebar.
- **Agent tools** expose named operations an agent can discover and call.
- **Services** observe approved lifecycle events or maintain useful context.
- **Components** compose richer views from a constrained semantic vocabulary.
- **Themes and fonts** add visual identities without taking over feature
  layout or behavior.

The manifest names the extension, its contributions, and the permissions each
capability requires.

## The standard path

Most extensions use the standard WebAssembly runtime:

1. declare capabilities and resource permissions;
2. let the user review the request;
3. execute inside the capability-scoped host;
4. ask the host to render semantic interface output.

Extensions settings also has a small **From Threading** section of reviewed
packages included in the app. There is no public marketplace. The source link
opens an HTTPS Git page for inspection, but Threading installs the app-bundled
copy and never clones or builds from Git. Installation still shows the
complete review and leaves the extension disabled until you enable it. Storm
is the first included extension.

Because the host draws the components, extension UI keeps the app's
accessibility, keyboard behavior, and theme, and an extension cannot bring a
second design system into the app.

## Companion extensions

Some integrations need a long-running native process or system access that a
WebAssembly module cannot provide. A Companion extension runs as a separate
executable, declares each operating-system capability it wants, and requires a
separate trust decision. Threading asks macOS only for the grants those
reviewed capabilities cover.

Use a Companion only when the standard capability model cannot do the job. It
still follows the normal extension boundaries.

## Native plugins

A native plugin is a different tier: a signed code bundle that Threading loads
into its own process, with full AppKit and no sandbox. It can fill a pane or
the workspace navigator and give agents tools of its own, and it receives the
app's theme and design-system components. The Device Logs pane ships this way.
Plugins bundled inside the app are trusted because the app's signature seals
them. Any other plugin, including one of ours installed separately, is refused
until you approve it. There is no install flow for plugins from other
developers yet.

## Authoring reference

Extension developers should read
[the authoring guide](../extensions/AGENT_AUTHORING.md) and the
[API v1 reference](../extensions/API_V1.md) instead of inferring behavior from
application internals.
