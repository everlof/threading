import XCTest
@testable import ThreadingRemoteKit

final class RemoteTerminalSelectionQuoteTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let nginxOutput = """
        nginx: the configuration file /etc/nginx/nginx.conf syntax is ok     \u{0}\u{0}
        nginx: configuration file /etc/nginx/nginx.conf test is successful
        """
        static let bracketStart = "\u{1b}[200~"
        static let bracketEnd = "\u{1b}[201~"
    }

    // MARK: - Tests

    func testASelectionOfOnlyWhitespaceIsNoQuote() {
        XCTAssertNil(RemoteTerminalSelectionQuote(selectedText: "   \n\n \u{0}\u{0}\n"))
        XCTAssertNil(RemoteTerminalSelectionQuote(selectedText: ""))
    }

    func testTerminalRowPaddingAndBlankEdgesAreTrimmed() throws {
        let quote = try XCTUnwrap(RemoteTerminalSelectionQuote(
            selectedText: "\n\n" + Fixture.nginxOutput + "\r\n   \n"
        ))

        XCTAssertEqual(quote.lineCount, 2)
        XCTAssertEqual(
            quote.lines[0],
            "nginx: the configuration file /etc/nginx/nginx.conf syntax is ok"
        )
        XCTAssertEqual(
            quote.text,
            "nginx: the configuration file /etc/nginx/nginx.conf syntax is ok\n"
                + "nginx: configuration file /etc/nginx/nginx.conf test is successful"
        )
    }

    func testAnInteriorBlankLineIsKept() throws {
        let quote = try XCTUnwrap(RemoteTerminalSelectionQuote(selectedText: "a\n\nb"))
        XCTAssertEqual(quote.lines, ["a", "", "b"])
    }

    func testThePreviewIsTheFirstMeaningfulLineCollapsedAndCapped() throws {
        let quote = try XCTUnwrap(RemoteTerminalSelectionQuote(
            selectedText: "   \n  error:    expected   keyboard inset to return to zero and then some more words past the cap\nnext"
        ))

        XCTAssertEqual(quote.preview.count, RemoteTerminalSelectionQuote.previewLength + 1)
        XCTAssertTrue(quote.preview.hasPrefix("error: expected keyboard inset"))
        XCTAssertTrue(quote.preview.hasSuffix("…"))

        let short = try XCTUnwrap(RemoteTerminalSelectionQuote(selectedText: "ok"))
        XCTAssertEqual(short.preview, "ok")
    }

    func testAMessageCarriesAtMostTheMaximum() throws {
        var quotes: [RemoteTerminalSelectionQuote] = []
        for index in 0..<(RemoteTerminalSelectionQuote.maximumPerMessage + 2) {
            let quote = try XCTUnwrap(RemoteTerminalSelectionQuote(selectedText: "line \(index)"))
            quotes = RemoteTerminalSelectionQuote.appending(quote, to: quotes)
        }

        XCTAssertEqual(quotes.count, RemoteTerminalSelectionQuote.maximumPerMessage)
        XCTAssertEqual(quotes.last?.text, "line \(RemoteTerminalSelectionQuote.maximumPerMessage - 1)")
    }

    func testInsertionIsOneBracketedPasteWhenTheProgramAsksForIt() throws {
        let first = try XCTUnwrap(RemoteTerminalSelectionQuote(selectedText: "one\ntwo"))
        let second = try XCTUnwrap(RemoteTerminalSelectionQuote(selectedText: "three"))

        XCTAssertEqual(
            RemoteTerminalSelectionQuote.insertionText(for: [first, second], bracketedPaste: true),
            Fixture.bracketStart + "one\ntwo\n\nthree" + Fixture.bracketEnd
        )
        XCTAssertEqual(
            RemoteTerminalSelectionQuote.insertionText(for: [first, second], bracketedPaste: false),
            "one\ntwo\n\nthree"
        )
        XCTAssertEqual(RemoteTerminalSelectionQuote.insertionText(for: [], bracketedPaste: true), "")
    }

    func testASubmissionPutsTheQuotesBeforeWhatWasTyped() throws {
        let quote = try XCTUnwrap(RemoteTerminalSelectionQuote(selectedText: "one\ntwo"))

        XCTAssertEqual(
            RemoteTerminalSelectionQuote.submissionText(
                for: [quote],
                draft: "  Fix it \n",
                bracketedPaste: true
            ),
            Fixture.bracketStart + "one\ntwo" + Fixture.bracketEnd + " Fix it"
        )
        XCTAssertEqual(
            RemoteTerminalSelectionQuote.submissionText(for: [quote], draft: "", bracketedPaste: true),
            Fixture.bracketStart + "one\ntwo" + Fixture.bracketEnd
        )
        XCTAssertEqual(
            RemoteTerminalSelectionQuote.submissionText(for: [], draft: "Fix it", bracketedPaste: true),
            "Fix it"
        )
    }

    /// The host writes a submitted line into the PTY as it stands and appends Return, so a draft
    /// holding line breaks used to arrive as several Returns — the first line submitting and the
    /// rest landing wherever the agent went next. Pasting is the only way a line break reaches
    /// that box, since Return sends it.
    func testAPastedMultiLineDraftTravelsAsOnePaste() {
        XCTAssertEqual(
            RemoteTerminalSelectionQuote.submissionText(
                for: [],
                draft: "def run():\n    return 1",
                bracketedPaste: true
            ),
            Fixture.bracketStart + "def run():\n    return 1" + Fixture.bracketEnd
        )
    }

    func testAPastedDraftLosesTheBlankEdgesTheHostWouldHaveTrimmed() {
        XCTAssertEqual(
            RemoteTerminalSelectionQuote.submissionText(
                for: [],
                draft: "\none\ntwo\n\n",
                bracketedPaste: true
            ),
            Fixture.bracketStart + "one\ntwo" + Fixture.bracketEnd,
            "delimiters hide the ends from the host's own trim, so they are trimmed here"
        )
    }

    func testAMultiLineDraftGoesInAsTypedWhenTheProgramNeverAskedForBracketedPaste() {
        XCTAssertEqual(
            RemoteTerminalSelectionQuote.submissionText(
                for: [],
                draft: "one\ntwo",
                bracketedPaste: false
            ),
            "one\ntwo",
            "a program that did not arm the mode cannot read the delimiters"
        )
    }

    /// The quotes stay their own paste and the instruction stays separate: an agent's prompt
    /// collapses a pasted block into one token, and folding the instruction inside it would
    /// hide what the person actually asked for.
    func testQuotesAndAPastedDraftRemainTwoBlocks() throws {
        let quote = try XCTUnwrap(RemoteTerminalSelectionQuote(selectedText: "one\ntwo"))

        XCTAssertEqual(
            RemoteTerminalSelectionQuote.submissionText(
                for: [quote],
                draft: "fix this\nand this",
                bracketedPaste: true
            ),
            Fixture.bracketStart + "one\ntwo" + Fixture.bracketEnd
                + " " + Fixture.bracketStart + "fix this\nand this" + Fixture.bracketEnd
        )
    }
}

