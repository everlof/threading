#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import ForgejoSourceControlExtensionSupport
import Foundation
import ThreadingExtensionKit

let manifest = ForgejoSourceControlExtensionContract.manifest
let registration = ForgejoSourceControlExtensionContract.registration
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

func writeProtocolValue<Value: Encodable>(_ value: Value) throws {
    var data = try encoder.encode(value)
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

func writeDiagnostic(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
}

try manifest.validate()
try registration.validate(for: manifest)

switch Array(CommandLine.arguments.dropFirst()) {
case ["--threading-register"]:
    try writeProtocolValue(registration)

case ["--threading-serve"]:
    try writeProtocolValue(registration)
    let provider = ForgejoSourceControlProvider(
        host: ForgejoSourceControlHostAdapter(client: try ExtensionHostClient())
    )
    while let line = readLine(strippingNewline: true) {
        guard line.utf8.count <= ForgejoSourceControlLimits.maximumProtocolLineBytes,
              let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(
                ExtensionSourceControlRequest.self,
                from: data
              ) else {
            writeDiagnostic("Forgejo Source Control received an invalid host request.")
            exit(65)
        }
        let response = await provider.handle(request)
        try response.validate()
        try writeProtocolValue(response)
    }

default:
    writeDiagnostic("Expected --threading-register or --threading-serve from the Threading host.")
    exit(64)
}
