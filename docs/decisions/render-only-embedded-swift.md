# Render-only Embedded Swift extension SDK

Date: 2026-10-04. Decision: prototype a separate small protocol target before changing the SDK.

The existing release extension pays about 68 MB, including roughly 38 MB of Foundation data
(the measured breakdown is in [the extension guide](../extensions/README.md)). Its Foundation,
Codable, JSONEncoder/Decoder and FileHandle dependencies cross many SDK types. Removing one
import does not make that API usable in Embedded Swift.

A local feasibility probe used Swift SDK `swift-6.3.3-RELEASE_wasm-embedded`, a Swift tools 6.3
executable with no dependencies and this complete source:

```swift
print("{\"protocolVersion\":1,\"patches\":[]}")
```

Command: `swift build --disable-sandbox -c release --swift-sdk swift-6.3.3-RELEASE_wasm-embedded`.
It compiled and linked in 0.73 seconds, producing a 21,272-byte `wasm32-unknown-wasip1` executable.
This is a toolchain feasibility result, **not an equivalent extension benchmark**. The probe
does not read a request, implement the current protocol, exercise rendering or run in the host;
no standalone Wasm runner was available for that measurement.

The next prototype should isolate the existing line protocol and a bounded JSON reader/writer,
then expose only typed render patches and required lifecycle messages. It should keep host
validation, resource admission and capability policy unchanged. Compare one real render-only
extension built both ways: module bytes, cold host load, patch output equivalence and resident
memory. Do not replace the Foundation SDK or advertise compatibility until those checks pass.
Extensions needing the full SDK retain it; a second mode must not silently omit capabilities.