/// Bracketed paste is the only thing standing between a block of text and a program reading
/// every line break in it as Return.
final class RemoteTerminalPasteTests: XCTestCase {

    func testTextIsDelimitedOnlyWhenTheProgramAskedForIt() {
        XCTAssertEqual(
            RemoteTerminalPaste.delimited("ls -la", bracketedPaste: true),
            "\u{1b}[200~ls -la\u{1b}[201~"
        )
        XCTAssertEqual(RemoteTerminalPaste.delimited("ls -la", bracketedPaste: false), "ls -la")
    }

    func testEmptyTextIsNeverDelimited() {
        XCTAssertEqual(RemoteTerminalPaste.delimited("", bracketedPaste: true), "")
    }

    func testFilePathsAreShellEscapedAndLeaveTheTerminalLineOpen() {
        XCTAssertEqual(
            RemoteTerminalPaste.filePathText(for: [
                "/tmp/first.png",
                "/tmp/My Photos/$draft.png",
            ]),
            "/tmp/first.png /tmp/My\\ Photos/\\$draft.png "
        )
        XCTAssertEqual(RemoteTerminalPaste.filePathText(for: []), "")
    }

    func testOnlyTextWithLineBreaksCountsAsAPaste() {
        XCTAssertFalse(RemoteTerminalPaste.carriesLineBreaks("one line"))
        XCTAssertTrue(RemoteTerminalPaste.carriesLineBreaks("one\ntwo"))
        XCTAssertTrue(RemoteTerminalPaste.carriesLineBreaks("one\r\ntwo"))
    }

    /// A raw terminal write is acknowledged by nothing, so a client that does not ask this
    /// question before sending pastes into silence.
    func testAWriteLargerThanTheHostAcceptsDoesNotFit() {
        let atLimit = String(repeating: "a", count: RemoteTerminalPaste.maximumBytes)
        XCTAssertTrue(RemoteTerminalPaste.fits(atLimit))
        XCTAssertFalse(RemoteTerminalPaste.fits(atLimit + "a"))
        XCTAssertFalse(
            RemoteTerminalPaste.fits(String(repeating: "é", count: RemoteTerminalPaste.maximumBytes)),
            "the bound is bytes, not characters"
        )
    }
}
