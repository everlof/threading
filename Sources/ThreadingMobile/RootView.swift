import ThreadingRemoteKit
import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @State private var showsShakeReportOptions = false
    @State private var issueReportRequest: MobileIssueReportRequest?
    @State private var isCapturingReportScreen = false
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
#endif

    var body: some View {
        Group {
#if DEBUG
            if Self.terminalDemoModes.contains(
                ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] ?? ""
            ) {
                NavigationStack {
                    TerminalRemoteView(connection: demoTerminal)
                        .navigationTitle(demoTerminalName)
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                == "attention-request" {
                AttentionRequestSheet(connection: demoConversation)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
                .hasPrefix("conversation") == true {
                NavigationStack {
                    ConversationRemoteView(connection: demoConversation)
                        .navigationTitle(demoConversationName)
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "pairing" {
                PairingView()
                    .environmentObject(model)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
                        .hasPrefix("welcome") == true {
                NavigationStack {
                    WelcomeView(openSettings: { showsSettings = true })
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "settings" {
                MobileSettingsView()
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "connection-progress-lab" {
                NavigationStack {
                    MobileConnectionProgressLab()
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "app-icon-settings" {
                NavigationStack {
                    MobileAppIconSettingsView()
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "collaboration-settings" {
                NavigationStack {
                    CollaborationSettingsView()
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "advanced-connection-settings" {
                NavigationStack {
                    AdvancedConnectionSettingsView(pool: .evidenceFixture())
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "debug-bridge-settings" {
                NavigationStack {
                    MobileDebugBridgeView()
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "notification-settings" {
                NotificationSettingsView()
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "terminal-key-settings" {
                NavigationStack {
                    TerminalKeyboardAgentList()
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "terminal-key-editor" {
                NavigationStack {
                    TerminalKeyboardEditorContent(agentKind: "claude")
                        .navigationTitle("Claude Code")
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "terminal-key-catalog" {
                NavigationStack {
                    TerminalKeyboardEditorDemo(screen: .catalog)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "terminal-key-snippet" {
                NavigationStack {
                    TerminalKeyboardEditorDemo(screen: .snippet)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "terminal-key-edit" {
                NavigationStack {
                    TerminalKeyboardEditorDemo(screen: .edit)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "mac-appearance-settings" {
                NavigationStack {
                    MacAppearanceSettingsView()
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "diagnostics" {
                RemoteDiagnosticsView()
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "shared-link" {
                SharedSessionLinkDemoHost(link: ShareChatDemo.link)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "share-chat-roles" {
                ShareChatDemoHost(isChatRunning: true, choice: nil)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "share-chat-blocked" {
                ShareChatDemoHost(isChatRunning: false, choice: nil)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "share-chat-link" {
                ShareChatDemoHost(isChatRunning: true, choice: .collaborateAndApprove)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "session-settings",
                      let session = model.me?.sessions.first {
                MobileSessionSettingsView(sessionID: session.id, onAccountMoved: {})
                    .environmentObject(model)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
                        .hasPrefix("permission") == true {
                NavigationStack {
                    ConversationRemoteView(connection: demoPermission)
                        .navigationTitle(demoPermissionName)
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
                        .hasPrefix("new-session") == true {
                NewRemoteSessionView()
                    .environmentObject(model)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "themed-dialog-alert" {
                ThemedDialogDemoView(kind: .alert)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "themed-dialog-confirmation" {
                ThemedDialogDemoView(kind: .confirmation)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
                        .hasPrefix("review") == true {
                NavigationStack {
                    RemoteGitReviewView(
                        session: model.me?.sessions.first ?? Self.workspaceDemoSession,
                        client: model.client ?? Self.workspaceDemoClient,
                        initialSection:
                            ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
                                .contains("files") == true ? .allFiles : .changed
                    )
                }
            } else if let openingFixture = MobileSessionOpeningFixture.current {
                NavigationStack {
                    SessionDetailView(session: openingFixture.session)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "browser-private" {
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
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "attachments" {
                NavigationStack {
                    RemoteAttachmentsView(
                        session: Self.workspaceDemoSession,
                        client: Self.workspaceDemoClient,
                        initialAttachments: Self.attachmentDemoItems,
                        loadsRemotely: false
                    )
                }
            } else if let attachmentDemo = ProcessInfo.processInfo.environment[
                "THREADING_MOBILE_DEMO"
            ], attachmentDemo.hasPrefix("attachment-detail-") {
                let attachmentKind = String(
                    attachmentDemo.dropFirst("attachment-detail-".count)
                )
                NavigationStack {
                    RemoteAttachmentPreviewDemo(kind: attachmentKind)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "workspace" {
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
            } else {
                standardRoot
            }
#else
            standardRoot
#endif
        }
        .mobileTheme(theme)
        .background(theme.ground.ignoresSafeArea())
        .background {
            ShakeGestureDetector {
                guard issueReportRequest == nil, !isCapturingReportScreen else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                showsShakeReportOptions = true
            }
            .frame(width: 0, height: 0)
        }
        .themedConfirmationDialog(
            "Report a problem?",
            message:
                "A screenshot can help explain visual problems, but it may contain code or "
                + "chat content. You can preview and remove it before sharing.",
            isPresented: $showsShakeReportOptions,
            actions: [
                ThemedDialogAction(
                    "Continue without screenshot",
                    systemImage: "doc.text"
                ) {
                    openShakeReport(screenshot: nil, requested: false)
                },
                ThemedDialogAction(
                    "Include current screen",
                    systemImage: "rectangle.dashed.badge.record"
                ) {
                    isCapturingReportScreen = true
                    Task { @MainActor in
                        // Let the confirmation dialog disappear before taking the opted-in image.
                        try? await Task.sleep(for: .milliseconds(300))
                        let screenshot = MobileScreenCapture.currentScreen()
                        isCapturingReportScreen = false
                        openShakeReport(screenshot: screenshot, requested: true)
                    }
                },
                ThemedDialogAction("Cancel", role: .cancel),
            ]
        )
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
            if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                == "project-sessions",
               model.navigationPath.isEmpty,
               let projectName = model.me?.sessions.first?.projectName {
                model.navigationPath = [.project(projectName)]
            }
        }
#endif
    }

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
        if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
            .hasPrefix("conversation") == true
            || ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                == "attention-request"
            || ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "permission"
            || Self.terminalDemoModes.contains(
                ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] ?? ""
            ) {
            return RemoteThemePalette(demoConversation.theme ?? model.me?.theme)
        }
#endif
        return RemoteThemePalette(model.me?.theme)
    }

    private func openShakeReport(screenshot: UIImage?, requested: Bool) {
        MobileDiagnostics.record(.issueReportOpened, fields: [
            .reason: "shake",
            .surface: screenshot == nil ? "none" : "screenshot",
        ])
        issueReportRequest = MobileIssueReportRequest(
            trigger: .shake,
            screenshot: screenshot,
            screenshotWasRequested: requested
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
    private static let terminalDemoModes: Set<String> = [
        "terminal-collaboration",
        "terminal-ansi",
        "terminal-scrollback",
        "terminal-attachments",
        "terminal-selection",
        "terminal-codex-tui",
        "terminal-claude-tui",
    ]

    private static let workspaceDemoSession = RemoteSessionSummaryDTO(
        id: "workspace-demo",
        title: "Remote access review",
        agentKind: "codex",
        surface: .conversation,
        state: "idle",
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
            kind: "pdf",
            byteCount: 842_761,
            origin: "agent",
            id: "attachment-review"
        ),
        RemoteAttachmentDTO(
            path: "screenshots/keyboard-dismissed.png",
            name: "keyboard-dismissed.png",
            kind: "image",
            byteCount: 184_320,
            origin: "user",
            id: "attachment-keyboard"
        ),
        RemoteAttachmentDTO(
            path: "reports/ui-evidence.html",
            name: "ui-evidence.html",
            kind: "html",
            byteCount: 32_914,
            origin: "agent",
            id: "attachment-report"
        ),
        RemoteAttachmentDTO(
            path: "exports/diagnostics.zip",
            name: "diagnostics.zip",
            kind: "archive",
            byteCount: 1_204_981,
            origin: "user",
            id: "attachment-diagnostics"
        ),
    ]

    @MainActor
    private func openIssueReportDemoIfNeeded() async {
        let mode = ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
        guard mode == "report-preflight"
                || mode == "report"
                || mode == "report-receipt"
                || mode == "report-screenshot" else {
            return
        }
        try? await Task.sleep(for: .milliseconds(650))
        switch mode {
        case "report-preflight":
            showsShakeReportOptions = true
        case "report", "report-receipt":
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

#if DEBUG
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
        let demo = ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
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
