// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThreadingGlanceKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "ThreadingGlanceKit", targets: ["ThreadingGlanceKit"])],
    dependencies: [.package(path: "../ThreadingRemoteKit")],
    targets: [
        .target(name: "ThreadingGlanceKit", dependencies: ["ThreadingRemoteKit"]),
        .testTarget(name: "ThreadingGlanceKitTests", dependencies: ["ThreadingGlanceKit"])
    ]
)
