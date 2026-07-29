import SkalmanRemoteKit
import SwiftUI
import UIKit
import UserNotifications

enum RemoteNotificationBridge {
    static let eventNotification = Notification.Name("SkalmanRemoteNotificationEvent")
    static let openedNotification = Notification.Name("SkalmanRemoteNotificationOpened")
    static let deviceTokenNotification = Notification.Name("SkalmanRemotePushToken")

    static func received(_ event: RemoteNotificationEventDTO, connectionID: String) {
        NotificationCenter.default.post(
            name: eventNotification,
            object: event,
            userInfo: ["connectionID": connectionID]
        )
    }

    static func opened(_ event: RemoteNotificationEventDTO) {
        NotificationCenter.default.post(name: openedNotification, object: event)
    }
}

final class SkalmanMobileAppDelegate: NSObject, UIApplicationDelegate,
    UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        MobileDiagnostics.record(.appLaunched, fields: [
            .protocolVersion: String(RemoteProtocol.current),
            .minimumProtocolVersion: String(RemoteProtocol.minimumSupported),
        ])
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "SKALMAN_PERMISSION",
                actions: [],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
            UNNotificationCategory(
                identifier: "SKALMAN_SESSION",
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
        ])
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
#if DEBUG
        let pushEnvironment = "sandbox"
#else
        let pushEnvironment = "production"
#endif
        MobileDiagnostics.record(.apnsRegistrationSucceeded, fields: [
            .environment: pushEnvironment
        ])
        NotificationCenter.default.post(
            name: RemoteNotificationBridge.deviceTokenNotification,
            object: token
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        MobileDiagnostics.record(
            .apnsRegistrationFailed,
            level: .error,
            fields: [.code: MobileDiagnostics.errorCode(error)]
        )
        NotificationCenter.default.post(
            name: RemoteNotificationBridge.deviceTokenNotification,
            object: ""
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if let event = Self.event(from: notification.request.content.userInfo) {
            MobileDiagnostics.record(.notificationReceived, fields: [
                .trace: event.id,
                .kind: event.kind.rawValue,
                .transport: "apns",
            ])
        }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let event = Self.event(from: response.notification.request.content.userInfo) else {
            return
        }
        MobileDiagnostics.record(.notificationOpened, fields: [
            .trace: event.id,
            .kind: event.kind.rawValue,
            .transport: "apns",
        ])
        RemoteNotificationBridge.opened(event)
    }

    private static func event(from userInfo: [AnyHashable: Any]) -> RemoteNotificationEventDTO? {
        let source: Any
        if let nested = userInfo["event"] {
            source = nested
        } else {
            source = userInfo
        }
        guard JSONSerialization.isValidJSONObject(source),
              let data = try? JSONSerialization.data(withJSONObject: source) else {
            return nil
        }
        return try? JSONDecoder().decode(RemoteNotificationEventDTO.self, from: data)
    }
}

@MainActor
final class RemoteNotificationManager: ObservableObject {

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var deviceToken: String?
    @Published private(set) var deliveryByConnection: [String: String] = [:]
    @Published var scenePhase: ScenePhase = .active

    @Published var sharedChatsEnabled: Bool {
        didSet { defaults.set(sharedChatsEnabled, forKey: Keys.sharedChats) }
    }
    @Published var permissionsEnabled: Bool {
        didSet { defaults.set(permissionsEnabled, forKey: Keys.permissions) }
    }
    @Published var agentUpdatesEnabled: Bool {
        didSet { defaults.set(agentUpdatesEnabled, forKey: Keys.agentUpdates) }
    }

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private var observers: [NSObjectProtocol] = []
    private var registeredSignatures: Set<String> = []
    private var deliveredEventIDs: [String] = []

    private enum Keys {
        static let onboardingDeferred = "remoteNotificationsOnboardingDeferred"
        static let sharedChats = "remoteNotificationsSharedChats"
        static let permissions = "remoteNotificationsPermissions"
        static let agentUpdates = "remoteNotificationsAgentUpdates"
    }

