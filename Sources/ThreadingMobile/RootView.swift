import ThreadingRemoteKit
import SwiftUI
import UIKit

// MARK: - Demo scenes

// Debug-only, like every fixture it names: `MobileSessionOpeningFixture` and the demo
// hosts below do not exist in a shipping build.
#if DEBUG

/// The root screen `THREADING_MOBILE_DEMO` names.
///
/// That variable is how iOS appearance is reviewed: `scripts/ui-evidence-ios.sh` launches the
/// shipping app once per capture with one id in the environment and photographs whatever comes
/// up. Nothing rejects an id, and an id nothing matches renders the real app — so a misspelling
/// photographed the wrong screen and passed review looking entirely plausible.
///
/// This used to be an ordered `if / else if` chain that mixed exact comparisons with `hasPrefix`
/// tests, where a prefix placed above an exact id would have swallowed it with nothing to say so.
/// Naming the scenes makes the routing one exhaustive `switch` and the ids enumerable
/// (`MobileDemoFixture`).
///
/// Prefix families stay parameterised rather than being flattened into exact cases: `review-files`
/// and `attachment-detail-pdf` carry a payload after the prefix that the screen reads.
enum MobileDemoScene: Equatable {
    /// No demo scene — the shipping root. Reached by an unset variable, by an id nothing matches,
    /// and deliberately by every fixture whose surface is met from *inside* the real app.
    case shippingRoot

    case terminal
    case attentionRequest
    case conversation
    case pairing
    case welcome
    case settings
    case connectionProgressLab
    case connectionStatus
    case appIconSettings
    case collaborationSettings
    case advancedConnectionSettings
    case localDiagnosticsSettings
    case notificationSettings
    case terminalKeySettings
    case terminalKeyEditor
    case terminalKeyCatalog
    case terminalKeySnippet
    case terminalKeyEdit
    case macAppearanceSettings
    case diagnostics
    case sharedLink
    case shareChatRoles
    case shareChatBlocked
    case shareChatLink
    case sessionSettings
    case permission
    case newSession
    case themedDialogAlert
    case themedDialogConfirmation
    /// Git Review. `showsAllFiles` is the `files` the id may carry after `review`.
    case review(showsAllFiles: Bool)
    /// One of the session-opening placeholders, which own their own ids.
    case sessionOpening(MobileSessionOpeningFixture)
    case browserPrivate
    case attachments
    /// One attachment preview. The kind is whatever followed `attachment-detail-`.
    case attachmentDetail(kind: RemoteAttachmentKind)
    case workspace
}

extension MobileDemoScene {
    /// The one spelling of the environment variable every demo fixture is launched with.
    static let environmentKey = "THREADING_MOBILE_DEMO"

    /// The ids that all reach the same mirrored terminal. What differs between them is the
    /// fixture data `RemoteSessionConnection.demoTerminal()` builds, not the screen.
    static let terminalFixtureIDs: Set<String> = [
        "terminal-collaboration",
        "terminal-compose",
        "terminal-ansi",
        "terminal-scrollback",
        "terminal-attachments",
        "terminal-browser-activity",
        "terminal-selection",
        "terminal-codex-tui",
        "terminal-claude-tui",
        "marketing-claude-tui",
        "marketing-claude-usage-menu",
        "marketing-codex-tui",
    ]

    private static let attachmentDetailPrefix = "attachment-detail-"

    /// The scene this process was launched for.
    static var current: MobileDemoScene {
        resolve(ProcessInfo.processInfo.environment[environmentKey])
    }

    /// Resolves an id to its scene.
    ///
    /// The cases are kept in the order the previous chain tested them, because order is still
    /// load-bearing between a prefix and any exact id it could swallow. Nothing below a prefix
    /// test starts with that prefix today, and `MobileDemoFixture` is what pins it.
    static func resolve(_ id: String?) -> MobileDemoScene {
        guard let id else { return .shippingRoot }
        switch id {
        case let id where terminalFixtureIDs.contains(id): return .terminal
        case "attention-request": return .attentionRequest
        case let id where id.hasPrefix("conversation"): return .conversation
        case "pairing": return .pairing
        case let id where id.hasPrefix("welcome"): return .welcome
        case "settings", "marketing-settings": return .settings
        case "connection-progress-lab": return .connectionProgressLab
        case "connection-status": return .connectionStatus
        case "app-icon-settings": return .appIconSettings
        case "collaboration-settings": return .collaborationSettings
        case "advanced-connection-settings": return .advancedConnectionSettings
        case "local-diagnostics-settings": return .localDiagnosticsSettings
        case "notification-settings": return .notificationSettings
        case "terminal-key-settings": return .terminalKeySettings
        case "terminal-key-editor": return .terminalKeyEditor
        case "terminal-key-catalog": return .terminalKeyCatalog
        case "terminal-key-snippet": return .terminalKeySnippet
        case "terminal-key-edit": return .terminalKeyEdit
        case "mac-appearance-settings": return .macAppearanceSettings
        case "diagnostics": return .diagnostics
        case "shared-link": return .sharedLink
        case "share-chat-roles": return .shareChatRoles
        case "share-chat-blocked": return .shareChatBlocked
        case "share-chat-link": return .shareChatLink
        case "session-settings": return .sessionSettings
        case let id where id.hasPrefix("permission"): return .permission
        case let id where id.hasPrefix("new-session"): return .newSession
        case "themed-dialog-alert": return .themedDialogAlert
        case "themed-dialog-confirmation": return .themedDialogConfirmation
        case let id where id.hasPrefix("review"):
            return .review(showsAllFiles: id.contains("files"))
        case "browser-private": return .browserPrivate
        case "attachments": return .attachments
        case let id where id.hasPrefix(attachmentDetailPrefix):
            return .attachmentDetail(
                kind: RemoteAttachmentKind(
                    rawValue: String(id.dropFirst(attachmentDetailPrefix.count))
                )
            )
        case "workspace": return .workspace
        default:
            // The chain tested this between `review` and `browser-private`. It reads the same
            // here: no session-opening id is `browser-private`, `attachments` or `workspace`,
            // and none begins with `attachment-detail-`.
            if let opening = MobileSessionOpeningFixture(rawValue: id) {
                return .sessionOpening(opening)
            }
            return .shippingRoot
        }
    }
}

