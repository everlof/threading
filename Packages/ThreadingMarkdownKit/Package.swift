// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThreadingMarkdownKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "ThreadingMarkdownKit", targets: ["ThreadingMarkdownKit"]),
        // The parsed document as plain values and its HTML, with no AppKit: the iPhone app, the
        // workroom portal and the Mac read one model and each draw it their own way.
        .library(name: "ThreadingMarkdownModel", targets: ["ThreadingMarkdownModel"])
    ],
    targets: [
        .target(name: "ThreadingMarkdownModel"),
        .target(name: "ThreadingMarkdownKit"),
        .testTarget(name: "ThreadingMarkdownKitTests", dependencies: ["ThreadingMarkdownKit"]),
        .testTarget(name: "ThreadingMarkdownModelTests", dependencies: ["ThreadingMarkdownModel"])
    ]
)
