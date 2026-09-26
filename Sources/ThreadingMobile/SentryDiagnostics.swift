import Foundation
import Sentry
import SwiftUI
import ThreadingRemoteKit

enum MobileSentryDiagnosticsConsent {
    static let enabledKey = "sentryDiagnosticsEnabled"
}

/// Phone-owned consent state. It is independent of the paired-Mac checkup switches: Sentry can
/// never become a side effect of connecting a Mac or asking for local evidence.
@MainActor
final class MobileSentryDiagnosticsStatus: ObservableObject {
    static let shared = MobileSentryDiagnosticsStatus()

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: MobileSentryDiagnosticsConsent.enabledKey)
            preferenceChanged(isEnabled)
        }
    }

    private let defaults: UserDefaults
    private let preferenceChanged: (Bool) -> Void

    init(
        defaults: UserDefaults = .standard,
        preferenceChanged: @escaping (Bool) -> Void = {
            SentryDiagnostics.preferenceDidChange(isEnabled: $0)
        }
    ) {
        self.defaults = defaults
        self.preferenceChanged = preferenceChanged
        isEnabled = defaults.bool(forKey: MobileSentryDiagnosticsConsent.enabledKey)
    }

#if DEBUG
    static func evidenceFixture(isEnabled: Bool) -> MobileSentryDiagnosticsStatus {
        let defaults = UserDefaults(suiteName: "codes.threading.mobile.sentry-evidence")!
        defaults.set(isEnabled, forKey: MobileSentryDiagnosticsConsent.enabledKey)
        return MobileSentryDiagnosticsStatus(defaults: defaults, preferenceChanged: { _ in })
    }
#endif
}

/// Opt-in, content-free diagnostics for the top-level iOS app. The widget extension does not run
/// the SDK: it shares no crash lifetime with the app and would otherwise create a second release
/// and cache for a process that cannot show this consent surface.
enum SentryDiagnostics {
    static let dsnInfoKey = "ThreadingSentryDSN"
    static let logger = "codes.threading.diagnostics"

    private static let sentryTagKeys: [RemoteDiagnosticField] = [
        .kind, .transport, .result, .code, .status, .environment, .capability, .surface,
        .phase, .networkStage, .networkProtocol, .networkPath, .connectionReused, .wave,
        .reason, .detail,
    ]
    private static let retainedContextKeys: Set<String> = ["app", "os", "runtime", "trace"]
    private static let retainedSpanOperations: Set<String> = [
        "app.lifecycle", "app.start", "app.start.cold", "app.start.warm", "ui.load",
        "ui.load.initial_display", "ui.load.full_display",
    ]
    @MainActor private static var started = false

    @MainActor
    static func startIfEnabled() {
        guard !started,
              NSClassFromString("XCTestCase") == nil,
              UserDefaults.standard.bool(forKey: MobileSentryDiagnosticsConsent.enabledKey),
              let dsn = Bundle.main.object(forInfoDictionaryKey: dsnInfoKey) as? String,
              !dsn.isEmpty else { return }

        SentrySDK.start { options in
            configure(options, dsn: dsn)
        }
        started = true

#if DEBUG
        if ProcessInfo.processInfo.environment["THREADING_SENTRY_VERIFY"] == "1" {
            captureVerificationEvent()
        }
#endif
    }

    @MainActor
    static func preferenceDidChange(isEnabled: Bool) {
        if isEnabled {
            startIfEnabled()
        } else if started || SentrySDK.isEnabled {
            SentrySDK.close()
            started = false
        }
    }

    static func capture(
        _ diagnosticEvent: RemoteDiagnosticEvent,
        level: RemoteDiagnosticLevel,
        fields: [RemoteDiagnosticField: String]
    ) {
        guard level != .info,
              UserDefaults.standard.bool(forKey: MobileSentryDiagnosticsConsent.enabledKey),
              SentrySDK.isEnabled else { return }

        let event = Event(level: level == .error ? .error : .warning)
        event.logger = logger
        event.message = SentryMessage(formatted: "remote.\(diagnosticEvent.rawValue)")

        var tags = [
            "component": "ios",
            "diagnostic.event": diagnosticEvent.rawValue,
        ]
        for field in sentryTagKeys {
            guard let value = fields[field], isMachineToken(value) else { continue }
            tags["diagnostic.\(field.rawValue)"] = value
        }
        event.tags = tags
        event.fingerprint = [
            "threading-diagnostic",
            "ios",
            diagnosticEvent.rawValue,
            tags["diagnostic.code"] ?? "none",
        ]
        SentrySDK.capture(event: event, attachAllThreads: false)
    }

    static func sanitize(_ event: Event, consentIsEnabled: Bool) -> Event? {
        guard consentIsEnabled else { return nil }

        event.user = nil
        event.request = nil
        event.serverName = nil
        event.breadcrumbs = nil
        event.extra = nil
        event.context = event.context?.filter { retainedContextKeys.contains($0.key) }
        event.tags = event.tags?.filter { key, _ in
            key == "component" || key.hasPrefix("diagnostic.")
        }

        if event.logger != logger {
            event.message = nil
        }
        event.transaction = event.type == "transaction" ? "threading.ios.activity" : nil
        event.error = nil
        event.exceptions?.forEach { exception in
            exception.value = "[redacted]"
            sanitize(exception.stacktrace)
        }
        event.threads?.forEach { thread in
            thread.name = nil
            sanitize(thread.stacktrace)
        }
        sanitize(event.stacktrace)
        sanitizeDebugImagePaths(event)
        return event
    }

