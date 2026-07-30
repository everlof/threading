import XCTest
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@testable import Threading

final class ProjectIconTests: XCTestCase {

    // MARK: - Fixtures

    /// A solid PNG of the given pixel size, built with ImageIO so the tests exercise the
    /// same decode path the store uses.
    private func pngData(
        size: Int,
        color: CGColor = CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1)
    ) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func pixelWidth(of data: Data) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
    }

    // MARK: - Store

    func testStoreNormalizesRoundTripsAndRemoves() throws {
        let projectID = ProjectID()
        let fileName = try XCTUnwrap(
            ProjectIconStore.store(imageData: pngData(size: 256), for: projectID)
        )
        defer { ProjectIconStore.remove(fileName: fileName) }

        XCTAssertEqual(fileName, projectID.uuidString + ".png")

        let icon = ProjectIcon(source: .repoFile, fileName: fileName)
        let image = try XCTUnwrap(ProjectIconStore.image(for: icon))
        XCTAssertTrue(image.isValid)

        // Normalisation caps a large source at the stored pixel size.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let stored = appSupport
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
            .appendingPathComponent(ProjectIconDefaults.iconDirectoryName)
            .appendingPathComponent(fileName)
        let storedWidth = try pixelWidth(of: Data(contentsOf: stored))
        XCTAssertLessThanOrEqual(storedWidth, ProjectIconDefaults.storedPixelSize)

        ProjectIconStore.remove(fileName: fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
    }

    func testStoreDoesNotUpscaleSmallIcons() throws {
        let projectID = ProjectID()
        let fileName = try XCTUnwrap(
            ProjectIconStore.store(imageData: pngData(size: 32), for: projectID)
        )
        defer { ProjectIconStore.remove(fileName: fileName) }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let stored = appSupport
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
            .appendingPathComponent(ProjectIconDefaults.iconDirectoryName)
            .appendingPathComponent(fileName)
        XCTAssertEqual(try pixelWidth(of: Data(contentsOf: stored)), 32)
    }

    func testUsableImageGate() throws {
        XCTAssertTrue(ProjectIconStore.isUsableImage(try pngData(size: 64)))

        // An HTML error page served with a 200 must not pass as an icon.
        let html = Data("<!doctype html><html><body>Not Found</body></html>".utf8)
        XCTAssertFalse(ProjectIconStore.isUsableImage(html))

        // Anything below the minimum cannot survive being drawn at 16pt.
        XCTAssertFalse(ProjectIconStore.isUsableImage(try pngData(size: 8)))
    }

    // MARK: - Backplate

    func testBackplateDecisionFollowsToneAndAppearance() {
        // A dark mark vanishes on the dark sidebar; a light one on the light sidebar.
        XCTAssertTrue(ProjectIconStore.needsBackplate(luminance: 0.1, darkAppearance: true))
        XCTAssertFalse(ProjectIconStore.needsBackplate(luminance: 0.1, darkAppearance: false))
        XCTAssertTrue(ProjectIconStore.needsBackplate(luminance: 0.95, darkAppearance: false))
        XCTAssertFalse(ProjectIconStore.needsBackplate(luminance: 0.95, darkAppearance: true))

        // Mid-tones read against either appearance; an undecodable icon never plates.
        XCTAssertFalse(ProjectIconStore.needsBackplate(luminance: 0.5, darkAppearance: true))
        XCTAssertFalse(ProjectIconStore.needsBackplate(luminance: 0.5, darkAppearance: false))
        XCTAssertFalse(ProjectIconStore.needsBackplate(luminance: nil, darkAppearance: true))
    }

    func testLuminanceReflectsIconTone() throws {
        let projectID = ProjectID()
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let fileName = try XCTUnwrap(
            ProjectIconStore.store(imageData: pngData(size: 64, color: white), for: projectID)
        )
        defer { ProjectIconStore.remove(fileName: fileName) }

        let icon = ProjectIcon(source: .custom, fileName: fileName)
        let luminance = try XCTUnwrap(ProjectIconStore.luminance(for: icon))
        XCTAssertGreaterThan(luminance, 0.9)
    }

    // MARK: - The Rounded Clip

    func testATileIsRecognisedAndALooseMarkIsNot() throws {
        XCTAssertTrue(
            ProjectIconStore.fillsItsBounds(try image(of: pngData(size: 64))),
            "an opaque favicon was not read as a tile"
        )
        XCTAssertFalse(
            ProjectIconStore.fillsItsBounds(try wordmarkMark()),
            "a mark on a clear background was read as a tile"
        )
    }

    /// A tile still rounds — that is the whole point of the clip.
    func testATileKeepsItsRoundedCorners() throws {
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let composed = ProjectIconStore.roundedDisplay(
            try image(of: pngData(size: 64, color: black))
        )

        let corner = try luminance(of: composed, atPoint: NSPoint(x: 0.5, y: 0.5))
        let middle = try luminance(of: composed, atPoint: NSPoint(x: 8, y: 8))

        XCTAssertGreaterThan(corner, 0.5, "a tile lost its rounded corner")
        XCTAssertLessThan(middle, 0.1, "the tile did not draw at all")
    }

    /// The reported case: `sonda`'s wordmark runs the full width of its canvas along the
    /// bottom, so the corner arcs took the outer edge off the `s` and the `a`. A mark on
    /// transparency has no corners to round, so the clip has nothing to take but ink.
    func testALooseMarkKeepsTheInkInItsCorners() throws {
        let composed = ProjectIconStore.roundedDisplay(try wordmarkMark())
        let trailingEdge: CGFloat = ProjectIconDefaults.displayPointSize - 0.5

        let leading = try luminance(of: composed, atPoint: NSPoint(x: 0.5, y: 0.5))
        let trailing = try luminance(of: composed, atPoint: NSPoint(x: trailingEdge, y: 0.5))

        XCTAssertLessThan(leading, 0.1, "the clip trimmed the leading edge of the wordmark")
        XCTAssertLessThan(trailing, 0.1, "the clip trimmed the trailing edge of the wordmark")
    }

    /// A wordmark's geometry, which is what makes this visible: ink along the whole bottom
    /// edge, clear everywhere the corner arcs would otherwise have nothing to do.
    ///
    /// Rasterised rather than built from a drawing handler — a handler-backed image composed
    /// inside another one does not keep this one's orientation, and a fixture that lands
    /// upside down tests the corners it was not written for.
    private func wordmarkMark(pixels: Int = 64) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: pixels * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels / 4))

        let size = NSSize(width: pixels, height: pixels)
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: size)
    }

    private func image(of data: Data) throws -> NSImage {
        try XCTUnwrap(NSImage(data: data))
    }

    /// The luminance the composite shows at one point of its 16pt face, rasterised at 4× over
    /// white so a fraction of a point resolves: black ink reads 0, the ground the clip
    /// exposes reads 1.
    private func luminance(of image: NSImage, atPoint point: NSPoint) throws -> CGFloat {
        let scale = 4
        let side = Int(ProjectIconDefaults.displayPointSize) * scale
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(
            in: CGRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        let data = try XCTUnwrap(context.data)
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        // The point is in the image's own bottom-left space; the bitmap's rows run top-down.
        let column: Int = min(side - 1, max(0, Int(point.x * CGFloat(scale))))
        let scanline: Int = min(side - 1, max(0, Int(point.y * CGFloat(scale))))
        let row: Int = side - 1 - scanline
        let offset: Int = (row * side + column) * 4

        let red = Double(pixels[offset])
        let green = Double(pixels[offset + 1])
        let blue = Double(pixels[offset + 2])
        let luminance: Double = 0.2126 * red + 0.7152 * green + 0.0722 * blue

        return CGFloat(luminance / 255)
    }

    // MARK: - Generated Tiles

    func testGeneratedIconIsDeterministicPerName() {
        // Stable across calls (and launches — hashValue is process-salted, this is not),
        // and different names diverge so same-initial projects still tell apart by colour.
        XCTAssertEqual(
            GeneratedProjectIcon.stableHash("sonda"),
            GeneratedProjectIcon.stableHash("sonda")
        )
        XCTAssertNotEqual(
            GeneratedProjectIcon.stableHash("sonda"),
            GeneratedProjectIcon.stableHash("sondalabs")
        )
        XCTAssertTrue(
            GeneratedProjectIcon.image(for: "sonda") === GeneratedProjectIcon.image(for: "sonda")
        )
    }

    // MARK: - Website Origins

    func testOriginFromWebsiteNormalisesInput() {
        XCTAssertEqual(
            ProjectIconDiscovery.origin(fromWebsite: "sonda.io")?.absoluteString,
            "https://sonda.io"
        )
        XCTAssertEqual(
            ProjectIconDiscovery.origin(fromWebsite: "https://sonda.io/deep/path?q=1")?.absoluteString,
            "https://sonda.io"
        )
        XCTAssertNil(ProjectIconDiscovery.origin(fromWebsite: "not a url"))
        XCTAssertNil(ProjectIconDiscovery.origin(fromWebsite: ""))
    }

    // MARK: - Account Avatars

    func testJWTClaimsDecodeWithoutVerification() throws {
        // Payload {"email":"a@b.se"} in base64url, with the url-safe characters the
        // decoder must translate exercised by the claim value.
        let payload = try XCTUnwrap(
            JSONSerialization.data(withJSONObject: ["email": "a@b.se", "n": "x?y>z"])
        ).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let claims = AccountAvatarStore.jwtClaims("header.\(payload).signature")
        XCTAssertEqual(claims?["email"] as? String, "a@b.se")

        XCTAssertNil(AccountAvatarStore.jwtClaims("no-dots-here"))
    }

    func testGravatarURLNormalisesAndHashes() {
        // SHA-256 of "developer@example.com" — casing and padding must not change it.
        let expected = ProjectIconTests.sha256("developer@example.com")
        XCTAssertEqual(
            AccountAvatarStore.gravatarURL(for: "  Developer@EXAMPLE.com ")?.absoluteString,
            "https://gravatar.com/avatar/\(expected)?d=404&s=128"
        )
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Account Badges

    /// The reason the badge reads the email at all: aliases are named after the *agent*, so
    /// `claude-dblock` and `claude-vlundborg` both reduce to `C` and identify nothing, while
    /// their addresses reduce to `D` and `L`.
    @MainActor
    func testBadgeInitialPrefersEmailOverAlias() throws {
        let dblock = try claudeAccount(
            handle: .named("claude-dblock"),
            email: "daniel.block3@example.com"
        )
        let vlundborg = try claudeAccount(
            handle: .named("claude-vlundborg"),
            email: "lundborg.viktor@example.com"
        )

        XCTAssertEqual(AccountBadge.initial(for: dblock), "D")
        XCTAssertEqual(AccountBadge.initial(for: vlundborg), "L")
    }

    /// An account whose config carries no address still has to render something, and its
    /// name is all that is left.
    @MainActor
    func testBadgeInitialFallsBackToNameWithoutEmail() throws {
        let account = try claudeAccount(handle: .named("claude-nameless"), email: nil)
        XCTAssertEqual(AccountBadge.initial(for: account), "C")
    }

    /// The chip marks an *alternate* account. On the default one the agent's own mark is
    /// already the whole answer, so a badge there would be chrome on every row.
    @MainActor
    func testDefaultAccountHasNoChip() throws {
        let account = try claudeAccount(
            handle: .standard,
            email: "developer@example.com"
        )
        XCTAssertNil(AccountBadge.chip(for: account))
        XCTAssertNil(AccountBadge.chip(for: nil))
    }

    /// A Claude account backed by a real config directory, since the badge reads the email
    /// from the CLI's own file rather than from the account record.
    private func claudeAccount(handle: AccountHandle, email: String?) throws -> AgentAccount {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let object: [String: Any] = email.map { ["oauthAccount": ["emailAddress": $0]] } ?? [:]
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent(".claude.json"))

        // Handles differ per test, since `cachedEmail` keys its memo on the account id and
        // would otherwise answer one account's lookup from another's entry.
        return AgentAccount(
            provider: .claude,
            handle: handle,
            configPath: directory.path,
            displayName: handle.name
        )
    }

    // MARK: - Git Remote

    func testRemoteOriginURLReadFromRepositoryConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-icon-tests-\(UUID().uuidString)")
        let gitDirectory = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "upstream"]
        \turl = git@example.com:someone/else.git
        [remote "origin"]
        \turl = git@github.com:anthropics/claude-code.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        try config.write(
            to: gitDirectory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            GitInfo.remoteOriginURL(for: root.path),
            "git@github.com:anthropics/claude-code.git"
        )
    }

    func testRemoteOriginURLNilOutsideRepository() {
        XCTAssertNil(GitInfo.remoteOriginURL(for: FileManager.default.temporaryDirectory.path))
    }

    func testHeadRevisionReadsLoosePackedAndDetachedHeads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-head-tests-\(UUID().uuidString)")
        let gitDirectory = root.appendingPathComponent(".git")
        let heads = gitDirectory.appendingPathComponent("refs/heads")
        try FileManager.default.createDirectory(at: heads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let looseRevision = String(repeating: "a", count: 40)
        try "ref: refs/heads/main\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        let mainRef = heads.appendingPathComponent("main")
        try "\(looseRevision)\n".write(
            to: mainRef,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(GitInfo.headRevision(for: root.path), looseRevision)

        try FileManager.default.removeItem(at: mainRef)
        let packedRevision = String(repeating: "b", count: 40)
        try "# pack-refs with: peeled\n\(packedRevision) refs/heads/main\n".write(
            to: gitDirectory.appendingPathComponent("packed-refs"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(GitInfo.headRevision(for: root.path), packedRevision)

        let detachedRevision = String(repeating: "c", count: 40)
        try "\(detachedRevision)\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(GitInfo.headRevision(for: root.path), detachedRevision)
    }
}
