// swift-tools-version: 6.0
import PackageDescription

// Portable durable work ownership. No UI, provider, network, or PTY dependency.
let package = Package(
    name: "ThreadingController",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ThreadingController", targets: ["ThreadingController"])],
    dependencies: [.package(path: "../ThreadingDomain")],
    targets: [
        .systemLibrary(name: "CControllerSQLite", pkgConfig: "sqlite3",
                       providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "ThreadingController", dependencies: ["CControllerSQLite", .product(name: "ThreadingDomain", package: "ThreadingDomain")]),
        .testTarget(name: "ThreadingControllerTests", dependencies: ["ThreadingController"])
    ]
)