    init() {
        defaults.register(defaults: [
            Keys.sharedChats: true,
            Keys.permissions: true,
            Keys.agentUpdates: true,
        ])
        sharedChatsEnabled = defaults.bool(forKey: Keys.sharedChats)
        permissionsEnabled = defaults.bool(forKey: Keys.permissions)
        agentUpdatesEnabled = defaults.bool(forKey: Keys.agentUpdates)

        observers.append(NotificationCenter.default.addObserver(
            forName: RemoteNotificationBridge.deviceTokenNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                let token = (note.object as? String)?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                self?.deviceToken = token?.isEmpty == false ? token : nil
                self?.registeredSignatures.removeAll()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: RemoteNotificationBridge.eventNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.object as? RemoteNotificationEventDTO else { return }
            let connectionID = note.userInfo?["connectionID"] as? String
            Task { @MainActor in
                self?.receiveLive(event, connectionID: connectionID)
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var shouldOfferOnboarding: Bool {
        authorizationStatus == .notDetermined
            && !defaults.bool(forKey: Keys.onboardingDeferred)
    }

    var enabledKinds: [RemoteNotificationKind] {
        var result: [RemoteNotificationKind] = []
        if sharedChatsEnabled { result.append(.sharedSession) }
        if permissionsEnabled { result.append(.permissionRequest) }
        if agentUpdatesEnabled { result.append(.agentMessage) }
        return result
    }

    var hasLiveOnlyConnections: Bool {
        deliveryByConnection.values.contains("live")
    }

    func prepare() async {
        await refreshAuthorization()
        if isAuthorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func refreshAuthorization() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
        MobileDiagnostics.record(.notificationAuthorization, fields: [
            .status: String(authorizationStatus.rawValue)
        ])
    }

    func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            // The settings refresh below produces the durable state and recovery UI.
        }
        await refreshAuthorization()
        if isAuthorized {
            defaults.set(false, forKey: Keys.onboardingDeferred)
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func deferOnboarding() {
        defaults.set(true, forKey: Keys.onboardingDeferred)
        objectWillChange.send()
    }

    func sync(hosts: [PairedRemoteHost]) async {
        guard isAuthorized else {
            MobileDiagnostics.record(
                .notificationRegistrationFailed,
                level: .warning,
                fields: [.reason: "authorization"]
            )
            return
        }
        guard let deviceToken else {
            MobileDiagnostics.record(
                .notificationRegistrationFailed,
                level: .warning,
                fields: [.reason: "deviceToken"]
            )
            return
        }
        let kinds = enabledKinds
        for host in hosts {
            let signature = [
                host.id,
                deviceToken,
                kinds.map(\.rawValue).sorted().joined(separator: ","),
                host.link.token,
            ].joined(separator: ":")
            guard !registeredSignatures.contains(signature) else { continue }
            let peer = MobileDiagnostics.pseudonym(host.id, prefix: "peer")
            MobileDiagnostics.record(.notificationRegistrationStarted, fields: [
                .peer: peer,
                .enabledKindCount: String(kinds.count),
            ])

#if DEBUG
            let pushEnvironment = "sandbox"
#else
            let pushEnvironment = "production"
#endif
            let registration = RemoteNotificationRegistrationDTO(
                deviceToken: deviceToken,
                environment: pushEnvironment,
                enabledKinds: kinds
            )
            do {
                let result = try await RemoteClient(link: host.link)
                    .registerNotifications(registration)
                deliveryByConnection[host.id] = result.delivery
                registeredSignatures.insert(signature)
                MobileDiagnostics.record(.notificationRegistrationSucceeded, fields: [
                    .peer: peer,
                    .transport: result.delivery,
                    .environment: pushEnvironment,
                ])
            } catch {
                MobileDiagnostics.record(
                    .notificationRegistrationFailed,
                    level: .error,
                    fields: [
                        .peer: peer,
                        .code: MobileDiagnostics.errorCode(error),
                    ]
                )
                // The ordinary refresh will retry once the Mac/relay is reachable again.
            }
        }
    }

    func settingsChanged(hosts: [PairedRemoteHost]) {
        registeredSignatures.removeAll()
        Task { await sync(hosts: hosts) }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    private func receiveLive(
        _ event: RemoteNotificationEventDTO,
        connectionID: String?
    ) {
        MobileDiagnostics.record(.notificationReceived, fields: [
            .trace: event.id,
            .kind: event.kind.rawValue,
            .transport: "live",
        ])
        guard isEnabled(event.kind) else {
            MobileDiagnostics.record(.notificationSuppressed, fields: [
                .trace: event.id,
                .reason: "preference",
            ])
            return
        }
        guard !deliveredEventIDs.contains(event.id) else {
            MobileDiagnostics.record(.notificationSuppressed, fields: [
                .trace: event.id,
                .reason: "duplicate",
            ])
            return
        }
        remember(event.id)

        // APNs owns system presentation once the Mac reports push delivery. Scheduling the live
        // mirror too would produce two banners for one permission request.
        if let connectionID, deliveryByConnection[connectionID] == "push" {
            MobileDiagnostics.record(.notificationSuppressed, fields: [
                .trace: event.id,
                .reason: "apnsOwnsPresentation",
            ])
            return
        }
        // While the app is visible, the session's own card/dot is the better cue.
        guard scenePhase != .active else {
            MobileDiagnostics.record(.notificationSuppressed, fields: [
                .trace: event.id,
                .reason: "foreground",
            ])
            return
        }

        let content = UNMutableNotificationContent()
        content.title = localizedText(event.titleLocalization, fallback: event.title)
        content.body = localizedText(event.bodyLocalization, fallback: event.body)
        content.sound = .default
        content.threadIdentifier = event.sessionID
        content.categoryIdentifier = event.kind == .permissionRequest
            ? "SKALMAN_PERMISSION"
            : "SKALMAN_SESSION"
        if let data = try? JSONEncoder().encode(event),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            content.userInfo = object
        }
        center.add(UNNotificationRequest(
            identifier: event.id,
            content: content,
            trigger: nil
        ))
        MobileDiagnostics.record(.notificationPresented, fields: [
            .trace: event.id,
            .transport: "live",
        ])
    }

    private func localizedText(
        _ localization: RemoteLocalizedTextDTO?,
        fallback: String
    ) -> String {
        guard let localization else { return fallback }
        return MobileL10n.string(localization.key, arguments: localization.arguments)
    }

    private func isEnabled(_ kind: RemoteNotificationKind) -> Bool {
        switch kind {
        case .sharedSession: return sharedChatsEnabled
        case .permissionRequest: return permissionsEnabled
        case .agentMessage: return agentUpdatesEnabled
        }
    }

    private func remember(_ id: String) {
        deliveredEventIDs.append(id)
        if deliveredEventIDs.count > 128 {
            deliveredEventIDs.removeFirst(deliveredEventIDs.count - 128)
        }
    }
}

struct NotificationOnboardingCard: View {
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @State private var isRequesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 44, height: 44)
                    .background(theme.accentMuted, in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Know when your code needs you")
                        .font(.headline)
                    Text("Get a quiet heads-up for permission requests, shared chats, and updates you ask an agent to send.")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button("Not now") {
                    notifications.deferOnboarding()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    isRequesting = true
                    Task {
                        await notifications.requestAuthorization()
                        await notifications.sync(hosts: model.hosts)
                        isRequesting = false
                    }
                } label: {
                    if isRequesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Turn on", systemImage: "bell")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .foregroundStyle(theme.ground)
                .disabled(isRequesting)
                .accessibilityLabel("Turn on notifications")
            }
        }
        .padding(18)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.panelRadius)
                .stroke(theme.accent.opacity(0.45), lineWidth: theme.borderWidth)
        )
        .remoteThemeGlow(theme)
    }
}

