// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Skalman",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Skalman", targets: ["Skalman"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Skalman",
            dependencies: ["SwiftTerm"],
            path: "Sources/Skalman"
        )
    ]
)