/// Every `THREADING_MOBILE_DEMO` id this repository launches the app with.
///
/// `MobileDemoScene` routes prefix families, so it accepts ids beyond this list. The catalogue
/// answers the narrower question tooling needs — whether an id is one somebody meant to write —
/// which a screenshot cannot answer, because an unknown id looks exactly like the shipping app
/// being the fixture on purpose. Adding a fixture id means adding a case here; that is the gate.
enum MobileDemoFixture: String, CaseIterable {
    /// The mirrored terminal, one id per captured terminal state.
    case terminalANSI = "terminal-ansi"
    case terminalAttachments = "terminal-attachments"
    case terminalBrowserActivity = "terminal-browser-activity"
    case terminalClaudeTUI = "terminal-claude-tui"
    case terminalCodexTUI = "terminal-codex-tui"
    case terminalCollaboration = "terminal-collaboration"
    case terminalCompose = "terminal-compose"
    case terminalScrollback = "terminal-scrollback"
    case terminalSelection = "terminal-selection"

    /// The five App Store/website checkpoints. They share one fixture story and are deliberately
    /// separate from the broader regression gallery so marketing copy can iterate independently.
    case marketingSessions = "marketing-sessions"
    case marketingClaudeTUI = "marketing-claude-tui"
    case marketingCodexTUI = "marketing-codex-tui"
    case marketingClaudeUsageMenu = "marketing-claude-usage-menu"
    case marketingSettings = "marketing-settings"

    /// The demo conversation. Everything after the prefix is read by the surface it configures.
    case conversation = "conversation"
    case conversationAttachments = "conversation-attachments"
    case conversationAwayFromLatest = "conversation-away-from-latest"
    case conversationColdStress = "conversation-cold-stress"
    case conversationCollaboration = "conversation-collaboration"
    case conversationContentTypes = "conversation-content-types"
    case conversationKeyboard = "conversation-keyboard"
    case conversationReconnectStress = "conversation-reconnect-stress"
    case conversationRichContent = "conversation-rich-content"
    case conversationRunPlan = "conversation-run-plan"
    case conversationRunPlanExpanded = "conversation-run-plan-expanded"
    case conversationScrollStress = "conversation-scroll-stress"
    case conversationStreaming = "conversation-streaming"
    case conversationToolExpanded = "conversation-tool-expanded"

    case attentionRequest = "attention-request"
    case pairing = "pairing"

    /// The welcome screen; the suffix focuses one feature card.
    case welcome = "welcome"
    case welcomeBrowser = "welcome-browser"
    case welcomeUsage = "welcome-usage"

    /// Settings and its pages.
    case settings = "settings"
    case appIconSettings = "app-icon-settings"
    case collaborationSettings = "collaboration-settings"
    case advancedConnectionSettings = "advanced-connection-settings"
    case localDiagnosticsSettings = "local-diagnostics-settings"
    case notificationSettings = "notification-settings"
    case macAppearanceSettings = "mac-appearance-settings"
    case connectionProgressLab = "connection-progress-lab"
    case connectionStatus = "connection-status"
    case diagnostics = "diagnostics"

    /// The mobile terminal key bar's editor.
    case terminalKeySettings = "terminal-key-settings"
    case terminalKeyEditor = "terminal-key-editor"
    case terminalKeyCatalog = "terminal-key-catalog"
    case terminalKeySnippet = "terminal-key-snippet"
    case terminalKeyEdit = "terminal-key-edit"

    /// Sharing a chat.
    case sharedLink = "shared-link"
    case shareChatRoles = "share-chat-roles"
    case shareChatBlocked = "share-chat-blocked"
    case shareChatLink = "share-chat-link"

    case sessionSettings = "session-settings"

