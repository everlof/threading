import AppKit

/// What an approval sheet shows for one exact revision, as facts a person can read in the order
/// they decide in: where it runs, when, as whom and on which model, with what authority, for how
/// long, and what happens after. It is a receipt for the decision, so it names everything that
/// will run — including the login a run falls back to when none was chosen, which is the fact a
/// sheet of identifiers used to hide.
///
/// Built as a value first so the choice of facts is testable without drawing anything.
@MainActor
struct AutomationReview: Equatable {
    enum Purpose: Equatable {
        /// The Activate button on a draft: future runs, from now on.
        case activate
        /// An agent's `enable` request.
        case enable
        /// An agent's or the person's `run` request: once, now.
        case runNow
    }

    struct Account: Equatable {
        let handle: AccountHandle
        let name: String
        let directory: String
    }

    /// The live lookups, injected so tests state what the app would have answered.
    struct Context {
        var project: @MainActor (ProjectID) -> (name: String, folder: String)?
        /// The login the revision resolves to, or nil when its agent has no accounts.
        var account: @MainActor (AgentKind, AccountHandle) -> Account?
        /// The model and effort a run will use, already in display words.
        var model: @MainActor (TriggerRevision) -> String
        var effort: @MainActor (TriggerRevision) -> String?
        var sourceName: @MainActor (TriggerSourceInstallationID) -> String?
    }

    let facts: [FactSheetView.Fact]
    let instructions: String

    static func make(_ revision: TriggerRevision, purpose: Purpose, context: Context) -> AutomationReview {
        var facts: [FactSheetView.Fact] = []
        let options = revision.automation
        let schedule = options?.schedule

        if let project = context.project(revision.projectID) {
            facts.append(.init(label: L10n.string("Project"), value: project.name,
                               detail: project.folder, identifier: "project"))
        } else {
            facts.append(.init(label: L10n.string("Project"), value: L10n.string("Unknown project"),
                               detail: revision.projectID.uuidString, tone: .caution, identifier: "project"))
        }

        facts.append(timing(revision, schedule: schedule, purpose: purpose, context: context))
        if schedule == nil {
            facts.append(.init(
                label: L10n.string("Conditions"),
                value: revision.conditions.isEmpty
                    ? L10n.string("Any event of this kind")
                    : revision.conditions.map(\.reviewDescription).joined(separator: "\n"),
                identifier: "conditions"
            ))
        }

        let agentWords = [revision.agentKind.displayName, context.model(revision), context.effort(revision)]
            .compactMap { $0 }
            .joined(separator: " · ")
        facts.append(.init(label: L10n.string("Agent"), value: agentWords, identifier: "agent"))

        let handle = AccountHandle(storedName: revision.accountHandleName)
        if let account = context.account(revision.agentKind, handle) {
            facts.append(accountFact(account, requested: revision.accountHandleName))
        }

        facts.append(.init(label: L10n.string("Permissions"), value: revision.executionMode.displayTitle,
                           detail: revision.checkoutPolicy.displayTitle, identifier: "permissions"))
        facts.append(allowedFact(revision.effectivePermissions))

        let runtime = L10n.format("Stops after %lld minutes", Int64(revision.limits.maximumRuntimeMinutes))
        facts.append(.init(
            label: L10n.string("Time limit"),
            value: runtime,
            detail: schedule == nil ? concurrency(revision.limits.maximumConcurrentRuns) : nil,
            identifier: "limits"
        ))

        if let options {
            facts.append(.init(
                label: L10n.string("After success"),
                value: options.archiveOnSuccess
                    ? L10n.string("Archive the chat; its history is kept")
                    : L10n.string("Keep the chat in the sidebar"),
                identifier: "afterSuccess"
            ))
        }

        facts.append(.init(label: L10n.string("Revision"),
                           value: String(revision.sequence),
                           detail: revision.id.uuidString, identifier: "revision"))
        return AutomationReview(facts: facts, instructions: revision.instructions)
    }

    private static func timing(
        _ revision: TriggerRevision, schedule: AutomationSchedule?, purpose: Purpose, context: Context
    ) -> FactSheetView.Fact {
        let missed: String? = revision.automation.map {
            $0.missedRunPolicy == .latest
                ? L10n.string("A missed time runs once when the Mac is back")
                : L10n.string("A missed time is skipped")
        }
        switch (purpose, schedule) {
        case (.runNow, let schedule?):
            return .init(label: L10n.string("When"), value: L10n.string("Once, now"),
                         detail: L10n.format("Saved schedule: %@", schedule.summary), identifier: "when")
        case (.runNow, nil):
            return .init(label: L10n.string("When"), value: L10n.string("Once, now"), identifier: "when")
        case (_, let schedule?):
            return .init(label: L10n.string("When"), value: schedule.summary, detail: missed, identifier: "when")
        case (_, nil):
            let source = context.sourceName(revision.sourceInstallationID)
                ?? L10n.format("Source %@", String(revision.sourceInstallationID.uuidString.prefix(8)))
            return .init(label: L10n.string("When"),
                         value: L10n.format("“%@” arrives", revision.eventKind),
                         detail: L10n.format("From %@", source), identifier: "when")
        }
    }

