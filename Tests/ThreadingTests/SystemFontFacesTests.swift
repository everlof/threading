import AppKit
import XCTest

@testable import Threading

/// AppKit loses a design-variant system face once the last font of that face is released, and
/// then hands back nil from factories imported as non-optional. See `SystemFontFaces`.
///
/// Each case reproduces the losing pattern directly — make the font, lay a string out in it,
/// drain the pool so nothing holds the face — and asks again. Unpinned, SF Mono comes back nil
/// tens of times in a couple of thousand cycles; the assertion is that it never does.
@MainActor
final class SystemFontFacesTests: XCTestCase {

    private enum Defaults {
        /// Measured unpinned on macOS 26.5, this test's own Heavy loop lost the face 34 to 180
        /// times per 2,000 cycles over eight processes, so an unpinned run cannot pass by luck.
        /// Pinned, the whole loop costs a few hundredths of a second.
        static let cycles = 2_000
        static let sample = "⌘⇧P"
    }

    /// The crash in `CommandPaletteRenderTests`: `ShortcutRecorderView` lays its label out in
    /// `Design.Typography.code()` and nothing else on that screen holds SF Mono, so a nil font
    /// reached CoreText and aborted the process. Heavy is a weight no app surface uses, so no
    /// unrelated live view can be holding the face for this test.
    func testCodeFontIsNeverNilAfterItsFaceWasReleased() {
        var lost = 0
        for _ in 0..<Defaults.cycles {
            autoreleasepool {
                let font = Design.Typography.code(weight: .heavy)
                guard !isNil(font) else {
                    lost += 1
                    return
                }
                _ = (Defaults.sample as NSString).size(withAttributes: [.font: font])
            }
        }
        XCTAssertEqual(lost, 0, "Design.Typography.code returned nil \(lost) times")
    }

    /// A theme's rounded or serif typeface goes through the same cache. Its initialiser admits
    /// nil, so the old failure was a silent fall back to SF for that draw rather than a crash.
    func testDesignedFaceIsNeverLostAfterItsFaceWasReleased() {
        var lost = 0
        for _ in 0..<Defaults.cycles {
            autoreleasepool {
                let base = NSFont.systemFont(ofSize: 13, weight: .black)
                guard let font = SystemFontFaces.designed(base, design: .rounded) else {
                    lost += 1
                    return
                }
                _ = (Defaults.sample as NSString).size(withAttributes: [.font: font])
            }
        }
        XCTAssertEqual(lost, 0, "the rounded face was lost \(lost) times")
    }

    func testAVendedFaceIsPinnedAcrossSizes() {
        let small = SystemFontFaces.monospaced(ofSize: 9, weight: .bold)
        let large = SystemFontFaces.monospaced(ofSize: 31, weight: .bold)

        XCTAssertFalse(isNil(small))
        XCTAssertTrue(small.isFixedPitch)
        XCTAssertEqual(small.fontName, large.fontName, "one face serves every size")
        XCTAssertTrue(SystemFontFaces.isPinned(large))
    }

    /// Reads the reference's bits: a `guard let` on the non-optional import was compiled away in
    /// a Debug build and let the nil through to CoreText, which aborted the whole test process.
    private func isNil(_ font: NSFont) -> Bool {
        withUnsafeBytes(of: font) { $0.load(as: UInt.self) } == 0
    }
}
