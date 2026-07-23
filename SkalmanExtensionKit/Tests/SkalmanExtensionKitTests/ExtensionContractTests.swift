import Foundation
import XCTest
@testable import SkalmanExtensionKit
@testable import SkalmanExtensionPolicy

final class ExtensionContractTests: XCTestCase {
    func testManifestRoundTripsUnknownCapabilities() throws {
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.example",
            name: "Example",
            version: "1.0.0",
            executable: "bin/example",
            capabilities: [.commands, .init(rawValue: "future.capability")]
        )

        try manifest.validate()
        let decoded = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: JSONEncoder().encode(manifest)
        )

        XCTAssertEqual(decoded, manifest)
    }

    func testManifestRejectsPathsThatEscapeTheExtensionDirectory() {
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.example",
            name: "Example",
            version: "1.0.0",
            executable: "../example"
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            let validation = error as? ExtensionValidationError
            XCTAssertEqual(validation?.issues.map(\.path), ["executable"])
        }
    }

    func testEveryNodeHasAStableTaggedJSONShapeAndRoundTrips() throws {
        let nodes: [ExtensionNode] = [
            .text("Heading", role: .heading),
            .button(id: "run", title: "Run", role: .primary, isEnabled: false),
            .status("Waiting", role: .warning),
            .divider,
            .spacer(.large),
            .stack(
                axis: .horizontal,
                spacing: .small,
                children: [.text("Child", role: .body)]
            )
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for node in nodes {
            let data = try encoder.encode(node)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertNotNil(object["type"], "\(node) has no wire discriminator")
            XCTAssertEqual(try decoder.decode(ExtensionNode.self, from: data), node)
        }
    }

    func testRegistrationRequiresCapabilitiesAndUniqueValidIDs() throws {
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.example",
            name: "Example",
            version: "1.0.0",
            executable: "bin/example"
        )
        let registration = ExtensionRegistration(
            commands: [
                .init(id: "Refresh", title: "First"),
                .init(id: "Refresh", title: "Second")
            ],
            panels: [
                .init(id: "status", title: "Status", root: .status("Ready", role: .positive))
            ]
        )

        XCTAssertThrowsError(try registration.validate(for: manifest)) { error in
            let paths = (error as? ExtensionValidationError)?.issues.map(\.path)
            XCTAssertEqual(
                paths,
                [
                    "commands[0].id",
                    "commands[1].id",
                    "commands[1].id",
                    "capabilities",
                    "capabilities"
                ]
            )
        }
    }

    func testTheSafeSDKDoesNotImportUIFrameworks() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot
            .appendingPathComponent("Sources/SkalmanExtensionKit", isDirectory: true)

        let files = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )

        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("import AppKit"), file.lastPathComponent)
            XCTAssertFalse(source.contains("import SwiftUI"), file.lastPathComponent)
        }
    }

    func testPolicyRejectsEverySwiftImportFormForUIFrameworks() {
        let source = """
            import Foundation
            import AppKit
            @_implementationOnly import SwiftUI
            import class AppKit.NSButton
            """

        let violations = ExtensionSourcePolicy.violations(
            in: source,
            path: "Sources/Example/main.swift"
        )

        XCTAssertEqual(
            violations.map(\.module),
            ["AppKit", "SwiftUI", "AppKit"]
        )
        XCTAssertEqual(violations.map(\.line), [2, 3, 4])
    }

    func testReferenceManifestDecodesAndValidates() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = packageRoot
            .appendingPathComponent("Examples/HelloStatusExtension/skalman-extension.json")

        let manifest = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        try manifest.validate()
        XCTAssertEqual(manifest.identifier, "se.mjukis.hello-status")
    }
}
