import ThreadingRemoteKit
import SwiftUI
import UIKit
import UserNotifications

enum RemoteNotificationBridge {
    static let eventNotification = Notification.Name("ThreadingRemoteNotificationEvent")
    static let deviceTokenNotification = Notification.Name("ThreadingRemotePushToken")

    static func received(_ event: RemoteNotificationEventDTO, connectionID: String) {
        NotificationCenter.default.post(
            name: eventNotification,
            object: event,
            userInfo: ["connectionID": connectionID]
        )
    }

}

/// Decodes both forms the iPhone can receive: the APNs payload nests the authenticated event
/// under `event`, while the live Remote Access socket delivers the event object itself.
///
/// Keeping this UIKit-free seam internal lets the iOS test bundle exercise the exact production
/// decoder without constructing private `UNNotification` implementation objects.
enum RemoteNotificationPayloadDecoder {
    static func event(from userInfo: [AnyHashable: Any]) -> RemoteNotificationEventDTO? {
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

@main
@MainActor
final class ThreadingMobileAppDelegate: NSObject, UIApplicationDelegate,
    UNUserNotificationCenterDelegate {

    private let continuity: MobileSessionContinuityStore
    private let keyboards: MobileTerminalKeyboardStore
    private let model: RemoteAppModel
    private let notifications: RemoteNotificationManager

    override init() {
        let continuity: MobileSessionContinuityStore
#if DEBUG
        if MobileTerminalWireFixtureConfiguration.current != nil,
           let defaults = UserDefaults(suiteName: "codes.threading.mobile.terminal-wire-fixture") {
            // Simulator fixture drafts and viewport positions must not replace the developer's
            // ordinary app continuity. The isolated suite is disposable on every lab launch.
            defaults.removePersistentDomain(forName: "codes.threading.mobile.terminal-wire-fixture")
            continuity = MobileSessionContinuityStore(defaults: defaults)
        } else {
            continuity = MobileSessionContinuityStore()
        }
#else
        continuity = MobileSessionContinuityStore()
#endif
        self.continuity = continuity
        keyboards = MobileTerminalKeyboardStore()
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
#if DEBUG
        // Catalogue captures exercise the shipping view tree, but motion makes two otherwise
        // identical frames differ forever. Disable UIKit animation before the root controller is
        // built; the capture coordinator still waits for asynchronous fixture data and several
        // identical rendered frames before accepting an image.
        if MobileUIEvidenceCapture.isRequested {
            UIView.setAnimationsEnabled(false)
        }
#endif
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

    /// Hands a delivered URL to the model, answering whether it was one of ours.
    @discardableResult
    func open(_ url: URL) -> Bool {
        model.open(url)
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
            controller.title = connection.mirroredCaption
            let navigationController = UINavigationController(rootViewController: controller)
            configure(navigationController, theme: theme)
            return navigationController
        }
#endif
        let root = ThreadingMobileHostedRoot(
            model: model,
            continuity: continuity,
            keyboards: keyboards,
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
        let pushEnvironment = RemoteNotificationEnvironment.sandbox
#else
        let pushEnvironment = RemoteNotificationEnvironment.production
#endif
        MobileDiagnostics.record(.apnsRegistrationSucceeded, fields: [
            .environment: pushEnvironment.rawValue
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if let event = RemoteNotificationPayloadDecoder.event(
            from: notification.request.content.userInfo
        ) {
            await MainActor.run {
                MobileDiagnostics.record(.notificationReceived, fields: [
                    .trace: event.id,
                    .kind: event.kind.rawValue,
                    .transport: "apns",
                ])
            }
        }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let event = RemoteNotificationPayloadDecoder.event(
            from: response.notification.request.content.userInfo
        ) else {
            return
        }
        await MainActor.run {
            MobileDiagnostics.record(.notificationOpened, fields: [
                .trace: event.id,
                .kind: event.kind.rawValue,
                .transport: "apns",
            ])
            model.openSessionFromNotification(event)
        }
    }

    func openNotification(from response: UNNotificationResponse) {
        guard let event = RemoteNotificationPayloadDecoder.event(
            from: response.notification.request.content.userInfo
        ) else {
            return
        }
        model.openSessionFromNotification(event)
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
#if DEBUG
        MobileUIEvidenceCapture.startIfRequested(in: window)
#endif
        if let response = connectionOptions.notificationResponse {
            appDelegate.openNotification(from: response)
        }
        open(connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        open(URLContexts)
    }

    /// Where a tapped `threading://` invitation arrives.
    ///
    /// SwiftUI's `onOpenURL` never fires in this app: the scene is UIKit's and the SwiftUI tree
    /// lives inside a hosting controller rather than in a `WindowGroup`, so the modifier has no
    /// scene to observe. This is that delivery point, and it covers the cold launch too, where
    /// the URL arrives with the scene's connection options rather than through the callback.
    private func open(_ contexts: Set<UIOpenURLContext>) {
        guard !contexts.isEmpty,
              let appDelegate = UIApplication.shared.delegate as? ThreadingMobileAppDelegate
        else { return }
        for context in contexts where appDelegate.open(context.url) {
            return
        }
    }
}

#if DEBUG
extension Notification.Name {
    static let mobileUIEvidenceFocusRequested = Notification.Name(
        "ThreadingMobileUIEvidenceFocusRequested"
    )
    static let mobileUIEvidenceDismissRequested = Notification.Name(
        "ThreadingMobileUIEvidenceDismissRequested"
    )
}

/// Captures deterministic, app-only simulator evidence for the browsable iOS catalogue.
///
/// The host script never guesses that a launch is ready. This coordinator renders the real key
/// window repeatedly and publishes its marker only after the pixels have remained identical over
/// several layout cycles. Output stays inside the app's temporary container; the host resolves
/// that exact container through `simctl` and copies only the named run.
@MainActor
private enum MobileUIEvidenceCapture {
    private enum Environment {
        static let run = "THREADING_MOBILE_UI_EVIDENCE_RUN"
        static let identifier = "THREADING_MOBILE_UI_EVIDENCE_ID"
        static let demo = "THREADING_MOBILE_DEMO"
        static let keyboardState = "THREADING_MOBILE_UI_EVIDENCE_KEYBOARD_STATE"
        static let captureMode = "THREADING_MOBILE_UI_EVIDENCE_CAPTURE_MODE"
        static let keyboardLayout = "THREADING_MOBILE_UI_EVIDENCE_KEYBOARD_LAYOUT"
    }

    private enum Contract {
        static let schemaVersion = 1
        static let kind = "threading-mobile-ui-evidence"
        static let directoryName = "threading-ui-evidence"
        static let maximumSegmentLength = 96
        static let sampleInterval = Duration.milliseconds(200)
        static let maximumSamples = 75
        // Observe the fixture for more than one ordinary caret-blink interval before accepting
        // it, then require the same pixels twice. Requiring four identical samples made a focused
        // text field impossible to capture: its UIKit-owned caret is expected to blink forever,
        // even with application animation disabled. Two adjacent frames still prove the view has
        // stopped laying itself out, while the minimum observation window prevents an empty
        // launch frame from winning early.
        static let minimumSamples = 8
        static let stableSamplesRequired = 2
        static let minimumPNGBytes = 8_000
    }

    private struct Request {
        let run: String
        let identifier: String
        let demo: String
        let keyboardState: KeyboardState?
        let captureMode: CaptureMode
        let keyboardLayout: KeyboardLayoutContract

        static func current() -> Request? {
            let environment = ProcessInfo.processInfo.environment
            guard let run = safeSegment(environment[Environment.run]),
                  let identifier = safeSegment(environment[Environment.identifier]) else {
                return nil
            }
            return Request(
                run: run,
                identifier: identifier,
                demo: environment[Environment.demo] ?? "standard",
                keyboardState: environment[Environment.keyboardState]
                    .flatMap(KeyboardState.init(rawValue:)),
                captureMode: environment[Environment.captureMode]
                    .flatMap(CaptureMode.init(rawValue:)) ?? .app,
                keyboardLayout: environment[Environment.keyboardLayout]
                    .flatMap(KeyboardLayoutContract.init(rawValue:)) ?? .frame
            )
        }

        private static func safeSegment(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value.count <= Contract.maximumSegmentLength,
                  value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { return nil }
            return value
        }
    }

    private struct Marker: Encodable {
        let schemaVersion: Int
        let kind: String
        let identifier: String
        let demo: String
        let image: String
        let pointWidth: Double
        let pointHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let sampleCount: Int
        let stabilized: Bool
        let keyboardState: String?
        let checks: [String: Bool]
    }

    /// A semantic keyboard state from the evidence manifest. The capture coordinator drives the
    /// real first editable control instead of asking each fixture to grow its own timer and focus
    /// implementation.
    private enum KeyboardState: String {
        case closed
        case open
        case dismissedAfterOpen = "dismissed-after-open"
    }

    /// App captures prove static pixel stability. Display captures are reserved for OS-owned
    /// pixels such as the software keyboard, whose caret and suggestion views are intentionally
    /// animated and cannot satisfy an app-window pixel comparison.
    private enum CaptureMode: String {
        case app
        case display
    }

    /// Fixed composers recover their whole frame. A platform Form editor can retain a different
    /// private text-container width after focus while its visible row remains correctly anchored.
    private enum KeyboardLayoutContract: String {
        case frame
        case origin
    }

    static var isRequested: Bool { Request.current() != nil }

    static func startIfRequested(in window: UIWindow) {
        guard let request = Request.current() else { return }
        Task { @MainActor in
            await capture(request, window: window)
        }
    }

    private static func capture(_ request: Request, window: UIWindow) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Contract.directoryName, isDirectory: true)
            .appendingPathComponent(request.run, isDirectory: true)
        let imageURL = directory.appendingPathComponent("\(request.identifier).png")
        let markerURL = directory.appendingPathComponent("\(request.identifier).json")

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            guard !FileManager.default.fileExists(atPath: imageURL.path),
                  !FileManager.default.fileExists(atPath: markerURL.path) else {
                return
            }

            let keyboardChecks = try await prepareKeyboard(
                request.keyboardState,
                layoutContract: request.keyboardLayout,
                in: window
            )

            let last: Data
            let sampleCount: Int
            let stabilized: Bool
            if request.captureMode == .display {
                // The host captures the complete Simulator display after this marker appears.
                // By this point the keyboard contract above has proved readiness, so waiting for
                // the blinking UIKit caret to become pixel-identical would only add fragility.
                try await Task.sleep(for: .milliseconds(200))
                window.layoutIfNeeded()
                last = try png(of: window)
                sampleCount = 1
                stabilized = true
            } else {
                var previous: Data?
                var latest: Data?
                var stableCount = 0
                var samples = 0
                var reachedStability = false

                while samples < Contract.maximumSamples, !Task.isCancelled {
                    try await Task.sleep(for: Contract.sampleInterval)
                    window.layoutIfNeeded()
                    let data = try png(of: window)
                    samples += 1
                    latest = data

                    if data == previous {
                        stableCount += 1
                    } else {
                        stableCount = 1
                        previous = data
                    }
                    if samples >= Contract.minimumSamples,
                       stableCount >= Contract.stableSamplesRequired {
                        reachedStability = true
                        break
                    }
                }
                guard let latest else { return }
                last = latest
                sampleCount = samples
                stabilized = reachedStability
            }

            try last.write(to: imageURL, options: .atomic)
            let scale = window.screen.scale
            let marker = Marker(
                schemaVersion: Contract.schemaVersion,
                kind: Contract.kind,
                identifier: request.identifier,
                demo: request.demo,
                image: imageURL.lastPathComponent,
                pointWidth: window.bounds.width,
                pointHeight: window.bounds.height,
                pixelWidth: Int((window.bounds.width * scale).rounded()),
                pixelHeight: Int((window.bounds.height * scale).rounded()),
                sampleCount: sampleCount,
                stabilized: stabilized,
                keyboardState: request.keyboardState?.rawValue,
                checks: keyboardChecks
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(marker).write(to: markerURL, options: .atomic)
        } catch {
            // Absence of the marker is the failure contract. The host retains stdout/stderr and
            // reports the exact fixture whose app-owned capture did not complete.
            let failureURL = directory.appendingPathComponent(
                "\(request.identifier).failure.txt"
            )
            try? "UI evidence failed: \(String(reflecting: error))\n".write(
                to: failureURL,
                atomically: true,
                encoding: .utf8
            )
            return
        }
    }

    private static func prepareKeyboard(
        _ state: KeyboardState?,
        layoutContract: KeyboardLayoutContract,
        in window: UIWindow
    ) async throws -> [String: Bool] {
        guard let state else { return [:] }
        let keyboard = KeyboardVisibilityObserver(window: window)

        // SwiftUI may still be mounting its platform text control when the scene becomes key.
        // Poll the shipping hierarchy rather than sleeping for a device-dependent magic delay.
        guard let editor = await waitForEditableControl(in: window) else {
            throw EvidenceError.editableControlMissing(editableHierarchy(in: window))
        }

        if let responder = firstResponder(in: window) {
            _ = responder.resignFirstResponder()
            window.endEditing(true)
            _ = await waitUntil { firstResponder(in: window) == nil }
        }
        let baselineFrame = await stableFrame(of: editor, in: window)
        let baselineSafeArea = window.safeAreaInsets

        if state == .closed {
            return [
                "keyboardHidden": firstResponder(in: window) == nil,
                "noFirstResponder": firstResponder(in: window) == nil,
            ]
        }

        var didFocusThroughView = false
        for _ in 0..<10 where !didFocusThroughView {
            NotificationCenter.default.post(
                name: .mobileUIEvidenceFocusRequested,
                object: window
            )
            didFocusThroughView = await waitUntil({ editor.isFirstResponder }, attempts: 2)
        }
        if !didFocusThroughView {
            // UIKit-owned editors (the native conversation and SwiftTerm) do not need a SwiftUI
            // focus binding. Focus them directly after giving a SwiftUI host one bounded chance
            // to handle the semantic request.
            if let field = editor as? UITextField {
                field.isEnabled = true
                field.isUserInteractionEnabled = true
            }
            guard editor.becomeFirstResponder() else {
                throw EvidenceError.editorRejectedFocus
            }
            editor.reloadInputViews()
        }
        guard await waitUntil({ keyboard.isVisible }) else {
            throw EvidenceError.keyboardDidNotShow
        }
        window.layoutIfNeeded()

        var checks = [
            "editorFocused": editor.isFirstResponder,
            "keyboardShown": keyboard.isVisible,
            "keyboardShownOnce": keyboard.didShow,
        ]
        if state == .open {
            return checks
        }

        NotificationCenter.default.post(
            name: .mobileUIEvidenceDismissRequested,
            object: window
        )
        // Let SwiftUI commit FocusState=false before touching UIKit. Resigning the platform
        // editor in the same synchronous turn leaves SwiftUI's previous `true` transaction as
        // the winner on complex containers such as Form, which immediately reopens the keyboard.
        // `endEditing` remains a bounded fallback for UIKit-owned editors with no FocusState.
        if !(await waitUntil({ firstResponder(in: window) == nil }, attempts: 20)) {
            window.endEditing(true)
        }
        guard await waitUntil({ !keyboard.isVisible }) else {
            throw EvidenceError.keyboardDidNotHide
        }
        guard await waitUntil({ firstResponder(in: window) == nil }) else {
            throw EvidenceError.editorKeptFocus
        }
        // Keyboard animations and a SwiftUI Form's scroll transaction do not necessarily finish
        // in the same frame. Poll the actual pre-keyboard geometry instead of baking an animation
        // duration into the evidence contract.
        let editorLayoutRestored = await waitUntil({
            window.layoutIfNeeded()
            let frame = editor.convert(editor.bounds, to: window)
            switch layoutContract {
            case .frame:
                return approximatelyEqual(frame, baselineFrame)
            case .origin:
                return approximatelyEqual(frame.origin, baselineFrame.origin)
            }
        }, attempts: 40)
        let safeAreaRestored = await waitUntil({
            window.layoutIfNeeded()
            return approximatelyEqual(window.safeAreaInsets, baselineSafeArea)
        }, attempts: 40)
        checks["keyboardHidden"] = !keyboard.isVisible
        checks["noFirstResponder"] = firstResponder(in: window) == nil
        checks["safeAreaRestored"] = safeAreaRestored
        switch layoutContract {
        case .frame:
            checks["editorFrameRestored"] = editorLayoutRestored
        case .origin:
            checks["editorOriginRestored"] = editorLayoutRestored
        }
        return checks
    }

    private static func waitForEditableControl(in window: UIWindow) async -> UIView? {
        for _ in 0..<100 {
            window.layoutIfNeeded()
            if let editor = editableControl(in: window, window: window) {
                return editor
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// SwiftUI may expose the backing editor before a Form has completed its first sizing pass.
    /// Taking that transient frame as the baseline makes ordinary initial layout look like failed
    /// keyboard restoration. Require several unchanged layout cycles before focus changes state.
    private static func stableFrame(of view: UIView, in window: UIWindow) async -> CGRect {
        var previous: CGRect?
        var latest = view.convert(view.bounds, to: window)
        var stableCount = 0
        for sample in 0..<40 {
            try? await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            latest = view.convert(view.bounds, to: window)
            if let previous, approximatelyEqual(latest, previous) {
                stableCount += 1
            } else {
                stableCount = 1
            }
            previous = latest
            if sample >= 3, stableCount >= 3 { break }
        }
        return latest
    }

    private static func editableControl(in view: UIView, window: UIWindow) -> UIView? {
        // A SwiftUI platform host may have zero bounds while a hosted UIKit control has a real,
        // visible frame. Test visibility on the candidate and its ancestors, but never prune a
        // subtree from an intermediate host's empty geometry.
        let visibleFrame = view.convert(view.bounds, to: window)
        let isVisibleCandidate = view.window != nil
            && !visibleFrame.isEmpty
            && visibleFrame.intersects(window.bounds)
            && ancestorsAreVisible(from: view, through: window)
        // SwiftUI owns focus outside this backing field. The coordinator asks the shipping view's
        // FocusState to activate it before falling back to direct UIKit focus.
        if isVisibleCandidate, let field = view as? UITextField {
            return field
        }
        if isVisibleCandidate, let textView = view as? UITextView,
           textView.isEditable, textView.isUserInteractionEnabled {
            return textView
        }
        if isVisibleCandidate,
           view.accessibilityLabel == MobileL10n.string("Remote terminal"),
           view.canBecomeFirstResponder {
            return view
        }
        for subview in view.subviews.reversed() {
            if let match = editableControl(in: subview, window: window) { return match }
        }
        return nil
    }

    private static func ancestorsAreVisible(from view: UIView, through window: UIWindow) -> Bool {
        var candidate: UIView? = view
        while let current = candidate {
            if current.isHidden || current.alpha <= 0.01 { return false }
            if current === window { return true }
            candidate = current.superview
        }
        return false
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let responder = firstResponder(in: subview) { return responder }
        }
        return nil
    }

    private static func editableHierarchy(in root: UIView) -> String {
        var matches: [String] = []
        func visit(_ view: UIView) {
            let name = NSStringFromClass(type(of: view))
            if name.localizedCaseInsensitiveContains("text")
                || name.localizedCaseInsensitiveContains("field")
                || name.localizedCaseInsensitiveContains("input") {
                let frame = view.convert(view.bounds, to: root)
                matches.append(
                    "\(name) frame=\(frame.debugDescription) hidden=\(view.isHidden) "
                        + "alpha=\(view.alpha) window=\(view.window != nil)"
                )
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return matches.prefix(30).joined(separator: " | ")
    }

    private static func waitUntil(
        _ condition: @MainActor () -> Bool,
        attempts: Int = 100
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// UIKit owns the keyboard in a separate window, so an app window's keyboard layout guide is
    /// not a reliable visibility oracle under every SwiftUI hosting arrangement. The lifecycle
    /// notifications are the platform contract: frame changes cover floating/undocked keyboards,
    /// while explicit show/hide events keep the semantic state unambiguous.
    @MainActor
    private final class KeyboardVisibilityObserver: NSObject {
        private(set) var isVisible = false
        private(set) var didShow = false
        private weak var window: UIWindow?

        init(window: UIWindow) {
            self.window = window
            super.init()
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(willShow(_:)),
                name: UIResponder.keyboardWillShowNotification,
                object: nil
            )
            center.addObserver(
                self,
                selector: #selector(willHide(_:)),
                name: UIResponder.keyboardWillHideNotification,
                object: nil
            )
            center.addObserver(
                self,
                selector: #selector(willChangeFrame(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func willShow(_ notification: Notification) {
            isVisible = true
            didShow = true
        }

        @objc private func willHide(_ notification: Notification) {
            isVisible = false
        }

        @objc private func willChangeFrame(_ notification: Notification) {
            guard let window,
                  let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                    as? NSValue else { return }
            let frame = window.convert(value.cgRectValue, from: window.screen.coordinateSpace)
            let visible = !window.bounds.intersection(frame).isNull
                && window.bounds.intersection(frame).height > 1
            isVisible = visible
            didShow = didShow || visible
        }
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2
            && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }

    private static func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 2 && abs(lhs.y - rhs.y) <= 2
    }

    private static func approximatelyEqual(_ lhs: UIEdgeInsets, _ rhs: UIEdgeInsets) -> Bool {
        abs(lhs.top - rhs.top) <= 1
            && abs(lhs.left - rhs.left) <= 1
            && abs(lhs.bottom - rhs.bottom) <= 1
            && abs(lhs.right - rhs.right) <= 1
    }

    private enum EvidenceError: Error {
        case editableControlMissing(String)
        case editorRejectedFocus
        case keyboardDidNotShow
        case keyboardDidNotHide
        case editorKeptFocus
    }

    private static func png(of window: UIWindow) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData(), data.count >= Contract.minimumPNGBytes else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
#endif

extension View {
    /// DEBUG evidence asks a shipping editor to traverse its normal SwiftUI focus boundary.
    /// Production builds erase the observers entirely.
    @ViewBuilder
    func mobileUIEvidenceKeyboardFocus(_ focus: FocusState<Bool>.Binding) -> some View {
#if DEBUG
        onReceive(NotificationCenter.default.publisher(
            for: .mobileUIEvidenceFocusRequested
        )) { _ in
            focus.wrappedValue = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .mobileUIEvidenceDismissRequested
        )) { _ in
            focus.wrappedValue = false
        }
#else
        self
#endif
    }
}

@MainActor
final class RemoteNotificationManager: ObservableObject {

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var deviceToken: String?
    @Published private(set) var deliveryByConnection: [String: RemoteNotificationDelivery] = [:]
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
            let token = (note.object as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            Task { @MainActor in
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

    isolated deinit {
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
        deliveryByConnection.values.contains(.live)
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
            let pushEnvironment = RemoteNotificationEnvironment.sandbox
#else
            let pushEnvironment = RemoteNotificationEnvironment.production
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
                        if case .server(let status, _, _) = error,
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
                    .transport: result.delivery.rawValue,
                    .environment: pushEnvironment.rawValue,
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
                // The ordinary refresh will retry once the Mac is reachable again.
            }
        }
    }

    private func registerNotifications(
        _ registration: RemoteNotificationRegistrationDTO,
        with host: PairedRemoteHost
    ) async throws -> RemoteNotificationRegistrationResponseDTO {
        let requestID = UUID().uuidString.lowercased()
        let peer = MobileDiagnostics.pseudonym(host.id, prefix: "peer")
        var lastError: Error = RemoteClientError.invalidResponse
        let candidates = host.candidates
        for (index, candidate) in candidates.enumerated() {
            let link = candidate.link
            let timeout = candidates.count > 1 && index < candidates.count - 1
                ? 8
                : RemoteClient.defaultRequestTimeout
            let startedAt = MobileDiagnostics.monotonicNow()
            let fields: [RemoteDiagnosticField: String] = [
                .trace: requestID,
                .peer: peer,
                .transport: candidate.kind.rawValue,
                .origin: MobileDiagnostics.originDigest(link.baseURL),
                .phase: "notificationRegistration.request",
                .timeoutMS: MobileDiagnostics.milliseconds(timeout),
                .attempt: String(index + 1),
                .total: String(candidates.count),
            ]
            MobileDiagnostics.recordConnectivity(
                .hostRouteStarted,
                fields: fields.merging([.result: "started"]) { _, new in new }
            )
            do {
                let response = try await RemoteClient(
                    link: link,
                    requestTimeout: timeout,
                    endpointKind: candidate.kind
                ).registerNotifications(registration, requestID: requestID)
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    fields: fields.merging([
                        .result: "succeeded",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                    ]) { _, new in new }
                )
                return response
            } catch is CancellationError {
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    fields: fields.merging([
                        .result: "cancelled",
                        .code: "swift.cancelled",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                    ]) { _, new in new }
                )
                throw CancellationError()
            } catch let error as RemoteClientError {
                var failedFields = fields.merging([
                    .result: "failed",
                    .code: MobileDiagnostics.errorCode(error),
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
                if case .server(let status, _, _) = error {
                    failedFields[.status] = String(status)
                }
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    level: .warning,
                    fields: failedFields
                )
                if case .server(let status, _, _) = error,
                   [502, 503, 504].contains(status) {
                    lastError = error
                    continue
                }
                throw error
            } catch {
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    level: .warning,
                    fields: fields.merging([
                        .result: "failed",
                        .code: MobileDiagnostics.errorCode(error),
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                    ]) { _, new in new }
                )
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
        if let connectionID, deliveryByConnection[connectionID] == .push {
            MobileDiagnostics.record(.notificationSuppressed, fields: [
                .trace: event.id,
                .reason: "apnsOwnsPresentation",
            ])
            return
        }
        // Ordinary state changes have an in-app card/dot. An agent update is an explicit
        // milestone the user asked to receive, including while looking at another chat.
        guard scenePhase != .active || event.kind == .agentMessage else {
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
                .accessibilityLabel(MobileL10n.string("Turn on notifications"))
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
                ThemedSettingsSection {
                    statusRow
                }

                ThemedSettingsSection {
                    Toggle("Chats shared with me", isOn: $notifications.sharedChatsEnabled)
                    Toggle("Permission requests", isOn: $notifications.permissionsEnabled)
                    Toggle("Agent needs my response", isOn: $notifications.agentQuestionsEnabled)
                    Toggle("Requests for my input", isOn: $notifications.attentionRequestsEnabled)
                    Toggle("Agent updates I request", isOn: $notifications.agentUpdatesEnabled)
                } header: {
                    Text("Notify me about")
                }
                .disabled(notifications.authorizationStatus == .denied)

                ThemedSettingsSection {
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

                ThemedSettingsSection {
                    Toggle(
                        "People in open sessions",
                        isOn: $notifications.peoplePresenceEnabled
                    )
                    Toggle(
                        "Typing indicators",
                        isOn: $notifications.typingIndicatorsEnabled
                    )
                } header: {
                    Text("In-app collaboration")
                } footer: {
                    Text(
                        "Presence stays inside the live session and never creates push "
                            + "notifications. A shared terminal uses its device composer so "
                            + "two people cannot mix keystrokes in one TUI line."
                    )
                }

                if notifications.hasLiveOnlyConnections {
                    ThemedSettingsSection {
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
                    ThemedSettingsSection {
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

                ThemedSettingsSection {
                    Text("Permission notifications open the exact chat for review. They never put Allow or Deny on the lock screen.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryLabel)
                }
            }
            .themedSettingsPage(theme)
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
