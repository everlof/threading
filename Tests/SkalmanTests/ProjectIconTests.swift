import XCTest
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@testable import Skalman

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
        let projectID = UUID()
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
        let projectID = UUID()
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
        let projectID = UUID()
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let fileName = try XCTUnwrap(
            ProjectIconStore.store(imageData: pngData(size: 64, color: white), for: projectID)
        )
        defer { ProjectIconStore.remove(fileName: fileName) }

        let icon = ProjectIcon(source: .custom, fileName: fileName)
        let luminance = try XCTUnwrap(ProjectIconStore.luminance(for: icon))
        XCTAssertGreaterThan(luminance, 0.9)
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

    // MARK: - Git Remote

    func testRemoteOriginURLReadFromRepositoryConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skalman-icon-tests-\(UUID().uuidString)")
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
}
