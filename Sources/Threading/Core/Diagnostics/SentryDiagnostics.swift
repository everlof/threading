import Foundation
import Sentry
import ThreadingRemoteKit

/// Opt-in, content-free production diagnostics for the top-level macOS process.
///
/// The PTY host and the other helpers deliberately do not initialize another SDK. When an owning
/// app observes a bounded helper failure through `MacRemoteDiagnostics`, warning/error records can
/// become one grouped Sentry event without duplicating crash handlers or release identities.
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
              consentIsEnabled,
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
              consentIsEnabled,
              SentrySDK.isEnabled else { return }

        let event = Event(level: level == .error ? .error : .warning)
        event.logger = logger
        event.message = SentryMessage(formatted: "remote.\(diagnosticEvent.rawValue)")

        var tags = [
            "component": "macos",
            "diagnostic.event": diagnosticEvent.rawValue,
        ]
        for field in sentryTagKeys {
            guard let value = fields[field], isMachineToken(value) else { continue }
            tags["diagnostic.\(field.rawValue)"] = value
        }
        event.tags = tags
        event.fingerprint = [
            "threading-diagnostic",
            "macos",
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

        let isStructuralDiagnostic = event.logger == logger
        if !isStructuralDiagnostic {
            event.message = nil
        }
        event.transaction = event.type == "transaction" ? "threading.macos.activity" : nil
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
        options.enableUncaughtNSExceptionReporting = true
        options.enableWatchdogTerminationTracking = true
        options.enableMetricKit = true
        options.enableMetricKitRawPayload = false
        options.enableAutoSessionTracking = false
        // The SDK's legacy hang detector is deprecated and can produce false positives. MetricKit
        // supplies system-attributed hang stacks on both supported Apple platforms instead.
        options.enableAppHangTracking = false

        options.attachStacktrace = true
        options.attachAllThreads = false
        options.maxBreadcrumbs = 0
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false

        options.enableAutoPerformanceTracing = true
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
            sanitize(event, consentIsEnabled: consentIsEnabled)
        }
        options.initialScope = { scope in
            scope.setTag(value: "macos", key: "component")
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

    private static var consentIsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "sentryDiagnosticsEnabled")
    }

    private static var buildEnvironment: String {
#if DEBUG
        "development"
#else
        switch Bundle.main.object(forInfoDictionaryKey: "ThreadingBuildChannel") as? String {
        case "beta": "beta"
        case "nightly": "nightly"
        default: "production"
        }
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
            "component": "macos",
            "diagnostic.event": "integration_verification",
        ]
        event.fingerprint = ["threading-diagnostic", "macos", "integration-verification"]
        SentrySDK.capture(event: event, attachAllThreads: false)
        SentrySDK.flush(timeout: 5)
    }
#endif
}