    private static func configure(_ options: Options, dsn: String) {
        options.dsn = dsn
        options.environment = buildEnvironment
        options.shutdownTimeInterval = 0.2
        options.sendDefaultPii = false
        options.enableMemoryIntrospection = false
#if DEBUG
        options.debug = ProcessInfo.processInfo.environment["THREADING_SENTRY_VERIFY"] == "1"
#endif

        options.enableCrashHandler = true
        options.enableWatchdogTerminationTracking = true
        options.enableMetricKit = true
        options.enableMetricKitRawPayload = false
        options.enableAppHangTracking = false
        options.enableAutoSessionTracking = false

        options.attachScreenshot = false
        options.attachViewHierarchy = false
        options.reportAccessibilityIdentifier = false
        options.attachStacktrace = true
        options.attachAllThreads = false
        options.maxBreadcrumbs = 0
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.sessionReplay.sessionSampleRate = 0
        options.sessionReplay.onErrorSampleRate = 0

        options.enableAutoPerformanceTracing = true
        options.enableUIViewControllerTracing = true
        options.enableUserInteractionTracing = false
        options.enableNetworkTracking = false
        options.enableFileIOTracing = false
        options.enableDataSwizzling = false
        options.enableFileManagerSwizzling = false
        options.enableCoreDataTracing = false
        options.tracePropagationTargets = []
        options.strictTraceContinuation = true
        options.swiftAsyncStacktraces = true
        options.tracesSampleRate = traceSampleRate
        options.configureProfiling = { profiling in
            profiling.lifecycle = .trace
            profiling.sessionSampleRate = profileSampleRate
            profiling.profileAppStarts = true
        }

        options.enableLogs = false
        options.enableMetrics = false
        options.beforeSendLog = { _ in nil }
        options.beforeSendMetric = { _ in nil }
        options.beforeBreadcrumb = { _ in nil }
        options.beforeSendSpan = { span in
            sanitize(span)
        }
        options.beforeSend = { event in
            sanitize(
                event,
                consentIsEnabled: UserDefaults.standard.bool(
                    forKey: MobileSentryDiagnosticsConsent.enabledKey
                )
            )
        }
        options.initialScope = { scope in
            scope.setTag(value: "ios", key: "component")
            scope.setUser(nil)
            return scope
        }
    }

    private static func sanitize(_ stacktrace: SentryStacktrace?) {
        stacktrace?.frames.forEach { frame in
            frame.fileName = nil
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil
            if let package = frame.package, package.contains("/") {
                frame.package = URL(fileURLWithPath: package).lastPathComponent
            }
        }
    }

    private static func sanitizeDebugImagePaths(_ event: Event) {
        event.debugMeta?.forEach { image in
            guard let codeFile = image.codeFile, codeFile.contains("/") else { return }
            image.codeFile = URL(fileURLWithPath: codeFile).lastPathComponent
        }
    }

    private static func sanitize(_ span: any Span) -> (any Span)? {
        guard retainedSpanOperations.contains(span.operation) else { return nil }
        span.spanDescription = nil
        let dataKeys = Array(span.data.keys)
        let tagKeys = Array(span.tags.keys)
        dataKeys.forEach { span.removeData(key: $0) }
        tagKeys.forEach { span.removeTag(key: $0) }
        return span
    }

    private static func isMachineToken(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 46 || byte == 58 || byte == 95
        }
    }

    private static var buildEnvironment: String {
#if DEBUG
        "development"
#else
        "production"
#endif
    }

    private static var traceSampleRate: NSNumber {
#if DEBUG
        1
#else
        0.15
#endif
    }

    private static var profileSampleRate: Float {
#if DEBUG
        1
#else
        0.05
#endif
    }

#if DEBUG
    private static func captureVerificationEvent() {
        let event = Event(level: .warning)
        event.logger = logger
        event.message = SentryMessage(formatted: "integration.verification")
        event.tags = [
            "component": "ios",
            "diagnostic.event": "integration_verification",
        ]
        event.fingerprint = ["threading-diagnostic", "ios", "integration-verification"]
        SentrySDK.capture(event: event, attachAllThreads: false)
        SentrySDK.flush(timeout: 5)
    }
#endif
}

struct SentryDiagnosticsSettingsView: View {
    @Environment(\.remoteTheme) private var theme
    @ObservedObject private var status: MobileSentryDiagnosticsStatus

    init(status: MobileSentryDiagnosticsStatus = .shared) {
        self.status = status
    }

    var body: some View {
        List {
            ThemedSettingsSection {
                Toggle("Share crash & performance reports", isOn: $status.isEnabled)
            } header: {
                Text("App diagnostics")
            } footer: {
                Text(
                    "When enabled, Threading sends crashes, system-attributed hangs, and sampled "
                        + "traces and profiles to Sentry. Prompts, terminal output, paths, "
                        + "screenshots, view hierarchy, network URLs and identifiers are excluded."
                )
            }

            ThemedSettingsSection {
                diagnosticsRow("Provider", value: "Sentry")
                diagnosticsRow("Default", value: "Off")
                diagnosticsRow("Screenshots", value: "Never")
                diagnosticsRow("Terminal content", value: "Never")
            } header: {
                Text("Privacy boundary")
            } footer: {
                Text("Turning the switch off stops new reports immediately.")
            }
        }
        .themedSettingsPage(theme)
        .navigationTitle("App diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diagnosticsRow(_ title: LocalizedStringKey, value: LocalizedStringKey) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(theme.secondaryLabel)
        }
    }
}
