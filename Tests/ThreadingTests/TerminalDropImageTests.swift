import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Threading

/// Which dropped images are rewritten before they are pasted, and which are left exactly where
/// they lie.
///
/// The lists come from the two CLIs and nowhere else: a format one of them matches on is a
/// format we must not touch, and a format neither matches is a drop that silently did nothing
/// before this. The shell case is the one worth protecting — a path handed to a shell has to be
/// the path the user pointed at.
final class TerminalDropImageTests: XCTestCase {

    private var directory: URL!
    private var converted: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil

        for path in converted {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        converted = []

        try super.tearDownWithError()
    }

    // MARK: - Left Alone

    /// A shell is handed paths, not pictures. Converting here would hand back a copy of the
    /// file the user pointed at, which is the wrong file for every command they could be typing.
    func testShellConvertsNothing() throws {
        let tiff = try write(.tiff, named: "scan")

        XCTAssertEqual(TerminalDropImage.readable([tiff], for: .shell), [tiff])
    }

    /// A format the CLI matches on already becomes an image on its own. A copy would be a
    /// second file for no gain, and would lose the name the user knows it by.
    func testFormatsTheAgentTakesAreUntouched() throws {
        let png = try write(.png, named: "shot")

        XCTAssertEqual(TerminalDropImage.readable([png], for: .agent(.claude)), [png])
        XCTAssertEqual(TerminalDropImage.readable([png], for: .agent(.codex)), [png])
    }

    /// Only images convert. Everything else a drop can carry is a path and stays one.
    func testOrdinaryFilesAreUntouched() throws {
        let source = directory.appendingPathComponent("notes.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            TerminalDropImage.readable([source.path], for: .agent(.claude)),
            [source.path]
        )
    }

    // MARK: - Converted

    /// TIFF is on neither CLI's list, which is what made a scan dropped on an agent read as a
    /// line of path.
    func testTIFFBecomesAPNGTheAgentCanRead() throws {
        let tiff = try write(.tiff, named: "scan")

        let result = TerminalDropImage.readable([tiff], for: .agent(.claude))
        converted = result

        let path = try XCTUnwrap(result.first)
        XCTAssertNotEqual(path, tiff)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertNotNil(NSImage(contentsOfFile: path))
    }

    /// The name survives the conversion, so what the agent names back is still recognisable as
    /// the file that was dropped.
    func testTheConvertedFileKeepsItsName() throws {
        let tiff = try write(.tiff, named: "receipt")

        let result = TerminalDropImage.readable([tiff], for: .agent(.claude))
        converted = result

        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(result.first)).lastPathComponent, "receipt.png")
    }

    /// The two CLIs do not take the same formats, and the reader is what decides. Claude Code
    /// matches GIF; Codex encodes only PNG and JPEG, so the same drop has to be rewritten there.
    func testGIFFollowsTheReaderRatherThanOneRule() throws {
        let gif = try write(.gif, named: "loop")

        XCTAssertEqual(TerminalDropImage.readable([gif], for: .agent(.claude)), [gif])

        let codex = TerminalDropImage.readable([gif], for: .agent(.codex))
        converted = codex
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(codex.first)).pathExtension, "png")
    }

    /// A photo out of Finder is a HEIC, which is the case that started this.
    func testHEICBecomesAPNG() throws {
        let heic = try XCTUnwrap(try? writeHEIC(named: "photo"), "HEIC encoding unavailable here")

        let result = TerminalDropImage.readable([heic], for: .agent(.claude))
        converted = result

        let path = try XCTUnwrap(result.first)
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "photo.png")
        XCTAssertNotNil(NSImage(contentsOfFile: path))
    }

    // MARK: - Failure

    /// A file that claims to be an image and is not leaves the drop as it was, rather than
    /// swallowing it. The path is still something the agent can look at and complain about.
    func testAnUnreadableImageFallsBackToItsPath() throws {
        let broken = directory.appendingPathComponent("truncated.heic")
        try Data([0x00, 0x01, 0x02]).write(to: broken)

        XCTAssertEqual(
            TerminalDropImage.readable([broken.path], for: .agent(.claude)),
            [broken.path]
        )
    }

    /// Several files at once keep their order and are decided one at a time, so a mixed drop
    /// does not become all-or-nothing.
    func testAMixedDropIsDecidedPerFile() throws {
        let png = try write(.png, named: "kept")
        let tiff = try write(.tiff, named: "rewritten")

        let result = TerminalDropImage.readable([png, tiff], for: .agent(.claude))
        converted = [result[1]]

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], png)
        XCTAssertEqual(URL(fileURLWithPath: result[1]).lastPathComponent, "rewritten.png")
    }

    // MARK: - Fixtures

    private func write(_ type: NSBitmapImageRep.FileType, named name: String) throws -> String {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()

        let data = try XCTUnwrap(bitmap.representation(using: type, properties: [:]))
        let url = directory
            .appendingPathComponent(name)
            .appendingPathExtension(extensionFor(type))
        try data.write(to: url)
        return url.path
    }

    private func extensionFor(_ type: NSBitmapImageRep.FileType) -> String {
        switch type {
        case .png: return "png"
        case .tiff: return "tiff"
        case .gif: return "gif"
        default: return "img"
        }
    }

    /// Encoded through ImageIO, which is the only way to make one without shelling out.
    private func writeHEIC(named name: String) throws -> String {
        let source = try write(.png, named: "\(name)-source")
        let image = try XCTUnwrap(NSImage(contentsOfFile: source))
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        let url = directory.appendingPathComponent(name).appendingPathExtension("heic")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url.path
    }
}
