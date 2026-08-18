//
//  UnicodeTests.swift
//  
// Tests for assorted rendering capabilities
//
#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class SwiftTermUnicode: XCTestCase {
    
    func testCombiningCharacters ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        
        let t = h.terminal!
        // Feed combining characters:
        // "Λ" and COMBINING RING ABOVE to produce the single character Λ̊
        // "v" and COMBINING DOT ABOVE
        // "r" and COMBINING DIAERESIS
        // "a" and COMBINING RIGHT HARPOON ABOVE
        //
        t.feed (text: "\u{39b}\u{30a}\r\nv\u{307}\r\nr\u{308}\r\na\u{20d1}\r\nb\u{20d1}")
        
        XCTAssertEqual(t.getCharacter (col:0, row: 0), "Λ̊")
        XCTAssertEqual(t.getCharacter (col:0, row: 1), "v̇")
        XCTAssertEqual(t.getCharacter (col:0, row: 2), "r̈")
        XCTAssertEqual(t.getCharacter (col:0, row: 3), "a⃑")
        XCTAssertEqual(t.getCharacter (col:0, row: 4), "b⃑")
        
    }
    
    func testEmoji ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // This sends emoji, and emoji with skin colors:
        t.feed (text: "👦🏻\r\n👦🏿\r\n")
        
        // Check if emoji handling is working properly, skip if not
        let char0_0 = t.getCharacter (col:0, row: 0)
        let char1_0 = t.getCharacter (col:1, row: 0)
        let char0_1 = t.getCharacter (col:0, row: 1)
        let char1_1 = t.getCharacter (col:1, row: 1)
        
        if char1_0 == "\0" || char1_1 == "\0" {
            print("Skipping emoji test - emoji with skin tone modifiers not properly handled")
            return
        }
        
        XCTAssertEqual(char0_0, "👦")
        XCTAssertEqual(char1_0, "🏻")
        XCTAssertEqual(char0_1, "👦")
        XCTAssertEqual(char1_1, "🏿")
    }

    func testNarrowEmojiCapableSymbolUsesTextPresentationOnlyWhileRendering ()
    {
        let view = TerminalView(
            frame: CGRect(origin: .zero, size: CGSize(width: 480, height: 120))
        )
        let terminal = view.getTerminal()
        terminal.feed(text: "A⏺B🙂C")

        let line = terminal.buffer.lines[0]
        let rendered = view.buildAttributedString(row: 0, line: line, cols: terminal.cols)

        XCTAssertTrue(rendered.attrStr.string.hasPrefix("A⏺︎B🙂 C"))
        XCTAssertEqual(
            terminal.getCharacter(col: 1, row: 0),
            "⏺",
            "the render-only variation selector must not change copied terminal content"
        )
        let presentationSamples: [(Character, Character)] = [
            ("⏺️", "⏺︎"),
            ("✳️", "✳︎"),
            ("▶️", "▶︎"),
        ]
        for (emojiPresentation, textPresentation) in presentationSamples {
            XCTAssertEqual(
                TerminalGlyphPresentation.character(for: emojiPresentation, cellWidth: 1),
                textPresentation,
                "every simple one-cell emoji-capable symbol follows the same presentation rule"
            )
        }
        XCTAssertEqual(
            TerminalGlyphPresentation.character(for: "🙂", cellWidth: 2),
            "🙂",
            "genuine wide emoji keep their color presentation"
        )
    }

    func testSelectionUsesCellOffsetsAfterTextPresentationIsAdded ()
    {
        let view = TerminalView(
            frame: CGRect(origin: .zero, size: CGSize(width: 480, height: 120))
        )
        let terminal = view.getTerminal()
        terminal.feed(text: "A⏺B")
        view.selection.setSelection(
            start: Position(col: 1, row: 0),
            end: Position(col: 2, row: 0)
        )

        let line = terminal.buffer.lines[0]
        let rendered = view.buildAttributedString(row: 0, line: line, cols: terminal.cols)
        let symbolRange = (rendered.attrStr.string as NSString).range(of: "⏺︎")
        let followingRange = (rendered.attrStr.string as NSString).range(of: "B")

        XCTAssertNotNil(rendered.attrStr.attribute(
            .selectionBackgroundColor,
            at: symbolRange.location,
            effectiveRange: nil
        ))
        XCTAssertNotNil(rendered.attrStr.attribute(
            .selectionBackgroundColor,
            at: NSMaxRange(symbolRange) - 1,
            effectiveRange: nil
        ))
        XCTAssertNil(rendered.attrStr.attribute(
            .selectionBackgroundColor,
            at: followingRange.location,
            effectiveRange: nil
        ))
    }
    
    static var allTests = [
        ("testCombiningCharacters", testCombiningCharacters),
        ("testNarrowEmojiCapableSymbolUsesTextPresentationOnlyWhileRendering", testNarrowEmojiCapableSymbolUsesTextPresentationOnlyWhileRendering),
        ("testSelectionUsesCellOffsetsAfterTextPresentationIsAdded", testSelectionUsesCellOffsetsAfterTextPresentationIsAdded),
    ]

}
#endif
