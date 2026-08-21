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
}
