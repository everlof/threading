#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import T3SidebarExtensionSupport
import ThreadingExtensionKit

let manifest = T3SidebarExtensionContract.manifest
let registration = T3SidebarExtensionContract.registration
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
    // Threading executes every declared row intent. Keeping stdin open retains the generation;
    // any action request would violate the pipeline contract.
    if readLine(strippingNewline: true) != nil {
        writeDiagnostic("T3 Sidebar received an unexpected action request.")
        exit(65)
    }

default:
    writeDiagnostic("Expected --threading-register or --threading-serve from the Threading host.")
    exit(64)
}
