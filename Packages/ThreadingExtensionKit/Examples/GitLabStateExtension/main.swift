#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import GitLabStateExtensionSupport
import ThreadingExtensionKit

let manifest = GitLabStateExtensionContract.manifest
let registration = GitLabStateExtensionContract.registration
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
    let client = try ExtensionHostClient()
    let provider = GitLabStateProvider(
        host: GitLabExtensionHostAdapter(client: client),
        diagnostic: { @Sendable message in writeDiagnostic(message) }
    )
    await provider.run()

default:
    writeDiagnostic("Expected --threading-register or --threading-serve from the Threading host.")
    exit(64)
}