    /// What the run may do without a person. Full permission is stated in caution tone, and an
    /// allow-list is shown rule by rule, because this sheet is where that authority is granted.
    private static func allowedFact(_ policy: AutomationPermissionPolicy) -> FactSheetView.Fact {
        switch policy {
        case .full:
            return .init(label: L10n.string("Without asking"), value: L10n.string("Full permission"),
                         detail: L10n.string("Every command runs without asking"),
                         tone: .caution, identifier: "allowed")
        case .allowList(let rules) where rules.isEmpty:
            return .init(label: L10n.string("Without asking"), value: L10n.string("Read-only commands only"),
                         detail: L10n.string("Anything else is refused"), identifier: "allowed")
        case .allowList(let rules):
            return .init(label: L10n.string("Without asking"), value: rules.map(\.text).joined(separator: "\n"),
                         detail: L10n.string("Plus read-only commands; anything else is refused"),
                         identifier: "allowed")
        }
    }

    private static func concurrency(_ runs: Int) -> String {
        runs == 1 ? L10n.string("One run at a time") : L10n.format("At most %lld runs at once", Int64(runs))
    }

    private static func accountFact(_ account: Account, requested: String?) -> FactSheetView.Fact {
        guard let requested else {
            // Name what will actually sign in: repeating the agent's name here said nothing, and
            // an unchosen default login is how an automation ran on an expired session.
            return .init(label: L10n.string("Account"),
                         value: L10n.format("Default login, %@", account.directory),
                         detail: L10n.string("No account chosen for this automation"),
                         tone: .caution, identifier: "account")
        }
        guard AccountHandle(storedName: requested) == account.handle else {
            return .init(label: L10n.string("Account"), value: account.name,
                         detail: L10n.format("“%@” was not found, so this login: %@", requested, account.directory),
                         tone: .caution, identifier: "account")
        }
        return .init(label: L10n.string("Account"), value: account.name, detail: account.directory,
                     identifier: "account")
    }
}

@MainActor
extension AutomationReview.Context {
    /// What the app knows now. `sourceName` is resolved by the caller, which may have to read
    /// the store asynchronously before the sheet is built.
    static func live(sourceName: String? = nil) -> Self {
        @MainActor func agentAccount(_ revision: TriggerRevision) -> AgentAccount? {
            AgentAccountDiscovery.account(
                for: revision.agentKind, handle: AccountHandle(storedName: revision.accountHandleName))
        }
        return Self(
            project: { id in
                ProjectStore.shared.project(withID: id).map {
                    ($0.name, ($0.folderPath as NSString).abbreviatingWithTildeInPath)
                }
            },
            account: { kind, handle in
                AgentAccountDiscovery.account(for: kind, handle: handle).map {
                    .init(handle: $0.handle, name: $0.displayName,
                          directory: ($0.configPath as NSString).abbreviatingWithTildeInPath)
                }
            },
            model: { revision in
                let account = agentAccount(revision)
                guard let model = revision.model ?? AgentModels.defaultModel(for: revision.agentKind, account: account)
                else { return L10n.string("Default model") }
                return AgentModels.displayName(for: model, account: account)
            },
            effort: { revision in
                let effort = revision.reasoningEffort
                    ?? AgentModels.defaultEffort(for: revision.agentKind, account: agentAccount(revision))
                return effort.map {
                    L10n.format("%@ effort", AgentReasoningLevel(effort: $0, description: "").displayName)
                }
            },
            sourceName: { _ in sourceName }
        )
    }
}

/// The review as the sheet draws it: one scrolling column holding the facts and then the
/// instructions as plain wrapped text. The sheet's own column scrolls when a long brief needs
/// it; there is no second, boxed scroller inside it.
@MainActor
final class AutomationReviewView: NSView {
    enum Layout {
        static let width: CGFloat = 520
        static let maximumHeight: CGFloat = 400
    }

    let review: AutomationReview
    let scrollView = ThemedScrollView()

    init(review: AutomationReview, instructionsTitle: String = L10n.string("Instructions")) {
        self.review = review
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let sheet = FactSheetView(facts: review.facts, width: Layout.width)

        let heading = NSTextField(labelWithString: instructionsTitle)
        heading.applyFont(.emphasizedBody)
        heading.textColor = Design.Text.label

        let body = NSTextField(wrappingLabelWithString: review.instructions)
        body.applyFont(.detail())
        body.textColor = Design.Text.secondary
        body.isSelectable = true
        body.preferredMaxLayoutWidth = Layout.width
        body.setAccessibilityIdentifier("review.instructions")

        let column = NSStackView(views: [sheet, heading, body])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.medium
        column.setCustomSpacing(Design.Spacing.small, after: heading)
        column.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalToConstant: Layout.width),
        ])
        let contentHeight = ceil(document.fittingSize.height)

        let scroll = scrollView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = contentHeight > Layout.maximumHeight
        scroll.hasHorizontalScroller = false
        scroll.documentView = document
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: Layout.width),
            heightAnchor.constraint(equalToConstant: min(contentHeight, Layout.maximumHeight)),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A long brief is cut at the sheet's measure, and an overlay scroller at rest draws nothing
    /// to say so; showing it once as the sheet opens says the instructions continue.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, scrollView.hasVerticalScroller { scrollView.flashScrollers() }
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
