// swift-tools-version: 5.9

import PackageDescription
import Foundation

let sdkPath = ProcessInfo.processInfo.environment["THREADING_EXTENSION_SDK_PATH"]
    ?? "Vendor/ThreadingExtensionKit"

// The dogfood extension is intentionally also a standalone author project. Building the SDK's
// umbrella package for WASI would ask SwiftPM to reason about its macOS-only example products;
// a real extension instead depends on the SDK and exposes only its safe Wasm core here.
let package = Package(
    name: "SimulatorRelayExtension",
    products: [
        .executable(name: "ExtensionMain", targets: ["ExtensionMain"])
    ],
    dependencies: [
        .package(path: sdkPath)
    ],
    targets: [
        .executableTarget(
            name: "ExtensionMain",
            dependencies: [
                .product(
                    name: "ThreadingExtensionKit",
                    package: "ThreadingExtensionKit"
                )
            ],
            plugins: [
                .plugin(
                    name: "ThreadingExtensionPolicyPlugin",
                    package: "ThreadingExtensionKit"
                )
            ]
        )
    ]
)
