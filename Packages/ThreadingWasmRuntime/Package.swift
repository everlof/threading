// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ThreadingWasmRuntime",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ThreadingWasmRuntime", targets: ["ThreadingWasmRuntime"]),
        .executable(
            name: "threading-wasm-extension-runner",
            targets: ["ThreadingWasmExtensionRunner"]
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
            name: "ThreadingWasmRuntime",
            dependencies: [
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
                .product(name: "SystemPackage", package: "swift-system")
            ]
        ),
        .executableTarget(
            name: "ThreadingWasmExtensionRunner",
            dependencies: ["ThreadingWasmRuntime"]
        ),
        .testTarget(
            name: "ThreadingWasmRuntimeTests",
            dependencies: [
                "ThreadingWasmRuntime",
                .product(name: "WAT", package: "WasmKit")
            ]
        )
    ]
)
