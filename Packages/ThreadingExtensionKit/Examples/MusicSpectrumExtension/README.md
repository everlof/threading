# Music Spectrum

A minimal safe extension drawing eight measured frequency bands beneath the sidebar.
It works with any app theme; enable **Motion → Music-reactive themes** and select an audio
source in Threading. Capture needs macOS 14.2+ and system-audio permission. A theme/extension
never enables capture by publishing a binding, and receives no raw audio or source identity.

The eight scalar inputs use the existing `values[8]` Metal ABI. Their frequency ranges are
20–80, 80–200, 200–500, 500–1,200, 1,200–3,000, 3,000–6,000, 6,000–12,000 and
12,000–20,000 Hz. Input defaults are zero, so unavailable capture draws no bars. The shader
has no clock-driven movement. Visibility, Reduce Motion, Theme animations and power gates
remain host-owned; the sidebar contract also retains passthrough input and its opacity ceiling.

From the SDK package, validate the example with these commands. Use the open-source Swift
toolchain matching the installed Wasm SDK for the second command; Apple's Xcode toolchain
does not include the WebAssembly target.

```sh
swift run MusicSpectrumExtensionExample --threading-register
swift build -c release --swift-sdk <installed-wasi-sdk-id> --product MusicSpectrumExtensionExample
```

For distribution, scaffold a project using Threading's extension authoring tools, vendor this
SDK snapshot and public docs, copy `main.swift` and `Resources/`, and use its `Scripts/package.sh`
to produce a complete source-bundled package. Do not install a native example executable as Wasm.

Ordinary theme JSON can adopt the host's compact analyzer without a shader:

```json
"sidebar": { "brand": { "analyzer": "audio" } }
```

The create/update theme tools expose the same choice as `sidebar.analyzer: "audio"`.
