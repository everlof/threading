// swift-tools-version: 5.9

import PackageDescription

// The Linux build of `threading-mcp-bridge`.
//
// **The Xcode project remains the build of the bridge the app embeds.** This manifest exists for
// the same reason `Targets/PTYHost/Package.swift` does: a remote execution host runs a static Linux
// build of the bridge, so an agent there reaches Threading's tools through a socket forwarded back
// to the Mac (`docs/feature-drafts/remote-execution-hosts.md`, slice 4). `scripts/test-ptyd-linux.sh`
// builds it beside the daemon. The bridge links Foundation and nothing else on either system.
//
// Nothing here is referenced by `Threading.xcodeproj`.
let package = Package(
    name: "ThreadingMCPBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "threading-mcp-bridge", targets: ["ThreadingMCPBridge"])
    ],
    targets: [
        .executableTarget(
            name: "ThreadingMCPBridge",
            path: ".",
            exclude: [
                "Info.plist",
                "threading-mcp-bridge.entitlements"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
