# SkalmanExtensionKit

The Foundation-only contract between Skalman and safe, out-of-process extensions.

The package contains:

- inspectable extension manifests and capabilities;
- semantic command and panel contributions;
- a Codable `ExtensionNode` UI tree rendered by Skalman;
- validation with machine-readable field paths;
- a SwiftPM build-tool plugin that rejects AppKit and SwiftUI imports;
- a compiling reference extension.

It deliberately contains no AppKit or SwiftUI dependency. Read
[`docs/extensions/AGENT_AUTHORING.md`](../docs/extensions/AGENT_AUTHORING.md) before generating
an extension.

```bash
swift build --package-path SkalmanExtensionKit
swift test --package-path SkalmanExtensionKit
swift run --package-path SkalmanExtensionKit HelloStatusExtensionExample
```

The process transport and Skalman host renderer have not been implemented yet. This package is
their shared data boundary.
