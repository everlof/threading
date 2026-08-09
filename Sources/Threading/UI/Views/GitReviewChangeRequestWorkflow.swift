import AppKit

enum GitReviewChangeRequestPrimaryAction: Equatable {
    case retry
    case push
    case create
    case open
    case none
}

/// The adaptive publish loop beside Git Review's diff: local git state, provider state, and one
/// explicit transition at a time. The AI composer is reachable only in `.create`; it returns
/// text to this controller and owns no route to GitHub itself.
extension GitReviewViewController {

    func setChangeRequestBarVisible(_ visible: Bool) {
        changeRequestBar.isHidden = !visible
        changeRequestBarHeight.constant = visible ? GitReviewChangeRequestDefaults.barHeight : 0
        // The collapsed bar is already the header-to-list margin: its top sits one inset below
        // the mode chip and its zero-height bottom is the scroll view's top. A visible surface
        // needs that same margin again below it, or its rounded bottom edge and the first file
        // card become one joined slab.
        scrollViewTop.constant = visible ? Design.Spacing.inset : 0
    }

    func refreshChangeRequest(in root: URL, forceRemote: Bool) {
        changeRequestGeneration += 1
        let expected = changeRequestGeneration
        changeRequestTask?.cancel()
        if changeRequestRepositoryStatus == nil, changeRequestFailureMessage == nil {
            setChangeRequestBarVisible(true)
            changeRequestBar.showLoading(branch: GitInfo.currentBranch(for: root.path))
        }

        changeRequestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let local = try await ChangeRequestGit.state(in: root)
                guard !Task.isCancelled, expected == self.changeRequestGeneration else { return }
                self.changeRequestLocalState = local

                guard let repository = local.repository else {
                    self.changeRequestRepositoryStatus = nil
                    self.changeRequestFailureMessage = nil
                    self.changeRequestPrimaryAction = .none
                    self.setChangeRequestBarVisible(true)
                    self.changeRequestBar.configure(
                        title: L10n.string("Pull request"),
                        detail: L10n.string("The origin remote is not a github.com repository."),
                        status: L10n.string("Unavailable"),
                        statusColor: Design.Text.tertiary,
                        actionTitle: nil,
                        actionEnabled: false,
                        showsOpen: false,
                        policy: self.changeRequestConfiguration.publishPolicy
                    )
                    return
                }

                let signature = "\(local.branch):\(local.headRevision)"
                if !forceRemote,
                   let last = self.lastChangeRequestRead,
                   last.signature == signature,
                   Date().timeIntervalSince(last.date) < GitReviewChangeRequestDefaults.remoteRefreshInterval {
                    if self.changeRequestRepositoryStatus != nil {
                        self.renderChangeRequestBar()
                    } else if let message = self.changeRequestFailureMessage {
                        self.changeRequestPrimaryAction = .retry
                        self.changeRequestBar.showFailure(
                            message,
                            policy: self.changeRequestConfiguration.publishPolicy
                        )
                    }
                    return
                }

                let outcome = await self.changeRequestClient.discover(
                    repository: repository,
                    branch: local.branch,
                    headRevision: local.headRevision
                )
                guard !Task.isCancelled, expected == self.changeRequestGeneration else { return }
                self.lastChangeRequestRead = (signature, Date())
                switch outcome {
                case .loaded(let status):
                    self.changeRequestRepositoryStatus = status
                    self.changeRequestFailureMessage = nil
                    self.renderChangeRequestBar()
                case .failed(let message):
                    self.changeRequestRepositoryStatus = nil
                    self.changeRequestFailureMessage = message
                    self.changeRequestPrimaryAction = .retry
                    self.setChangeRequestBarVisible(true)
                    self.changeRequestBar.showFailure(
                        message,
                        policy: self.changeRequestConfiguration.publishPolicy
                    )
                }
            } catch {
                guard !Task.isCancelled, expected == self.changeRequestGeneration else { return }
                self.changeRequestRepositoryStatus = nil
                self.changeRequestFailureMessage = error.localizedDescription
                self.changeRequestPrimaryAction = .retry
                self.setChangeRequestBarVisible(true)
                self.changeRequestBar.showFailure(
                    error.localizedDescription,
                    policy: self.changeRequestConfiguration.publishPolicy
                )
            }
        }
    }

    var changeRequestConfiguration: ChangeRequestConfiguration {
        ChangeRequestConfigurationStore.shared.configuration(forProjectPath: folderPath)
    }

    func renderChangeRequestBar() {
        guard let local = changeRequestLocalState,
              let status = changeRequestRepositoryStatus else { return }
        setChangeRequestBarVisible(true)

        let policy = changeRequestConfiguration.publishPolicy
        let pullRequest = status.pullRequest
        let title = pullRequest.map { "#\($0.number) · \($0.title)" }
            ?? L10n.format("Publish %@", local.branch)
        var details = ["\(local.branch) → \(status.defaultBranch)"]
        if let pullRequest {
            if pullRequest.isDraft { details.append(L10n.string("Draft")) }
            if pullRequest.reviews.changesRequested > 0 {
                details.append(L10n.format(
                    "%lld requested changes",
                    Int64(pullRequest.reviews.changesRequested)
                ))
            } else if pullRequest.reviews.approvals > 0 {
                details.append(L10n.format(
                    "%lld approvals",
                    Int64(pullRequest.reviews.approvals)
                ))
            } else if pullRequest.reviews.requested > 0 {
                details.append(L10n.format(
                    "%lld reviewers requested",
                    Int64(pullRequest.reviews.requested)
                ))
            }
        }
        if local.hasUncommittedChanges {
            details.append(L10n.string("uncommitted changes stay local"))
        }

        let checkSummary = pullRequest?.checks ?? status.checks
        let (checkText, checkColor) = checkPresentation(checkSummary)
        let action: GitReviewChangeRequestPrimaryAction
        let actionTitle: String?
        let actionEnabled: Bool
        if isChangingRequest {
            action = .none
            actionTitle = L10n.string("Working…")
            actionEnabled = false
        } else if pullRequest != nil, local.needsPush {
            action = .push
            actionTitle = L10n.string("Push update")
            actionEnabled = true
        } else if pullRequest != nil {
            action = .open
            actionTitle = L10n.string("Open pull request")
            actionEnabled = true
        } else if local.branch == status.defaultBranch {
            action = .none
            actionTitle = nil
            details.append(L10n.string("Default branch"))
            actionEnabled = false
        } else if local.needsPush {
            action = .push
            actionTitle = L10n.string("Push branch")
            actionEnabled = true
        } else if policy == .pushOnly {
            action = .none
            actionTitle = nil
            details.append(L10n.string("Branch pushed"))
            actionEnabled = false
        } else {
            action = .create
            switch policy {
            case .reviewBeforePublishing:
                actionTitle = L10n.string("Create pull request…")
            case .createDraft:
                actionTitle = L10n.string("Create draft pull request")
            case .createReady:
                actionTitle = L10n.string("Create pull request")
            case .pushOnly:
                actionTitle = nil
                details.append(L10n.string("Branch pushed"))
            }
            actionEnabled = actionTitle != nil
        }
        changeRequestPrimaryAction = action
        changeRequestBar.configure(
            title: title,
            detail: details.joined(separator: " · "),
            status: checkText,
            statusColor: checkColor,
            actionTitle: actionTitle,
            actionEnabled: actionEnabled,
            showsOpen: pullRequest != nil && action != .open,
            policy: policy
        )
    }

    private func checkPresentation(_ checks: ChangeRequestChecks) -> (String, NSColor) {
        switch checks.state {
        case .unavailable: return ("", Design.Text.tertiary)
        case .none: return (L10n.string("No checks"), Design.Text.tertiary)
        case .pending:
            return (
                L10n.format("%lld checks pending", Int64(checks.pending)),
                Design.Status.warning
            )
        case .passing:
            return (
                L10n.format("%lld checks passed", Int64(checks.passed)),
                Design.Status.positive
            )
        case .failing:
            return (
                L10n.format("%lld checks failed", Int64(checks.failed)),
                Design.Status.negative
            )
        }
    }

    func performChangeRequestPrimaryAction() {
        switch changeRequestPrimaryAction {
        case .retry:
            guard let root = repositoryRoot else { return }
            lastChangeRequestRead = nil
            changeRequestFailureMessage = nil
            refreshChangeRequest(in: root, forceRemote: true)
        case .push:
            pushCurrentBranch()
        case .create:
            createCurrentPullRequest()
        case .open:
            openCurrentPullRequest()
        case .none:
            break
        }
    }

    func openCurrentPullRequest() {
        guard let url = changeRequestRepositoryStatus?.pullRequest?.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func pushCurrentBranch() {
        guard let local = changeRequestLocalState,
              let repository = local.repository,
              !isChangingRequest else { return }
        isChangingRequest = true
        renderChangeRequestBar()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ChangeRequestGit.push(local)
                ChangeRequestReceiptStore.shared.append(ChangeRequestReceipt(
                    date: Date(),
                    action: .pushed,
                    repository: repository.slug,
                    branch: local.branch,
                    url: nil,
                    credentialTier: nil
                ))
                self.notice = (L10n.format("Pushed %@.", local.branch), false)
                self.show(self.phase)
                self.isChangingRequest = false
                self.lastChangeRequestRead = nil
                self.refreshChangeRequest(in: local.root, forceRemote: true)
            } catch {
                self.isChangingRequest = false
                self.notice = (error.localizedDescription, true)
                self.show(self.phase)
                self.renderChangeRequestBar()
            }
        }
    }

    private func createCurrentPullRequest() {
        guard let local = changeRequestLocalState,
              let status = changeRequestRepositoryStatus,
              status.pullRequest == nil,
              !local.needsPush,
              !isChangingRequest else { return }
        let policy = changeRequestConfiguration.publishPolicy
        guard policy != .pushOnly else { return }

        isChangingRequest = true
        renderChangeRequestBar()
        Task { [weak self] in
            guard let self else { return }
            do {
                let seed = try await ChangeRequestGit.proposalSeed(
                    in: local.root,
                    baseBranch: status.defaultBranch
                )
                let proposal: ChangeRequestProposal?
                switch policy {
                case .reviewBeforePublishing:
                    proposal = PullRequestComposerAlert.ask(
                        seed: seed,
                        root: local.root,
                        baseBranch: status.defaultBranch,
                        headBranch: local.branch,
                        isDraft: true
                    )
                case .createDraft, .createReady:
                    proposal = ChangeRequestProposal(
                        title: seed.title,
                        body: seed.body,
                        baseBranch: status.defaultBranch,
                        headBranch: local.branch,
                        isDraft: policy == .createDraft
                    )
                case .pushOnly:
                    proposal = nil
                }
                guard let proposal else {
                    self.isChangingRequest = false
                    self.renderChangeRequestBar()
                    return
                }
                let outcome = await self.changeRequestClient.create(
                    repository: status.repository,
                    proposal: proposal
                )
                self.finishChangeRequestCreation(
                    outcome,
                    proposal: proposal,
                    repository: status.repository
                )
            } catch {
                self.isChangingRequest = false
                self.notice = (error.localizedDescription, true)
                self.show(self.phase)
                self.renderChangeRequestBar()
            }
        }
    }

    private func finishChangeRequestCreation(
        _ outcome: ChangeRequestWriteOutcome,
        proposal: ChangeRequestProposal,
        repository: ChangeRequestRepository
    ) {
        isChangingRequest = false
        switch outcome {
        case .created(let pullRequest, let tier):
            ChangeRequestReceiptStore.shared.append(ChangeRequestReceipt(
                date: Date(),
                action: proposal.isDraft ? .createdDraft : .createdReady,
                repository: repository.slug,
                branch: proposal.headBranch,
                url: pullRequest.url,
                credentialTier: tier
            ))
            notice = (
                L10n.format("Created pull request #%lld.", Int64(pullRequest.number)),
                false
            )
            lastChangeRequestRead = nil
            if let root = repositoryRoot {
                refreshChangeRequest(in: root, forceRemote: true)
            }
        case .webForm(let url, let message):
            notice = (message, false)
            NSWorkspace.shared.open(url)
            renderChangeRequestBar()
        case .failed(let message):
            notice = (message, true)
            renderChangeRequestBar()
        }
        show(phase)
    }
}

enum GitReviewChangeRequestDefaults {
    static let barHeight: CGFloat = 54
    static let remoteRefreshInterval: TimeInterval = 15
}
