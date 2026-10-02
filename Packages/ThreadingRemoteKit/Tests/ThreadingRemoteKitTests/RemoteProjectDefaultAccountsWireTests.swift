import XCTest
@testable import ThreadingRemoteKit

/// The wire half of a project's ordered default logins: every addition is optional and decodes
/// from a payload that predates it, and the two new vocabularies keep a word they do not know.
final class RemoteProjectDefaultAccountsWireTests: XCTestCase {

    private let work = RemoteAccountReferenceDTO(agentID: "claude", accountID: "work")
    private let spare = RemoteAccountReferenceDTO(agentID: "claude", accountID: "spare")
    private let codex = RemoteAccountReferenceDTO(agentID: "codex", accountID: "default")

    // MARK: - Catalogue

    func testProjectChoiceCarriesItsOrderedListThroughARoundTrip() throws {
        let project = RemoteProjectChoiceDTO(
            id: "project",
            name: "Threading",
            branch: "master",
            checkoutLabel: "Threading",
            defaultAccounts: [work, spare, codex]
        )

        let decoded = try roundTrip(project)

        XCTAssertEqual(decoded, project)
        XCTAssertEqual(decoded.defaultAccounts, [work, spare, codex], "the order is the meaning")
    }

    func testAnOlderHostsProjectDecodesWithNoList() throws {
        let older = try JSONDecoder().decode(
            RemoteProjectChoiceDTO.self,
            from: Data(#"{"id":"project","name":"Threading","checkoutLabel":"Threading"}"#.utf8)
        )

        XCTAssertNil(older.defaultAccounts)
    }

    func testAProjectWithoutAListSendsNoField() throws {
        let project = RemoteProjectChoiceDTO(
            id: "project",
            name: "Threading",
            branch: nil,
            checkoutLabel: "Threading"
        )

        let object = try jsonObject(project)

        XCTAssertNil(object["defaultAccounts"], "absent, not null or empty, when there is no list")
    }

    func testAReferenceIsTheCataloguesTwoIdentifiers() throws {
        let object = try jsonObject(work)

        XCTAssertEqual(object["agentID"] as? String, "claude")
        XCTAssertEqual(object["accountID"] as? String, "work")
        XCTAssertEqual(object.count, 2, "a reference carries no name or usage of its own")
    }

    // MARK: - Mutation

    func testTheSetRequestRoundTripsTheWholeList() throws {
        let request = RemoteSetProjectDefaultAccountsRequestDTO(
            projectID: "project",
            accounts: [codex, work]
        )

        XCTAssertEqual(try roundTrip(request), request)
        let object = try jsonObject(request)
        XCTAssertEqual(object["projectID"] as? String, "project")
        XCTAssertEqual((object["accounts"] as? [[String: Any]])?.count, 2)
    }

    func testAnEmptySetRequestClearsRatherThanDisappears() throws {
        let clear = RemoteSetProjectDefaultAccountsRequestDTO(projectID: "project", accounts: [])

        XCTAssertEqual(try roundTrip(clear), clear)
        XCTAssertEqual((try jsonObject(clear)["accounts"] as? [Any])?.count, 0)
    }

    func testTheFeatureAndRouteAreNamedOnTheWire() {
        XCTAssertEqual(
            RemoteRESTFeature(rawValue: "project-default-accounts"),
            .projectDefaultAccounts
        )
        XCTAssertEqual(RemoteRoute.projectDefaultAccounts.rawValue, "api/project/default-accounts")
        XCTAssertEqual(RemoteProjectDefaultAccounts.spentFraction, 0.92)
        XCTAssertEqual(RemoteProjectDefaultAccounts.maximumEntries, 32)
    }

    // MARK: - Create

    func testACreateSaysWhereItsLoginCameFrom() throws {
        for selection in [RemoteAccountSelection.explicit, .projectDefault] {
            let request = creation(accountSelection: selection)
            XCTAssertEqual(try roundTrip(request).accountSelection, selection)
        }
        XCTAssertEqual(
            try jsonObject(creation(accountSelection: .projectDefault))["accountSelection"]
                as? String,
            "project-default"
        )
        XCTAssertEqual(
            try jsonObject(creation(accountSelection: .explicit))["accountSelection"] as? String,
            "explicit"
        )
    }

    func testACreateWithNoSelectionSendsNoField() throws {
        let object = try jsonObject(creation(accountSelection: nil))

        XCTAssertNil(object["accountSelection"], "absent means explicit to every Mac")
    }

    func testAnOlderPhonesCreateDecodesAsExplicit() throws {
        let older = try JSONDecoder().decode(
            RemoteCreateSessionRequestDTO.self,
            from: Data(
                #"{"projectID":"project","agentKind":"claude","accountHandle":"work","surface":"terminal","prompt":"Go"}"#
                    .utf8
            )
        )

        XCTAssertNil(older.accountSelection)
        XCTAssertEqual(older.accountHandle, "work")
    }

    func testAnUnknownSelectionIsKeptRatherThanRefused() throws {
        let future = try JSONDecoder().decode(
            RemoteCreateSessionRequestDTO.self,
            from: Data(
                #"{"projectID":"project","agentKind":"claude","surface":"terminal","prompt":"Go","accountSelection":"team-default"}"#
                    .utf8
            )
        )

        XCTAssertEqual(future.accountSelection, .unknown("team-default"))
        XCTAssertEqual(
            try jsonObject(future)["accountSelection"] as? String,
            "team-default",
            "a word this build does not know goes back out unchanged"
        )
    }

    // MARK: - Create Response

    func testACompactResponseCarriesTheSubstitution() throws {
        let substitution = RemoteAccountSubstitutionDTO(
            requestedAccountID: "work",
            accountID: "spare",
            reason: .spent,
            resetsAt: 2_000_000_000
        )
        let response = RemoteCreateSessionResponseDTO(
            sessionID: "session",
            session: RemoteSessionSummaryDTO(
                id: "session",
                title: "Review",
                agentKind: "claude",
                surface: .terminal,
                state: .working,
                projectName: "Threading"
            ),
            startup: .ready,
            accountSubstitution: substitution
        )

        let decoded = try roundTrip(response)

        XCTAssertEqual(decoded.accountSubstitution, substitution)
        XCTAssertEqual(
            (try jsonObject(response)["accountSubstitution"] as? [String: Any])?["reason"]
                as? String,
            "spent"
        )
    }

    func testASubstitutionWithoutAKnownResetSendsNoTime() throws {
        let substitution = RemoteAccountSubstitutionDTO(
            requestedAccountID: "work",
            accountID: "spare",
            reason: .ownLimit
        )

        XCTAssertEqual(try roundTrip(substitution), substitution)
        let object = try jsonObject(substitution)
        XCTAssertEqual(object["reason"] as? String, "own-limit")
        XCTAssertNil(object["resetsAt"])
    }

    func testAnOlderMacsResponseDecodesWithNoSubstitution() throws {
        let older = try JSONDecoder().decode(
            RemoteCreateSessionResponseDTO.self,
            from: Data(
                #"""
                {"sessionID":"session","startup":"ready","session":{"id":"session","title":"Review","agentKind":"claude","surface":"terminal","state":"working","projectName":"Threading"}}
                """#.utf8
            )
        )

        XCTAssertNil(older.accountSubstitution)
        XCTAssertEqual(older.session?.id, "session")
    }

    func testAnUnknownReasonIsKeptRatherThanRefused() throws {
        let future = try JSONDecoder().decode(
            RemoteAccountSubstitutionDTO.self,
            from: Data(
                #"{"requestedAccountID":"work","accountID":"spare","reason":"maintenance"}"#.utf8
            )
        )

        XCTAssertEqual(future.reason, .unknown("maintenance"))
        XCTAssertEqual(try jsonObject(future)["reason"] as? String, "maintenance")
    }

    // MARK: - Helpers

    private func creation(accountSelection: RemoteAccountSelection?) -> RemoteCreateSessionRequestDTO {
        RemoteCreateSessionRequestDTO(
            projectID: "project",
            agentKind: "claude",
            accountHandle: "work",
            model: nil,
            reasoningEffort: nil,
            fastMode: nil,
            permissionMode: nil,
            surface: .terminal,
            compactResponse: true,
            accountSelection: accountSelection,
            prompt: "Go"
        )
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
    }
}
