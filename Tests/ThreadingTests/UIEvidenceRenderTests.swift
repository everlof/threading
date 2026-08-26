import AppKit
import XCTest
@testable import Threading

/// The checked-in contract and opt-in renderer behind the browsable UI evidence catalogue.
///
/// Ordinary test runs validate the contract only. `scripts/ui-evidence.sh` supplies a fresh
/// output directory and opts into the complete Component Gallery capture. The gallery is a fixed
/// developer-authored catalogue, so walking all of it is bounded; externally sized product data
/// remains in the existing virtualized surface fixtures selected by the script.
@MainActor
final class UIEvidenceRenderTests: XCTestCase {
    private enum Contract {
        static let schemaVersion = 1
        static let componentMetadataName = "component-evidence.json"
        static let componentMetadataKind = "threading-component-evidence"
        static let componentEntryID = "design-system-components"
        static let captureEnvironmentKey = "THREADING_UI_EVIDENCE_OUT"
        static let gallerySize = NSSize(width: 1_020, height: 780)
        static let minimumPNGBytes = 1_000
    }

    private struct ComponentEvidenceDocument: Encodable {
        let schemaVersion: Int
        let kind: String
        let artifacts: [ComponentArtifact]
    }

    private struct ComponentArtifact: Encodable {
        let id: String
        let entryID: String
        let title: String
        let variant: String
        let description: String
        let image: String
        let tags: [String]
    }

    private struct CoverageDocument: Decodable {
        let schemaVersion: Int
        let entries: [CoverageEntry]
    }

    private struct CoverageEntry: Decodable {
        let id: String
        let kind: String
        let status: String
        let priority: String
        let title: String
        let description: String
        let states: [String]
        let source: CoverageSource?
        let capture: CoverageCapture?
    }

    private struct CoverageSource: Decodable {
        let path: String
        let test: String?
        let tests: [String]?
        let command: String?

        var selectors: [String] {
            if let test { return [test] }
            return tests ?? []
        }

        var contractNames: [String] {
            selectors + (command.map { [$0] } ?? [])
        }

        var contractKindCount: Int {
            [test == nil ? nil : "test", tests == nil ? nil : "tests", command]
                .compactMap { $0 }
                .count
        }
    }

    private struct CoverageCapture: Decodable {
        let metadata: String?
        let glob: String?
        let journey: String?
    }

    // MARK: - Contract

    func testCoverageManifestReferencesRealEvidenceTests() throws {
        let repository = repositoryRoot
        for manifestName in ["coverage.json", "ios-coverage.json"] {
            let manifestURL = repository
                .appendingPathComponent("Tests/UIEvidence")
                .appendingPathComponent(manifestName)
            let document = try JSONDecoder().decode(
                CoverageDocument.self,
                from: Data(contentsOf: manifestURL)
            )

            XCTAssertEqual(document.schemaVersion, Contract.schemaVersion, manifestName)
            XCTAssertFalse(document.entries.isEmpty, manifestName)
            XCTAssertEqual(
                Set(document.entries.map(\.id)).count,
                document.entries.count,
                manifestName
            )

            let allowedKinds = Set(["component", "surface", "journey"])
            let allowedStatuses = Set(["implemented", "planned"])
            let allowedPriorities = Set(["critical", "important", "supporting"])

            for entry in document.entries {
                let context = "\(manifestName): \(entry.id)"
                XCTAssertFalse(entry.id.isEmpty, context)
                XCTAssertFalse(entry.title.isEmpty, context)
                XCTAssertFalse(entry.description.isEmpty, context)
                XCTAssertFalse(entry.states.isEmpty, context)
                XCTAssertTrue(allowedKinds.contains(entry.kind), context)
                XCTAssertTrue(allowedStatuses.contains(entry.status), context)
                XCTAssertTrue(allowedPriorities.contains(entry.priority), context)

                guard entry.status == "implemented" else { continue }
                let source = try XCTUnwrap(entry.source, context)
                let capture = try XCTUnwrap(entry.capture, context)
                let captureContracts = [capture.metadata, capture.glob, capture.journey]
                    .compactMap { $0 }
                XCTAssertEqual(captureContracts.count, 1, context)
                XCTAssertEqual(source.contractKindCount, 1, context)
                XCTAssertFalse(source.contractNames.isEmpty, context)

                let sourceURL = repository.appendingPathComponent(source.path)
                let sourceText = try String(contentsOf: sourceURL, encoding: .utf8)
                for selector in source.selectors {
                    let method = try XCTUnwrap(selector.split(separator: "/").last, selector)
                    XCTAssertTrue(
                        sourceText.contains("func \(method)("),
                        "\(context) references missing test \(selector)"
                    )
                }
                if let command = source.command {
                    XCTAssertTrue(
                        sourceText.contains("\(command)()"),
                        "\(context) references missing evidence command \(command)"
                    )
                }
            }
        }
    }

