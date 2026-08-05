import ThreadingRemoteKit
import SwiftUI
import UIKit
import UserNotifications

enum RemoteNotificationBridge {
    static let eventNotification = Notification.Name("ThreadingRemoteNotificationEvent")
    static let openedNotification = Notification.Name("ThreadingRemoteNotificationOpened")
    static let deviceTokenNotification = Notification.Name("ThreadingRemotePushToken")

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

@main
@MainActor
final class ThreadingMobileAppDelegate: NSObject, UIApplicationDelegate,
    UNUserNotificationCenterDelegate {

    private let continuity: MobileSessionContinuityStore
    private let model: RemoteAppModel
    private let notifications: RemoteNotificationManager

    override init() {
        let continuity = MobileSessionContinuityStore()
        self.continuity = continuity
        model = RemoteAppModel(continuity: continuity)
        notifications = RemoteNotificationManager()
        super.init()
    }

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
                identifier: "THREADING_PERMISSION",
                actions: [],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
            UNNotificationCategory(
                identifier: "THREADING_SESSION",
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
        ])
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Threading",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = ThreadingMobileSceneDelegate.self
        return configuration
    }

    func makeRootViewController() -> UIViewController {
#if DEBUG
        if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
            .hasPrefix("conversation") == true {
            let connection = RemoteSessionConnection.demoConversation()
            let theme = RemoteThemePalette(connection.theme ?? model.me?.theme)
            let controller = RemoteConversationViewController(
                connection: connection,
                model: model,
                continuity: continuity,
                notifications: notifications,
                inheritedTheme: theme
            )
            controller.title = connection.title
            let navigationController = UINavigationController(rootViewController: controller)
            configure(navigationController, theme: theme)
            return navigationController
        }
#endif
        let root = ThreadingMobileHostedRoot(
            model: model,
            continuity: continuity,
            notifications: notifications
        )
        return UIHostingController(rootView: root)
    }

    private func configure(
        _ navigationController: UINavigationController,
        theme: RemoteThemePalette
    ) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = theme.uiGround
        appearance.shadowColor = theme.uiDivider
        appearance.titleTextAttributes = [.foregroundColor: theme.uiLabel]
        navigationController.navigationBar.standardAppearance = appearance
        navigationController.navigationBar.compactAppearance = appearance
        navigationController.navigationBar.scrollEdgeAppearance = appearance
        navigationController.navigationBar.tintColor = theme.uiAccent
        navigationController.overrideUserInterfaceStyle = theme.colorScheme == .light
            ? .light : .dark
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
final class ThreadingMobileSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? ThreadingMobileAppDelegate
        else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = appDelegate.makeRootViewController()
        self.window = window
        window.makeKeyAndVisible()
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
    @Published var agentQuestionsEnabled: Bool {
        didSet { defaults.set(agentQuestionsEnabled, forKey: Keys.agentQuestions) }
    }
    @Published var agentUpdatesEnabled: Bool {
        didSet { defaults.set(agentUpdatesEnabled, forKey: Keys.agentUpdates) }
    }
    @Published var attentionRequestsEnabled: Bool {
        didSet { defaults.set(attentionRequestsEnabled, forKey: Keys.attentionRequests) }
    }
    @Published var peoplePresenceEnabled: Bool {
        didSet { defaults.set(peoplePresenceEnabled, forKey: Keys.peoplePresence) }
    }
    @Published var typingIndicatorsEnabled: Bool {
        didSet { defaults.set(typingIndicatorsEnabled, forKey: Keys.typingIndicators) }
    }
    @Published var independentTerminalDraftsEnabled: Bool {
        didSet {
            defaults.set(independentTerminalDraftsEnabled, forKey: Keys.independentTerminalDrafts)
        }
    }
    @Published var notificationSoundsEnabled: Bool {
        didSet { defaults.set(notificationSoundsEnabled, forKey: Keys.notificationSounds) }
    }
    @Published var permissionSoundsEnabled: Bool {
        didSet { defaults.set(permissionSoundsEnabled, forKey: Keys.permissionSounds) }
    }
    @Published var questionSoundsEnabled: Bool {
        didSet { defaults.set(questionSoundsEnabled, forKey: Keys.questionSounds) }
    }
    @Published var attentionSoundsEnabled: Bool {
        didSet { defaults.set(attentionSoundsEnabled, forKey: Keys.attentionSounds) }
    }
    @Published var updateSoundsEnabled: Bool {
        didSet { defaults.set(updateSoundsEnabled, forKey: Keys.updateSounds) }
    }
    @Published var sharedChatSoundsEnabled: Bool {
        didSet { defaults.set(sharedChatSoundsEnabled, forKey: Keys.sharedChatSounds) }
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
        static let agentQuestions = "remoteNotificationsAgentQuestions"
        static let agentUpdates = "remoteNotificationsAgentUpdates"
        static let attentionRequests = "remoteNotificationsAttentionRequests"
        static let peoplePresence = "remoteCollaborationPeoplePresence"
        static let typingIndicators = "remoteCollaborationTypingIndicators"
        static let independentTerminalDrafts = "remoteCollaborationIndependentTerminalDrafts"
        static let notificationSounds = "remoteNotificationSounds"
        static let permissionSounds = "remoteNotificationPermissionSounds"
        static let questionSounds = "remoteNotificationQuestionSounds"
        static let attentionSounds = "remoteNotificationAttentionSounds"
        static let updateSounds = "remoteNotificationUpdateSounds"
        static let sharedChatSounds = "remoteNotificationSharedChatSounds"
    }

    init() {
        defaults.register(defaults: [
            Keys.sharedChats: true,
            Keys.permissions: true,
            Keys.agentQuestions: true,
            Keys.agentUpdates: true,
            Keys.attentionRequests: true,
            Keys.peoplePresence: true,
            Keys.typingIndicators: true,
            Keys.independentTerminalDrafts: true,
            Keys.notificationSounds: true,
            Keys.permissionSounds: true,
            Keys.questionSounds: true,
            Keys.attentionSounds: true,
            Keys.updateSounds: false,
            Keys.sharedChatSounds: false,
        ])
        sharedChatsEnabled = defaults.bool(forKey: Keys.sharedChats)
        permissionsEnabled = defaults.bool(forKey: Keys.permissions)
        agentQuestionsEnabled = defaults.bool(forKey: Keys.agentQuestions)
        agentUpdatesEnabled = defaults.bool(forKey: Keys.agentUpdates)
        attentionRequestsEnabled = defaults.bool(forKey: Keys.attentionRequests)
        peoplePresenceEnabled = defaults.bool(forKey: Keys.peoplePresence)
        typingIndicatorsEnabled = defaults.bool(forKey: Keys.typingIndicators)
        independentTerminalDraftsEnabled = defaults.bool(forKey: Keys.independentTerminalDrafts)
        notificationSoundsEnabled = defaults.bool(forKey: Keys.notificationSounds)
        permissionSoundsEnabled = defaults.bool(forKey: Keys.permissionSounds)
        questionSoundsEnabled = defaults.bool(forKey: Keys.questionSounds)
        attentionSoundsEnabled = defaults.bool(forKey: Keys.attentionSounds)
        updateSoundsEnabled = defaults.bool(forKey: Keys.updateSounds)
        sharedChatSoundsEnabled = defaults.bool(forKey: Keys.sharedChatSounds)

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
        if agentQuestionsEnabled { result.append(.agentQuestion) }
        if agentUpdatesEnabled { result.append(.agentMessage) }
        if attentionRequestsEnabled { result.append(.attentionRequest) }
        return result
    }

    var soundEnabledKinds: [RemoteNotificationKind] {
        guard notificationSoundsEnabled else { return [] }
        var result: [RemoteNotificationKind] = []
        if sharedChatSoundsEnabled { result.append(.sharedSession) }
        if permissionSoundsEnabled { result.append(.permissionRequest) }
        if questionSoundsEnabled { result.append(.agentQuestion) }
        if updateSoundsEnabled { result.append(.agentMessage) }
        if attentionSoundsEnabled { result.append(.attentionRequest) }
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
        let soundKinds = soundEnabledKinds
        for host in hosts {
            let signature = [
                host.id,
                deviceToken,
                kinds.map(\.rawValue).sorted().joined(separator: ","),
                soundKinds.map(\.rawValue).sorted().joined(separator: ","),
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
            // Register the established kinds first. An older Mac cannot decode a newly added
            // enum case, so sending attentionRequest in the only registration would also turn
            // off otherwise-compatible notifications. The second registration upgrades the
            // preference atomically on hosts that know the optional feature.
            let baselineKinds = kinds.filter {
                $0 != .attentionRequest && $0 != .agentQuestion
            }
            let baselineRegistration = RemoteNotificationRegistrationDTO(
                deviceToken: deviceToken,
                environment: pushEnvironment,
                enabledKinds: baselineKinds,
                soundEnabledKinds: soundKinds.filter { baselineKinds.contains($0) }
            )
            do {
                var result = try await registerNotifications(
                    baselineRegistration,
                    with: host
                )
                if kinds.contains(.attentionRequest) || kinds.contains(.agentQuestion) {
                    let extendedRegistration = RemoteNotificationRegistrationDTO(
                        deviceToken: deviceToken,
                        environment: pushEnvironment,
                        enabledKinds: kinds,
                        soundEnabledKinds: soundKinds
                    )
                    do {
                        result = try await registerNotifications(
                            extendedRegistration,
                            with: host
                        )
                    } catch let error as RemoteClientError {
                        if case .server(let status) = error,
                           (400...499).contains(status) {
                            // The baseline registration is already active. Remember this result
                            // for this launch instead of repeatedly probing an older host.
                            MobileDiagnostics.record(
                                .notificationRegistrationFailed,
                                level: .warning,
                                fields: [
                                    .peer: peer,
                                    .reason: "optionalNotificationKindsUnsupported",
                                ]
                            )
                        } else {
                            throw error
                        }
                    }
                }
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

    private func registerNotifications(
        _ registration: RemoteNotificationRegistrationDTO,
        with host: PairedRemoteHost
    ) async throws -> RemoteNotificationRegistrationResponseDTO {
        let requestID = UUID().uuidString.lowercased()
        var lastError: Error = RemoteClientError.invalidResponse
        let candidates = host.candidateLinks
        for (index, link) in candidates.enumerated() {
            do {
                let timeout: TimeInterval? = candidates.count > 1
                    && index < candidates.count - 1 ? 8 : nil
                return try await RemoteClient(
                    link: link,
                    requestTimeout: timeout
                ).registerNotifications(registration, requestID: requestID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as RemoteClientError {
                if case .server(let status) = error,
                   [502, 503, 504].contains(status) {
                    lastError = error
                    continue
                }
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
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
        content.sound = playsSound(for: event.kind) ? .default : nil
        content.threadIdentifier = event.sessionID
        content.categoryIdentifier = event.kind == .permissionRequest
            ? "THREADING_PERMISSION"
            : "THREADING_SESSION"
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
        case .agentQuestion: return agentQuestionsEnabled
        case .agentMessage: return agentUpdatesEnabled
        case .attentionRequest: return attentionRequestsEnabled
        }
    }

    private func playsSound(for kind: RemoteNotificationKind) -> Bool {
        notificationSoundsEnabled && soundEnabledKinds.contains(kind)
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
                    Text("Get a quiet heads-up for permission requests, shared chats, human input requests, and updates you ask an agent to send.")
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
                    Toggle("Agent needs my response", isOn: $notifications.agentQuestionsEnabled)
                    Toggle("Requests for my input", isOn: $notifications.attentionRequestsEnabled)
                    Toggle("Agent updates I request", isOn: $notifications.agentUpdatesEnabled)
                }
                .disabled(notifications.authorizationStatus == .denied)

                Section {
                    Toggle("Play notification sounds", isOn: $notifications.notificationSoundsEnabled)
                    if notifications.notificationSoundsEnabled {
                        Toggle("Permission requests", isOn: $notifications.permissionSoundsEnabled)
                            .disabled(!notifications.permissionsEnabled)
                        Toggle("Agent needs my response", isOn: $notifications.questionSoundsEnabled)
                            .disabled(!notifications.agentQuestionsEnabled)
                        Toggle("Requests from people", isOn: $notifications.attentionSoundsEnabled)
                            .disabled(!notifications.attentionRequestsEnabled)
                        Toggle("Requested agent updates", isOn: $notifications.updateSoundsEnabled)
                            .disabled(!notifications.agentUpdatesEnabled)
                        Toggle("Newly shared chats", isOn: $notifications.sharedChatSoundsEnabled)
                            .disabled(!notifications.sharedChatsEnabled)
                    }
                } header: {
                    Text("Sounds")
                } footer: {
                    Text("Blocking questions and requests from people sound by default; routine updates stay quiet.")
                }
                .disabled(notifications.authorizationStatus == .denied)

                Section {
                    Toggle(
                        "People in open sessions",
                        isOn: $notifications.peoplePresenceEnabled
                    )
                    Toggle(
                        "Typing indicators",
                        isOn: $notifications.typingIndicatorsEnabled
                    )
                    Toggle(
                        "Independent terminal drafts",
                        isOn: $notifications.independentTerminalDraftsEnabled
                    )
                } header: {
                    Text("In-app collaboration")
                } footer: {
                    Text(
                        "Presence stays inside the live session and never creates push "
                            + "notifications. Independent drafts prevent devices from mixing "
                            + "keystrokes; turn them off for direct terminal typing."
                    )
                }

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
            .onChange(of: notifications.agentQuestionsEnabled) { _, _ in sync() }
            .onChange(of: notifications.agentUpdatesEnabled) { _, _ in sync() }
            .onChange(of: notifications.attentionRequestsEnabled) { _, _ in sync() }
            .onChange(of: notifications.notificationSoundsEnabled) { _, _ in sync() }
            .onChange(of: notifications.permissionSoundsEnabled) { _, _ in sync() }
            .onChange(of: notifications.questionSoundsEnabled) { _, _ in sync() }
            .onChange(of: notifications.attentionSoundsEnabled) { _, _ in sync() }
            .onChange(of: notifications.updateSoundsEnabled) { _, _ in sync() }
            .onChange(of: notifications.sharedChatSoundsEnabled) { _, _ in sync() }
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
