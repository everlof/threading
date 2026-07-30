import Foundation
import ThreadingExtensionKit

let statusDependency = ExtensionServiceDependency(
    providerIdentifier: "codes.threading.hello-status",
    serviceID: "status",
    version: 1,
    required: true
)

let manifest = ExtensionManifest(
    identifier: "codes.threading.hello-status-consumer",
    name: "Hello Status Consumer",
    version: "0.1.0",
    runtime: .webAssembly,
    executable: "bin/hello-status-consumer.wasm",
    capabilities: [
        .commands,
        .servicesConsume
    ],
    serviceDependencies: [statusDependency]
)

let command = ExtensionCommand(
    id: "read-hello-status",
    title: "Read Hello Status service",
    description: "Calls the brokered status service from the Hello Status extension."
)

func registration() -> ExtensionRegistration {
    ExtensionRegistration(commands: [command])
}

func writeProtocolValue<Value: Encodable>(_ value: Value) throws {
    var data = try JSONEncoder().encode(value)
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

switch Array(CommandLine.arguments.dropFirst()) {
case ["--threading-register"]:
    try manifest.validate()
    try registration().validate(for: manifest)
    try writeProtocolValue(registration())

case ["--threading-serve"]:
    try manifest.validate()
    try registration().validate(for: manifest)
    try writeProtocolValue(registration())
    let host = try ExtensionHostClient()

    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(
                  ExtensionCommandRequest.self,
                  from: data
              ) else {
            FileHandle.standardError.write(Data("Unsupported request.\n".utf8))
            exit(65)
        }
        try request.validate()

        let response: ExtensionCommandResponse
        do {
            let value = try await host.callService(
                providerIdentifier: statusDependency.providerIdentifier,
                serviceID: statusDependency.serviceID,
                version: statusDependency.version
            )
            let encoded = String(
                decoding: try JSONEncoder().encode(value),
                as: UTF8.self
            )
            response = ExtensionCommandResponse(
                requestID: request.requestID,
                commandID: request.commandID,
                message: "Hello Status returned \(encoded)."
            )
        } catch {
            response = ExtensionCommandResponse(
                requestID: request.requestID,
                commandID: request.commandID,
                error: error.localizedDescription
            )
        }
        try response.validate()
        try writeProtocolValue(response)
    }

default:
    FileHandle.standardError.write(
        Data("Use --threading-register or --threading-serve.\n".utf8)
    )
    exit(64)
}