    // MARK: - Component evidence

    func testCapturesEveryComponentGalleryStory() throws {
        // Empty, not absent, is the case worth guarding: the test plan forwards this as
        // `$(THREADING_UI_EVIDENCE_OUT)`, which expands to the empty string when nothing set it.
        // A bare `if let` therefore never skips, and the empty path is the volume root — so this
        // failed with a read-only write rather than the skip it was written to take.
        guard let outputPath = ProcessInfo.processInfo.environment[Contract.captureEnvironmentKey]
            .flatMap({ $0.isEmpty ? nil : $0 })
        else {
            throw XCTSkip("Run scripts/ui-evidence.sh to capture the complete gallery")
        }

        let output = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        let metadataURL = output.appendingPathComponent(Contract.componentMetadataName)
        let componentDirectory = output.appendingPathComponent("components", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: metadataURL.path) else {
            XCTFail("UI evidence output must be new for every run")
            return
        }
        guard !FileManager.default.fileExists(atPath: componentDirectory.path) else {
            XCTFail("UI evidence component directory must be new for every run")
            return
        }
        try FileManager.default.createDirectory(
            at: componentDirectory,
            withIntermediateDirectories: true
        )

        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        AppThemePalette.set(.system)

        let owner = ComponentGalleryWindowController()
        let window = try XCTUnwrap(owner.window)
        let controller = try XCTUnwrap(
            window.contentViewController as? ComponentGalleryViewController
        )
        window.setContentSize(Contract.gallerySize)
        controller.view.layoutSubtreeIfNeeded()

        let stories = descendants(of: controller.view)
            .filter { $0.accessibilityIdentifier().hasPrefix("gallery.story.") }
            .sorted {
                $0.accessibilityIdentifier() < $1.accessibilityIdentifier()
            }
        XCTAssertFalse(stories.isEmpty, "The Component Gallery exposed no story cards")

        let slugs = stories.map { slug(for: storyName(of: $0)) }
        XCTAssertEqual(Set(slugs).count, stories.count, "Component story slugs must be unique")

        var artifacts: [ComponentArtifact] = []
        for appearance in ComponentGalleryViewController.AppearanceMode.allCases {
            controller.setAppearance(appearance)
            AppThemeRefresh.repaint(controller.view)
            controller.view.layoutSubtreeIfNeeded()
            let captureAppearance = try XCTUnwrap(appearance.appearance)

            for story in stories {
                // AppKit only materializes view-based table cells while their table intersects
                // the outer gallery viewport. Capturing an off-screen story directly otherwise
                // records a truthful table frame with a fictitious empty body. Bring the story
                // through the same viewport a reviewer would, then ask the bounded fixture rows
                // to exist before caching the story as an image.
                story.scrollToVisible(story.bounds)
                controller.view.layoutSubtreeIfNeeded()
                prepareVirtualizedContent(in: story)

                let name = storyName(of: story)
                let storySlug = slug(for: name)
                let relativePath = "components/\(storySlug)/system-\(appearance.rawValue.lowercased()).png"
                let imageURL = output.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: imageURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let data = try png(of: story, appearance: captureAppearance)
                XCTAssertGreaterThan(
                    data.count,
                    Contract.minimumPNGBytes,
                    "\(name) \(appearance.rawValue) rendered unexpectedly little image data"
                )
                try data.write(to: imageURL, options: Data.WritingOptions.atomic)

                artifacts.append(ComponentArtifact(
                    id: "component.\(storySlug).system-\(appearance.rawValue.lowercased())",
                    entryID: Contract.componentEntryID,
                    title: name,
                    variant: "System · \(appearance.rawValue)",
                    description: storySummary(of: story),
                    image: relativePath,
                    tags: ["component", "system", appearance.rawValue.lowercased()]
                ))
            }
        }

        let document = ComponentEvidenceDocument(
            schemaVersion: Contract.schemaVersion,
            kind: Contract.componentMetadataKind,
            artifacts: artifacts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: metadataURL, options: .atomic)

        XCTAssertEqual(
            artifacts.count,
            stories.count * ComponentGalleryViewController.AppearanceMode.allCases.count
        )
    }

    // MARK: - Capture helpers

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func storyName(of story: NSView) -> String {
        let identifier = story.accessibilityIdentifier()
        return String(identifier.dropFirst("gallery.story.".count))
    }

