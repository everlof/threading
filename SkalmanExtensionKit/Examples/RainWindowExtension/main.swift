#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import SkalmanExtensionKit

let manifest = ExtensionManifest(
    identifier: "se.mjukis.skalman-rain",
    name: "Usage Rain",
    version: "0.1.0",
    runtime: .webAssembly,
    executable: "bin/usage-rain.wasm",
    capabilities: [
        .componentCustomization,
        .customMetalSurfaces
    ]
)

let rainHook = ExtensionComponentPatch(
    id: "usage-rain-window-hook",
    target: .init(
        component: .applicationMainWindow,
        contractVersion: 1
    ),
    hook: .overlay(
        base: .proceed,
        overlay: .customSurface(
            .metal(ExtensionMetalSurface(
                shaderResource: "Resources/usage-rain.metal",
                preferredFramesPerSecond: 60,
                inputs: [
                    .init(
                        name: "density",
                        value: .signal(
                            .activeAccountUsageRemaining,
                            mapping: .init(
                                outputMinimum: 1,
                                outputMaximum: 0.03,
                                curve: .easeIn,
                                fallback: 0
                            )
                        )
                    ),
                    .init(name: "opacity", value: .constant(0.46)),
                    .init(
                        name: "speed",
                        value: .signal(
                            .activeAccountUsageRemaining,
                            mapping: .init(
                                outputMinimum: 1.45,
                                outputMaximum: 0.35,
                                curve: .easeOut,
                                fallback: 0
                            )
                        )
                    )
                ]
            )),
            accessibilityLabel: nil
        )
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
try SkalmanComponentCatalog.applicationMainWindow.validate(rainHook)

switch Array(CommandLine.arguments.dropFirst()) {
case ["--skalman-register"]:
    try writeProtocolValue(registration)

case ["--skalman-serve"]:
    try writeProtocolValue(registration)
    let host = try ExtensionHostClient()
    try await host.publishComponentPatches([rainHook])

    // This extension has no interactive actions. Keeping stdin open ties its lifetime to the
    // supervised process; EOF means Skalman disabled, reloaded, or removed this generation.
    while readLine(strippingNewline: true) != nil {}

default:
    FileHandle.standardError.write(
        Data("Use --skalman-register or --skalman-serve.\n".utf8)
    )
    exit(64)
}
