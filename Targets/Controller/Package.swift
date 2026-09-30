// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThreadingControllerCLI",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "threading-controller", targets: ["ThreadingControllerCLI"])],
    dependencies: [
        .package(path: "../../Packages/ThreadingController"),
        .package(path: "../../Packages/ThreadingPTYClient"),
        .package(path: "../../Packages/ThreadingPTYHostKit"),
        .package(path: "../../Packages/ThreadingDomain")
    ],
    targets: [
        .target(name: "ControllerRuntime", dependencies: [
            .product(name: "ThreadingController", package: "ThreadingController"),
            .product(name: "ThreadingPTYClient", package: "ThreadingPTYClient"),
            .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit"),
            .product(name: "ThreadingDomain", package: "ThreadingDomain")
        ]),
        .executableTarget(name: "ThreadingControllerCLI", dependencies: ["ControllerRuntime",
            .product(name: "ThreadingController", package: "ThreadingController")
        ])
    ]
)
