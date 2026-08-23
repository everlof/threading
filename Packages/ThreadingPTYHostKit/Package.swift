// swift-tools-version: 5.9

import PackageDescription

// The wire contract between Threading and the `threading-ptyd` PTY host, and nothing else.
//
// Both ends link this package, so there is one definition of the framing, the frames and the
// version rule rather than two that drift. It is deliberately Foundation-only and depends only
// on `ThreadingDomain` (which has no dependencies at all): the daemon must stay a process that
// can be described on one page, and a package that could reach the app's stores, themes or
// terminal emulation is how that stops being true. Everything here is a value type, so the whole
// protocol is testable with no daemon, no app and no window.
let package = Package(
    name: "ThreadingPTYHostKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ThreadingPTYHostKit", targets: ["ThreadingPTYHostKit"])
    ],
    dependencies: [
        .package(path: "../ThreadingDomain")
    ],
    targets: [
        .target(
            name: "ThreadingPTYHostKit",
            dependencies: ["ThreadingDomain"]
        ),
        .testTarget(
            name: "ThreadingPTYHostKitTests",
            dependencies: ["ThreadingPTYHostKit", "ThreadingDomain"]
        )
    ]
)
