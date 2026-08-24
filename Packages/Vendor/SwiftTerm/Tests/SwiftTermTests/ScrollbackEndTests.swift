import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

@MainActor
struct ScrollbackEndTests {
    private let esc = "\u{1b}"

    private func inlineTranscriptView() -> TerminalView {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 320)
        )
        let rows = view.withTerminal { $0.rows }
        for index in 0..<(rows * 3) {
            view.feed(text: "history \(index)\r\n")
        }
        view.feed(text: "\(esc)[2J\(esc)[Hworking\r\nprompt\r\nstatus")
        view.frameTick()
        return view
    }

    @Test func compactEndPlacesTheInlineViewportAtTheBottom() {
        let view = inlineTranscriptView()
        let screenEnd = view.withTerminal { $0.displayBuffer.yBase }

        view.scrollbackEnd = .lastPopulatedRow

        let state = view.withTerminal { terminal in
            (
                end: terminal.maximumViewYDisp(),
                yDisp: terminal.displayBuffer.yDisp,
                userScrolling: terminal.userScrolling
            )
        }
        #expect(state.end < screenEnd)
        #expect(state.yDisp == state.end)
        #expect(!state.userScrolling)
        #expect(view.scrollPosition == 1)

        view.scrollUp(lines: 2)
        #expect(view.withTerminal { $0.userScrolling })
        view.scrollDown(lines: 10_000)
        #expect(view.withTerminal { terminal in
            terminal.displayBuffer.yDisp == terminal.maximumViewYDisp()
                && !terminal.userScrolling
        })
    }

    @Test func compactEndFollowsAStillGrowingInlineViewport() {
        let view = inlineTranscriptView()
        view.scrollbackEnd = .lastPopulatedRow
        let before = view.withTerminal { $0.maximumViewYDisp() }

        view.feed(text: "\r\nnext")
        view.frameTick()

        let after = view.withTerminal { terminal in
            (
                end: terminal.maximumViewYDisp(),
                yDisp: terminal.displayBuffer.yDisp,
                userScrolling: terminal.userScrolling
            )
        }
        #expect(after.end == before + 1)
        #expect(after.yDisp == after.end)
        #expect(!after.userScrolling)
    }

    @Test func standardAndPopulatedFullScreensKeepTheTerminalScreenEnd() {
        let standard = inlineTranscriptView()
        #expect(standard.withTerminal { terminal in
            terminal.maximumViewYDisp() == terminal.displayBuffer.yBase
        })

        let compact = inlineTranscriptView()
        compact.scrollbackEnd = .lastPopulatedRow
        let rows = compact.withTerminal { $0.rows }
        compact.feed(text: "\(esc)[\(rows);1Hfooter")
        compact.frameTick()

        #expect(compact.withTerminal { terminal in
            terminal.maximumViewYDisp() == terminal.displayBuffer.yBase
                && terminal.displayBuffer.yDisp == terminal.displayBuffer.yBase
        })
    }
}
#endif
