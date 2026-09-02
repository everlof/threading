#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
final class TerminalContrastDetectorTests {
    private func makeWhiteView () -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 520, height: 120))
        let white = Color(red8: 255, green8: 255, blue8: 255)
        view.installColors(Array(repeating: white, count: 16))
        view.nativeForegroundColor = .black
        view.nativeBackgroundColor = .white
        return view
    }

    @Test func reportsFinalExplicitCollisionOncePerPalette () throws {
        let view = makeWhiteView()
        var conflicts: [TerminalTextColorConflict] = []
        view.onLowContrastText = { conflicts.append($0) }

        view.feed(text: "\u{1b}[97m[last: 12s] git:main")
        view.frameTick()
        view.frameTick()

        #expect(conflicts.count == 1)
        let conflict = try #require(conflicts.first)
        #expect(conflict.foregroundSource == .ansi256(index: 15))
        #expect(conflict.backgroundSource == .defaultBackground)
        #expect(conflict.foreground == TerminalRenderedColor(red: 255, green: 255, blue: 255))
        #expect(conflict.background == TerminalRenderedColor(red: 255, green: 255, blue: 255))
        #expect(abs(conflict.contrastRatio - 1) < 0.001)
        #expect(conflict.sample == "[last: 12s] git:main")
    }

    @Test func sanitizesAndBoundsTheCapturedRun () throws {
        let view = makeWhiteView()
        var conflicts: [TerminalTextColorConflict] = []
        view.onLowContrastText = { conflicts.append($0) }

        view.feed(text: "\u{1b}[97m   compiling\u{200b}   every single one of the workspace targets now")
        view.frameTick()

        let sample = try #require(conflicts.first?.sample)
        #expect(sample.hasPrefix("compiling every"))
        #expect(!sample.unicodeScalars.contains("\u{200b}"))
        #expect(sample.count <= TerminalContrastSample.characterLimit + 1)
        #expect(sample.last == TerminalContrastSample.ellipsis)
    }

    @Test func ignoresDefaultsOrnamentAndIntentionalConcealment () {
        let view = makeWhiteView()
        var conflicts: [TerminalTextColorConflict] = []
        view.onLowContrastText = { conflicts.append($0) }

        view.feed(text: "plain text\r\n\u{1b}[97m   \r\n---\r\n\u{1b}[8mlong hidden value")
        view.frameTick()

        #expect(conflicts.isEmpty)
    }
}
#endif
