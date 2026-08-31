import XCTest

@testable import Threading

final class UniversalSearchContractTests: XCTestCase {
    private let projectID = ProjectID()
    private let sessionID = SessionID()

    func testQueryParserKeepsLiteralTermsPhrasesExclusionsAndFiltersDistinct() throws {
        let query = try XCTUnwrap(try? SearchQueryParser.parse(
            #"needle "exact phrase" -generated type:conversation from:agent project:"Threading App" -is:archived has:error"#,
            scope: .project(projectID),
            generation: 41
        ).get())

        XCTAssertEqual(query.generation, 41)
        XCTAssertEqual(query.scope, .project(projectID))
        XCTAssertEqual(query.expression.terms, [
            SearchTextTerm(text: "needle", match: .token, isExcluded: false),
            SearchTextTerm(text: "exact phrase", match: .phrase, isExcluded: false),
            SearchTextTerm(text: "generated", match: .token, isExcluded: true),
        ])
        XCTAssertEqual(query.expression.filters, [
            SearchFilter(predicate: .kind(.conversation), isExcluded: false),
            SearchFilter(predicate: .author(.agent), isExcluded: false),
            SearchFilter(predicate: .project("Threading App"), isExcluded: false),
            SearchFilter(predicate: .archived, isExcluded: true),
            SearchFilter(predicate: .error, isExcluded: false),
        ])
    }

    func testQueryParserAcceptsEscapedQuotesAndDateFilters() throws {
        let query = try SearchQueryParser.parse(
            #"\"quoted\" before:2026-08-31 after:2026-08-30T12:00:00Z"#,
            scope: .everywhere,
            generation: 1
        ).get()

        XCTAssertEqual(
            query.expression.terms,
            [SearchTextTerm(text: #""quoted""#, match: .token, isExcluded: false)]
        )
        XCTAssertEqual(query.expression.filters.count, 2)
        guard case .before = query.expression.filters[0].predicate,
              case .after = query.expression.filters[1].predicate
        else {
            return XCTFail("date filters were not parsed into typed predicates")
        }
    }

    func testQueryParserReportsUnknownOrMalformedFiltersInsteadOfSearchingThemLiterally() {
        XCTAssertEqual(
            SearchQueryParser.parse("where:anywhere", scope: .everywhere, generation: 1),
            .failure(.unknownFilter(name: "where"))
        )
        XCTAssertEqual(
            SearchQueryParser.parse("type:", scope: .everywhere, generation: 1),
            .failure(.missingFilterValue(name: "type"))
        )
        XCTAssertEqual(
            SearchQueryParser.parse("type:thought", scope: .everywhere, generation: 1),
            .failure(.invalidFilterValue(name: "type", value: "thought"))
        )
        XCTAssertEqual(
            SearchQueryParser.parse("\"unfinished", scope: .everywhere, generation: 1),
            .failure(.unterminatedQuote)
        )
    }

    func testQueryParserPinsUTF8AndFilterBounds() {
        let multiByteQuery = String(
            repeating: "å",
            count: UniversalSearchDefaults.maximumQueryUTF8Bytes / 2 + 1
        )
        XCTAssertEqual(
            SearchQueryParser.parse(multiByteQuery, scope: .everywhere, generation: 1),
            .failure(.queryTooLarge(
                maximumUTF8Bytes: UniversalSearchDefaults.maximumQueryUTF8Bytes
            ))
        )

        let filters = Array(
            repeating: "type:file",
            count: UniversalSearchDefaults.maximumFilters + 1
        ).joined(separator: " ")
        XCTAssertEqual(
            SearchQueryParser.parse(filters, scope: .everywhere, generation: 1),
            .failure(.tooManyFilters(maximum: UniversalSearchDefaults.maximumFilters))
        )
    }

    func testStableOrderUsesGroupThenTierThenRecencyThenTitleAndIdentity() {
        let now = Date(timeIntervalSince1970: 2000)
        let old = Date(timeIntervalSince1970: 1000)
        let values = [
            order(id: "z", group: .conversations, tier: .literalText, date: now, title: "Zulu"),
            order(id: "a", group: .destinations, tier: .metadataPrefix, date: old, title: "Alpha"),
            order(id: "b", group: .destinations, tier: .exactIdentifier, date: old, title: "Beta"),
            order(id: "c", group: .destinations, tier: .exactIdentifier, date: now, title: "Zulu"),
            order(id: "d", group: .destinations, tier: .exactIdentifier, date: now, title: "Alpha"),
        ]

        XCTAssertEqual(values.sorted().map(\.stableID.rawValue), ["d", "c", "b", "a", "z"])
    }

    func testClientEligibilityFiltersMacOnlyDestinationsBeforePresentation() {
        let command = hit(locator: .command("view.files"), kind: .command)
        let attachment = hit(
            locator: .attachment(
                projectID: projectID,
                sessionID: sessionID,
                attachmentID: SearchAttachmentID(rawValue: "attachment-1")
            ),
            kind: .attachment
        )

        XCTAssertTrue(command.isEligible(for: .macOS))
        XCTAssertFalse(command.isEligible(for: .remoteIOS))
        XCTAssertTrue(attachment.isEligible(for: .remoteIOS))
    }

    func testConversationLocatorCarriesStableSourceIdentityAndNotAProviderPath() {
        let locator = SearchConversationLocator(
            projectID: projectID,
            sessionID: sessionID,
            sourceID: SearchSourceID(rawValue: "claude:session"),
            recordID: SearchSourceRecordID(rawValue: "message-42"),
            sourceGeneration: 7,
            match: SearchTextRange(utf16Location: 4, utf16Length: 6)
        )

        XCTAssertEqual(locator.projectID, projectID)
        XCTAssertEqual(locator.sessionID, sessionID)
        XCTAssertEqual(locator.sourceGeneration, 7)
        XCTAssertEqual(locator.recordID.rawValue, "message-42")
    }

    private func order(
        id: String,
        group: SearchResultGroup,
        tier: SearchScoreTier,
        date: Date,
        title: String
    ) -> SearchStableOrder {
        SearchStableOrder(
            group: group,
            scoreTier: tier,
            recency: date,
            title: title,
            stableID: SearchHitID(rawValue: id)
        )
    }

    private func hit(locator: SearchLocator, kind: SearchHitKind) -> SearchHit {
        let id = SearchHitID(rawValue: "hit")
        return SearchHit(
            id: id,
            provider: .navigation,
            kind: kind,
            title: "Result",
            snippet: nil,
            provenance: SearchProvenance(projectID: projectID, sessionID: sessionID),
            stableOrder: SearchStableOrder(
                group: .destinations,
                scoreTier: .exactMetadata,
                recency: nil,
                title: "Result",
                stableID: id
            ),
            locator: locator
        )
    }
}
