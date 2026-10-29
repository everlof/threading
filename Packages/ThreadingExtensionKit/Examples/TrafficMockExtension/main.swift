#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import ThreadingExtensionKit

// The fixture is manifest data. No request or proxy socket reaches this process.
let manifest = ExtensionManifest(
    identifier: "codes.threading.example.traffic-mock",
    name: "Traffic Mock Example",
    version: "0.1.0",
    runtime: .webAssembly,
    executable: "bin/traffic-mock.wasm",
    capabilities: [.trafficMockResponses],
    trafficMocks: [
        ExtensionTrafficMock(
            host: "127.0.0.1", port: 8080, method: "GET", path: "/v1/items",
            status: 200, headers: ["Content-Type": "application/json"],
            body: "{\"items\":[]}"
        )
    ]
)
let registration = ExtensionRegistration()
try manifest.validate()
try registration.validate(for: manifest)

var output = try JSONEncoder().encode(registration)
output.append(0x0A)
switch Array(CommandLine.arguments.dropFirst()) {
case ["--threading-register"]:
    try FileHandle.standardOutput.write(contentsOf: output)
case ["--threading-serve"]:
    try FileHandle.standardOutput.write(contentsOf: output)
    while readLine(strippingNewline: true) != nil {}
default:
    exit(64)
}
