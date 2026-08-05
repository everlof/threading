import XCTest
@testable import Threading

final class ChangeRequestTests: XCTestCase {

    // MARK: - Identity and project policy

    func testRemoteIdentityUnderstandsHTTPSAndSCPWithoutCredentials() {
        XCTAssertEqual(
            GitRemoteIdentity(remote: "https://token:secret@GitHub.com/team/app.git"),
            GitRemoteIdentity(host: "github.com", path: "team/app")
        )
        XCTAssertEqual(
            GitRemoteIdentity(remote: "git@gitlab.com:group/app.git"),
            GitRemoteIdentity(host: "gitlab.com", path: "group/app")
        )
        XCTAssertNil(GitRemoteIdentity(remote: "../private.git"))
        XCTAssertNil(ChangeRequestRepository.github(remote: "git@gitlab.com:group/app.git"))
        XCTAssertEqual(
            ChangeRequestRepository.github(remote: "git@github.com:team/app.git")?.slug,
            "team/app"
        )
    }

    @MainActor
    func testProjectPolicyIsSharedAcrossWorktreesAndPersists() throws {
        let fixture = try repositoryWithLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let suite = "ChangeRequestTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ChangeRequestConfigurationStore(userDefaults: defaults)
        XCTAssertEqual(
            store.configuration(forProjectPath: fixture.main.path),
            .default
        )
        store.setPublishPolicy(.createDraft, forProjectPath: fixture.main.path)

        XCTAssertEqual(
            store.configuration(forProjectPath: fixture.linked.path).publishPolicy,
            .createDraft,
            "linked worktrees must not acquire different publish behavior"
        )
        XCTAssertEqual(
            ChangeRequestConfigurationStore(userDefaults: defaults)
                .configuration(forProjectPath: fixture.linked.path)
                .publishPolicy,
            .createDraft,
            "the repository policy must survive a relaunch"
        )
    }

    @MainActor
    func testPublishReceiptsAreBoundedDurableAndNameTheCredentialTier() throws {
        let suite = "ChangeRequestReceipts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChangeRequestReceiptStore(userDefaults: defaults)

        store.append(ChangeRequestReceipt(
            date: Date(timeIntervalSince1970: 1),
            action: .createdDraft,
            repository: "team/app",
            branch: "feature",
            url: URL(string: "https://github.com/team/app/pull/7"),
            credentialTier: .ghCLI
        ))

        let restored = try XCTUnwrap(
            ChangeRequestReceiptStore(userDefaults: defaults).receipts.first
        )
        XCTAssertEqual(restored.repository, "team/app")
        XCTAssertEqual(restored.branch, "feature")
        XCTAssertEqual(restored.credentialTier, .ghCLI)
        XCTAssertEqual(restored.action, .createdDraft)
    }

    // MARK: - GitHub discovery