    /// The permission prompt; `-long` lengthens the fixture inside the same scene.
    case permission = "permission"
    case permissionLong = "permission-long"

    /// The new-session draft; the suffix chooses which state it opens in.
    case newSession = "new-session"
    case newSessionDraftMatrix = "new-session-draft-matrix"
    case newSessionModelEffortPicker = "new-session-model-effort-picker"
    case newSessionMultiline = "new-session-multiline"
    case newSessionSingleCharacter = "new-session-single-character"
    case newSessionScrollOverflow = "new-session-scroll-overflow"
    case newSessionStructuredError = "new-session-structured-error"

    case themedDialogAlert = "themed-dialog-alert"
    case themedDialogConfirmation = "themed-dialog-confirmation"

    /// Git Review; `files` selects the All Files section, `massive` the stress cardinality.
    case review = "review"
    case reviewFiles = "review-files"
    case reviewFilesMassive = "review-files-massive"

    /// The session-opening placeholders (`MobileSessionOpeningFixture`).
    case sessionOpeningConnecting = "session-opening-connecting"
    case sessionOpeningResuming = "session-opening-resuming"
    case sessionOpeningFailed = "session-opening-failed"

    /// The session workspace and what it opens.
    case workspace = "workspace"
    case browserPrivate = "browser-private"
    case attachments = "attachments"

    /// One attachment preview; the suffix is a `RemoteAttachmentKind` raw value.
    case attachmentDetailHTML = "attachment-detail-html"
    case attachmentDetailImage = "attachment-detail-image"
    case attachmentDetailPDF = "attachment-detail-pdf"
    case attachmentDetailText = "attachment-detail-text"

    // Ids that deliberately resolve to no root scene: the shipping app is the
    // fixture, and the surface below is reached from inside it.

    /// The usage dashboard, reached through the dashboard's own sheet.
    case usage = "usage"
    case usageLimit = "usage-limit"
    case usageLimitUnavailable = "usage-limit-unavailable"
    case usageLimitZero = "usage-limit-zero"
    case usageStale = "usage-stale"

    /// The session list, and one project's slice of it.
    case sessions = "sessions"
    case sessionsConnecting = "sessions-connecting"
    case sessionsOffline = "sessions-offline"
    case projectSessions = "project-sessions"

    /// The issue report, presented over whatever the root already shows.
    case report = "report"
    case reportScreenshot = "report-screenshot"

    /// The root scene this id reaches.
    var scene: MobileDemoScene { MobileDemoScene.resolve(rawValue) }

    static let marketingIDs: Set<String> = [
        marketingSessions.rawValue,
        marketingClaudeTUI.rawValue,
        marketingCodexTUI.rawValue,
        marketingClaudeUsageMenu.rawValue,
        marketingSettings.rawValue,
    ]

    static func isMarketing(_ id: String?) -> Bool {
        id.map(marketingIDs.contains) ?? false
    }
}
#endif

struct RootView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @State private var issueReportRequest: MobileIssueReportRequest?
    @State private var showsSettings = false
#if DEBUG
    @StateObject private var demoConversation = RemoteSessionConnection.demoConversation()
    @StateObject private var demoPermission = RemoteSessionConnection.demoPermissionConversation()
    @StateObject private var demoTerminal = RemoteSessionConnection.demoTerminal()
    @StateObject private var workspaceDemoActivity = MobileWorkspaceActivity(
        sessionID: "workspace-demo"
    )

    /// A fixture's own name, the way the app takes one: from the catalogue row, never from the
    /// socket caption the mirrored surface happens to be showing.
    private var demoTerminalName: String { demoTerminal.session.title }
    private var demoConversationName: String { demoConversation.session.title }
    private var demoPermissionName: String { demoPermission.session.title }
    private var isMarketingTerminalFixture: Bool {
        let id = ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
        return id == MobileDemoFixture.marketingClaudeTUI.rawValue
            || id == MobileDemoFixture.marketingCodexTUI.rawValue
            || id == MobileDemoFixture.marketingClaudeUsageMenu.rawValue
    }
#endif

    var body: some View {
        MobileRootBackdrop(ground: theme.ground) {
#if DEBUG
            demoRoot
#else
            standardRoot
#endif
        }
        .mobileTheme(theme)
        .background {
            ShakeGestureDetector {
                guard issueReportRequest == nil else { return }
                // Taken here, before anything is presented, because the screen the shake was
                // about is the one still on the display: a prompt asking permission first is a
                // prompt standing in front of the evidence. The image never leaves the phone
                // unless the report sheet's screenshot checkmark is still on when it is sent
                // or shared, and it is discarded with the sheet otherwise.
                let screenshot = MobileScreenCapture.currentScreen()
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                openShakeReport(screenshot: screenshot)
            }
            .frame(width: 0, height: 0)
        }
        .sheet(item: $issueReportRequest) { request in
            MobileIssueReportView(request: request)
                .mobileTheme(theme)
        }
#if DEBUG
        .task {
            await openIssueReportDemoIfNeeded()
        }
        // Screenshot/verification tooling for the *runtime* demo — the same startDemo() the
        // welcome button calls, unlike THREADING_MOBILE_DEMO's static preview hosts.
        .task {
            switch ProcessInfo.processInfo.environment["THREADING_MOBILE_RUNTIME_DEMO"] {
            case "1":
                model.startDemo()
            case "session":
                model.startDemo()
                if let first = model.me?.sessions.first {
                    model.navigationPath = [.session(first.id)]
                }
            case "terminal":
                model.startDemo()
                if let terminal = model.me?.sessions.first(where: { $0.surface == .terminal }) {
                    model.navigationPath = [.session(terminal.id)]
                }
            default:
                break
            }
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "project-sessions",
               model.navigationPath.isEmpty,
               let projectName = model.me?.sessions.first?.projectName {
                model.navigationPath = [.project(projectName)]
            }
        }
#endif
    }

