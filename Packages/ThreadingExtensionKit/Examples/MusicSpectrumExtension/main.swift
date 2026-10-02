#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import ThreadingExtensionKit

// A real music-driven sidebar backdrop. The host supplies every band at draw time;
// this process has no audio device, recording, source identity, or high-frequency IPC.
let manifest = ExtensionManifest(
    identifier: "codes.threading.examples.music-spectrum",
    name: "Music Spectrum",
    version: "0.1.0",
    runtime: .webAssembly,
    executable: "bin/music-spectrum.wasm",
    capabilities: [.componentCustomization, .customMetalSurfaces]
)

let patch = ExtensionComponentPatch(
    id: "music-spectrum",
    target: .sidebarBackdrop(),
    hook: .overlay(
        base: .customSurface(.metal(ExtensionMetalSurface(
            shaderResource: "Resources/spectrum.metal",
            preferredFramesPerSecond: 30,
            inputs: ExtensionHostSignal.audioBands.enumerated().map { index, signal in
                .init(name: "band.\(index)", value: .signal(signal, mapping: .identity))
            }
        )), accessibilityLabel: nil),
        overlay: .proceed
    )
)
let registration = ExtensionRegistration()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
func write<Value: Encodable>(_ value: Value) throws {
    var data = try encoder.encode(value)
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

try manifest.validate()
try registration.validate(for: manifest)
try ThreadingComponentCatalog.sidebarBackdrop.validate(patch)
switch Array(CommandLine.arguments.dropFirst()) {
case ["--threading-register"]:
    try write(registration)
case ["--threading-serve"]:
    try write(registration)
    try await ExtensionHostClient().publishComponentPatches([patch])
    while readLine(strippingNewline: true) != nil {}
default:
    FileHandle.standardError.write(Data("Use --threading-register or --threading-serve.\n".utf8))
    exit(64)
}
