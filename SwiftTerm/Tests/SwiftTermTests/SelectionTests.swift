//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/29/20.
//

import Foundation
import XCTest

#if os(macOS)
import AppKit
#endif

@testable import SwiftTerm

final class SelectionTests: XCTestCase, TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        print ("here")
    }
    
    func testDoesNotCrashWhenSelectingWordOrExpressionOutsideColumnRange ()
    {
        let terminal = Terminal(delegate: self, options: TerminalOptions (cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed (text: "1234567890")
        
        // depending on the size of terminal view, there might be a space near the margin where the user
        // clicks which might result in a col or row outside the bounds of terminal,
        selection.selectWordOrExpression(at: Position(col: -1, row: 0), in: terminal.buffer)
        selection.selectWordOrExpression(at: Position(col: 11, row: 0), in: terminal.buffer)
    }
    
    func testDoesNotCrashWhenSelectingWordOrExpressionOutsideRowRange ()
    {
        let terminal = Terminal(delegate: self, options: TerminalOptions (cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed (text: "1234567890")

        // depending on the size of terminal view, there might be a space near the margin where the user
        // clicks which might result in a col or row outside the bounds of terminal,
        selection.selectWordOrExpression(at: Position (col: 0, row: -1), in: terminal.buffer)

    }

#if os(macOS)
    func testMouseHitUsesViewportRowsWhenScrolled() {
        let view = makeScrollableView()
        let topCell = CGPoint(
            x: view.cellDimension.width / 2,
            y: view.bounds.height - view.cellDimension.height / 2
        )

        view.scrollTo(row: view.terminal.buffer.yBase)
        let bottomViewportHit = view.calculateMouseHit(at: topCell).grid
        XCTAssertEqual(bottomViewportHit.row, 0)
        XCTAssertEqual(
            bottomViewportHit.row + view.terminal.buffer.yDisp,
            view.terminal.buffer.yBase,
            "buffer coordinates are derived by adding the viewport offset"
        )

        view.scrollTo(row: 0)
        let topViewportHit = view.calculateMouseHit(at: topCell).grid
        XCTAssertEqual(topViewportHit.row, 0)
        XCTAssertEqual(topViewportHit.row + view.terminal.buffer.yDisp, 0)
    }

    func testScrolledBackViewportStaysPutWhileOutputArrives() {
        let view = makeScrollableView()
        let heldPosition = max(view.terminal.buffer.yBase - 5, 0)

        view.scrollTo(row: heldPosition)
        XCTAssertTrue(view.terminal.userScrolling)

        view.feed(text: "new output while reviewing history\r\n")

        XCTAssertEqual(
            view.terminal.buffer.yDisp,
            heldPosition,
            "live output must not pull a scrolled-back Claude transcript to the bottom"
        )

        view.scrollTo(row: view.terminal.buffer.yBase)
        XCTAssertFalse(view.terminal.userScrolling)

        view.feed(text: "new output at the live edge\r\n")
        XCTAssertEqual(view.terminal.buffer.yDisp, view.terminal.buffer.yBase)
    }

    func testClaudeStyleMouseModeForwardsWheelAndOptionScrollsHistory() throws {
        let view = WheelCapturingTerminalView(
            frame: CGRect(origin: .zero, size: CGSize(width: 480, height: 240))
        )
        fillScrollback(in: view)
        view.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")
        XCTAssertEqual(view.terminal.mouseMode, .anyEvent)

        let bottomPosition = view.terminal.buffer.yDisp
        let forwardedWheel = try XCTUnwrap(makeWheelEvent(modifiers: []))
        view.scrollWheel(with: forwardedWheel)

        XCTAssertFalse(view.sentData.isEmpty, "Claude-style mouse mode should receive wheel input")
        XCTAssertEqual(
            view.terminal.buffer.yDisp,
            bottomPosition,
            "forwarding a wheel event must not move local scrollback"
        )

        view.sentData.removeAll()
        let localWheel = try XCTUnwrap(makeWheelEvent(modifiers: [.option]))
        view.scrollWheel(with: localWheel)

        XCTAssertTrue(view.sentData.isEmpty, "Option-wheel is the local scrollback escape hatch")
        XCTAssertLessThan(view.terminal.buffer.yDisp, bottomPosition)
    }

    private func makeScrollableView() -> TerminalView {
        let view = TerminalView(
            frame: CGRect(origin: .zero, size: CGSize(width: 480, height: 240))
        )
        fillScrollback(in: view)
        return view
    }

    private func fillScrollback(in view: TerminalView) {
        for line in 0..<200 {
            view.feed(text: "line \(line)\r\n")
        }
        XCTAssertGreaterThan(view.terminal.buffer.yBase, 0)
    }

    private func makeWheelEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ) else {
            return nil
        }
        event.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        return NSEvent(cgEvent: event)
    }
#endif
}

#if os(macOS)
private final class WheelCapturingTerminalView: TerminalView {
    var sentData: [UInt8] = []

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        sentData.append(contentsOf: data)
    }
}
#endif
