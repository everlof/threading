import Testing
@testable import SwiftTerm

@Suite("Directory reports across replay boundaries")
struct DirectoryReplayTests {
    private let historical = Array("\u{1b}]7;file:///old\u{7}".utf8)
    private let live = "\u{1b}]7;file:///live\u{7}"

    @Test func directorySequenceIsHistoricalAtEveryFragmentBoundary() {
        for split in 1..<historical.count {
            let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
            defer { withExtendedLifetime(delegate) {} }
            terminal.feed(buffer: historical[..<split], recordingCurrentDirectory: false)
            terminal.feed(buffer: historical[split...])
            #expect(terminal.hostCurrentDirectory == nil, "replay prefix ending at byte \(split)")
            terminal.feed(text: live)
            #expect(terminal.hostCurrentDirectory == "file:///live")
        }
    }

    @Test func replayContinuationCannotCompleteALiveDirectoryReport() {
        for split in 1..<historical.count {
            let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
            defer { withExtendedLifetime(delegate) {} }
            terminal.feed(buffer: historical[..<split])
            terminal.feed(buffer: historical[split...], recordingCurrentDirectory: false)
            #expect(terminal.hostCurrentDirectory == nil)
            terminal.feed(text: live)
            #expect(terminal.hostCurrentDirectory == "file:///live")
        }
    }

    @Test func historyRendersAndCannotOverwriteLiveDirectory() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        defer { withExtendedLifetime(delegate) {} }
        terminal.feed(text: live)
        terminal.feed(buffer: (historical + Array("hello".utf8))[...], recordingCurrentDirectory: false)
        #expect(terminal.hostCurrentDirectory == "file:///live")
        #expect(terminal.getCharacter(for: terminal.getCharData(col: 0, row: 0)!) == "h")
        terminal.feed(buffer: historical[...])
        #expect(terminal.hostCurrentDirectory == "file:///old")
    }

    @Test func cancelledHistoryAndC1IntroducerStartFreshReports() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        defer { withExtendedLifetime(delegate) {} }
        terminal.feed(buffer: historical.dropLast(), recordingCurrentDirectory: false)
        terminal.feed(text: "\u{18}" + live)
        #expect(terminal.hostCurrentDirectory == "file:///live")
        // The current parser recognizes the C1 transition from escape state; raw high bytes
        // in ground state follow its existing printable/UTF-8 path.
        let c1: [UInt8] = [0x1b, 0x9d] + Array("7;file:///c1".utf8) + [0x07]
        terminal.feed(buffer: c1[...], recordingCurrentDirectory: false)
        #expect(terminal.hostCurrentDirectory == "file:///live")
        terminal.feed(buffer: c1[...])
        #expect(terminal.hostCurrentDirectory == "file:///c1")
    }

    @Test func stringTerminatorPreservesHistoricalProvenance() {
        let sequence = Array("\u{1b}]7;file:///old\u{1b}\\".utf8)
        for split in 1..<sequence.count {
            let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
            defer { withExtendedLifetime(delegate) {} }
            terminal.feed(buffer: sequence[..<split], recordingCurrentDirectory: false)
            terminal.feed(buffer: sequence[split...])
            #expect(terminal.hostCurrentDirectory == nil)
            terminal.feed(text: live)
            #expect(terminal.hostCurrentDirectory == "file:///live")
        }
    }
}
