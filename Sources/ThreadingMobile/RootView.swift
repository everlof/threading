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
#endif

    var body: some View {
        Group {
#if DEBUG
            if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                == "terminal-collaboration" {
                NavigationStack {
                    TerminalRemoteView(connection: demoTerminal)
                        .navigationTitle(demoTerminal.title)
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                == "attention-request" {
                AttentionRequestSheet(connection: demoConversation)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
                .hasPrefix("conversation") == true {
                NavigationStack {
                    ConversationRemoteView(connection: demoConversation)
                        .navigationTitle(demoConversation.title)
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "pairing" {
                PairingView()
                    .environmentObject(model)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "welcome" {
                NavigationStack {
                    WelcomeView(openSettings: { showsSettings = true })
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "settings" {
                MobileSettingsView()
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
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "permission" {
                NavigationStack {
                    ConversationRemoteView(connection: demoPermission)
                        .navigationTitle(demoPermission.title)
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "new-session" {
                NewRemoteSessionView()
                    .environmentObject(model)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "themed-dialog-alert" {
                ThemedDialogDemoView(kind: .alert)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                        == "themed-dialog-confirmation" {
                ThemedDialogDemoView(kind: .confirmation)
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "review",
                      let session = model.me?.sessions.first,
                      let client = model.client {
                NavigationStack {
                    RemoteGitReviewView(session: session, client: client)
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
        .environment(\.remoteTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.accent)
        .toggleStyle(MobileThemedToggleStyle(theme: theme))
        .foregroundStyle(theme.label)
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
                    model.navigationPath = [first.id]
                }
            case "terminal":
                model.startDemo()
                if let terminal = model.me?.sessions.first(where: { $0.surface == "terminal" }) {
                    model.navigationPath = [terminal.id]
                }
            default:
                break
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
        if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
            .hasPrefix("conversation") == true
            || ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                == "attention-request"
            || ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "permission"
            || ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                == "terminal-collaboration" {
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

#if DEBUG
    private static let workspaceDemoSession = RemoteSessionSummaryDTO(
        id: "workspace-demo",
        title: "Remote access review",
        agentKind: "codex",
        surface: "conversation",
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
                id: UUID().uuidString,
                title: "Release checklist",
                displayURL: "developer.apple.com/…/distributing-your-app",
                isActive: true,
                isPrivate: false,
                canPreview: true
            ),
            RemoteBrowserTabDTO(
                id: UUID().uuidString,
                title: "",
                displayURL: nil,
                isActive: false,
                isPrivate: true,
                canPreview: false
            ),
        ],
        latestActivityID: "workspace-demo-browser"
    )

    @MainActor
    private func openIssueReportDemoIfNeeded() async {
        let mode = ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
        guard mode == "report-preflight"
                || mode == "report"
                || mode == "report-screenshot" else {
            return
        }
        try? await Task.sleep(for: .milliseconds(650))
        switch mode {
        case "report-preflight":
            showsShakeReportOptions = true
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
                    SessionDashboard(openSettings: { showsSettings = true })
                }
            }
            .navigationDestination(for: String.self) { sessionID in
                if let session = model.me?.sessions.first(where: { $0.id == sessionID }) {
                    SessionDetailView(session: session)
                } else {
                    ContentUnavailableView(
                        "Session unavailable",
                        systemImage: "bubble.left.and.exclamationmark.bubble.right",
                        description: Text("The link may have expired or the Mac may be offline.")
                    )
                }
            }
        }
        .sheet(isPresented: $model.isPairing) {
            PairingView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showsSettings) {
            MobileSettingsView()
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    let openSettings: () -> Void

    var body: some View {
        ZStack {
            theme.ground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: MobileDesign.Spacing.pane) {
                    Image("ThreadingMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .padding(MobileDesign.Spacing.inset)
                        .background(
                            theme.panel,
                            in: RoundedRectangle(cornerRadius: theme.panelRadius)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.panelRadius)
                                .stroke(theme.border, lineWidth: theme.borderWidth)
                        }
                        .remoteThemeGlow(theme)

                    VStack(spacing: MobileDesign.Spacing.small) {
                        Text("Your code, within reach")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                        Text("Pair your own Mac, or open a chat someone shared with you.")
                            .font(.body)
                            .foregroundStyle(theme.secondaryLabel)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: MobileDesign.Spacing.small) {
                        WelcomeCapability(symbol: "bubble.left.and.bubble.right", title: "Chats")
                        WelcomeCapability(symbol: "terminal", title: "Terminal")
                        WelcomeCapability(symbol: "person.2", title: "Shared")
                    }
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, MobileDesign.Spacing.pane)
                .padding(.top, 54)
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
        .navigationTitle("Threading")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct WelcomeCapability: View {
    @Environment(\.remoteTheme) private var theme
    let symbol: String
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.small) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.accent)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 74)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.controlRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        }
    }
}