    func testDiscoveryCombinesPullRequestChecksAndLatestReviews() async throws {
        let chain = resolver(app: "app-token")
        let recorder = RequestRecorder()
        let subject = GitHubPullRequestClient(
            resolver: chain,
            transport: { request in
                recorder.record(request)
                let path = request.url?.path ?? ""
                let body: Data
                switch path {
                case "/repos/team/app":
                    body = Data(#"{"default_branch":"main"}"#.utf8)
                case "/repos/team/app/pulls":
                    body = Data("[\(String(decoding: Self.pullBody(number: 12), as: UTF8.self))]".utf8)
                case "/repos/team/app/commits/remote-sha/check-runs":
                    body = Data(#"{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"neutral"}]}"#.utf8)
                case "/repos/team/app/pulls/12/reviews":
                    body = Data(#"[{"state":"CHANGES_REQUESTED","user":{"login":"sam"}},{"state":"APPROVED","user":{"login":"sam"}},{"state":"APPROVED","user":{"login":"lee"}}]"#.utf8)
                default:
                    return (Data(#"{"message":"missing fixture"}"#.utf8), Self.response(404, request))
                }
                return (body, Self.response(200, request))
            }
        )
        let repository = try XCTUnwrap(
            ChangeRequestRepository.github(remote: "git@github.com:team/app.git")
        )

        let outcome = await subject.discover(
            repository: repository,
            branch: "feature",
            headRevision: "local-sha"
        )
        guard case .loaded(let status) = outcome else {
            return XCTFail("expected native pull-request state, got \(outcome)")
        }
        let pull = try XCTUnwrap(status.pullRequest)
        XCTAssertEqual(status.defaultBranch, "main")
        XCTAssertEqual(pull.number, 12)
        XCTAssertEqual(pull.checks.state, .passing)
        XCTAssertEqual(pull.checks.passed, 2)
        XCTAssertEqual(pull.reviews.approvals, 2, "only each reviewer's latest decision counts")
        XCTAssertEqual(pull.reviews.changesRequested, 0)
        XCTAssertEqual(pull.reviews.requested, 1)
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer app-token"
        })
    }

    func testCreatingAPullRequestIsOneAuthenticatedPOST() async throws {
        let chain = resolver(gh: "gh-token")
        let recorder = RequestRecorder()
        let subject = GitHubPullRequestClient(
            resolver: chain,
            transport: { request in
                recorder.record(request)
                return (Self.pullBody(number: 21), Self.response(201, request))
            }
        )
        let repository = try XCTUnwrap(
            ChangeRequestRepository.github(remote: "https://github.com/team/app.git")
        )
        let proposal = ChangeRequestProposal(
            title: "Add native pull requests",
            body: "## Summary\n\n- Add the workflow",
            baseBranch: "main",
            headBranch: "feature",
            isDraft: true
        )

        guard case .created(let pull, let tier) = await subject.create(
            repository: repository,
            proposal: proposal
        ) else { return XCTFail("expected GitHub to create the pull request") }

        XCTAssertEqual(pull.number, 21)
        XCTAssertEqual(tier, .ghCLI)
        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/repos/team/app/pulls")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gh-token")
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        )
        XCTAssertEqual(json["draft"] as? Bool, true)
        XCTAssertEqual(json["base"] as? String, "main")
        XCTAssertEqual(json["head"] as? String, "feature")
    }

    func testAWriteTransportFailureNeverWalksToAnotherCredential() async throws {
        let chain = resolver(app: "app-token", gh: "gh-token")
        let recorder = RequestRecorder()
        struct Offline: Error {}
        let subject = GitHubPullRequestClient(
            resolver: chain,
            transport: { request in recorder.record(request); throw Offline() }
        )
        let repository = try XCTUnwrap(
            ChangeRequestRepository.github(remote: "git@github.com:team/app.git")
        )
        let outcome = await subject.create(
            repository: repository,
            proposal: ChangeRequestProposal(
                title: "Title",
                body: "Body",
                baseBranch: "main",
                headBranch: "feature",
                isDraft: false
            )
        )

        guard case .failed = outcome else { return XCTFail("transport ambiguity must stop") }
        XCTAssertEqual(recorder.requests.count, 1, "a second POST could create a duplicate")
    }

    func testSignedOutCreationUsesAPrefilledBrowserFormWithoutPosting() async throws {
        let chain = resolver()
        let recorder = RequestRecorder()
        let subject = GitHubPullRequestClient(
            resolver: chain,
            transport: { request in
                recorder.record(request)
                return (Data(), Self.response(500, request))
            }
        )
        let repository = try XCTUnwrap(
            ChangeRequestRepository.github(remote: "git@github.com:team/app.git")
        )
        let outcome = await subject.create(
            repository: repository,
            proposal: ChangeRequestProposal(
                title: "Title",
                body: "Body",
                baseBranch: "main",
                headBranch: "feature",
                isDraft: true
            )
        )

        guard case .webForm(let url, _) = outcome else {
            return XCTFail("a browser sign-in is the signed-out fallback")
        }
        XCTAssertTrue(url.absoluteString.contains("/compare/main...feature"))
        XCTAssertTrue(recorder.requests.isEmpty, "anonymous creation is a guaranteed 401")
    }

    // MARK: - AI boundary

    func testCodexDraftParserAcceptsFencedJSONAndNothingElse() {
        XCTAssertEqual(
            ChangeRequestTextComposer.draft(from: """
            Here is the draft:
            ```json
            {"title":"Native PRs","body":"## Summary\\n\\n- Add them"}
            ```
            """),
            ChangeRequestDraftText(title: "Native PRs", body: "## Summary\n\n- Add them")
        )
        XCTAssertNil(ChangeRequestTextComposer.draft(from: "I published it"))
    }

    func testCodexPromptExplicitlyForbidsPublishing() {
        let prompt = ChangeRequestTextComposer.prompt(seed: ChangeRequestProposalSeed(
            title: "Native PRs",
            body: "",
            commitSubjects: ["Add PR state"],
            diff: "diff --git a/a b/a",
            template: "## Testing"
        ))
        XCTAssertTrue(prompt.contains("Do not publish anything"))
        XCTAssertTrue(prompt.contains("Preserve and complete this repository template"))
        XCTAssertTrue(prompt.contains("diff --git"))
    }

    // MARK: - Helpers

    private func resolver(
        app: String? = nil,
        gh: String? = nil,
        git: String? = nil
    ) -> GitHubCredentialResolver {
        GitHubCredentialResolver(
            appConnection: FakeAppTokens(token: app),
            ghSource: FakeTokenSource(token: gh),
            gitSource: FakeTokenSource(token: git)
        )
    }

    private static func response(_ status: Int, _ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func pullBody(number: Int) -> Data {
        Data("""
        {
          "number": \(number),
          "title": "Native pull requests",
          "body": "Body",
          "html_url": "https://github.com/team/app/pull/\(number)",
          "draft": true,
          "merged_at": null,
          "base": {"ref":"main","sha":"base-sha"},
          "head": {"ref":"feature","sha":"remote-sha"},
          "requested_reviewers": [{"login":"pat"}]
        }
        """.utf8)
    }

    private func repositoryWithLinkedWorktree() throws -> (
        container: URL,
        main: URL,
        linked: URL
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-change-request-\(UUID().uuidString)")
        let main = container.appendingPathComponent("main")
        let linked = container.appendingPathComponent("linked")
        let common = main.appendingPathComponent(".git")
        let linkedIdentity = common.appendingPathComponent("worktrees/feature")
        try FileManager.default.createDirectory(at: linkedIdentity, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "gitdir: \(linkedIdentity.path)\n".write(
            to: linked.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        return (container, main, linked)
    }
}
