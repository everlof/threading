---
title: Extensions
description: Add commands, panels, tools, services, themes, and fonts through declared capabilities.
group: Customize
order: 80
---

# Extensions

Extensions add focused capabilities to the app. The public model favors
portable WebAssembly, declared permissions, narrow host functions, and
semantic interface components rendered by the host.

## Extension points

An extension can contribute one or more declared capabilities:

- **Commands** add focused actions to the command palette.
- **Panels** present project information in native host surfaces.
- **Agent tools** expose named operations an agent can discover and call.
- **Services** observe approved lifecycle events or maintain useful context.
- **Components** compose richer views from a constrained semantic vocabulary.
- **Themes and fonts** add visual identities without taking over feature
  layout or behavior.

The manifest names the extension, its contributions, and the permissions each
capability requires.

## The standard path

Most extensions should use the standard portable runtime:

1. declare capabilities and resource permissions;
2. let the user review the request;
3. execute inside the capability-scoped host;
4. ask the host to render semantic interface output.

At launch, Extensions settings also has a small **From Threading** section. These are reviewed
packages included in the app rather than a public marketplace: the source link opens an HTTPS Git
page for inspection, but Threading installs the app-bundled copy and never clones or builds from
Git. Installation still shows the complete review and leaves the extension disabled until the
user enables it. Storm is the initial included extension.

Host-rendered components preserve accessibility, keyboard behavior, and theme
compatibility. They also keep an extension from creating an unrelated second
design system inside the app.

## Companion extensions

Some integrations need a long-running native process or system access that a
portable module cannot provide. A Companion extension makes that tradeoff
explicit and requires a separate trust decision.

Use a Companion only when the standard capability model is genuinely
insufficient. Its broader execution model is an advanced tier, not a shortcut
around normal extension boundaries.

## Authoring reference

Extension developers should read
[the authoring guide](../extensions/AGENT_AUTHORING.md) and
[API v1 reference](../extensions/API_V1.md) before inferring behavior from
application internals.
