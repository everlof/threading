import ThreadingRemoteKit
import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @State private var showsShakeReportOptions = false
    @State private var issueReportRequest: MobileIssueReportRequest?
    @State private var isCapturingReportScreen = false
#if DEBUG
    @StateObject private var demoConversation = RemoteSessionConnection.demoConversation()
    @StateObject private var demoPermission = RemoteSessionConnection.demoPermissionConversation()
    @StateObject private var workspaceDemoActivity = MobileWorkspaceActivity(
        sessionID: "workspace-demo"
    )
#endif

    var body: some View {
        Group {
#if DEBUG
            if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
                .hasPrefix("conversation") == true {
                NavigationStack {
                    ConversationRemoteView(connection: demoConversation)
                        .navigationTitle(demoConversation.title)
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "pairing" {
                PairingView()
                    .environmentObject(model)
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
#endif
    }

    private var theme: RemoteThemePalette {
#if DEBUG
        if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
            .hasPrefix("conversation") == true
            || ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "permission" {
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
                    WelcomeView()
                } else {
                    SessionDashboard()
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
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Your code, within reach")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Pair your own Mac, or open a chat someone shared with you.")
                    .font(.body)
                    .foregroundStyle(theme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
            }

            Button {
                model.isPairing = true
            } label: {
                Label("Add a connection", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(theme.accent, in: Capsule())
                    .foregroundStyle(theme.ground)
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle("Code")
        .navigationBarTitleDisplayMode(.inline)
        .background(theme.ground)
    }
}
