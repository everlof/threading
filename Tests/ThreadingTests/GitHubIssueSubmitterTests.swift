import XCTest
@testable import Threading

/// The write half of the GitHub chain: what a POST does that the broker's GET must not, and
/// what it must never do twice.
final class GitHubIssueSubmitterTests: XCTestCase {

    private enum Fixture {
        static let repository = "everlof/threading"
        static let draft = GitHubIssueDraft(
            title: "The sidebar eats the archive button",
            body: "Steps, evidence, versions.",
            labels: ["bug"]
        )
    }

    // MARK: - Helpers

    private func resolver(
        app: String? = nil,
        gh: String? = nil,
        git: String? = nil
    ) -> (GitHubCredentialResolver, FakeAppTokens, FakeTokenSource, FakeTokenSource) {
        let appTokens = FakeAppTokens(token: app)
        let ghSource = FakeTokenSource(token: gh)
        let gitSource = FakeTokenSource(token: git)
        return (
            GitHubCredentialResolver(
                appConnection: appTokens,
                ghSource: ghSource,
                gitSource: gitSource
            ),
            appTokens,
            ghSource,
            gitSource
        )
    }

    private func response(_ status: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func createdBody(number: Int) -> Data {
        Data("""
        {"number": \(number), "html_url": "https://github.com/everlof/threading/issues/\(number)"}
        """.utf8)
    }

    // MARK: - Creating

    func testTheFirstCredentialThatMayWriteCreatesTheIssue() async {
        let (chain, _, _, _) = resolver(app: "app-token", gh: "gh-token")
        let recorder = RequestRecorder()

        let subject = GitHubIssueSubmitter(
            repository: Fixture.repository,
            resolver: chain,
            transport: { request in
                recorder.record(request)
                return (self.createdBody(number: 42), self.response(201, for: request))
            }
        )

        let outcome = await subject.submit(Fixture.draft)

        guard case .created(let url, let number, let tier) = outcome else {
            return XCTFail("expected a created issue, got \(outcome)")
        }
        XCTAssertEqual(number, 42)
        XCTAssertEqual(tier, .app)
        XCTAssertEqual(url.absoluteString, "https://github.com/everlof/threading/issues/42")
        XCTAssertEqual(recorder.requests.count, 1, "a second tier was tried after a success")

        let request = recorder.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.github.com/repos/everlof/threading/issues"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer app-token")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-GitHub-Api-Version"),
            GitHubDefaults.apiVersion
        )
    }

    /// GitHub accepted it, so the issue exists. Reporting a failure here is what would produce
    /// a second one.
    func testAnUnreadableSuccessStillCountsAsCreated() async {
        let (chain, _, _, _) = resolver(gh: "gh-token")
        let subject = GitHubIssueSubmitter(
            repository: Fixture.repository,
            resolver: chain,
            transport: { request in (Data("<html>".utf8), self.response(201, for: request)) }
        )

        guard case .created(_, let number, _) = await subject.submit(Fixture.draft) else {
            return XCTFail("an accepted POST must not read as a failure")
        }
        XCTAssertEqual(number, 0)
    }

    // MARK: - Walking the chain

    func testAnUnauthorizedTokenIsInvalidatedAndTheNextTierIsTried() async {
        let (chain, appTokens, ghSource, _) = resolver(app: "stale-token", gh: "gh-token")
        let recorder = RequestRecorder()

        let subject = GitHubIssueSubmitter(
            repository: Fixture.repository,
            resolver: chain,
            transport: { request in
                recorder.record(request)
                let isStale = request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer stale-token"
                return isStale
                    ? (Data(#"{"message":"Bad credentials"}"#.utf8), self.response(401, for: request))
                    : (self.createdBody(number: 7), self.response(201, for: request))
            }
        )

        guard case .created(_, let number, let tier) = await subject.submit(Fixture.draft) else {
            return XCTFail("the second tier should have created the issue")
        }
        XCTAssertEqual(number, 7)
        XCTAssertEqual(tier, .ghCLI)
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(appTokens.rejections, 1, "a 401 is proof the cached token died")
        let probes = await ghSource.probeCount
        XCTAssertEqual(probes, 1)
    }

    /// 422 is GitHub reading the issue and objecting to it. Every other token hears the same
    /// objection, so walking the chain would only repeat the refusal.
    func testAValidationRefusalDoesNotWalkTheChain() async {
        let (chain, _, _, _) = resolver(app: "app-token", gh: "gh-token", git: "git-token")
        let recorder = RequestRecorder()

        let subject = GitHubIssueSubmitter(
            repository: Fixture.repository,
            resolver: chain,
            transport: { request in
                recorder.record(request)
                return (
                    Data(#"{"message":"Validation Failed"}"#.utf8),
                    self.response(422, for: request)
                )
            }
        )

        guard case .failed(let message) = await subject.submit(Fixture.draft) else {
            return XCTFail("a validation refusal is an error, not a fallback")
        }
        XCTAssertTrue(message.contains("Validation Failed"), message)
        XCTAssertEqual(recorder.requests.count, 1)
    }

    /// The one rule a POST has that a GET does not: a request that may have been received is
    /// never sent again on the app's initiative.
    func testATransportFailureIsNotRetriedUnderAnotherTier() async {
        let (chain, _, _, _) = resolver(app: "app-token", gh: "gh-token")
        let recorder = RequestRecorder()

        let subject = GitHubIssueSubmitter(
            repository: Fixture.repository,
            resolver: chain,
            transport: { request in
                recorder.record(request)
                throw URLError(.timedOut)
            }
        )

        guard case .failed = await subject.submit(Fixture.draft) else {
            return XCTFail("a transport failure has no safe fallback")
        }
        XCTAssertEqual(recorder.requests.count, 1, "a POST that may have landed was repeated")
    }

    // MARK: - The web form

    func testWithNoCredentialTheFormIsPrefilledInsteadOfPosting() async {
        let (chain, _, _, _) = resolver()
        let recorder = RequestRecorder()

        let subject = GitHubIssueSubmitter(
            repository: Fixture.repository,
            resolver: chain,
            transport: { request in
                recorder.record(request)
                return (Data(), self.response(201, for: request))
            }
        )

        guard case .webForm(let url, _) = await subject.submit(Fixture.draft) else {
            return XCTFail("anonymous cannot post, so the form is the way in")
        }
        XCTAssertEqual(recorder.requests.count, 0, "anonymous was sent to the API")

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        XCTAssertEqual(components?.host, "github.com")
        XCTAssertEqual(components?.path, "/everlof/threading/issues/new")
        XCTAssertEqual(items.first { $0.name == "title" }?.value, Fixture.draft.title)
        XCTAssertEqual(items.first { $0.name == "body" }?.value, Fixture.draft.body)
        XCTAssertEqual(items.first { $0.name == "labels" }?.value, "bug")
    }

    func testEveryCredentialRefusingEndsAtTheFormRatherThanAnError() async {
        let (chain, _, _, _) = resolver(app: "app-token", gh: "gh-token")
        let recorder = RequestRecorder()

        let subject = GitHubIssueSubmitter(
            repository: Fixture.repository,
            resolver: chain,
            transport: { request in
                recorder.record(request)
                return (
                    Data(#"{"message":"Not Found"}"#.utf8),
                    self.response(404, for: request)
                )
            }
        )

        guard case .webForm = await subject.submit(Fixture.draft) else {
            return XCTFail("a permission answer is not an error")
        }
        XCTAssertEqual(recorder.requests.count, 2, "both writable tiers should be tried")
    }

    func testALongBodyIsCutBeforeItBecomesAURL() {
        let long = String(repeating: "x", count: GitHubIssueDefaults.webFormBodyLimit + 500)
        let cut = GitHubIssueSubmitter.truncate(long, to: GitHubIssueDefaults.webFormBodyLimit)

        XCTAssertLessThan(cut.count, long.count)
        XCTAssertTrue(cut.hasSuffix(L10n.string("_Report truncated._")))
    }

    // MARK: - Wire format

    func testTheRequestBodyCarriesTitleBodyAndLabels() throws {
        let data = try XCTUnwrap(GitHubIssueSubmitter.requestBody(for: Fixture.draft))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["title"] as? String, Fixture.draft.title)
        XCTAssertEqual(json["body"] as? String, Fixture.draft.body)
        XCTAssertEqual(json["labels"] as? [String], ["bug"])
    }

    func testAnUnlabelledDraftOmitsTheFieldRatherThanSendingAnEmptyList() throws {
        let draft = GitHubIssueDraft(title: "t", body: "b")
        let data = try XCTUnwrap(GitHubIssueSubmitter.requestBody(for: draft))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(json["labels"], "an empty label list is a validation refusal waiting")
    }

    // MARK: - Composition

    func testTheTitleIsTheFirstLineOfWhatWasWritten() {
        let title = GitHubIssueComposer.title(
            fromNote: "Archive button is unclickable\n\nIt only works every third press.",
            fallback: "Element Report"
        )
        XCTAssertEqual(title, "Archive button is unclickable")
    }

    func testAnEmptyNoteFallsBackToTheReportsOwnName() {
        let title = GitHubIssueComposer.title(fromNote: "   \n  ", fallback: "Element Report")
        XCTAssertEqual(title, "Element Report")
    }

    func testALongFirstLineIsCutToATitleLength() {
        let note = String(repeating: "a", count: GitHubIssueDefaults.titleLimit + 40)
        let title = GitHubIssueComposer.title(fromNote: note, fallback: "x")

        XCTAssertEqual(title.count, GitHubIssueDefaults.titleLimit + 1, "the ellipsis is the +1")
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testTheNoteLeadsAndTheEnvironmentCloses() {
        let body = GitHubIssueComposer.body(
            note: "  It cuts off the favicon.  ",
            report: "- Element: SidebarRowView",
            environment: "Threading 0.1.0 (12) · Version 15.4"
        )

        XCTAssertTrue(body.hasPrefix("It cuts off the favicon."), body)
        XCTAssertTrue(body.hasSuffix("---\nThreading 0.1.0 (12) · Version 15.4"), body)
        XCTAssertTrue(body.contains("- Element: SidebarRowView"))
    }

    func testAReportWithNoNoteStillCarriesEvidenceAndEnvironment() {
        let body = GitHubIssueComposer.body(
            note: "",
            report: "- Element: SidebarRowView",
            environment: "Threading 0.1.0"
        )

        XCTAssertTrue(body.hasPrefix("- Element: SidebarRowView"), body)
        XCTAssertTrue(body.contains("Threading 0.1.0"))
    }

    func testTheEnvironmentLineNamesVersionBuildAndSystemAndNothingElse() {
        let line = GitHubIssueEnvironment.markdown(
            info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "12"],
            operatingSystem: "Version 15.4 (Build 24E248)"
        )

        XCTAssertEqual(line, "Threading 0.1.0 (12) · Version 15.4 (Build 24E248)")
    }
}
