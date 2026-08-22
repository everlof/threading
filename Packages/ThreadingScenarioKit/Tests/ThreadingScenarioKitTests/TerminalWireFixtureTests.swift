import Foundation
import XCTest
@testable import ThreadingScenarioKit

final class TerminalWireFixtureTests: XCTestCase {
    func testCodexFixtureBuildsNormalScrollbackAndRepairsItOnResize() throws {
        var fixture = TerminalWireFixture(
            provider: .codex,
            historyLines: 80,
            size: .init(columns: 80, rows: 24)
        )

        let initial = String(decoding: fixture.bootstrap(), as: UTF8.self)
        let resized = try XCTUnwrap(fixture.resize(to: .init(columns: 48, rows: 41)))
        let resizedText = String(decoding: resized, as: UTF8.self)

        XCTAssertTrue(initial.contains("\u{1b}[?1049l"))
        XCTAssertFalse(initial.contains("\u{1b}[?1049h"))
        XCTAssertTrue(initial.contains("80 history rows"))
        XCTAssertTrue(resizedText.contains("\u{1b}[3J"), "resize must repair terminal-owned history")
        XCTAssertTrue(resizedText.contains("48×41"))
        XCTAssertGreaterThan(resized.count, 4_000, "a resize that did not replay history is the wrong workload")
    }

    func testClaudeFixtureOwnsAnAlternateViewportAndConsumesWheelReports() {
        var fixture = TerminalWireFixture(
            provider: .claude,
            historyLines: 120,
            size: .init(columns: 60, rows: 20)
        )

        let initial = String(decoding: fixture.bootstrap(), as: UTF8.self)
        let wheel = fixture.receive(Data("\u{1b}[<64;12;8M".utf8))
        let frame = wheel.outputs.map { String(decoding: $0, as: UTF8.self) }.joined()

        XCTAssertTrue(initial.contains("\u{1b}[?1049h"))
        XCTAssertTrue(initial.contains("\u{1b}[?1000h"))
        XCTAssertTrue(initial.contains("\u{1b}[?1006h"))
        XCTAssertEqual(wheel.outputs.count, 1)
        XCTAssertTrue(frame.contains("Transcript offset"))
        XCTAssertFalse(wheel.shouldExit)
    }

    func testACompleteLineProducesAStreamingBurstAndFinishRestoresTheTerminal() {
        for provider in TerminalWireFixtureProvider.allCases {
            var fixture = TerminalWireFixture(
                provider: provider,
                historyLines: 20,
                size: .init(columns: 48, rows: 18)
            )
            _ = fixture.bootstrap()

            let more = fixture.receive(Data("more\r".utf8))
            XCTAssertGreaterThan(more.outputs.count, 20, "\(provider) did not stream a turn")
            XCTAssertFalse(more.shouldExit)

            let finish = fixture.receive(Data("finish\r".utf8))
            XCTAssertTrue(finish.shouldExit)
            let ending = finish.outputs.map { String(decoding: $0, as: UTF8.self) }.joined()
            XCTAssertTrue(ending.contains("Fixture complete"))
            if provider == .claude {
                XCTAssertTrue(ending.contains("\u{1b}[?1049l"))
            }
        }
    }

    func testFragmentedMouseAndLineInputWaitForACompleteEvent() {
        var fixture = TerminalWireFixture(
            provider: .claude,
            historyLines: 30,
            size: .init(columns: 48, rows: 18)
        )
        _ = fixture.bootstrap()

        XCTAssertTrue(fixture.receive(Data("\u{1b}[<64;".utf8)).outputs.isEmpty)
        XCTAssertEqual(fixture.receive(Data("12;8M".utf8)).outputs.count, 1)
        XCTAssertEqual(fixture.receive(Data("mo".utf8)).outputs.count, 2)
        XCTAssertGreaterThan(fixture.receive(Data("re\r".utf8)).outputs.count, 20)
    }

    func testBatchedMouseReportsUseDataIndicesAsDistances() {
        var fixture = TerminalWireFixture(
            provider: .claude,
            historyLines: 600,
            size: .init(columns: 48, rows: 41)
        )
        _ = fixture.bootstrap()
        let reports = (0..<64)
            .map { "\u{1b}[<64;\(12 + $0 % 8);\(8 + $0 % 12)M" }
            .joined()

        let batch = fixture.receive(Data(reports.utf8))

        XCTAssertEqual(batch.outputs.count, 64)
        XCTAssertFalse(batch.shouldExit)
        XCTAssertEqual(
            fixture.receive(Data("\u{1b}[<65;12;8M".utf8)).outputs.count,
            1,
            "a report after the drained batch must start from the buffer's current index"
        )
    }
}
