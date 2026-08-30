#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import ActivityInboxExtensionSupport
import Foundation
import ThreadingExtensionKit

let manifest = ActivityInboxExtensionContract.manifest
let registration = ActivityInboxExtensionContract.registration
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
    // A pipeline navigator has no extension action route. Keeping stdin open retains the
    // generation which owns this declaration; any request would be a host/protocol mismatch.
    if readLine(strippingNewline: true) != nil {
        writeDiagnostic("Activity Inbox received an unexpected action request.")
        exit(65)
    }

default:
    writeDiagnostic("Expected --threading-register or --threading-serve from the Threading host.")
    exit(64)
}
