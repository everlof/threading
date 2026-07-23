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
        .executable(
            name: "HelloStatusExtensionExample",
            targets: ["HelloStatusExtensionExample"]
        )
    ],
    targets: [
        .target(
            name: "SkalmanExtensionKit"
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
        .testTarget(
            name: "SkalmanExtensionKitTests",
            dependencies: [
                "SkalmanExtensionKit",
                "SkalmanExtensionPolicy"
            ]
        )
    ]
)
