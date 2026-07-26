// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SkalmanWasmRuntime",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SkalmanWasmRuntime", targets: ["SkalmanWasmRuntime"]),
        .executable(
            name: "skalman-wasm-extension-runner",
            targets: ["SkalmanWasmExtensionRunner"]
        )
    ],
    dependencies: [
        // 0.1.6 is the newest release whose published manifest supports macOS 13.
        // Later releases select a Swift 6.1 manifest with a macOS 14 minimum.
        .package(url: "https://github.com/swiftwasm/WasmKit", exact: "0.1.6"),
        // Pin the version already used by the Xcode workspace. Apart from reproducibility,
        // this avoids a source incompatibility in SystemExtras with swift-system 1.7.
        .package(url: "https://github.com/apple/swift-system", exact: "1.6.3")
    ],
    targets: [
        .target(
            name: "SkalmanWasmRuntime",
            dependencies: [
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
                .product(name: "SystemPackage", package: "swift-system")
            ]
        ),
        .executableTarget(
            name: "SkalmanWasmExtensionRunner",
            dependencies: ["SkalmanWasmRuntime"]
        ),
        .testTarget(
            name: "SkalmanWasmRuntimeTests",
            dependencies: [
                "SkalmanWasmRuntime",
                .product(name: "WAT", package: "WasmKit")
            ]
        )
    ]
)