struct NotificationSettingsView: View {
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var isRequesting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow
                }

                Section("Notify me about") {
                    Toggle("Chats shared with me", isOn: $notifications.sharedChatsEnabled)
                    Toggle("Permission requests", isOn: $notifications.permissionsEnabled)
                    Toggle("Agent updates I request", isOn: $notifications.agentUpdatesEnabled)
                }
                .disabled(notifications.authorizationStatus == .denied)

                if notifications.hasLiveOnlyConnections {
                    Section {
                        Label(
                            "This Mac can currently deliver while the live connection is open, "
                                + "but APNs provider delivery is not configured.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryLabel)
                    }
                }

                #if DEBUG
                if let deviceToken = notifications.deviceToken {
                    Section {
                        Button {
                            UIPasteboard.general.string = deviceToken
                        } label: {
                            HStack {
                                Label("Copy APNs test token", systemImage: "doc.on.doc")
                                Spacer()
                                Text(String(deviceToken.suffix(8)))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(theme.secondaryLabel)
                            }
                        }
                    } header: {
                        Text("Development")
                    } footer: {
                        Text(
                            "Available only in debug builds. Use this sandbox token with the "
                                + "opt-in notification end-to-end tests."
                        )
                    }
                }
                #endif

                Section {
                    Text("Permission notifications open the exact chat for review. They never put Allow or Deny on the lock screen.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryLabel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.ground)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: notifications.sharedChatsEnabled) { _, _ in sync() }
            .onChange(of: notifications.permissionsEnabled) { _, _ in sync() }
            .onChange(of: notifications.agentUpdatesEnabled) { _, _ in sync() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var statusRow: some View {
        switch notifications.authorizationStatus {
        case .notDetermined:
            Button {
                isRequesting = true
                Task {
                    await notifications.requestAuthorization()
                    await notifications.sync(hosts: model.hosts)
                    isRequesting = false
                }
            } label: {
                Label(
                    MobileL10n.string(
                        isRequesting ? "Turning on…" : "Turn on notifications"
                    ),
                    systemImage: "bell.badge"
                )
            }
            .disabled(isRequesting)
        case .denied:
            Button {
                notifications.openSystemSettings()
            } label: {
                Label("Allow in iOS Settings", systemImage: "gear")
            }
        case .authorized, .provisional, .ephemeral:
            Label("Notifications are on", systemImage: "checkmark.circle.fill")
                .foregroundStyle(theme.positive)
        @unknown default:
            Text("Notification status unavailable")
        }
    }

    private func sync() {
        notifications.settingsChanged(hosts: model.hosts)
    }
}
