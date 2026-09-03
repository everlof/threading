import XCTest
@testable import Threading

/// `ThreadingPluginKit` is the one package here that is meant to leave this repository one day.
///
/// The decision not to publish it yet is a decision about timing, not about shape, so the shape has
/// to stay ready: a third party gets this directory and nothing else, and everything they need to
/// build a loadable plugin has to be inside it. That property degrades silently — one convenient
/// symlink into `Sources/Threading`, one `.package(path: "../../Something")`, and the split stops
/// being a copy and becomes an untangling job. `ThreadingDesignKit` is what that looks like: 80
/// symlinks into the app plus five sibling packages, and it cannot be published at all.
///
/// So this is the guard. It reads the directory rather than trusting anyone to remember.
final class PluginKitPublishabilityTests: XCTestCase {

    private var package: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ThreadingTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Packages/ThreadingPluginKit")
    }

    /// Modules the package may import: its own, and what any Mac has.
    private let permittedImports: Set<String> = [
        "ThreadingPluginKit", "AppKit", "Foundation", "Security", "XCTest", "PackageDescription",
    ]

    // MARK: - Self-containment

    /// A symlink out of the directory is the cheapest way to lose publishability, and the hardest
    /// to notice: everything still builds here, and only the copy someone else clones is broken.
    func testNoSymlinkReachesOutsideThePackage() throws {
        let root = package.resolvingSymlinksInPath().path
        for file in try sources(under: package) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
            let destination = file.resolvingSymlinksInPath().path
            XCTAssertTrue(
                destination.hasPrefix(root + "/"),
                "\(file.lastPathComponent) is a symlink to \(destination), outside the package"
            )
        }
    }

    /// Every `Package.swift` inside — the kit's and each example's — may only depend on paths that
    /// stay within the directory. `Examples/HelloPanePlugin` pointing at `../..` is the package
    /// root, which is exactly right; anything reaching `../../../` has left.
    func testNoPathDependencyEscapesThePackage() throws {
        let manifests = try sources(under: package).filter { $0.lastPathComponent == "Package.swift" }
        XCTAssertGreaterThanOrEqual(manifests.count, 2, "expected the kit's manifest and an example's")

        for manifest in manifests {
            let text = try String(contentsOf: manifest, encoding: .utf8)
            for path in pathDependencies(in: text) {
                let resolved = manifest.deletingLastPathComponent()
                    .appendingPathComponent(path)
                    .standardizedFileURL
                    .resolvingSymlinksInPath().path
                let root = package.resolvingSymlinksInPath().path
                XCTAssertTrue(
                    resolved == root || resolved.hasPrefix(root + "/"),
                    "\(manifest.lastPathComponent) depends on \(path), which resolves outside the package"
                )
            }
        }
    }

    /// An import of a module that will not exist in the published repository is the same defect
    /// stated in Swift rather than in a manifest.
    func testNothingImportsAModuleThatWouldNotBePublishedWithIt() throws {
        for file in try sources(under: package) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = String(trimmed.dropFirst("import ".count))
                    .split(separator: ".").first.map(String.init) ?? ""
                XCTAssertTrue(
                    permittedImports.contains(module),
                    "\(file.lastPathComponent) imports \(module), which is not published with the kit"
                )
            }
        }
    }

    // MARK: - Completeness

    /// The contract alone does not produce a bundle Threading will load. Three of the steps in the
    /// recipe are not guessable — `-bundle`, `NSPrincipalClass`, and the install-name rewrite —
    /// and each fails by blaming something else, so the recipe ships with the contract.
    func testTheBuildRecipeShipsInsideThePackage() throws {
        let tool = package.appendingPathComponent("Tools/build-plugin.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tool.path),
                      "Tools/build-plugin.sh must be present and executable")

        let recipe = try String(contentsOf: tool, encoding: .utf8)
        XCTAssertTrue(recipe.contains("ThreadingPluginKit.framework/Versions/A/ThreadingPluginKit"),
                      "the install-name rewrite is the step nobody can guess")
        XCTAssertTrue(recipe.contains("NSPrincipalClass"))

        // Ours is a wrapper over that one, so the script a third party is handed is the script we
        // exercise. A private copy of the recipe here would let the published one rot unnoticed.
        let wrapper = try String(
            contentsOf: package.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("scripts/build_plugin.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(wrapper.contains("Packages/ThreadingPluginKit/Tools/build-plugin.sh"),
                      "scripts/build_plugin.sh must delegate to the published recipe")
    }

    /// A worked example is the answer to "what exactly does a third party need", in a form that
    /// stops being true if it breaks.
    func testAnExampleShowsTheWholeContractAndDependsOnNothingElse() throws {
        let example = package.appendingPathComponent("Examples/HelloPanePlugin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: example.path))

        let manifest = try String(
            contentsOf: example.appendingPathComponent("Package.swift"), encoding: .utf8
        )
        XCTAssertEqual(pathDependencies(in: manifest), ["../.."],
                       "the example must need the kit and nothing besides")
        XCTAssertTrue(manifest.contains("type: .dynamic"),
                      "a plugin product is linked into a loadable bundle")

        let source = try String(
            contentsOf: example.appendingPathComponent("Sources/HelloPanePlugin/HelloPanePlugin.swift"),
            encoding: .utf8
        )
        for member in ["pluginAPIVersion", "pluginIdentifier", "makePaneView", "apply(theme:",
                       "pluginTools", "invokeTool"] {
            XCTAssertTrue(source.contains(member), "the example should demonstrate \(member)")
        }
        XCTAssertTrue(source.contains("@objc(HelloPanePlugin)"),
                      "NSPrincipalClass is resolved through the Objective-C runtime")
    }

    /// The published package has to carry its own instructions, since the architecture notes that
    /// explain this tier stay here.
    func testThePackageDocumentsItself() throws {
        let readme = try String(
            contentsOf: package.appendingPathComponent("README.md"), encoding: .utf8
        )
        XCTAssertTrue(readme.contains("Tools/build-plugin.sh"))
        XCTAssertTrue(readme.contains("disable-library-validation"),
                      "a reader has to be told the operating system enforces nothing here")
    }

    // MARK: - Helpers

    private func sources(under directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var found: [URL] = []
        while let entry = enumerator?.nextObject() as? URL {
            // Build products are not part of the package.
            if entry.pathComponents.contains(".build") { continue }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue { continue }
            found.append(entry)
        }
        return found
    }

    /// The `path:` arguments of every `.package(path: "…")` in a manifest.
    private func pathDependencies(in manifest: String) -> [String] {
        let pattern = #"\.package\(path:\s*"([^"]+)"\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(manifest.startIndex..., in: manifest)
        return expression.matches(in: manifest, range: range).compactMap { match in
            Range(match.range(at: 1), in: manifest).map { String(manifest[$0]) }
        }
    }
}
