// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThreadingMarkdownKit",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ThreadingMarkdownKit", targets: ["ThreadingMarkdownKit"])],
    targets: [
        .target(name: "ThreadingMarkdownKit"),
        .testTarget(name: "ThreadingMarkdownKitTests", dependencies: ["ThreadingMarkdownKit"])
    ]
)
