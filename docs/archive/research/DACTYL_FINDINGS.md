# Archived Dactyl technical findings

> Research snapshot: 2026-08-25. This record summarizes the public site, documentation, and
> browser-served source inspected on that date. It is provenance, not a current product claim;
> re-check Dactyl before relying on availability, compatibility, or effort comparisons.

## The short answer

Dactyl appeared to be an AI app builder around a clean-room, SwiftUI-compatible runtime. It
compiled Swift to WebAssembly for an interactive browser preview, rendered that preview through a
custom display-list engine, then compiled the same source against Apple SwiftUI for native iOS or
against a custom Android host. Apple SwiftUI itself was not running in the browser.

```text
prompt -> coding agent -> Swift source
                            |
                            +-> Swift/Wasm + Dactyl UI runtime
                            |      -> binary display list -> Canvas/WebGPU preview
                            |
                            +-> Xcode + Apple SwiftUI -> signed native iOS build
                            |
                            +-> native Swift + Kotlin/JNI host -> Android APK
```

## What the public implementation showed

- The browser path cross-compiled generated Swift against Dactyl's own module named `SwiftUI`.
  The resulting Wasm included application code, state/layout machinery, Foundation shims, and the
  Swift runtime.
- The Swift side emitted compact drawing opcodes for text, rounded fills, symbols, maps, camera,
  video, glass, buttons, and text input. JavaScript decoded them and rendered primarily with
  Canvas 2D, with WebGPU for shader/3D work and DOM overlays for native input and accessibility.
- Browser services such as fetch, WebSockets, camera, location, microphone, maps, images, and
  OAuth crossed a Wasm-to-host bridge.
- The preview was a compatibility implementation calibrated toward SwiftUI, not Apple's private
  renderer. Public source included typography metrics, safe-area/device geometry, symbol assets,
  pixel snapping, and parity machinery.
- Native iOS builds used cloud Macs, Xcode, Apple frameworks, signing, and device/TestFlight
  delivery. Android used native Swift behind a Kotlin/JNI host and custom-rendered UI rather than
  a WebView or ordinary Compose widgets.
- A cacheable base Wasm module plus a smaller application side module shortened the edit loop.
  The public dynamic loader handled Swift/Wasm relocations and protocol-conformance records and
  could preserve state across reloads.
- The surrounding editor used comparatively conventional web technology: React/Vite, Tailwind,
  Monaco, an agent WebSocket, and Cloudflare-backed services. The novel investment was the
  compiler/runtime/rendering stack rather than the editor shell.

The consequence is a hard compatibility boundary: a preview can use only the frameworks and
behaviors Dactyl has implemented or bridged. At the time of the snapshot, its documentation named
HealthKit, WeatherKit, notifications, persistent SwiftData, and some MapKit paths as unsupported or
preview-limited.

## Effort assessment

No public staffing history established the actual investment. The following ranges were an
engineering inference from the breadth and maturity of the served implementation:

| Scope | Dated estimate | What the estimate includes |
| --- | ---: | --- |
| Visible product | 10-25 engineer-years | Runtime, agents, editor, backend, accounts, builds, signing, Android, and operations |
| Swift/Wasm UI runtime alone | 4-8 engineer-years | Compatibility API, layout/state, renderer, bridges, dynamic linking, parity, and performance |
| Small useful competitor | 6-10 engineers for 12-24 months | Useful component subset, reliable agent loop, native publishing, backend, and accounts |
| Comparable platform | 10+ engineers for several years | Broad compatibility, both native platforms, device APIs, security, performance, and operations |

These are order-of-magnitude planning ranges, not disclosed headcount or a valuation of the
company.

## POC boundaries

Different demonstrations prove very different things:

| POC | Dated estimate | What it proves |
| --- | ---: | --- |
| Product illusion | 1-2 engineers, 3-6 weeks | A typed/JSON UI previews in React while separate SwiftUI is exported |
| Real Swift/Wasm | 2-3 engineers, 2-4 months | Swift compiles to Wasm and a small set of text, stacks, buttons, and state is interactive |
| Convincing builder | 3-5 engineers, 4-8 months | Navigation, scrolling, forms, images, networking, reload, and an agent loop |
| Native iOS vertical slice | 5-7 engineers, 6-12 months | Browser preview plus cloud Xcode build, signing, and device installation |

The recommended POC was deliberately narrower than Dactyl's technical breakthrough:

1. Have the model generate a constrained typed UI document.
2. Render that document with an ordinary browser client.
3. Generate equivalent SwiftUI from the same document.
4. Compile the SwiftUI project on a Mac and deliver a genuine native build.
5. Add direct Swift editing only after the product loop proves useful.

That tests `prompt -> preview -> iterate -> native build` in roughly four to eight weeks without
committing to a clean-room SwiftUI implementation. A real Swift/Wasm proof is closer to a
multi-month compiler/runtime project; arbitrary AI-generated SwiftUI compatibility is the
multi-year part.

## Sources inspected

- Dactyl introduction: <https://dactyl.dev/docs/introduction/>
- Browser/runtime entry point: <https://dactyl.dev/src/sdk/src/runtime.mjs>
- Generated opcode decoder: <https://dactyl.dev/src/host/generated/opcodes.js>
- Canvas renderer: <https://dactyl.dev/src/host/src/renderer.mjs>
- Swift browser bridge: <https://dactyl.dev/src/Sources/SwiftUI/Render/Kernel.swift>
- Native host bridge: <https://dactyl.dev/src/Sources/SwiftUI/Render/Host.swift>
- Swift/Wasm dynamic loader: <https://dactyl.dev/src/host/src/dynloader.mjs>
- Device-build documentation: <https://dactyl.dev/docs/run-on-device/>
- Preview limitations: <https://dactyl.dev/docs/device/>
- Cloud/auth documentation and implementation: <https://dactyl.dev/docs/auth/> and
  <https://dactyl.dev/src/Sources/SwiftUI/Cloud.swift>
