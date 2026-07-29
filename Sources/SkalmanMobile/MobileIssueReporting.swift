import Darwin
import CoreMotion
import SkalmanRemoteKit
import SwiftUI
import UIKit
import UserNotifications

enum MobileIssueReportTrigger: String {
    case shake
    case diagnostics
}

struct MobileIssueReportRequest: Identifiable {
    let id = UUID()
    let trigger: MobileIssueReportTrigger
    let screenshot: UIImage?
    let screenshotWasRequested: Bool
}

/// The consent surface between an in-app symptom and files that can leave the device.
///
/// The base report remains content-free. Device context is not even gathered until its toggle
/// is on and the user taps Share. A screenshot is captured only after the separate preflight
/// choice shown for a shake report, then previewed here and removable before export.
struct MobileIssueReportView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let request: MobileIssueReportRequest

    @State private var reporterNote = ""
    @State private var includeAdditionalDetails = false
    @State private var includeScreenshot: Bool
    @State private var isPreparing = false
    @State private var sharePayload: DiagnosticsSharePayload?
    @State private var exportError: String?

    init(request: MobileIssueReportRequest) {
        self.request = request
        _includeScreenshot = State(initialValue: request.screenshot != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $reporterNote)
                        .frame(minHeight: 110)
                        .overlay(alignment: .topLeading) {
                            if reporterNote.isEmpty {
                                Text("What happened, and what did you expect?")
                                    .foregroundStyle(theme.tertiaryLabel)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: reporterNote) { _, value in
                            if value.count > 10_000 {
                                reporterNote = String(value.prefix(10_000))
                            }
                        }
                } header: {
                    Text("Description")
                } footer: {
                    Text("Your description is shared exactly as written in a separate text file.")
                }

                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connection diagnostics")
                            Text("Build, protocol and recent state transitions")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryLabel)
                        }
                    } icon: {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }

                    Toggle(isOn: $includeAdditionalDetails) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Additional device details")
                            Text("Model, locale, power, display and connection state")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryLabel)
                        }
                    }

                    if let screenshot = request.screenshot {
                        Toggle(isOn: $includeScreenshot) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Current screen")
                                Text("May contain code or chat content")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryLabel)
                            }
                        }

                        if includeScreenshot {
                            Image(uiImage: screenshot)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(theme.border, lineWidth: 1)
                                }
                                .accessibilityLabel("Screenshot that will be shared")
                        }
                    } else if request.screenshotWasRequested {
                        Label("The current screen couldn’t be captured", systemImage: "photo.badge.exclamationmark")
                            .foregroundStyle(theme.warning)
                    }
                } header: {
                    Text("Included")
                } footer: {
                    Text(Self.privacyFooter)
                }

            }
            .scrollContentBackground(.hidden)
            .background(theme.ground)
            .safeAreaInset(edge: .bottom) {
                Button {
                    prepareShare()
                } label: {
                    HStack {
                        Spacer()
                        if isPreparing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(theme.ground)
                        } else {
                            Label("Share report", systemImage: "square.and.arrow.up")
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .foregroundStyle(theme.ground)
                .disabled(isPreparing)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(theme.ground)
            }
            .navigationTitle("Report a problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            DiagnosticsActivityView(items: payload.items)
        }
        .themedAlert(
            "Couldn’t prepare report",
            message: exportError ?? "",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
        .presentationDetents([.large])
    }

    private func prepareShare() {
        isPreparing = true
        do {
            let extra = includeAdditionalDetails
                ? MobileDiagnostics.additionalDetails(model: model, notifications: notifications)
                : [:]
            MobileDiagnostics.record(.issueReportExported, fields: [
                .reason: request.trigger.rawValue,
                .enabledKindCount: String(extra.count),
                .surface: includeScreenshot ? "screenshot" : "none",
            ])

            var items = [try MobileDiagnostics.supportReport(additionalDetails: extra)]
            if let note = try MobileDiagnostics.writeReporterNote(reporterNote) {
                items.append(note)
            }
            if includeScreenshot,
               let screenshot = request.screenshot,
               let image = try MobileDiagnostics.writeScreenshot(screenshot) {
                items.append(image)
            }
            sharePayload = DiagnosticsSharePayload(items: items)
        } catch {
            exportError = MobileL10n.string("The report files could not be prepared.")
        }
        isPreparing = false
    }

    private static let privacyFooter =
        MobileL10n.string(
            "Diagnostics never include messages, prompts, paths, notification text, device names "
                + "or credentials. Optional details contain no stable device identifier."
        )
}

extension MobileDiagnostics {
    @MainActor
    static func additionalDetails(
        model: RemoteAppModel,
        notifications: RemoteNotificationManager
    ) -> [RemoteDiagnosticExtraField: String] {
        let process = ProcessInfo.processInfo
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .screen
        var details: [RemoteDiagnosticExtraField: String] = [
            .deviceModel: machineIdentifier(),
            .interfaceIdiom: interfaceIdiom(UIDevice.current.userInterfaceIdiom),
            .locale: Locale.current.identifier,
            .preferredLanguage: Locale.preferredLanguages.first ?? "unknown",
            .timeZone: TimeZone.current.identifier,
            .lowPowerMode: process.isLowPowerModeEnabled ? "enabled" : "disabled",
            .thermalState: thermalState(process.thermalState),
            .physicalMemoryMB: String(process.physicalMemory / 1_048_576),
            .applicationState: applicationState(UIApplication.shared.applicationState),
            .connectionState: connectionState(model.phase),
            .pairedHostCount: String(model.hosts.count),
            .visibleSessionCount: String(model.me?.sessions.count ?? 0),
            .activeScope: model.me?.share.scope ?? "none",
            .activeCapability: model.me?.share.capability ?? "none",
            .notificationAuthorization: notificationAuthorization(
                notifications.authorizationStatus
            ),
        ]

        if let host = model.activeHost {
            details[.notificationDelivery] =
                notifications.deliveryByConnection[host.id] ?? "none"
        } else {
            details[.notificationDelivery] = "none"
        }
        if let screen {
            details[.displayPoints] =
                "\(Int(screen.bounds.width))x\(Int(screen.bounds.height))"
            details[.displayScale] = String(format: "%.2f", screen.scale)
        }
        if let available = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            details[.availableStorageMB] = String(available / 1_048_576)
        }
        return details
    }

    static func writeReporterNote(_ note: String) throws -> URL? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "skalman-report-note-\(UUID().uuidString.lowercased()).txt"
        )
        try Data(trimmed.utf8).write(to: url, options: .atomic)
        return url
    }

    static func writeScreenshot(_ image: UIImage) throws -> URL? {
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "skalman-report-screen-\(UUID().uuidString.lowercased()).png"
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func machineIdentifier() -> String {
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private static func interfaceIdiom(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone: return "phone"
        case .pad: return "pad"
        case .tv: return "tv"
        case .carPlay: return "carPlay"
        case .mac: return "mac"
        case .vision: return "vision"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }

    private static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func applicationState(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func connectionState(_ phase: RemoteAppModel.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .online: return "online"
        case .offline: return "offline"
        }
    }

    private static func notificationAuthorization(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}

/// A zero-size responder that turns a physical or Simulator shake into a SwiftUI callback.
///
/// Core Motion keeps this working while a composer owns first responder (the exact moment a
/// text field would otherwise consume shake for Undo). The system motion event remains the
/// Simulator/fallback path. Monitoring pauses whenever the app leaves the foreground.
struct ShakeGestureDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onShake: onShake)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onShake = onShake
    }

    final class Controller: UIViewController {
        var onShake: () -> Void
        private let motionManager = CMMotionManager()
        private var firstImpulse: CMAcceleration?
        private var firstImpulseAt: TimeInterval = 0
        private var lastTriggerAt: TimeInterval = 0

        init(onShake: @escaping () -> Void) {
            self.onShake = onShake
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var canBecomeFirstResponder: Bool { true }

        override func loadView() {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            self.view = view
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(startMotionMonitoring),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(stopMotionMonitoring),
                name: UIApplication.willResignActiveNotification,
                object: nil
            )
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
            startMotionMonitoring()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stopMotionMonitoring()
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake {
                triggerIfReady()
            } else {
                super.motionEnded(motion, with: event)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            motionManager.stopDeviceMotionUpdates()
        }

        @objc private func startMotionMonitoring() {
            guard motionManager.isDeviceMotionAvailable,
                  !motionManager.isDeviceMotionActive else {
                return
            }
            motionManager.deviceMotionUpdateInterval = 1.0 / 20.0
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let acceleration = motion?.userAcceleration else { return }
                self?.consume(acceleration)
            }
        }

        @objc private func stopMotionMonitoring() {
            motionManager.stopDeviceMotionUpdates()
            firstImpulse = nil
        }

        /// Requires a quick reversal, distinguishing a deliberate back-and-forth shake from a
        /// single bump or putting the phone down on a table.
        private func consume(_ acceleration: CMAcceleration) {
            let magnitude = sqrt(
                acceleration.x * acceleration.x
                    + acceleration.y * acceleration.y
                    + acceleration.z * acceleration.z
            )
            guard magnitude >= 1.35 else { return }

            let now = ProcessInfo.processInfo.systemUptime
            guard let first = firstImpulse, now - firstImpulseAt <= 0.7 else {
                firstImpulse = acceleration
                firstImpulseAt = now
                return
            }

            let firstMagnitude = sqrt(
                first.x * first.x + first.y * first.y + first.z * first.z
            )
            let dot = (
                acceleration.x * first.x
                    + acceleration.y * first.y
                    + acceleration.z * first.z
            ) / (magnitude * firstMagnitude)
            guard dot <= -0.25 else { return }

            firstImpulse = nil
            triggerIfReady(at: now)
        }

        private func triggerIfReady(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            guard now - lastTriggerAt >= 1.5 else { return }
            lastTriggerAt = now
            onShake()
        }
    }
}

@MainActor
enum MobileScreenCapture {
    static func currentScreen() -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else {
            return nil
        }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}
