# Simulator Relay dogfood extension

This is an advanced extension built only from Skalman's generic public contracts:

- the WebAssembly core contributes one ordinary panel;
- its on-demand companion opts into process launch, screen capture, input control, and remote
  surfaces;
- the companion finds and captures the Simulator window, sends bounded BGRA8 frames, and maps
  normalized panel input back to that window.

There is no Simulator-specific API in Skalman. The example is deliberately a window relay so the
same primitives can support another simulator, a device tool, or a separately rendered native
surface.

## Build the distributable package

Cross-compiling requires a Swift.org toolchain and an exactly matching official WebAssembly SDK;
Xcode's Apple Swift toolchain is not sufficient on macOS.

```bash
Scripts/package.sh swift-6.3.2-RELEASE_wasm
```

The script automatically prefers Swiftly's standard Swift.org toolchain path. Set
`SKALMAN_SWIFT_EXEC` only when that toolchain lives elsewhere.

The script produces
`Build/se.mjukis.simulator-relay.skalmanextension`. It builds a real Wasm module, constructs and
signs the nested sandboxed companion app with hardened runtime, and retains this complete
project plus a vendored SDK and its complete authoring contract under `Source/`. A new agent
working only from the package starts at
`Source/Vendor/docs/extensions/AGENT_AUTHORING.md`; the API freeze, schemas, and generated
component catalogue are beside it.

Import the package from Settings ▸ Extensions. It installs disabled; review the core and
companion capabilities, enable it, then choose **Simulator** from the display-pane `+` menu.
macOS attributes Screen Recording and Accessibility for the directly supervised companion to
Skalman. Skalman requests only the grants represented by the reviewed companion capabilities
before starting it; the companion defensively preflights them again before capture or input.

## Run the opt-in product-boundary test

With a Simulator window open:

```bash
xcodebuild -project ../../../Skalman.xcodeproj -scheme Skalman \
  -destination 'platform=macOS' test \
  DEVELOPMENT_TEAM=SMQ3E8Y57T CODE_SIGN_IDENTITY='Apple Development' \
  -only-testing:SkalmanTests/ExtensionBundleLoaderTests/testSimulatorRelayDogfoodProducesARealFrameAndAcceptsInput
```

The test uses the production bundle inspector, signature checks, companion supervisor, and
remote-surface channel. It discovers the package under `Build/` and saves the first relayed
frame as `/tmp/skalman-simulator-relay-frame.png` for visual inspection. Run it from a
development-signed Skalman build: an ad-hoc Debug signature changes identity whenever the app is
rebuilt, making a Screen Recording grant immediately stale.
