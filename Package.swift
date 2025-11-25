// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AnotherTerminal",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AnotherTerminal", targets: ["AnotherTerminal"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "AnotherTerminal",
            dependencies: ["SwiftTerm"],
            path: "Sources/AnotherTerminal"
        )
    ]
)
