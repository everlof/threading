// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SkalmanExtensionKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "SkalmanExtensionKit",
            targets: ["SkalmanExtensionKit"]
        ),
        .plugin(
            name: "SkalmanExtensionPolicyPlugin",
            targets: ["SkalmanExtensionPolicyPlugin"]
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
            name: "SkalmanComponentCatalogGenerator",
            targets: ["SkalmanComponentCatalogGenerator"]
        )
    ],
    targets: [
        .target(
            name: "SkalmanExtensionKit",
            swiftSettings: [
                .enableExperimentalFeature(
                    "Extern",
                    .when(platforms: [.wasi])
                )
            ]
        ),
        .target(
            name: "SkalmanExtensionPolicy"
        ),
        .executableTarget(
            name: "SkalmanExtensionPolicyChecker",
            dependencies: ["SkalmanExtensionPolicy"]
        ),
        .plugin(
            name: "SkalmanExtensionPolicyPlugin",
            capability: .buildTool(),
            dependencies: ["SkalmanExtensionPolicyChecker"]
        ),
        .executableTarget(
            name: "HelloStatusExtensionExample",
            dependencies: ["SkalmanExtensionKit"],
            path: "Examples/HelloStatusExtension",
            exclude: ["skalman-extension.json"],
            plugins: ["SkalmanExtensionPolicyPlugin"]
        ),
        .executableTarget(
            name: "HelloStatusConsumerExtensionExample",
            dependencies: ["SkalmanExtensionKit"],
            path: "Examples/HelloStatusConsumerExtension",
            exclude: ["skalman-extension.json"],
            plugins: ["SkalmanExtensionPolicyPlugin"]
        ),
        // No policy plugin: the probe imports `Security` deliberately, to try the one thing a
        // real extension must never reach directly. It is a measuring instrument, not a
        // template — `HelloStatusExtension` is the template.
        .executableTarget(
            name: "DenialProbeExtension",
            dependencies: ["SkalmanExtensionKit"],
            path: "Examples/DenialProbeExtension",
            exclude: ["skalman-extension.json"]
        ),
        .executableTarget(
            name: "RainWindowExtensionExample",
            dependencies: ["SkalmanExtensionKit"],
            path: "Examples/RainWindowExtension",
            exclude: ["skalman-extension.json", "Resources"],
            plugins: ["SkalmanExtensionPolicyPlugin"]
        ),
        .executableTarget(
            name: "SessionInfoExtensionExample",
            dependencies: ["SkalmanExtensionKit"],
            path: "Examples/SessionInfoExtension",
            exclude: ["skalman-extension.json"],
            plugins: ["SkalmanExtensionPolicyPlugin"]
        ),
        .executableTarget(
            name: "SimulatorRelayExtensionExample",
            dependencies: ["SkalmanExtensionKit"],
            path: "Examples/SimulatorRelayExtension/Sources/ExtensionMain",
            plugins: ["SkalmanExtensionPolicyPlugin"]
        ),
        // The companion is deliberately outside the safe Wasm policy target: it is the
        // separately signed, sandboxed macOS process whose reviewed capabilities permit AppKit,
        // window capture, subprocess launch, and normalized input relay.
        .executableTarget(
            name: "SimulatorRelayCompanionExample",
            dependencies: ["SkalmanExtensionKit"],
            path: "Examples/SimulatorRelayExtension/Companion",
            exclude: [
                "Info.plist",
                "SimulatorRelayCompanion.entitlements"
            ]
        ),
        .executableTarget(
            name: "SkalmanComponentCatalogGenerator",
            dependencies: ["SkalmanExtensionKit"]
        ),
        .testTarget(
            name: "SkalmanExtensionKitTests",
            dependencies: [
                "SkalmanExtensionKit",
                "SkalmanExtensionPolicy"
            ]
        )
    ]
)