#if DEBUG
    /// The one place `THREADING_MOBILE_DEMO` decides what the root shows.
    ///
    /// Exhaustive on purpose: a new `MobileDemoScene` case is a compile error here rather than a
    /// fixture that silently photographs the shipping app.
    @ViewBuilder
    private var demoRoot: some View {
        switch MobileDemoScene.current {
        case .terminal:
            NavigationStack {
                if isMarketingTerminalFixture {
                    // Use the shipping detail chrome so the capture proves the actual account,
                    // usage, Workspace and session-actions menu rather than a fixture facsimile.
                    SessionDetailView(evidenceConnection: demoTerminal)
                } else {
                    TerminalRemoteView(connection: demoTerminal)
                        .navigationTitle(demoTerminalName)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { demoTerminalToolbar }
                }
            }
            .task {
                guard ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                        == MobileDemoFixture.terminalBrowserActivity.rawValue else { return }
                workspaceDemoActivity.receive(RemoteWorkspaceChangedDTO(
                    kind: .browser,
                    activityID: "terminal-browser-activity"
                ))
            }
        case .attentionRequest:
            AttentionRequestSheet(connection: demoConversation)
        case .conversation:
            NavigationStack {
                ConversationRemoteView(connection: demoConversation)
                    .navigationTitle(demoConversationName)
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .pairing:
            PairingView()
                .environmentObject(model)
        case .welcome:
            NavigationStack {
                WelcomeView(openSettings: { showsSettings = true })
            }
        case .settings:
            MobileSettingsView()
        case .connectionProgressLab:
            NavigationStack {
                MobileConnectionProgressLab()
            }
        case .connectionStatus:
            // The panel's content on its own stack, from the demo Mac's record: what the sheet
            // shows, without a sheet to wait for. The chain reaches this only with a host, which
            // every demo mode has from the first render.
            if let host = model.activeHost {
                NavigationStack {
                    MobileConnectionStatusContent(
                        report: MobileConnectionReport.demo(
                            host: host,
                            record: model.lastConnection
                        ),
                        isChecking: false,
                        check: {},
                        copy: {}
                    )
                }
            } else {
                standardRoot
            }
        case .appIconSettings:
            NavigationStack {
                MobileAppIconSettingsView()
            }
        case .collaborationSettings:
            NavigationStack {
                CollaborationSettingsView()
            }
        case .advancedConnectionSettings:
            NavigationStack {
                AdvancedConnectionSettingsView(pool: .evidenceFixture())
            }
        case .localDiagnosticsSettings:
            NavigationStack {
                MobileDiagnosticsView()
            }
        case .notificationSettings:
            NotificationSettingsView()
        case .terminalKeySettings:
            NavigationStack {
                TerminalKeyboardAgentList()
            }
        case .terminalKeyEditor:
            NavigationStack {
                TerminalKeyboardEditorContent(agentKind: "claude")
                    .navigationTitle("Claude Code")
            }
        case .terminalKeyCatalog:
            NavigationStack {
                TerminalKeyboardEditorDemo(screen: .catalog)
            }
        case .terminalKeySnippet:
            NavigationStack {
                TerminalKeyboardEditorDemo(screen: .snippet)
            }
        case .terminalKeyEdit:
            NavigationStack {
                TerminalKeyboardEditorDemo(screen: .edit)
            }
        case .macAppearanceSettings:
            NavigationStack {
                MacAppearanceSettingsView()
            }
        case .diagnostics:
            RemoteDiagnosticsView()
        case .sharedLink:
            SharedSessionLinkDemoHost(link: ShareChatDemo.link)
        case .shareChatRoles:
            ShareChatDemoHost(isChatRunning: true, choice: nil)
        case .shareChatBlocked:
            ShareChatDemoHost(isChatRunning: false, choice: nil)
        case .shareChatLink:
            ShareChatDemoHost(isChatRunning: true, choice: .collaborateAndApprove)
        case .sessionSettings:
            // The chain reached this branch only with a session in hand and fell through to the
            // shipping root without one, because `me` arrives after the first render.
            if let session = model.me?.sessions.first {
                MobileSessionSettingsView(sessionID: session.id, onAccountMoved: {})
                    .environmentObject(model)
            } else {
                standardRoot
            }
        case .permission:
            NavigationStack {
                ConversationRemoteView(connection: demoPermission)
                    .navigationTitle(demoPermissionName)
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .newSession:
            // Met as it is shipped: pushed onto a stack, with a back button where the
            // sheet's Cancel used to be. Held as the root it had no back button, and the
            // account disc at the other end pushed the title off centre — a geometry the
            // real screen never has.
            SessionDraftDemoHost()
                .environmentObject(model)
        case .themedDialogAlert:
            ThemedDialogDemoView(kind: .alert)
        case .themedDialogConfirmation:
            ThemedDialogDemoView(kind: .confirmation)
        case .review(let showsAllFiles):
            NavigationStack {
                RemoteGitReviewView(
                    session: model.me?.sessions.first ?? Self.workspaceDemoSession,
                    client: model.client ?? Self.workspaceDemoClient,
                    initialSection: showsAllFiles ? .allFiles : .changed
                )
            }
        case .sessionOpening(let openingFixture):
            NavigationStack {
                SessionDetailView(session: openingFixture.session)
            }
        case .browserPrivate:
            NavigationStack {
                RemoteBrowserFollowView(
                    session: Self.workspaceDemoSession,
                    client: Self.workspaceDemoClient,
                    activity: workspaceDemoActivity,
                    initialTabID: "browser-private",
                    initialWorkspace: Self.browserDemoSnapshot,
                    loadsRemotely: false
                )
            }
        case .attachments:
            NavigationStack {
                RemoteAttachmentsView(
                    session: Self.workspaceDemoSession,
                    client: Self.workspaceDemoClient,
                    initialAttachments: Self.attachmentDemoItems,
                    loadsRemotely: false
                )
            }
        case .attachmentDetail(let kind):
            NavigationStack {
                RemoteAttachmentPreviewDemo(kind: kind)
            }
        case .workspace:
            SessionWorkspaceView(
                session: Self.workspaceDemoSession,
                client: Self.workspaceDemoClient,
                activity: workspaceDemoActivity,
                initialWorkspace: Self.workspaceDemoSnapshot
            )
            .task {
                workspaceDemoActivity.receive(RemoteWorkspaceChangedDTO(
                    kind: .browser,
                    activityID: UUID().uuidString
                ))
            }
        case .shippingRoot:
            standardRoot
        }
    }

    @ToolbarContentBuilder
    private var demoTerminalToolbar: some ToolbarContent {
        if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
            == MobileDemoFixture.terminalBrowserActivity.rawValue {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    SessionWorkspaceMenuButton(
                        hasUnseenBrowser: workspaceDemoActivity.hasUnseenBrowser,
                        action: {}
                    )
                } label: {
                    SessionActionsToolbarIcon(
                        activity: workspaceDemoActivity,
                        identity: .resolve("codex"),
                        reading: MobileAccountUsageReading(
                            rings: [.init(id: "7d", fraction: 0.56)],
                            summary: "7d 56%"
                        ),
                        account: nil
                    )
                }
                .accessibilityLabel(
                    MobileL10n.string("Session actions, new browser activity")
                )
            }
        }
    }
