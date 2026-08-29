import XCTest
@testable import Threading

final class ChangeRequestTests: XCTestCase {

    // MARK: - Identity and project policy

    func testCheckModelKeepsExactOutcomesCoverageAndIndependentPolling() {
        let checks = ChangeRequestChecks(
            outcomes: [
                .passed: 6,
                .neutral: 1,
                .skipped: 4,
                .allowedFailure(original: "failed"): 2,
                .requested: 1,
                .queued: 1,
                .waiting: 1,
                .pending: 1,
                .running: 1,
                .inProgress: 1,
                .cancelling: 1,
                .failed: 1,
                .error: 1,
                .startupFailure: 1,
                .actionRequired: 1,
                .timedOut: 1,
                .cancelled: 1,
                .stale: 1,
                .unknownActive("provider future active value"): 1,
                .unknownTerminal("provider future terminal value"): 1
            ],
            coverage: .init(isPartial: true, isCapped: true, additionalCount: 7)
        )

        XCTAssertEqual(checks.state, .needsAttention, "attention wins the headline precedence")
        XCTAssertTrue(checks.shouldPoll, "an active check still refreshes beside an adverse one")
        XCTAssertEqual(checks.count(disposition: .successful), 6)
        XCTAssertEqual(checks.count(disposition: .nonBlocking), 7)
        XCTAssertEqual(checks.count(disposition: .active), 8)
        XCTAssertEqual(checks.count(disposition: .needsAttention), 8)

        let fragments = ChangeRequestCheckPresentation.fragments(for: checks)
        XCTAssertEqual(fragments.first, "6 passed")
        XCTAssertTrue(fragments.contains("4 skipped"))
        XCTAssertTrue(fragments.contains("2 failed (allowed)"))
        XCTAssertTrue(fragments.contains("1 running"))
        XCTAssertTrue(fragments.contains("1 timed out"))
        XCTAssertTrue(fragments.contains("1 unknown (provider future active v)"))
        XCTAssertTrue(fragments.contains("summary incomplete"))
        XCTAssertEqual(fragments.last, "7 more not loaded")

        let settledFailure = ChangeRequestChecks(outcomes: [.failed: 1])
        XCTAssertFalse(settledFailure.shouldPoll)

        var futureValues: [ChangeRequestCheckOutcome: Int] = [:]
        for index in 0..<20 {
            futureValues[.unknownActive("future-active-\(index)")] = 1
            futureValues[.unknownTerminal("future-terminal-\(index)")] = 1
        }
        let boundedFuture = ChangeRequestChecks(outcomes: futureValues)
        XCTAssertEqual(boundedFuture.totalCount, 40)
        XCTAssertLessThanOrEqual(
            boundedFuture.buckets.count,
            ChangeRequestCheckDefaults.maximumUnknownOutcomeBucketsPerDisposition * 2
        )
        XCTAssertEqual(boundedFuture.count(of: .unknownActive("other values")), 17)
        XCTAssertEqual(boundedFuture.count(of: .unknownTerminal("other values")), 17)

        let oneSource = ChangeRequestChecks(outcomes: [.passed: 2]).merging(.unavailable)
        XCTAssertEqual(oneSource.passed, 2)
        XCTAssertTrue(oneSource.coverage.isPartial)
        XCTAssertEqual(ChangeRequestCheckPresentation.fragments(for: oneSource).last,
                       "summary incomplete")
        XCTAssertEqual(ChangeRequestChecks.unavailable.merging(.unavailable), .unavailable)
    }

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

