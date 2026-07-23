# Skalman Extensions

Skalman extensions are intended to be authored by coding agents from a documented contract,
not by copying application internals. The default extension kind is therefore:

- an executable process rather than code loaded into Skalman;
- described by a manifest Skalman can inspect before executing it;
- compiled against the Foundation-only `SkalmanExtensionKit`;
- allowed to return semantic UI values, never AppKit or SwiftUI views;
- rendered by Skalman through the same theme boundary as built-in UI.

This keeps ordinary extensions isolated and lets the host retain control of themes,
accessibility, focus, motion, component state, and future visual changes.

## Current implementation status

The first contract layer exists:

- [`SkalmanExtensionKit`](../../SkalmanExtensionKit) defines manifests, capabilities,
  contributions, and the initial declarative UI nodes.
- [`SkalmanExtensionPolicyPlugin`](../../SkalmanExtensionKit/Plugins/SkalmanExtensionPolicyPlugin)
  fails the supported safe-extension build when source imports AppKit or SwiftUI.
- [`HelloStatusExtension`](../../SkalmanExtensionKit/Examples/HelloStatusExtension) is the
  compiling reference implementation.
- [`extension-manifest.schema.json`](schema/extension-manifest.schema.json) is the
  machine-readable manifest schema.
- [`extension-node.schema.json`](schema/extension-node.schema.json) is the machine-readable UI
  schema.

Skalman does not discover or run these executables yet. The process protocol and host renderer
are the next layer; the current types intentionally establish their shared data boundary first.

## Two extension tiers

### Safe extensions

The default. They run outside Skalman and use `SkalmanExtensionKit`. Their UI is an
`ExtensionNode` tree rendered by the host. The extension cannot inject a view into Skalman.

The build plugin is correctness enforcement for generated source, not the security boundary.
Process isolation and the absence of any view-bearing protocol are the security boundary.

### Native extensions

A later, explicitly trusted tier may return an `NSViewController` and use selected components
from a public native design framework. Native extensions will run in Skalman's process, can
crash it, cannot be reliably hot-unloaded, and will require signing and compatibility policy.
They are an escape hatch, not the default authoring model.

## Design rules

1. A contribution describes meaning. Skalman chooses pixels.
2. Capabilities are declared before the extension runs.
3. Manifests and wire values remain inspectable when they contain a capability newer than the
   host.
4. Stable extension API is smaller than Skalman's internal design system.
5. The reference example and schemas are normative. Prose explains them but does not override
   them.
6. New UI vocabulary is added only for a real extension that cannot express its interface with
   existing nodes.

## Repository layout

```text
SkalmanExtensionKit/
├── Package.swift
├── Sources/SkalmanExtensionKit/
├── Plugins/SkalmanExtensionPolicyPlugin/
├── Examples/HelloStatusExtension/
└── Tests/SkalmanExtensionKitTests/

docs/extensions/
├── README.md
├── AGENT_AUTHORING.md
└── schema/
```

## Validation

From the repository root:

```bash
swift build --package-path SkalmanExtensionKit
swift test --package-path SkalmanExtensionKit
swift run --package-path SkalmanExtensionKit HelloStatusExtensionExample
```

The example target uses the same policy plugin generated extensions must use.
