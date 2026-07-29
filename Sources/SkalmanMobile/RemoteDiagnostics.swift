import CryptoKit
import SkalmanRemoteKit
import SwiftUI
import UIKit
import UserNotifications

enum MobileDiagnostics {
    static let journal = RemoteDiagnosticJournal(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skalman", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true),
        source: .iOSClient
    )

    static func record(
        _ event: RemoteDiagnosticEvent,
        level: RemoteDiagnosticLevel = .info,
        fields: [RemoteDiagnosticField: String] = [:]
    ) {
        journal.record(event, level: level, fields: fields)
    }

    /// Stable inside support reports without exposing the original host, session, or device id.
    static func pseudonym(_ value: String, prefix: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let short = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(short)"
    }

    /// Error descriptions can contain a full request URL, whose fragment is a bearer. Reports
    /// therefore store only a bounded, structural code.
    static func errorCode(_ error: Error) -> String {
        if let remote = error as? RemoteClientError {
            switch remote {
            case .invalidResponse: return "remote.invalidResponse"
            case .unauthorized: return "remote.unauthorized"
            case .upgradeRequired: return "remote.upgradeRequired"
            case .server(let status): return "remote.http.\(status)"
            }
        }
        if let url = error as? URLError {
            return "url.\(url.code.rawValue)"
        }
        let cocoa = error as NSError
        if cocoa.domain == NSPOSIXErrorDomain {
            return "posix.\(cocoa.code)"
        }
        if cocoa.domain == NSCocoaErrorDomain {
            return "cocoa.\(cocoa.code)"
        }
        return "other.\(cocoa.code)"
    }

    static func supportReport(
        additionalDetails: [RemoteDiagnosticExtraField: String] = [:]
    ) throws -> URL {
        let info = Bundle.main.infoDictionary
        return try journal.writeSupportReport(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info?["CFBundleVersion"] as? String ?? "?",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            protocolVersion: RemoteProtocol.current,
            minimumProtocolVersion: RemoteProtocol.minimumSupported,
            additionalDetails: additionalDetails
        )
    }
}

struct RemoteDiagnosticsView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var isRunningChecks = false
    @State private var sharePayload: DiagnosticsSharePayload?
    @State private var issueReportRequest: MobileIssueReportRequest?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    diagnosticRow(
                        "Mac",
                        value: model.activeHost?.name ?? MobileL10n.string("None")
                    )
                    diagnosticRow("Status", value: connectionStatus)
                    diagnosticRow(
                        "Remote protocol",
                        value: MobileL10n.string(
                            "%lld · accepts %lld+",
                            Int64(RemoteProtocol.current),
                            Int64(RemoteProtocol.minimumSupported)
                        )
                    )
                }

                Section("Notifications") {
                    diagnosticRow("Permission", value: authorizationStatus)
                    diagnosticRow(
                        "APNs device token",
                        value: MobileL10n.string(
                            notifications.deviceToken == nil ? "Waiting" : "Registered"
                        )
                    )
                    diagnosticRow("Delivery", value: deliveryStatus)
                }

                Section {
                    Button {
                        isRunningChecks = true
                        Task {
                            await notifications.refreshAuthorization()
                            await model.refresh()
                            await notifications.sync(hosts: model.hosts)
                            isRunningChecks = false
                        }
                    } label: {
                        if isRunningChecks {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Checking…")
                            }
                        } else {
                            Label("Run connection checks", systemImage: "stethoscope")
                        }
                    }
                    .disabled(isRunningChecks)

                    Button {
                        MobileDiagnostics.record(.issueReportOpened, fields: [
                            .reason: "diagnostics"
                        ])
                        issueReportRequest = MobileIssueReportRequest(
                            trigger: .diagnostics,
                            screenshot: nil,
                            screenshotWasRequested: false
                        )
                    } label: {
                        Label("Report a problem", systemImage: "exclamationmark.bubble")
                    }

                    Button {
                        do {
                            MobileDiagnostics.record(.issueReportExported, fields: [
                                .reason: "diagnostics-only",
                            ])
                            let url = try MobileDiagnostics.supportReport()
                            sharePayload = DiagnosticsSharePayload(items: [url])
                        } catch {
                            exportError = MobileL10n.string(
                                "The support report could not be prepared."
                            )
                        }
                    } label: {
                        Label("Share diagnostics only", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text(
                        "Reports contain build, protocol and connection events. They exclude "
                            + "messages, prompts, file paths, notification text and credentials."
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.ground)
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            DiagnosticsActivityView(items: payload.items)
        }
        .sheet(item: $issueReportRequest) { request in
            MobileIssueReportView(request: request)
        }
        .themedAlert(
            "Couldn’t export diagnostics",
            message: exportError ?? "",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
        .presentationDetents([.medium, .large])
    }

    private func diagnosticRow(_ title: String, value: String) -> some View {
        HStack {
            Text(MobileL10n.string(title))
            Spacer()
            Text(value)
                .foregroundStyle(theme.secondaryLabel)
                .multilineTextAlignment(.trailing)
        }
    }

    private var connectionStatus: String {
        switch model.phase {
        case .idle: return MobileL10n.string("Idle")
        case .connecting: return MobileL10n.string("Connecting")
        case .online: return MobileL10n.string("Online")
        case .offline: return MobileL10n.string("Offline")
        }
    }

    private var authorizationStatus: String {
        switch notifications.authorizationStatus {
        case .notDetermined: return MobileL10n.string("Not requested")
        case .denied: return MobileL10n.string("Denied")
        case .authorized: return MobileL10n.string("Allowed")
        case .provisional: return MobileL10n.string("Provisional")
        case .ephemeral: return MobileL10n.string("Temporary")
        @unknown default: return MobileL10n.string("Unknown")
        }
    }

    private var deliveryStatus: String {
        guard let host = model.activeHost else { return MobileL10n.string("No Mac") }
        switch notifications.deliveryByConnection[host.id] {
        case "push": return "APNs"
        case "live": return MobileL10n.string("Live only")
        case .some(let value): return value
        case nil: return MobileL10n.string("Not registered")
        }
    }
}

struct DiagnosticsSharePayload: Identifiable {
    let id = UUID()
    let items: [URL]
}

struct DiagnosticsActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