    func testProviderDetectionSupportsGitLabNamespacesAndRefusesRecognizableSelfHostedGitLab() throws {
        let https = try XCTUnwrap(
            ChangeRequestRepository.gitlab(
                remote: "https://gitlab.com/platform/mobile/client.git"
            )
        )
        XCTAssertEqual(https.provider, .gitlab)
        XCTAssertEqual(https.host, "gitlab.com")
        XCTAssertEqual(https.namespace, "platform/mobile")
        XCTAssertEqual(https.name, "client")
        XCTAssertEqual(https.slug, "platform/mobile/client")
        XCTAssertEqual(
            ChangeRequestRepository.gitlab(
                remote: "ssh://git@gitlab.com/platform/mobile/client.git"
            ),
            https
        )
        XCTAssertEqual(
            ChangeRequestRepository.gitlab(
                remote: "git@gitlab.com:platform/mobile/client.git"
            ),
            https
        )

        guard case .unsupported(let message) = ChangeRequestRepository.detect(
            remote: "git@gitlab.company.test:platform/client.git"
        ) else { return XCTFail("a recognizable self-hosted GitLab remote must be refused explicitly") }
        XCTAssertTrue(message.contains("Self-hosted GitLab"))
        XCTAssertEqual(
            ChangeRequestRepository.detect(remote: "git@code.company.test:platform/client.git"),
            .unrecognized,
            "an arbitrary Git host must not be guessed to be GitLab"
        )
        XCTAssertFalse(https.capabilities.supportsSelfHosted)
        XCTAssertFalse(https.capabilities.reportsChangesRequested)
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
    func testUnreadableProjectPolicyIsPreservedBeforeANewChoiceReplacesIt() throws {
        let fixture = try repositoryWithLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let suite = "ChangeRequestPolicyRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "changeRequest.repositoryConfigurations.v1"
        let corrupt = Data("{".utf8)
        defaults.set(corrupt, forKey: key)

        let store = ChangeRequestConfigurationStore(userDefaults: defaults)
        XCTAssertEqual(store.configuration(forProjectPath: fixture.main.path), .default)
        XCTAssertEqual(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: key)),
            corrupt
        )
        XCTAssertTrue(store.setPublishPolicy(.createReady, forProjectPath: fixture.main.path))
        XCTAssertEqual(
            ChangeRequestConfigurationStore(userDefaults: defaults)
                .configuration(forProjectPath: fixture.main.path).publishPolicy,
            .createReady
        )
    }

    @MainActor
    func testPublishReceiptsAreBoundedDurableAndNameTheCredentialSource() throws {
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
            credentialSource: .ghCLI
        ))

        let restored = try XCTUnwrap(
            ChangeRequestReceiptStore(userDefaults: defaults).receipts.first
        )
        XCTAssertEqual(restored.repository, "team/app")
        XCTAssertEqual(restored.branch, "feature")
        XCTAssertEqual(restored.credentialSource, .ghCLI)
        XCTAssertEqual(restored.action, .createdDraft)
    }

    @MainActor
    func testUnreadableReceiptsArePreservedAndUnsafeURLsAreNotRecorded() throws {
        let suite = "ChangeRequestReceiptRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "changeRequest.publishReceipts.v1"
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: key)

        let store = ChangeRequestReceiptStore(userDefaults: defaults)
        XCTAssertEqual(store.receipts, [])
        XCTAssertEqual(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: key)),
            corrupt
        )
        XCTAssertFalse(store.append(ChangeRequestReceipt(
            date: Date(timeIntervalSince1970: 1),
            action: .createdReady,
            repository: "team/app",
            branch: "feature",
            url: URL(fileURLWithPath: "/private/pull-request"),
            credentialSource: .ghCLI
        )))
        XCTAssertEqual(store.receipts, [])
    }

    @MainActor
    func testLegacyGitHubReceiptCredentialTierDecodesAsProviderCredentialSource() throws {
        let suite = "LegacyChangeRequestReceipts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data("""
        [{
          "date": 0,
          "action": "createdReady",
          "repository": "team/app",
          "branch": "feature",
          "credentialTier": "gh-cli"
        }]
        """.utf8)
        defaults.set(legacy, forKey: "changeRequest.publishReceipts.v1")

        let restored = try XCTUnwrap(
            ChangeRequestReceiptStore(userDefaults: defaults).receipts.first
        )
        XCTAssertEqual(restored.credentialSource, .ghCLI)
        XCTAssertEqual(restored.action, .createdReady)
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
                    body = Data(#"{"total_count":14,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"neutral"},{"status":"completed","conclusion":"skipped"},{"status":"requested","conclusion":null},{"status":"queued","conclusion":null},{"status":"waiting","conclusion":null},{"status":"pending","conclusion":null},{"status":"in_progress","conclusion":null},{"status":"completed","conclusion":"failure"},{"status":"completed","conclusion":"cancelled"},{"status":"completed","conclusion":"timed_out"},{"status":"completed","conclusion":"action_required"},{"status":"completed","conclusion":"startup_failure"},{"status":"completed","conclusion":"stale"}]}"#.utf8)
                case "/repos/team/app/commits/remote-sha/status":
                    body = Data(#"{"total_count":4,"statuses":[{"state":"success"},{"state":"pending"},{"state":"failure"},{"state":"error"}]}"#.utf8)
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
        let pull = try XCTUnwrap(status.changeRequest)
        XCTAssertEqual(status.defaultBranch, "main")
        XCTAssertEqual(pull.number, 12)
        XCTAssertEqual(pull.checks.state, .needsAttention)
        XCTAssertEqual(pull.checks.passed, 2)
        XCTAssertEqual(pull.checks.skipped, 1)
        XCTAssertEqual(pull.checks.count(of: .neutral), 1)
        XCTAssertEqual(pull.checks.count(of: .requested), 1)
        XCTAssertEqual(pull.checks.count(of: .queued), 1)
        XCTAssertEqual(pull.checks.count(of: .waiting), 1)
        XCTAssertEqual(pull.checks.count(of: .pending), 2)
        XCTAssertEqual(pull.checks.count(of: .inProgress), 1)
        XCTAssertEqual(pull.checks.count(of: .failed), 2)
        XCTAssertEqual(pull.checks.count(of: .error), 1)
        XCTAssertEqual(pull.checks.count(of: .startupFailure), 1)
        XCTAssertEqual(pull.checks.count(of: .actionRequired), 1)
        XCTAssertEqual(pull.checks.count(of: .timedOut), 1)
        XCTAssertEqual(pull.checks.count(of: .cancelled), 1)
        XCTAssertEqual(pull.checks.count(of: .stale), 1)
        XCTAssertEqual(pull.reviews.approvals, 2, "only each reviewer's latest decision counts")
        XCTAssertEqual(pull.reviews.changesRequested, 0)
        XCTAssertEqual(pull.reviews.requested, 1)
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer app-token"
        })
    }

    func testLifecycleReadsAClosedPullRequestByDurableNumber() async throws {
        let recorder = RequestRecorder()
        let subject = GitHubPullRequestClient(
            resolver: resolver(gh: "gh-token"),
            transport: { request in
                recorder.record(request)
                return (
                    Self.pullBody(
                        number: 42,
                        state: "closed",
                        mergedAt: "2026-08-08T12:00:00Z",
                        headBranch: "threading/session-id",
                        headRevision: "published-sha"
                    ),
                    Self.response(200, request)
                )
            }
        )
        let repository = try XCTUnwrap(
            ChangeRequestRepository.github(remote: "git@github.com:team/app.git")
        )

        let outcome = await subject.lifecycle(repository: repository, number: 42)
        guard case .loaded(let lifecycle) = outcome else {
            return XCTFail("expected a closed review lifecycle, got \(outcome)")
        }
        XCTAssertEqual(lifecycle.number, 42)
        XCTAssertEqual(lifecycle.state, .closed(merged: true))
        XCTAssertEqual(lifecycle.headBranch, "threading/session-id")
        XCTAssertEqual(lifecycle.headRevision, "published-sha")
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.url?.path, "/repos/team/app/pulls/42")
        XCTAssertEqual(
            recorder.requests.first?.cachePolicy,
            .reloadIgnoringLocalCacheData,
            "a cached closed response must never authorize branch deletion after a reopen"
        )
    }

    func testGitHubCheckCollectionStopsAtFivePagesAndReportsTheExactRemainder() async throws {
        let recorder = RequestRecorder()
        let run = #"{"status":"completed","conclusion":"success"}"#
        let pageText = "{\"total_count\":507,\"check_runs\":["
            + Array(repeating: run, count: 100).joined(separator: ",")
            + "]}"
        let pageBody = Data(pageText.utf8)
        let subject = GitHubPullRequestClient(
            resolver: resolver(app: "app-token"),
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
                    body = pageBody
                case "/repos/team/app/commits/remote-sha/status":
                    body = Data(#"{"total_count":0,"statuses":[]}"#.utf8)
                case "/repos/team/app/pulls/12/reviews":
                    body = Data("[]".utf8)
                default:
                    return (Data(), Self.response(404, request))
                }
                return (body, Self.response(200, request))
            }
        )
        let repository = try XCTUnwrap(
            ChangeRequestRepository.github(remote: "git@github.com:team/app.git")
        )

        guard case .loaded(let status) = await subject.discover(
            repository: repository,
            branch: "feature",
            headRevision: "local-sha"
        ) else { return XCTFail("expected a bounded GitHub check summary") }
        let checks = try XCTUnwrap(status.changeRequest).checks
        XCTAssertEqual(checks.passed, 500)
        XCTAssertTrue(checks.coverage.isCapped)
        XCTAssertEqual(checks.coverage.additionalCount, 7)
        XCTAssertEqual(ChangeRequestCheckPresentation.fragments(for: checks).last, "7 more not loaded")

        let checkRequests = recorder.requests.filter {
            $0.url?.path.hasSuffix("/check-runs") == true
        }
        XCTAssertEqual(checkRequests.count, ChangeRequestCheckDefaults.maximumPages)
        let pages = checkRequests.compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value
        }.sorted()
        XCTAssertEqual(pages, ["1", "2", "3", "4", "5"])
        XCTAssertTrue(checkRequests.allSatisfy { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            return items?.contains(URLQueryItem(name: "filter", value: "latest")) == true
                && items?.contains(URLQueryItem(name: "per_page", value: "100")) == true
        })
    }

    func testManagedRemoteCleanerNeverTouchesAnOpenReviewBranch() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-review-cleaner-\(UUID().uuidString)")
        let root = container.appendingPathComponent("repo")
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try """
        [remote "origin"]
            url = git@github.com:team/app.git
        """.write(
            to: git.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )

        let sessionID = SessionID()
        let branch = ManagedGitWorkspace.publicationBranch(for: sessionID)
        let finalCommit = String(repeating: "a", count: 40)
        let recorder = RequestRecorder()
        let client = GitHubPullRequestClient(
            resolver: resolver(),
            transport: { request in
                recorder.record(request)
                return (
                    Self.pullBody(
                        number: 42,
                        headBranch: branch,
                        headRevision: finalCommit
                    ),
                    Self.response(200, request)
                )
            }
        )
        let workspace = ManagedWorkspace(
            repositoryRoot: root.path,
            sourceCheckoutPath: root.path,
            worktreeRoot: container.appendingPathComponent("disposed").path,
            executionPath: container.appendingPathComponent("disposed").path,
            targetBranch: "main",
            baseCommit: String(repeating: "b", count: 40),
            delivery: .mergeAndCleanUp,
            publication: .draft,
            remoteBranch: branch,
            finalCommit: finalCommit,
            changeRequest: ManagedWorkspaceChangeRequest(
                provider: "github",
                repository: "team/app",
                remote: "origin",
                branch: branch,
                number: 42,
                url: try XCTUnwrap(URL(string: "https://github.com/team/app/pull/42")),
                isDraft: true
            ),
            remoteBranchState: .awaitingReviewCompletion,
            state: .published,
            lastError: nil
        )

        let outcome = await ManagedWorkspaceRemoteCleaner(
            providers: .githubFixture(client)
        ).reconcile(
            sessionID: sessionID,
            workspace: workspace
        )
        XCTAssertEqual(outcome, .waiting)
        XCTAssertEqual(recorder.requests.count, 1, "an open review requires no Git write")
    }

    func testManagedRemoteCleanerRoutesAGitLabReceiptThroughTheProviderBoundary() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-gitlab-review-cleaner-\(UUID().uuidString)")
        let root = container.appendingPathComponent("repo")
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try """
        [remote "origin"]
            url = git@gitlab.com:team/app.git
        """.write(
            to: git.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )

        let sessionID = SessionID()
        let branch = ManagedGitWorkspace.publicationBranch(for: sessionID)
        let finalCommit = String(repeating: "a", count: 40)
        let recorder = GitLabInvocationRecorder()
        let gitlab = GitLabChangeRequestClient { invocation in
            recorder.record(invocation)
            return GitLabCLIResult(
                status: 0,
                output: Self.gitlabMergeRequestBody(
                    headBranch: branch,
                    headRevision: finalCommit
                ),
                diagnostic: ""
            )
        }
        let providers = ChangeRequestProviderRegistry(
            github: GitHubPullRequestClient(resolver: resolver()),
            gitlab: gitlab
        )
        let workspace = ManagedWorkspace(
            repositoryRoot: root.path,
            sourceCheckoutPath: root.path,
            worktreeRoot: container.appendingPathComponent("disposed").path,
            executionPath: container.appendingPathComponent("disposed").path,
            targetBranch: "main",
            baseCommit: String(repeating: "b", count: 40),
            delivery: .mergeAndCleanUp,
            publication: .draft,
            remoteBranch: branch,
            finalCommit: finalCommit,
            changeRequest: ManagedWorkspaceChangeRequest(
                provider: "gitlab",
                repository: "team/app",
                remote: "origin",
                branch: branch,
                number: 31,
                url: try XCTUnwrap(
                    URL(string: "https://gitlab.com/team/app/-/merge_requests/31")
                ),
                isDraft: true
            ),
            remoteBranchState: .awaitingReviewCompletion,
            state: .published,
            lastError: nil
        )

        let outcome = await ManagedWorkspaceRemoteCleaner(providers: providers).reconcile(
            sessionID: sessionID,
            workspace: workspace
        )
        XCTAssertEqual(outcome, .waiting)
        XCTAssertEqual(recorder.snapshot().count, 1, "an open review requires no Git write")
        XCTAssertEqual(
            recorder.snapshot().first?.arguments.last,
            "projects/team%2Fapp/merge_requests/31"
        )
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

    func testAutomaticCreationRequiresANativeCredentialBeforeAnyWrite() async throws {
        let signedOut = GitHubPullRequestClient(resolver: resolver())
        let signedIn = GitHubPullRequestClient(resolver: resolver(git: "git-token"))
        let repository = try XCTUnwrap(
            ChangeRequestRepository.github(remote: "git@github.com:team/app.git")
        )

        let signedOutReadiness = await signedOut.automaticCreationReadiness(
            repository: repository
        )
        let signedInReadiness = await signedIn.automaticCreationReadiness(
            repository: repository
        )
        guard case .unavailable = signedOutReadiness else {
            return XCTFail("signed-out GitHub must refuse unattended publication")
        }
        XCTAssertEqual(signedInReadiness, .ready(credential: .gitCredential))
    }

    // MARK: - GitLab discovery and creation

    func testGitLabReadinessUsesAuthenticatedCLIWithoutReadingAToken() async throws {
        let recorder = GitLabInvocationRecorder()
        let subject = GitLabChangeRequestClient { invocation in
            recorder.record(invocation)
            return GitLabCLIResult(status: 0, output: Data(), diagnostic: "")
        }
        let repository = try XCTUnwrap(
            ChangeRequestRepository.gitlab(remote: "git@gitlab.com:team/app.git")
        )

        let readiness = await subject.automaticCreationReadiness(repository: repository)
        XCTAssertEqual(readiness, .ready(credential: .glabCLI))
        XCTAssertEqual(
            recorder.snapshot().map(\.arguments),
            [["auth", "status", "--hostname", "gitlab.com"]]
        )
    }

    func testGitLabReadinessFailurePreventsMergeRequestPOST() async throws {
        let recorder = GitLabInvocationRecorder()
        let subject = GitLabChangeRequestClient { invocation in
            recorder.record(invocation)
            return GitLabCLIResult(status: 1, output: Data(), diagnostic: "not authenticated")
        }
        let repository = try XCTUnwrap(
            ChangeRequestRepository.gitlab(remote: "git@gitlab.com:team/app.git")
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

        guard case .failed(let message) = outcome else {
            return XCTFail("signed-out GitLab creation must fail before a write")
        }
        XCTAssertTrue(message.contains("signed in"))
        XCTAssertFalse(recorder.snapshot().contains { $0.arguments.contains("POST") })
    }

    func testGitLabDiscoveryCombinesRepositoryMergeRequestChecksAndApprovals() async throws {
        let recorder = GitLabInvocationRecorder()
        let subject = GitLabChangeRequestClient { invocation in
            recorder.record(invocation)
            let endpoint = invocation.arguments.last ?? ""
            let output: Data
            switch endpoint {
            case "projects/team%2Fapp":
                output = Data(#"{"default_branch":"trunk","http_url_to_repo":"https://gitlab.com/team/app.git","ssh_url_to_repo":"git@gitlab.com:team/app.git"}"#.utf8)
            case "projects/team%2Fapp/merge_requests":
                output = Self.gitlabMergeRequestsBody()
            case "projects/team%2Fapp/repository/commits/remote-sha/statuses":
                output = Data(#"[{"status":"success"},{"status":"skipped"},{"status":"pending"},{"status":"running"},{"status":"canceling"},{"status":"failed"},{"status":"canceled"},{"status":"failed","allow_failure":true},{"status":"canceled","allow_failure":true}]"#.utf8)
            case "projects/team%2Fapp/merge_requests/31/approvals":
                output = Data(#"{"approved_by":[{"user":{"id":1}},{"user":{"id":2}}]}"#.utf8)
            default:
                return GitLabCLIResult(status: 1, output: Data(), diagnostic: "missing fixture")
            }
            return GitLabCLIResult(status: 0, output: output, diagnostic: "")
        }
        let repository = try XCTUnwrap(
            ChangeRequestRepository.gitlab(remote: "git@gitlab.com:team/app.git")
        )

        let outcome = await subject.discover(
            repository: repository,
            branch: "feature",
            headRevision: "local-sha"
        )
        guard case .loaded(let status) = outcome else {
            return XCTFail("expected GitLab merge-request state, got \(outcome)")
        }
        let request = try XCTUnwrap(status.changeRequest)
        XCTAssertEqual(status.defaultBranch, "trunk")
        XCTAssertEqual(status.cloneURLs.https?.absoluteString, "https://gitlab.com/team/app.git")
        XCTAssertEqual(status.cloneURLs.ssh, "git@gitlab.com:team/app.git")
        XCTAssertEqual(request.number, 31)
        XCTAssertTrue(request.isDraft)
        XCTAssertEqual(request.headRevision, "remote-sha")
        XCTAssertEqual(request.checks.state, .needsAttention)
        XCTAssertEqual(request.checks.passed, 1)
        XCTAssertEqual(request.checks.skipped, 1)
        XCTAssertEqual(request.checks.count(of: .pending), 1)
        XCTAssertEqual(request.checks.count(of: .running), 1)
        XCTAssertEqual(request.checks.count(of: .cancelling), 1)
        XCTAssertEqual(request.checks.count(of: .failed), 1)
        XCTAssertEqual(request.checks.count(of: .cancelled), 1)
        XCTAssertEqual(request.checks.count(of: .allowedFailure(original: "failed")), 1)
        XCTAssertEqual(request.checks.count(of: .allowedFailure(original: "canceled")), 1)
        XCTAssertEqual(request.reviews.approvals, 2)
        XCTAssertEqual(request.reviews.requested, 1)
        XCTAssertEqual(request.reviews.changesRequested, 0)
        XCTAssertTrue(recorder.snapshot().allSatisfy {
            $0.arguments.contains("--hostname") && $0.arguments.contains("gitlab.com")
        })
        let checksCall = try XCTUnwrap(recorder.snapshot().first {
            $0.arguments.last?.contains("/statuses") == true
        })
        XCTAssertTrue(checksCall.arguments.contains("ref=feature"))
        XCTAssertTrue(checksCall.arguments.contains("per_page=100"))
        XCTAssertTrue(checksCall.arguments.contains("page=1"))
    }

    func testCreatingADraftGitLabMergeRequestUsesOneJSONPOST() async throws {
        let recorder = GitLabInvocationRecorder()
        let subject = GitLabChangeRequestClient { invocation in
            recorder.record(invocation)
            if invocation.arguments.first == "auth" {
                return GitLabCLIResult(status: 0, output: Data(), diagnostic: "")
            }
            return GitLabCLIResult(
                status: 0,
                output: Self.gitlabMergeRequestBody(),
                diagnostic: ""
            )
        }
        let repository = try XCTUnwrap(
            ChangeRequestRepository.gitlab(remote: "https://gitlab.com/team/app.git")
        )
        let outcome = await subject.create(
            repository: repository,
            proposal: ChangeRequestProposal(
                title: "Add provider boundary",
                body: "## Summary\n\n- Add GitLab",
                baseBranch: "trunk",
                headBranch: "feature",
                isDraft: true
            )
        )

        guard case .created(let request, let credential) = outcome else {
            return XCTFail("expected GitLab to create a merge request, got \(outcome)")
        }
        XCTAssertEqual(request.number, 31)
        XCTAssertEqual(credential, .glabCLI)
        let posts = recorder.snapshot().filter { $0.arguments.contains("POST") }
        XCTAssertEqual(posts.count, 1, "an ambiguous retry could create a duplicate MR")
        let post = try XCTUnwrap(posts.first)
        XCTAssertEqual(post.arguments.last, "projects/team%2Fapp/merge_requests")
        XCTAssertTrue(post.arguments.contains("--input"))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(post.input)) as? [String: Any]
        )
        XCTAssertEqual(json["source_branch"] as? String, "feature")
        XCTAssertEqual(json["target_branch"] as? String, "trunk")
        XCTAssertEqual(json["title"] as? String, "Draft: Add provider boundary")
        XCTAssertEqual(json["description"] as? String, "## Summary\n\n- Add GitLab")
    }

    func testGitLabCheckCollectionStopsAtFivePagesAndMarksAnUnknownRemainder() async throws {
        let recorder = GitLabInvocationRecorder()
        let statusPage = Data(
            ("[" + Array(repeating: #"{"status":"success"}"#, count: 100)
                .joined(separator: ",") + "]").utf8
        )
        let subject = GitLabChangeRequestClient { invocation in
            recorder.record(invocation)
            let endpoint = invocation.arguments.last ?? ""
            let output: Data
            switch endpoint {
            case "projects/team%2Fapp":
                output = Data(#"{"default_branch":"trunk"}"#.utf8)
            case "projects/team%2Fapp/merge_requests":
                output = Self.gitlabMergeRequestsBody()
            case "projects/team%2Fapp/repository/commits/remote-sha/statuses":
                output = statusPage
            case "projects/team%2Fapp/merge_requests/31/approvals":
                output = Data(#"{"approved_by":[]}"#.utf8)
            default:
                return GitLabCLIResult(status: 1, output: Data(), diagnostic: "missing fixture")
            }
            return GitLabCLIResult(status: 0, output: output, diagnostic: "")
        }
        let repository = try XCTUnwrap(
            ChangeRequestRepository.gitlab(remote: "git@gitlab.com:team/app.git")
        )

        guard case .loaded(let status) = await subject.discover(
            repository: repository,
            branch: "feature",
            headRevision: "local-sha"
        ) else { return XCTFail("expected a bounded GitLab check summary") }
        let checks = try XCTUnwrap(status.changeRequest).checks
        XCTAssertEqual(checks.passed, 500)
        XCTAssertTrue(checks.coverage.isCapped)
        XCTAssertNil(checks.coverage.additionalCount)
        XCTAssertEqual(
            ChangeRequestCheckPresentation.fragments(for: checks).last,
            "more results not loaded"
        )

        let checkCalls = recorder.snapshot().filter {
            $0.arguments.last?.hasSuffix("/statuses") == true
        }
        XCTAssertEqual(checkCalls.count, ChangeRequestCheckDefaults.maximumPages)
        let pageFields = checkCalls.flatMap(\.arguments).filter { $0.hasPrefix("page=") }.sorted()
        XCTAssertEqual(pageFields, ["page=1", "page=2", "page=3", "page=4", "page=5"])
        XCTAssertTrue(checkCalls.allSatisfy {
            $0.arguments.contains("ref=feature") && $0.arguments.contains("per_page=100")
        })
    }

    func testFailedGitLabPOSTIsNeverRetried() async throws {
        let recorder = GitLabInvocationRecorder()
        let subject = GitLabChangeRequestClient { invocation in
            recorder.record(invocation)
            if invocation.arguments.first == "auth" {
                return GitLabCLIResult(status: 0, output: Data(), diagnostic: "")
            }
            return GitLabCLIResult(status: 1, output: Data(), diagnostic: "connection lost")
        }
        let repository = try XCTUnwrap(
            ChangeRequestRepository.gitlab(remote: "git@gitlab.com:team/app.git")
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

        guard case .failed = outcome else { return XCTFail("the ambiguous write must stop") }
        XCTAssertEqual(
            recorder.snapshot().filter { $0.arguments.contains("POST") }.count,
            1
        )
    }

    func testGitLabLifecycleUsesDurableIIDAndReportsMergedState() async throws {
        let recorder = GitLabInvocationRecorder()
        let subject = GitLabChangeRequestClient { invocation in
            recorder.record(invocation)
            return GitLabCLIResult(
                status: 0,
                output: Self.gitlabMergeRequestBody(state: "merged"),
                diagnostic: ""
            )
        }
        let repository = try XCTUnwrap(
            ChangeRequestRepository.gitlab(remote: "git@gitlab.com:team/app.git")
        )

        let outcome = await subject.lifecycle(repository: repository, number: 31)
        guard case .loaded(let lifecycle) = outcome else {
            return XCTFail("expected GitLab lifecycle, got \(outcome)")
        }
        XCTAssertEqual(lifecycle.number, 31)
        XCTAssertEqual(lifecycle.state, .closed(merged: true))
        XCTAssertEqual(lifecycle.headBranch, "feature")
        XCTAssertEqual(lifecycle.headRevision, "remote-sha")
        XCTAssertEqual(
            recorder.snapshot().first?.arguments.last,
            "projects/team%2Fapp/merge_requests/31"
        )
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

    func testCodexPromptUsesGitLabMergeRequestTerminology() {
        let prompt = ChangeRequestTextComposer.prompt(
            seed: ChangeRequestProposalSeed(
                title: "Native MRs",
                body: "",
                commitSubjects: [],
                diff: "",
                template: nil
            ),
            provider: .gitlab
        )
        XCTAssertTrue(prompt.contains("Draft a merge request title and body"))
        XCTAssertFalse(prompt.contains("pull request"))
        XCTAssertTrue(prompt.contains("Do not publish anything"))
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

    private static func pullBody(
        number: Int,
        state: String = "open",
        mergedAt: String? = nil,
        headBranch: String = "feature",
        headRevision: String = "remote-sha"
    ) -> Data {
        let mergedAtJSON = mergedAt.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {
          "number": \(number),
          "title": "Native pull requests",
          "body": "Body",
          "html_url": "https://github.com/team/app/pull/\(number)",
          "state": "\(state)",
          "draft": true,
          "merged_at": \(mergedAtJSON),
          "base": {"ref":"main","sha":"base-sha"},
          "head": {"ref":"\(headBranch)","sha":"\(headRevision)"},
          "requested_reviewers": [{"login":"pat"}]
        }
        """.utf8)
    }

    private static func gitlabMergeRequestsBody() -> Data {
        Data("[\(String(decoding: gitlabMergeRequestBody(), as: UTF8.self))]".utf8)
    }

    private static func gitlabMergeRequestBody(
        state: String = "opened",
        headBranch: String = "feature",
        headRevision: String = "remote-sha"
    ) -> Data {
        Data("""
        {
          "iid": 31,
          "title": "Draft: Native merge requests",
          "description": "Body",
          "web_url": "https://gitlab.com/team/app/-/merge_requests/31",
          "state": "\(state)",
          "draft": true,
          "source_branch": "\(headBranch)",
          "target_branch": "trunk",
          "sha": "\(headRevision)",
          "merged_at": \(state == "merged" ? "\"2026-08-08T12:00:00Z\"" : "null"),
          "reviewers": [{"id": 7}]
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

final class GitLabInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [GitLabCLIInvocation] = []

    func record(_ invocation: GitLabCLIInvocation) {
        lock.lock()
        invocations.append(invocation)
        lock.unlock()
    }

    func snapshot() -> [GitLabCLIInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}

extension ChangeRequestProviderRegistry {
    static func githubFixture(_ github: GitHubPullRequestClient) -> Self {
        Self(
            github: github,
            gitlab: GitLabChangeRequestClient { _ in
                GitLabCLIResult(status: 1, output: Data(), diagnostic: "unused GitLab fixture")
            }
        )
    }
}
