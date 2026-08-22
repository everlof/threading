import Foundation
import SwiftUI
import ThreadingRemoteKit
import UIKit

/// The shipping phone-owned consent boundary for local diagnostics.
///
/// Both choices are off on a fresh install. The main switch controls every network request;
/// automatic screenshots are a narrower, independent choice and cannot collect while the main
/// switch is off. Changing either value takes effect on the live event socket without a restart.
@MainActor
final class MobileDiagnosticsStatus: ObservableObject {
    static let shared = MobileDiagnosticsStatus()

    private static let enabledKey = "localDiagnosticsEnabled"
    private static let errorScreenshotsKey = "localDiagnosticsErrorScreenshotsEnabled"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                MobileDiagnosticsIncidentRecorder.shared.featureWasEnabled()
            } else {
                MobileDiagnosticsIncidentRecorder.shared.featureWasDisabled()
            }
        }
    }

    @Published var capturesErrorScreenshots: Bool {
        didSet {
            guard capturesErrorScreenshots != oldValue else { return }
            UserDefaults.standard.set(capturesErrorScreenshots, forKey: Self.errorScreenshotsKey)
            MobileDiagnosticsIncidentRecorder.shared.screenshotConsentChanged(
                isEnabled: capturesErrorScreenshots
            )
        }
    }

    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastIncidentAt: Date?
    @Published private(set) var lastFailureCode: String?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        capturesErrorScreenshots = UserDefaults.standard.bool(forKey: Self.errorScreenshotsKey)
    }

    func uploaded(at date: Date = Date()) {
        lastUploadAt = date
        lastFailureCode = nil
    }

    func incidentCaptured(at date: Date = Date()) {
        lastIncidentAt = date
    }

    func incidentsCleared() {
        lastIncidentAt = nil
        lastFailureCode = nil
    }

    func failed(_ error: Error) {
        lastFailureCode = MobileDiagnostics.errorCode(error)
    }
}

/// Retains only the newest few screenshots taken at error boundaries.
///
/// Collection requires both phone switches, the app must be foreground-active, and the network
/// still requires a paired owner Mac to ask for a capture. A generation token makes turning a
/// switch off revoke a screenshot already waiting in the short error-settling delay.
@MainActor
final class MobileDiagnosticsIncidentRecorder {
    static let shared = MobileDiagnosticsIncidentRecorder()

    static let maximumImages = 3
    static let maximumImageBytes = 420 * 1024
    static let cooldown: TimeInterval = 60

    private let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Threading", isDirectory: true)
        .appendingPathComponent("MobileDiagnosticsIncidents", isDirectory: true)
    private var lastCaptureAt: Date?
    private var pendingCapture = false
    private var consentGeneration = 0
    private weak var model: RemoteAppModel?

    func attach(_ model: RemoteAppModel) {
        self.model = model
    }

    func featureWasEnabled() {
        model?.sendMobileDiagnosticsHelloIfConnected()
    }

    func featureWasDisabled() {
        consentGeneration &+= 1
        pendingCapture = false
        model?.sendMobileDiagnosticsDisabledIfConnected()
    }

    func screenshotConsentChanged(isEnabled: Bool) {
        guard !isEnabled else { return }
        consentGeneration &+= 1
        pendingCapture = false
    }