#endif

    private var theme: RemoteThemePalette {
#if DEBUG
        let requestedTheme = ProcessInfo.processInfo.environment["THREADING_MOBILE_THEME"]
        if requestedTheme == "fallback" {
            return RemoteThemePalette(nil)
        }
        if requestedTheme == "light" {
            return RemoteThemePalette(RemoteAppModel.demoLightTheme)
        }
        if requestedTheme == "threading" {
            return RemoteThemePalette(RemoteAppModel.demoThreadingTheme)
        }
        if requestedTheme == "system-remote" {
            return RemoteThemePalette(RemoteAppModel.demoSystemRemoteTheme)
        }
        if let requestedTheme,
           let catalogTheme = RemoteAppModel.demoCatalogThemes.first(where: {
               $0.id == requestedTheme
           }) {
            return RemoteThemePalette(catalogTheme)
        }
        // Deliberately not `MobileDemoScene`: the route matches `permission` by prefix while
        // this matches it exactly, so `permission-long` has always taken the account's theme
        // rather than the demo conversation's. Preserved, because changing it would move a
        // published appearance baseline.
        let demoID = ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey] ?? ""
        if demoID.hasPrefix("conversation")
            || demoID == "attention-request"
            || demoID == "permission"
            || MobileDemoScene.terminalFixtureIDs.contains(demoID) {
            return RemoteThemePalette(demoConversation.theme ?? model.me?.theme)
        }
#endif
        return RemoteThemePalette(model.appTheme)
    }

    private func openShakeReport(screenshot: UIImage?) {
        MobileDiagnostics.record(.issueReportOpened, fields: [
            .reason: "shake",
            .surface: screenshot == nil ? "none" : "screenshot",
        ])
        issueReportRequest = MobileIssueReportRequest(
            trigger: .shake,
            screenshot: screenshot,
            screenshotWasRequested: true
        )
    }

    private func openConnectionRecoveryReport() {
        let trigger = MobileIssueReportTrigger.connectionRecovery
        MobileDiagnostics.record(.issueReportOpened, fields: [
            .reason: trigger.rawValue,
            .surface: "none",
        ])
        issueReportRequest = MobileIssueReportRequest(
            trigger: trigger,
            screenshot: nil,
            screenshotWasRequested: false
        )
    }