    private func storySummary(of story: NSView) -> String {
        guard let content = story.subviews.first as? NSStackView,
              let heading = content.arrangedSubviews.first as? NSStackView else {
            return "Interactive Component Gallery story for \(storyName(of: story))."
        }
        let labels = heading.arrangedSubviews.compactMap { $0 as? NSTextField }
        guard labels.count > 1, !labels[1].stringValue.isEmpty else {
            return "Interactive Component Gallery story for \(storyName(of: story))."
        }
        return labels[1].stringValue
    }

    private func prepareVirtualizedContent(in story: NSView) {
        for table in descendants(of: story).compactMap({ $0 as? NSTableView }) {
            table.reloadData()
            if let outline = table as? NSOutlineView {
                outline.expandItem(nil, expandChildren: true)
            }
            guard table.numberOfRows > 0, !table.tableColumns.isEmpty else { continue }
            table.scrollRowToVisible(0)
            table.layoutSubtreeIfNeeded()
            _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            table.displayIfNeeded()
        }
    }

    private func slug(for value: String) -> String {
        var result = ""
        var previousWasSeparator = false
        for character in value.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
                previousWasSeparator = false
            } else if !result.isEmpty, !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }
        while result.last == "-" { result.removeLast() }
        return result
    }

    private func png(of view: NSView, appearance: NSAppearance) throws -> Data {
        let inheritedAppearance = view.appearance
        view.appearance = appearance
        defer { view.appearance = inheritedAppearance }
        AppThemeRefresh.repaint(view)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds.integral
        XCTAssertFalse(bounds.isEmpty)

        let beams = descendants(of: view).compactMap { $0 as? AgentActivityBeamView }
        return try withCachedDisplayFallbacks(beams, at: 0) {
            let representation = try XCTUnwrap(
                view.bitmapImageRepForCachingDisplay(in: bounds)
            )
            appearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: bounds, to: representation)
            }
            let cachedImage = try XCTUnwrap(representation.cgImage)
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(
                data: nil,
                width: representation.pixelsWide,
                height: representation.pixelsHigh,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let pixelBounds = CGRect(
                x: 0,
                y: 0,
                width: representation.pixelsWide,
                height: representation.pixelsHigh
            )
            // `Design.Surface.ground` is dynamic. Resolving it against NSApp here silently gives
            // a dark backing when an off-screen light fixture is captured from a dark-running
            // test host: the fixture's text resolves light, then its translucent surfaces are
            // flattened over the wrong appearance. Resolve the theme role against the fixture's
            // own appearance explicitly, just as the component did while drawing.
            let dynamicGround = AppThemePalette.current.resolved(
                .ground,
                appearance: appearance
            )
            var resolvedGround: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                // The System theme returns AppKit's dynamic system colour even when its variant
                // selection was explicit; converting that colour is the operation that freezes
                // light or dark, so it must happen inside the requested drawing appearance too.
                resolvedGround = dynamicGround.usingColorSpace(.sRGB)
            }
            let ground = try XCTUnwrap(resolvedGround)
            context.setFillColor(ground.cgColor)
            context.fill(pixelBounds)
            context.draw(cachedImage, in: pixelBounds)

            let composedImage = try XCTUnwrap(context.makeImage())
            let composed = NSBitmapImageRep(cgImage: composedImage)
            let data = try XCTUnwrap(composed.representation(using: .png, properties: [:]))
            let corner = try XCTUnwrap(composed.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
            let cornerAlpha = corner.alphaComponent
            XCTAssertEqual(
                cornerAlpha, 1, accuracy: 0.001,
                "component evidence must be composited over the gallery ground"
            )
            XCTAssertLessThan(
                colorDistance(corner, ground), 0.06,
                "component evidence must use the fixture appearance's gallery ground"
            )
            return data
        }
    }

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        max(
            abs(lhs.redComponent - rhs.redComponent),
            abs(lhs.greenComponent - rhs.greenComponent),
            abs(lhs.blueComponent - rhs.blueComponent)
        )
    }

    private func withCachedDisplayFallbacks<Result>(
        _ views: [AgentActivityBeamView],
        at index: Int,
        _ body: () throws -> Result
    ) rethrows -> Result {
        guard index < views.count else { return try body() }
        return try views[index].withCachedDisplayFallback {
            try withCachedDisplayFallbacks(views, at: index + 1, body)
        }
    }

    private func descendants(of root: NSView) -> [NSView] {
        var result: [NSView] = []
        var pending = root.subviews
        while let view = pending.popLast() {
            result.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return result
    }
}
