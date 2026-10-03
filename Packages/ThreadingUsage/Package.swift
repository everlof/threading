// swift-tools-version: 6.0
import PackageDescription

// Provider-neutral usage accounting shared by the Mac app and the controller: token categories,
// ledger records, the Claude/Codex/OpenCode transcript adapters, the strict JSONL reader they
// stream through and the pricing catalogue. Foundation only, so it builds on Linux too.
let package = Package(
    name: "ThreadingUsage",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ThreadingUsage", targets: ["ThreadingUsage"])],
    targets: [
        .target(name: "ThreadingUsage"),
        .testTarget(name: "ThreadingUsageTests", dependencies: ["ThreadingUsage"])
    ]
)