#if DEBUG
    private static let workspaceDemoSession = RemoteSessionSummaryDTO(
        id: "workspace-demo",
        title: "Remote access review",
        agentKind: "codex",
        surface: .conversation,
        state: .idle,
        projectName: "Threading"
    )

    private static let workspaceDemoClient = RemoteClient(link: RemoteConnectionLink(
        baseURL: URL(string: "https://workspace.invalid")!,
        token: "workspace-demo"
    )!)

    private static let workspaceDemoSnapshot = RemoteWorkspaceDTO(
        browserTabs: [
            RemoteBrowserTabDTO(
                id: "browser-release",
                title: "Release checklist",
                displayURL: "developer.apple.com/…/distributing-your-app",
                isActive: true,
                isPrivate: false,
                canPreview: true
            ),
            RemoteBrowserTabDTO(
                id: "browser-private",
                title: "",
                displayURL: nil,
                isActive: false,
                isPrivate: true,
                canPreview: false
            ),
        ],
        latestActivityID: "workspace-demo-browser"
    )

    private static let browserDemoSnapshot = RemoteWorkspaceDTO(
        browserTabs: [
            RemoteBrowserTabDTO(
                id: "browser-private",
                title: "",
                displayURL: nil,
                isActive: true,
                isPrivate: true,
                canPreview: false
            ),
            RemoteBrowserTabDTO(
                id: "browser-release",
                title: "Release checklist",
                displayURL: "developer.apple.com/…/distributing-your-app",
                isActive: false,
                isPrivate: false,
                canPreview: true
            ),
        ],
        latestActivityID: "browser-private-demo"
    )

    private static let attachmentDemoItems = [
        RemoteAttachmentDTO(
            path: "artifacts/threading-ui-review.pdf",
            name: "threading-ui-review.pdf",
            kind: .pdf,
            byteCount: 842_761,
            origin: .agent,
            id: "attachment-review"
        ),
        RemoteAttachmentDTO(
            path: "screenshots/keyboard-dismissed.png",
            name: "keyboard-dismissed.png",
            kind: .image,
            byteCount: 184_320,
            origin: .user,
            id: "attachment-keyboard"
        ),
        RemoteAttachmentDTO(
            path: "reports/ui-evidence.html",
            name: "ui-evidence.html",
            kind: .html,
            byteCount: 32_914,
            origin: .agent,
            id: "attachment-report"
        ),
        RemoteAttachmentDTO(
            path: "exports/diagnostics.zip",
            name: "diagnostics.zip",
            kind: .archive,
            byteCount: 1_204_981,
            origin: .user,
            id: "attachment-diagnostics"
        ),
    ]

    @MainActor
    private func openIssueReportDemoIfNeeded() async {
        let mode = ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
        guard mode == "report" || mode == "report-screenshot" else {
            return
        }
        try? await Task.sleep(for: .milliseconds(650))
        switch mode {
        case "report":
            issueReportRequest = MobileIssueReportRequest(
                trigger: .diagnostics,
                screenshot: nil,
                screenshotWasRequested: false
            )
        case "report-screenshot":
            let screenshot = MobileScreenCapture.currentScreen()
            issueReportRequest = MobileIssueReportRequest(
                trigger: .shake,
                screenshot: screenshot,
                screenshotWasRequested: true
            )
        default:
            break
        }
    }
#endif

    private var standardRoot: some View {
        NavigationStack(path: $model.navigationPath) {
            Group {
                if model.hosts.isEmpty {
                    WelcomeView(openSettings: { showsSettings = true })
                } else {
                    SessionDashboard(
                        openSettings: { showsSettings = true },
                        reportConnectionIssue: openConnectionRecoveryReport
                    )
                }
            }
            .navigationDestination(for: MobileNavigationRoute.self) { route in
                switch route {
                case .project(let projectName):
                    SessionDashboard(
                        projectName: projectName,
                        openSettings: { showsSettings = true },
                        reportConnectionIssue: openConnectionRecoveryReport
                    )
                case .session(let sessionID):
                    if let session = model.me?.sessions.first(where: { $0.id == sessionID }) {
                        SessionDetailView(session: session)
                    } else {
                        ContentUnavailableView(
                            "Session unavailable",
                            systemImage: "bubble.left.and.exclamationmark.bubble.right",
                            description: Text("The link may have expired or the Mac may be offline.")
                        )
                    }
                case .terminal(let terminalID):
                    if let terminal = model.me?.terminals?.first(where: { $0.id == terminalID }) {
                        ProjectTerminalDetailView(terminal: terminal)
                    } else {
                        ContentUnavailableView(
                            "Terminal unavailable",
                            systemImage: "terminal",
                            description: Text("The link may have expired or the Mac may be offline.")
                        )
                    }
                case .draft(let draft):
                    SessionDraftView(draft: draft)
                }
            }
        }
        .sheet(isPresented: $model.isPairing) {
            PairingView()
                .environmentObject(model)
                .mobileTheme(theme)
        }
        .sheet(isPresented: $showsSettings) {
            MobileSettingsView()
                .mobileTheme(theme)
        }
    }
}

