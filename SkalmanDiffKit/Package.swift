// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SkalmanDiffKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SkalmanDiffCore", targets: ["SkalmanDiffCore"]),
        .library(name: "SkalmanDiffAppKit", targets: ["SkalmanDiffAppKit"]),
        .library(name: "SkalmanDiffUIKit", targets: ["SkalmanDiffUIKit"]),
    ],
    targets: [
        .target(name: "SkalmanDiffCore"),
        .target(
            name: "SkalmanDiffAppKit",
            dependencies: ["SkalmanDiffCore"]
        ),
        .target(
            name: "SkalmanDiffUIKit",
            dependencies: ["SkalmanDiffCore"]
        ),
        .testTarget(
            name: "SkalmanDiffCoreTests",
            dependencies: ["SkalmanDiffCore"]
        ),
    ]
)