    func captureIfNeeded() {
        let status = MobileDiagnosticsStatus.shared
        guard status.isEnabled,
              status.capturesErrorScreenshots,
              UIApplication.shared.applicationState == .active,
              !pendingCapture else { return }
        let now = Date()
        if let lastCaptureAt, now.timeIntervalSince(lastCaptureAt) < Self.cooldown { return }
        let generation = consentGeneration
        pendingCapture = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            if generation == self.consentGeneration { self.pendingCapture = false }
            let status = MobileDiagnosticsStatus.shared
            guard generation == self.consentGeneration,
                  status.isEnabled,
                  status.capturesErrorScreenshots,
                  let image = MobileScreenCapture.currentScreen(),
                  let data = image.mobileDiagnosticsJPEG(maximumBytes: Self.maximumImageBytes)
            else { return }
            do {
                try FileManager.default.createDirectory(
                    at: self.directory,
                    withIntermediateDirectories: true
                )
                let slot = Int(now.timeIntervalSince1970 / Self.cooldown) % Self.maximumImages
                try data.write(
                    to: self.directory.appendingPathComponent("incident-\(slot).jpg"),
                    options: [.atomic]
                )
                self.lastCaptureAt = now
                status.incidentCaptured(at: now)
                self.prune()
                self.model?.sendMobileDiagnosticsIncidentIfConnected()
            } catch {
                status.failed(error)
            }
        }
    }

    func latestJPEG() -> Data? {
        guard let newest = incidentFiles().max(by: { $0.1 < $1.1 }),
              let data = try? Data(contentsOf: newest.0, options: [.mappedIfSafe]),
              data.count <= Self.maximumImageBytes else { return nil }
        return data
    }

    var retainedIncidentCount: Int {
        min(incidentFiles().count, Self.maximumImages)
    }

    func clearIncidents() {
        for (url, _) in incidentFiles() {
            try? FileManager.default.removeItem(at: url)
        }
        lastCaptureAt = nil
        MobileDiagnosticsStatus.shared.incidentsCleared()
    }

    private func incidentFiles() -> [(URL, Date)] {
        guard let urls = try? RemoteBoundedDirectoryReader.shallowContents(
            of: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            maximumEntries: Self.maximumImages * 3
        ) else { return [] }
        return urls.compactMap { url -> (URL, Date)? in
            guard url.pathExtension.lowercased() == "jpg",
                  let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= Self.maximumImageBytes else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
    }

    private func prune() {
        for (url, _) in incidentFiles().sorted(by: { $0.1 > $1.1 }).dropFirst(Self.maximumImages) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension RemoteAppModel {
    func sendMobileDiagnosticsHelloIfConnected() {
        guard let task = mobileDiagnosticsAuthenticatedEventsTask else { return }
        sendMobileDiagnosticsHello(on: task)
    }

    func sendMobileDiagnosticsDisabledIfConnected() {
        guard let task = mobileDiagnosticsAuthenticatedEventsTask,
              activeHost?.isOwnerDevice == true,
              activeHost?.activeEndpointKind == RemoteHostEndpointKind.lan else { return }
        sendMobileDiagnosticsSignal(type: "mobileDiagnosticsDisabled", on: task)
    }

    func sendMobileDiagnosticsIncidentIfConnected() {
        guard let task = mobileDiagnosticsAuthenticatedEventsTask,
              MobileDiagnosticsStatus.shared.isEnabled,
              activeHost?.isOwnerDevice == true,
              activeHost?.activeEndpointKind == RemoteHostEndpointKind.lan else { return }
        sendMobileDiagnosticsSignal(type: "mobileDiagnosticsIncident", on: task)
    }

    func sendMobileDiagnosticsHello(on task: URLSessionWebSocketTask) {
        guard MobileDiagnosticsStatus.shared.isEnabled,
              activeHost?.isOwnerDevice == true,
              activeHost?.activeEndpointKind == RemoteHostEndpointKind.lan else { return }
        sendMobileDiagnosticsSignal(type: "mobileDiagnosticsHello", on: task)
    }

    func performMobileDiagnosticsCapture(
        _ request: RemoteMobileDiagnosticsCaptureRequestDTO,
        hostID: String
    ) async {
        guard MobileDiagnosticsStatus.shared.isEnabled,
              activeHostID == hostID,
              activeHost?.isOwnerDevice == true,
              activeHost?.activeEndpointKind == RemoteHostEndpointKind.lan,
              let client else { return }

        let screenshot: (Data, String)?
        switch request.screenshotPolicy {
        case .none:
            screenshot = nil
        case .latestIncident:
            screenshot = MobileDiagnosticsIncidentRecorder.shared.latestJPEG().map {
                ($0, "incident")
            }
        case .current:
            screenshot = MobileScreenCapture.currentScreen()?
                .mobileDiagnosticsJPEG(
                    maximumBytes: MobileDiagnosticsIncidentRecorder.maximumImageBytes
                )
                .map { ($0, "current") }
        }

        let records = Array(MobileDiagnostics.journal.records().suffix(
            RemoteDiagnosticUploadPolicy.maximumRecordsPerUpload
        ))
        guard !records.isEmpty else { return }
        let info = Bundle.main.infoDictionary
        let capture = RemoteMobileDiagnosticsCaptureDTO(
            captureID: UUID().uuidString.lowercased(),
            requestID: request.requestID,
            capturedAt: Self.mobileDiagnosticsTimestamp(Date()),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info?["CFBundleVersion"] as? String ?? "?",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: Self.mobileDiagnosticsMachineIdentifier(),
            applicationState: Self.mobileDiagnosticsApplicationState(
                UIApplication.shared.applicationState
            ),
            connectionState: MobileDiagnostics.connectionState(phase),
            activeEndpointKind: RemoteHostEndpointKind.lan,
            pairedHostCount: min(hosts.count, 64),
            visibleSessionCount: min(me?.sessions.count ?? 0, 10_000),
            diagnostics: records,
            screenshotJPEGBase64: screenshot?.0.base64EncodedString(),
            screenshotKind: screenshot?.1
        )
        do {
            let response = try await client.uploadMobileDiagnosticsCapture(capture)
            guard response.captureID == capture.captureID else {
                throw RemoteClientError.invalidResponse
            }
            MobileDiagnosticsStatus.shared.uploaded()
        } catch {
            MobileDiagnosticsStatus.shared.failed(error)
        }
    }

    private func sendMobileDiagnosticsSignal(type: String, on task: URLSessionWebSocketTask) {
        let message = RemoteClientMessage(type: type, state: RemoteHostEndpointKind.lan)
        guard let data = try? JSONEncoder().encode(message) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private static func mobileDiagnosticsApplicationState(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func mobileDiagnosticsMachineIdentifier() -> String {
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private static func mobileDiagnosticsTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension UIImage {
    func mobileDiagnosticsJPEG(maximumBytes: Int) -> Data? {
        let longestSide = max(size.width, size.height)
        guard longestSide > 0 else { return nil }
        for dimension: CGFloat in [720, 600, 480, 360, 280] {
            let scale = min(1, dimension / longestSide)
            let outputSize = CGSize(
                width: max(1, floor(size.width * scale)),
                height: max(1, floor(size.height * scale))
            )
            let format = UIGraphicsImageRendererFormat.preferred()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
                draw(in: CGRect(origin: .zero, size: outputSize))
            }
            for quality: CGFloat in [0.62, 0.48, 0.36, 0.26, 0.18] {
                guard let data = resized.jpegData(compressionQuality: quality) else { continue }
                if data.count <= maximumBytes { return data }
            }
        }
        return nil
    }
}

struct MobileDiagnosticsView: View {
    @Environment(\.remoteTheme) private var theme
    @ObservedObject private var status = MobileDiagnosticsStatus.shared

    var body: some View {
        List {
            ThemedSettingsSection {
                Toggle("Local diagnostics", isOn: $status.isEnabled)
                Toggle(
                    "Automatic error screenshots",
                    isOn: $status.capturesErrorScreenshots
                )
                .disabled(!status.isEnabled)
                diagnosticsRow(
                    "Route",
                    value: MobileL10n.string("Paired Mac · local network")
                )
            } header: {
                Text("Device checkups")
            } footer: {
                Text(
                    "When enabled on this iPhone and its paired Mac, Threading can send bounded "
                        + "connection evidence over the local network. Turning it off stops new "
                        + "requests immediately."
                )
            }

            ThemedSettingsSection {
                diagnosticsRow(
                    "Last upload",
                    value: status.lastUploadAt?.formatted() ?? MobileL10n.string("Not yet")
                )
                diagnosticsRow(
                    "Saved error screenshots",
                    value: String(MobileDiagnosticsIncidentRecorder.shared.retainedIncidentCount)
                )
                if let lastFailureCode = status.lastFailureCode {
                    diagnosticsRow("Last failure", value: lastFailureCode)
                }
                Button("Clear error screenshots") {
                    MobileDiagnosticsIncidentRecorder.shared.clearIncidents()
                }
                .disabled(MobileDiagnosticsIncidentRecorder.shared.retainedIncidentCount == 0)
            } header: {
                Text("Evidence")
            } footer: {
                Text(
                    "Error screenshots require their own switch, capture only the foreground "
                        + "Threading window, and stay in a three-image ring. A current screenshot "
                        + "is taken only when you explicitly ask the agent for one. Prompts, "
                        + "terminal output, paths, credentials and notification text are not logged."
                )
            }

            ThemedSettingsSection {
                Text("Check up on my iOS app usage.")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("Agent prompt")
            } footer: {
                Text("The agent will say whether it used fresh or cached phone evidence.")
            }
        }
        .themedSettingsPage(theme)
        .navigationTitle("Local diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diagnosticsRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(verbatim: value)
                .foregroundStyle(theme.secondaryLabel)
                .multilineTextAlignment(.trailing)
        }
    }
}