/// Paints the application ground independently of whichever screen navigation is laying out.
///
/// A focused destination is keyboard-sized during an interactive pop. Attaching its background
/// to that destination therefore leaves the hosting window visible below it while the screen is
/// sliding away. The sibling layer stays window-sized while navigation and the keyboard animate.
struct MobileRootBackdrop<Content: View>: View {
    let ground: Color
    let content: Content

    init(ground: Color, @ViewBuilder content: () -> Content) {
        self.ground = ground
        self.content = content()
    }

    var body: some View {
        ZStack {
            ground.ignoresSafeArea()
            content
        }
    }
}

#if DEBUG
/// The draft as it is actually met: pushed from a list, so the bar has a back button on one
/// side of the title and the account disc on the other.
private struct SessionDraftDemoHost: View {
    @Environment(\.remoteTheme) private var theme
    @State private var path: [MobileNavigationRoute] = [.draft(MobileSessionDraft())]

    var body: some View {
        NavigationStack(path: $path) {
            theme.ground
                .ignoresSafeArea()
                .navigationDestination(for: MobileNavigationRoute.self) { route in
                    if case .draft(let draft) = route {
                        SessionDraftView(draft: draft)
                    }
                }
        }
    }
}

/// The link-ready sheet as it is actually met: presented over the screen that made it.
///
/// Held as a bare root it filled the display, which is the one shape the real surface never
/// takes — and the shape it does take, a detent that stops part way up the screen, is what
/// clipped its closing line for the whole of its life. A fixture that cannot show that defect
/// cannot show the fix either.
private struct SharedSessionLinkDemoHost: View {
    @Environment(\.remoteTheme) private var theme
    @State private var isPresented = false

    let link: SharedSessionLink

    var body: some View {
        theme.ground
            .ignoresSafeArea()
            .sheet(isPresented: $isPresented) {
                SharedSessionLinkView(link: link)
                    .mobileTheme(theme)
            }
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                isPresented = true
            }
    }
}

/// Share Chat as it is actually met, at whichever stage the fixture asks for.
///
/// The link stage is reached by *choosing a grant*, not by seeding the sheet with one, so the
/// photograph proves the transition the owner asked for rather than the destination alone. The
/// flow is held here rather than inside `ShareChatSheet`, which is what lets the fixture reach
/// in and make that choice.
private struct ShareChatDemoHost: View {
    private enum Timing {
        static let beforePresenting = 250
        static let beforeChoosing = 400
    }

    @Environment(\.remoteTheme) private var theme
    @StateObject private var flow: ShareChatFlow
    @State private var isPresented = false

    private let choice: ShareChatRole?

    init(isChatRunning: Bool, choice: ShareChatRole?) {
        _flow = StateObject(wrappedValue: ShareChatDemo.flow(isChatRunning: isChatRunning))
        self.choice = choice
    }

    var body: some View {
        theme.ground
            .ignoresSafeArea()
            .sheet(isPresented: $isPresented) {
                ShareChatSheetContent(flow: flow)
                    .mobileTheme(theme)
            }
            .task {
                try? await Task.sleep(for: .milliseconds(Timing.beforePresenting))
                isPresented = true
                guard let choice else { return }
                try? await Task.sleep(for: .milliseconds(Timing.beforeChoosing))
                await flow.choose(choice)
            }
    }
}
#endif

private struct WelcomeView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @State private var selectedFeatureID: String?
    let openSettings: () -> Void

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
#if DEBUG
        let demo = ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
        let requestedID = demo?.hasPrefix("welcome-") == true
            ? String(demo!.dropFirst("welcome-".count))
            : nil
        _selectedFeatureID = State(
            initialValue: WelcomeFeature.items.contains(where: { $0.id == requestedID })
                ? requestedID
                : WelcomeFeature.items.first?.id
        )
#else
        _selectedFeatureID = State(initialValue: WelcomeFeature.items.first?.id)
