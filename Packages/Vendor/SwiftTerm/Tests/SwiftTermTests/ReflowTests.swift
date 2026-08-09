//
//  ReflowTests.swift
//  
//
//  Created by Miguel de Icaza on 4/17/20.
//
#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class ReflowTests: XCTestCase {
    
    func testDoesNotCrashWhenReflowingToTinyWidth ()
    {
        let options = TerminalOptions(cols: 10, rows: 10, scrollback: 1)
        let h = HeadlessTerminal (queue: SwiftTermTests.queue, options: options) { exitCode in }
        
        let t = h.terminal!
        
        t.feed (text: "1234567890\r\n")
        t.feed (text: "ABCDEFGH\r\n")
        t.feed (text: "abcdefghijklmnopqrstxxx\r\n")
        t.feed (text: "\r\n")
        
        // if we resize to a small column width, content is pushed back up and out the top
        // of the buffer. Ensure that this does not crash
        t.resize(cols: 3, rows: 10)
        XCTAssert(true)
    }

    /// Scrollback's maximum length is reserved capacity. Reading its empty slots materializes
    /// blank lines, so a resize must visit only the logical buffer or a fresh 24-row terminal
    /// materializes its entire 10,024-line capacity on its first width change.
    func testResizeDoesNotMaterializeEmptyScrollbackCapacity ()
    {
        let rows = 24
        let options = TerminalOptions(cols: 80, rows: rows, scrollback: 10_000)
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: options) { _ in }
        let t = h.terminal!

        XCTAssertEqual(t.normalBuffer.lines.count, rows)
        let allocatedBeforeResize = t.normalBuffer.lines.getArray().compactMap { $0 }.count
        XCTAssertLessThan(allocatedBeforeResize, 100)

        t.resize(cols: 120, rows: rows)

        XCTAssertEqual(t.normalBuffer.lines.count, rows)
        XCTAssertEqual(
            t.normalBuffer.lines.getArray().compactMap { $0 }.count,
            allocatedBeforeResize
        )
    }

    /// The normal buffer is invisible while a full-screen program owns the alternate buffer.
    /// Reflow it at the final size on return, not at every intermediate window-drag width.
    func testAlternateScreenDefersNormalScrollbackReflowUntilReturn ()
    {
        let options = TerminalOptions(cols: 80, rows: 24, scrollback: 10_000)
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: options) { _ in }
        let t = h.terminal!

        t.feed(text: "normal buffer marker")
        t.feed(text: "\u{1b}[?1049h")
        XCTAssertTrue(t.isCurrentBufferAlternate)

        t.resize(cols: 120, rows: 40)

        XCTAssertEqual(t.altBuffer.cols, 120)
        XCTAssertEqual(t.altBuffer.rows, 40)
        XCTAssertEqual(t.normalBuffer.cols, 80)
        XCTAssertEqual(t.normalBuffer.rows, 24)

        t.feed(text: "\u{1b}[?1049l")

        XCTAssertFalse(t.isCurrentBufferAlternate)
        XCTAssertEqual(t.normalBuffer.cols, 120)
        XCTAssertEqual(t.normalBuffer.rows, 40)
        XCTAssertTrue(
            t.normalBuffer.lines.getArray().compactMap { $0 }.contains { line in
                line.translateToString(trimRight: true).contains("normal buffer marker")
            }
        )
    }

    /// A consumer looking for paths or URLs needs the line the process wrote, not the physical
    /// rows the current terminal width happened to lay it over.
    func testRecentLogicalBufferTextJoinsAutomaticallyWrappedRows ()
    {
        let options = TerminalOptions(cols: 12, rows: 6, scrollback: 100)
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: options) { _ in }
        let t = h.terminal!
        let path = "/tmp/a-very-long-render-name.png"

        t.feed(text: path)

        let text = t.getRecentLogicalBufferText(maximumUTF8Bytes: 4_096)
        XCTAssertTrue(text.contains(path))
        XCTAssertFalse(text.contains("render-na\nme.png"))
    }

    /// A hard newline is semantic and must not be erased while automatic wraps are joined.
    func testRecentLogicalBufferTextPreservesHardLineBreaks ()
    {
        let options = TerminalOptions(cols: 40, rows: 6, scrollback: 100)
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: options) { _ in }
        let t = h.terminal!

        t.feed(text: "first line\r\nsecond line")

        XCTAssertTrue(
            t.getRecentLogicalBufferText(maximumUTF8Bytes: 4_096)
                .contains("first line\nsecond line")
        )
    }

    /// Reflow changes physical rows and keeps the logical line. The extraction must follow the
    /// reflow metadata rather than preserving the width at which output first arrived.
    func testRecentLogicalBufferTextSurvivesResizeReflow ()
    {
        let options = TerminalOptions(cols: 80, rows: 8, scrollback: 100)
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: options) { _ in }
        let t = h.terminal!
        let path = "/tmp/a-render-that-will-wrap-after-the-terminal-is-narrowed.png"
        // Finish the line before resizing. Reflow deliberately leaves the live cursor row to
        // cursor-preservation logic; completed output is the scrollback contract exercised here.
        t.feed(text: path + "\r\n")

        t.resize(cols: 14, rows: 8)

        XCTAssertTrue(
            t.getRecentLogicalBufferText(maximumUTF8Bytes: 4_096).contains(path)
        )
    }

    /// The scanner's budget is a construction bound, not a suffix applied after allocating the
    /// complete scrollback. An oversized logical line is omitted whole so its tail cannot be
    /// mistaken for an independently printed path.
    func testRecentLogicalBufferTextIsBoundedAndReturnsNoPartialLogicalLine ()
    {
        let options = TerminalOptions(cols: 8, rows: 6, scrollback: 100)
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: options) { _ in }
        let t = h.terminal!
        t.feed(text: "/tmp/this-logical-line-is-larger-than-the-budget.png")

        let text = t.getRecentLogicalBufferText(maximumUTF8Bytes: 16)

        XCTAssertLessThanOrEqual(text.utf8.count, 16)
        XCTAssertFalse(text.contains(".png"), "a truncated path escaped as complete text")
        XCTAssertFalse(text.contains("budget"), "the oversized logical line was returned in part")
    }
    
    static var allTests = [
          ("testDoesNotCrashWhenReflowingToTinyWidth", testDoesNotCrashWhenReflowingToTinyWidth),
          (
              "testResizeDoesNotMaterializeEmptyScrollbackCapacity",
              testResizeDoesNotMaterializeEmptyScrollbackCapacity
          ),
          (
              "testAlternateScreenDefersNormalScrollbackReflowUntilReturn",
              testAlternateScreenDefersNormalScrollbackReflowUntilReturn
          ),
          (
              "testRecentLogicalBufferTextJoinsAutomaticallyWrappedRows",
              testRecentLogicalBufferTextJoinsAutomaticallyWrappedRows
          ),
          (
              "testRecentLogicalBufferTextPreservesHardLineBreaks",
              testRecentLogicalBufferTextPreservesHardLineBreaks
          ),
          (
              "testRecentLogicalBufferTextSurvivesResizeReflow",
              testRecentLogicalBufferTextSurvivesResizeReflow
          ),
          (
              "testRecentLogicalBufferTextIsBoundedAndReturnsNoPartialLogicalLine",
              testRecentLogicalBufferTextIsBoundedAndReturnsNoPartialLogicalLine
          ),
    ]
}
#endif
