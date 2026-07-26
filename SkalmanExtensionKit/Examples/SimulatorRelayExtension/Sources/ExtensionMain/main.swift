#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import SkalmanExtensionKit

let simulatorSurface = ExtensionRemoteSurface(
    id: "simulator-window",
    title: "Simulator",
    accessibilityLabel: "Live Simulator window",
    maximumWidth: 1_920,
    maximumHeight: 1_200,
    acceptsPointer: true,
    acceptsKeyboard: true
)

let simulatorCompanion = ExtensionCompanion(
    id: "simulator",
    bundlePath: "Companions/SimulatorRelayCompanion.app",
    activation: .onDemand,
    capabilities: [
        .processSpawn,
        .screenCapture,
        .inputControl,
        .remoteSurfaces
    ],
    surfaces: [simulatorSurface]
)

let manifest = ExtensionManifest(
    identifier: "se.mjukis.simulator-relay",
    name: "Simulator Relay",
    version: "0.1.0",
    runtime: .webAssembly,
    executable: "bin/simulator-relay.wasm",
    capabilities: [.panels],
    companions: [simulatorCompanion]
)

let registration = ExtensionRegistration(panels: [
    ExtensionPanel(
        id: "simulator",
        title: "Simulator",
        root: .stack(
            axis: .vertical,
            spacing: .medium,
            children: [
                .text("Simulator", role: .heading),
                .status(
                    "The Simulator companion is unavailable. Check Screen Recording and "
                        + "Accessibility permissions, then reload the extension.",
                    role: .warning
                )
            ]
        ),
        remoteSurface: .init(
            companionID: simulatorCompanion.id,
            surfaceID: simulatorSurface.id
        )
    )
])

func write<Value: Encodable>(_ value: Value) throws {
    var data = try JSONEncoder().encode(value)
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

try manifest.validate()
try registration.validate(for: manifest)

switch Array(CommandLine.arguments.dropFirst()) {
case ["--skalman-register"]:
    try write(registration)

case ["--skalman-serve"]:
    try write(registration)
    while readLine(strippingNewline: true) != nil {
        FileHandle.standardError.write(
            Data("Simulator Relay has no semantic panel actions.\n".utf8)
        )
    }

default:
    FileHandle.standardError.write(
        Data("Use --skalman-register or --skalman-serve.\n".utf8)
    )
    exit(64)
}