#endif
    }

    var body: some View {
        ZStack {
            theme.ground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: MobileDesign.Spacing.pane) {
                    VStack(spacing: MobileDesign.Spacing.medium) {
                        WelcomeBrandMark()

                        Text("Threading")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                    }

                    VStack(spacing: MobileDesign.Spacing.small) {
                        Text("Pair your own Mac, or open a chat someone shared with you.")
                            .font(.body)
                            .foregroundStyle(theme.secondaryLabel)
                            .multilineTextAlignment(.center)
                    }

                    GeometryReader { geometry in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: MobileDesign.Spacing.medium) {
                                ForEach(WelcomeFeature.items) { feature in
                                    WelcomeFeatureCard(
                                        feature: feature,
                                        isFocused: feature.id == selectedFeatureID
                                    )
                                    .frame(width: geometry.size.width)
                                    .id(feature.id)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .scrollPosition(id: $selectedFeatureID)
                    }
                    .frame(height: 132)

                    HStack(spacing: MobileDesign.Spacing.small) {
                        ForEach(WelcomeFeature.items) { feature in
                            Circle()
                                .fill(feature.id == selectedFeatureID
                                    ? theme.accent
                                    : theme.tertiaryLabel.opacity(0.55))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, MobileDesign.Spacing.pane)
                .padding(.top, MobileDesign.Spacing.pane)
                .padding(.bottom, MobileDesign.Spacing.large)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: MobileDesign.Spacing.small) {
                    Button {
                        model.isPairing = true
                    } label: {
                        Label("Add a connection", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(theme.accent, in: Capsule())
                            .foregroundStyle(theme.ground)
                    }
                    .buttonStyle(.plain)

                    // The door for someone with no Mac in reach — including App Review, which
                    // runs this app with nothing to pair (releasing.md, "Releasing beside the
                    // iOS companion"). Everything inside is canned; the pipeline is real.
                    Button {
                        model.startDemo()
                    } label: {
                        Label("Try the demo", systemImage: "sparkles")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: MobileDesign.Size.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryLabel)

                    Button(action: openSettings) {
                        Label("Settings", systemImage: "gearshape")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: MobileDesign.Size.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryLabel)
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, MobileDesign.Spacing.pane)
                .padding(.top, MobileDesign.Spacing.inset)
                .padding(.bottom, MobileDesign.Spacing.small)
                .background(.ultraThinMaterial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct WelcomeBrandMark: View {
    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseIsBright = false

    var body: some View {
        ZStack {
            Image("ThreadingMark")
                .resizable()
                .scaledToFit()

            // The mark's centre is part of the raster asset, so pulse a masked radial light
            // rather than fading the whole logo. Evidence capture freezes the bright phase;
            // production breathes gently and honours Reduce Motion.
            RadialGradient(
                colors: [Color.white.opacity(0.95), Color.white.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: 30
            )
            .opacity(pulseIsBright ? 0.58 : 0.16)
            .blendMode(.screen)
            .mask {
                Image("ThreadingMark")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 88, height: 88)
        .padding(MobileDesign.Spacing.inset)
        .background(
            theme.panel,
            in: RoundedRectangle(cornerRadius: theme.panelRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.panelRadius)
                .strokeBorder(theme.border, lineWidth: theme.borderWidth)
        }
        .remoteThemeGlow(theme)
        .onAppear {
            guard !reduceMotion, !isCapturingEvidence else {
                pulseIsBright = true
                return
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulseIsBright = true
            }
        }
    }

    private var isCapturingEvidence: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"] != nil
#else
        false
#endif
    }
}

@MainActor
private struct WelcomeFeature: Identifiable {
    let id: String
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    static let items = [
        WelcomeFeature(
            id: "collaborate",
            symbol: "person.2.wave.2",
            title: "Work together",
            detail: "Follow the same session, request input, and keep each device’s draft separate."
        ),
        WelcomeFeature(
            id: "browser",
            symbol: "safari",
            title: "Follow the browser",
            detail: "See the active Mac tab when it is shareable, without moving private tabs off the Mac."
        ),
        WelcomeFeature(
            id: "usage",
            symbol: "chart.bar.xaxis",
            title: "Track usage",
            detail: "Review provider cost, tokens, limits, and reset history while work is running."
        ),
        WelcomeFeature(
            id: "terminal",
            symbol: "terminal",
            title: "Use the real terminal",
            detail: "Resume the agent’s own TUI with colors, scrollback, and mobile terminal keys intact."
        ),
        WelcomeFeature(
            id: "shared",
            symbol: "bubble.left.and.bubble.right",
            title: "Open shared chats",
            detail: "Join one invited conversation without granting access to the rest of the Mac."
        ),
    ]
}

private struct WelcomeFeatureCard: View {
    @Environment(\.remoteTheme) private var theme
    let feature: WelcomeFeature
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
            Image(systemName: feature.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 42, height: 42)
                .background(theme.accentMuted, in: RoundedRectangle(cornerRadius: theme.controlRadius))

            VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                Text(feature.title)
                    .font(.headline)
                    .foregroundStyle(theme.label)
                Text(feature.detail)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(MobileDesign.Spacing.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.controlRadius)
                .strokeBorder(
                    isFocused ? theme.accent.opacity(0.72) : theme.border,
                    lineWidth: max(theme.borderWidth, isFocused ? 1 : 0)
                )
        }
        .scaleEffect(isFocused ? 1 : 0.96)
        .opacity(isFocused ? 1 : 0.72)
        .animation(.easeInOut(duration: MobileDesign.Motion.controlResponse), value: isFocused)
        .accessibilityElement(children: .combine)
    }
}
