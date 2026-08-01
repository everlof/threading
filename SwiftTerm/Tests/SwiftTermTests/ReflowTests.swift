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
    ]
}
#endif
