// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Skalman",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Skalman", targets: ["Skalman"])
    ],
    dependencies: [
        .package(path: "SwiftTerm")
    ],
    targets: [
        .executableTarget(
            name: "Skalman",
            dependencies: ["SwiftTerm"],
            path: "Sources/Skalman",
            exclude: ["Resources/Info.plist", "Resources/Skalman.entitlements"],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "SkalmanTests",
            dependencies: ["Skalman"],
            path: "Tests/SkalmanTests"
        )
    ]
)
