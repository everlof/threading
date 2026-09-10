#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import ThreadingExtensionKit

// Sidebar Aurora: a live surface *under* the project sidebar.
//
// This is the smallest possible `sidebar.backdrop@1` extension, and the shape of the patch is
// the whole lesson. The contract requires an `overlay` whose top is `.proceed` — the sidebar's
// own brand row, list and footer — so everything the extension draws lands beneath them. The
// window hook (`RainWindowExtension`) is the same node the other way up: there the surface
// goes *over* `.proceed`, because rain falls in front of things. A backdrop does not.
//
// What the host keeps, whatever the shader does:
//
//   - the whole tree is composited below an opacity ceiling, so the rows keep a floor of their
//     own contrast — the shader's alpha is a request, not the final word;
//   - the frame rate is clamped to the contract's ceiling (30 here; this asks for 24), and the
//     surface holds its frames while the window is occluded, miniaturized or hidden;
//   - under Reduce Motion the surface's clock stops at zero;
//   - nothing beneath the rows can be clicked, hovered or read by VoiceOver.
//
// The shader binds `workload.intensity`, the same 0...1 envelope the sidebar's workload
// analyzer draws, so the aurora brightens as agents work and settles when they stop — without
// this extension ever reading a session, a transcript or a clock.

let manifest = ExtensionManifest(
    identifier: "codes.threading.examples.aurora",
    name: "Sidebar Aurora",
    version: "0.1.0",
    runtime: .webAssembly,
    executable: "bin/sidebar-aurora.wasm",
    capabilities: [
        .componentCustomization,
        .customMetalSurfaces
    ]
)

let auroraHook = ExtensionComponentPatch(
    id: "sidebar-aurora",
    target: .sidebarBackdrop(),
    hook: .overlay(
        base: .customSurface(
            .metal(ExtensionMetalSurface(
                shaderResource: "Resources/aurora.metal",
                preferredFramesPerSecond: 24,
                inputs: [
                    .init(
                        name: "energy",
                        value: .signal(
                            .workloadIntensity,
                            mapping: .init(
                                outputMinimum: 0.15,
                                outputMaximum: 1,
                                curve: .easeOut,
                                fallback: 0.15
                            )
                        )
                    ),
                    .init(name: "opacity", value: .constant(0.5)),
                    .init(
                        name: "hour",
                        value: .signal(.timeOfDayFraction, mapping: .identity)
                    )
                ]
            )),
            accessibilityLabel: nil
        ),
        overlay: .proceed
    )
)

let registration = ExtensionRegistration()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

func writeProtocolValue<Value: Encodable>(_ value: Value) throws {
    var data = try encoder.encode(value)
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

try manifest.validate()
try registration.validate(for: manifest)
try ThreadingComponentCatalog.sidebarBackdrop.validate(auroraHook)

switch Array(CommandLine.arguments.dropFirst()) {
case ["--threading-register"]:
    try writeProtocolValue(registration)

case ["--threading-serve"]:
    try writeProtocolValue(registration)
    let host = try ExtensionHostClient()
    try await host.publishComponentPatches([auroraHook])

    // No interactive actions. Keeping stdin open ties the process to the supervised
    // generation; EOF means Threading disabled, reloaded, or removed this generation, and the
    // host takes the backdrop down with it.
    while readLine(strippingNewline: true) != nil {}

default:
    FileHandle.standardError.write(
        Data("Use --threading-register or --threading-serve.\n".utf8)
    )
    exit(64)
}
