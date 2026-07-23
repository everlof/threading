# Agent Contract: Authoring a Safe Skalman Extension

This document is written for an AI creating or changing a Skalman extension. Follow it
literally. Do not infer APIs from Skalman's application source.

## Before writing code

1. Read this complete document.
2. Read `docs/extensions/schema/extension-manifest.schema.json`.
3. Read `docs/extensions/schema/extension-node.schema.json` when contributing UI.
4. Use `SkalmanExtensionKit/Examples/HelloStatusExtension` as the source template.
5. Do not copy types from `Sources/Skalman`.

## Required extension layout

```text
MyExtension/
├── Package.swift
├── skalman-extension.json
└── Sources/MyExtension/main.swift
```

The manifest is read before the executable starts:

```json
{
  "formatVersion": 1,
  "identifier": "com.example.my-extension",
  "name": "My Extension",
  "version": "0.1.0",
  "executable": "bin/my-extension",
  "capabilities": ["commands", "panels"]
}
```

Rules:

- `identifier` is lowercase reverse DNS with at least two components.
- `executable` is relative to the installed extension directory.
- `executable` must not contain `.` or `..` path components.
- Declare `commands` before registering commands.
- Declare `panels` before registering panels.
- Unknown capabilities are not permission.
- Use contribution identifiers beginning with a lowercase letter and containing only lowercase
  letters, digits, `-`, or `.`.

## Required package policy

The executable target must use `SkalmanExtensionPolicyPlugin`. Do not remove it to make a build
pass.

```swift
.executableTarget(
    name: "MyExtension",
    dependencies: [
        .product(
            name: "SkalmanExtensionKit",
            package: "SkalmanExtensionKit"
        )
    ],
    plugins: [
        .plugin(
            name: "SkalmanExtensionPolicyPlugin",
            package: "SkalmanExtensionKit"
        )
    ]
)
```

## Forbidden in a safe extension

Do not:

- import AppKit;
- import SwiftUI;
- construct `NSView`, `NSViewController`, `View`, or platform controls;
- access Skalman application internals;
- assume a theme colour, font, size, radius, or animation duration;
- encode raw HTML as a substitute for an unsupported UI node;
- add a capability merely to silence validation;
- remove validation or the policy plugin.

If a requested interface cannot be expressed, report the missing semantic component. That is
an SDK design input, not permission to bypass the host renderer.

## Constructing UI

Return meaning through `ExtensionNode`:

```swift
let root = ExtensionNode.stack(
    axis: .vertical,
    spacing: .medium,
    children: [
        .text("Deployment", role: .heading),
        .status("Ready", role: .positive),
        .button(
            id: "deploy",
            title: "Deploy",
            role: .primary,
            isEnabled: true
        )
    ]
)
```

Skalman decides how heading text, positive status, primary actions, spacing, focus,
accessibility, and live theme changes render.

## Completion checklist

Before reporting an extension complete:

1. Call `manifest.validate()`.
2. Call `registration.validate(for: manifest)`.
3. Run `swift build`.
4. Run `swift test` when the extension has tests.
5. Confirm the policy plugin ran.
6. Confirm every registered contribution has its required capability.
7. Report any SDK node the requested interface still needs.

Do not claim the extension can be installed into Skalman until the repository contains the host
discovery and process runtime. At the current implementation stage, extensions can compile and
validate their contract but Skalman does not launch them.
