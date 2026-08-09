// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ThreadingExtensionKit",
    // The extension process and authoring tools remain Mac-hosted. The semantic contract is also
    // consumed by the iOS remote client, which renders the same validated `ExtensionNode` tree
    // natively instead of receiving pixels or an HTML projection.
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(
            name: "ThreadingExtensionKit",
            targets: ["ThreadingExtensionKit"]
        ),
        .plugin(
            name: "ThreadingExtensionPolicyPlugin",
            targets: ["ThreadingExtensionPolicyPlugin"]
        ),
        .executable(
            name: "HelloStatusExtensionExample",
            targets: ["HelloStatusExtensionExample"]
        ),
        .executable(
            name: "HelloStatusConsumerExtensionExample",
            targets: ["HelloStatusConsumerExtensionExample"]
        ),
        .executable(
            name: "DenialProbeExtension",
            targets: ["DenialProbeExtension"]
        ),
        .executable(
            name: "RainWindowExtensionExample",
            targets: ["RainWindowExtensionExample"]
        ),
        .executable(
            name: "SessionInfoExtensionExample",
            targets: ["SessionInfoExtensionExample"]
        ),
        .executable(
            name: "SimulatorRelayExtensionExample",
            targets: ["SimulatorRelayExtensionExample"]
        ),
        .executable(
            name: "SimulatorRelayCompanionExample",
            targets: ["SimulatorRelayCompanionExample"]
        ),
        .executable(
            name: "ThreadingComponentCatalogGenerator",
            targets: ["ThreadingComponentCatalogGenerator"]
        )
    ],
    targets: [
        .target(
            name: "ThreadingExtensionKit",
            swiftSettings: [
                .enableExperimentalFeature(
                    "Extern",
                    .when(platforms: [.wasi])
                )
            ]
        ),
        .target(
            name: "ThreadingExtensionPolicy"
        ),
        .executableTarget(
            name: "ThreadingExtensionPolicyChecker",
            dependencies: ["ThreadingExtensionPolicy"]
        ),
        .plugin(
            name: "ThreadingExtensionPolicyPlugin",
            capability: .buildTool(),
            dependencies: ["ThreadingExtensionPolicyChecker"]
        ),
        .executableTarget(
            name: "HelloStatusExtensionExample",
            dependencies: ["ThreadingExtensionKit"],
            path: "Examples/HelloStatusExtension",
            exclude: ["threading-extension.json"],
            plugins: ["ThreadingExtensionPolicyPlugin"]
        ),
        .executableTarget(
            name: "HelloStatusConsumerExtensionExample",
            dependencies: ["ThreadingExtensionKit"],
            path: "Examples/HelloStatusConsumerExtension",
            exclude: ["threading-extension.json"],
            plugins: ["ThreadingExtensionPolicyPlugin"]
        ),
        // No policy plugin: the probe imports `Security` deliberately, to try the one thing a
        // real extension must never reach directly. It is a measuring instrument, not a
        // template — `HelloStatusExtension` is the template.
        .executableTarget(
            name: "DenialProbeExtension",
            dependencies: ["ThreadingExtensionKit"],
            path: "Examples/DenialProbeExtension",
            exclude: ["threading-extension.json"]
        ),
        .executableTarget(
            name: "StormThemeExtensionExample",
            dependencies: ["ThreadingExtensionKit"],
            path: "Examples/StormThemeExtension",
            exclude: ["threading-extension.json", "Resources", "Scripts"],
            plugins: ["ThreadingExtensionPolicyPlugin"]
        ),
        .executableTarget(
            name: "RainWindowExtensionExample",
            dependencies: ["ThreadingExtensionKit"],
            path: "Examples/RainWindowExtension",
            exclude: ["threading-extension.json", "Resources"],
            plugins: ["ThreadingExtensionPolicyPlugin"]
        ),
        .executableTarget(
            name: "SessionInfoExtensionExample",
            dependencies: ["ThreadingExtensionKit"],
            path: "Examples/SessionInfoExtension",
            exclude: ["threading-extension.json"],
            plugins: ["ThreadingExtensionPolicyPlugin"]
        ),
        .executableTarget(
            name: "SimulatorRelayExtensionExample",
            dependencies: ["ThreadingExtensionKit"],
            path: "Examples/SimulatorRelayExtension/Sources/ExtensionMain",
            plugins: ["ThreadingExtensionPolicyPlugin"]
        ),
        // The companion is deliberately outside the safe Wasm policy target: it is the
        // separately signed, sandboxed macOS process whose reviewed capabilities permit AppKit,
        // window capture, subprocess launch, and normalized input relay.
        .executableTarget(
            name: "SimulatorRelayCompanionExample",
            dependencies: ["ThreadingExtensionKit"],
            path: "Examples/SimulatorRelayExtension/Companion",
            exclude: [
                "Info.plist",
                "SimulatorRelayCompanion.entitlements"
            ]
        ),
        .executableTarget(
            name: "ThreadingComponentCatalogGenerator",
            dependencies: ["ThreadingExtensionKit"]
        ),
        .testTarget(
            name: "ThreadingExtensionKitTests",
            dependencies: [
                "ThreadingExtensionKit",
                "ThreadingExtensionPolicy"
            ]
        )
    ]
)
