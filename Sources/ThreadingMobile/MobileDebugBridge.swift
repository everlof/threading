#if DEBUG
import Foundation
import SwiftUI
import ThreadingRemoteKit
import UIKit

@MainActor
final class MobileDebugBridgeStatus: ObservableObject {
    static let shared = MobileDebugBridgeStatus()

    private static let enabledKey = "mobileDebugBridgeEnabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                MobileDebugIncidentRecorder.shared.bridgeWasEnabled()
            }
        }
    }
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastIncidentAt: Date?
    @Published private(set) var lastFailureCode: String?

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func uploaded(at date: Date = Date()) {
        lastUploadAt = date
        lastFailureCode = nil
    }

    func incidentCaptured(at date: Date = Date()) {
        lastIncidentAt = date
    }

    func failed(_ error: Error) {
        lastFailureCode = MobileDiagnostics.errorCode(error)
    }
}

/// Retains only the newest few error-boundary images. These files never exist in Release builds,
/// and they are uploaded only after a paired owner Mac asks over its authenticated LAN socket.
@MainActor
final class MobileDebugIncidentRecorder {
    static let shared = MobileDebugIncidentRecorder()

    static let maximumImages = 3
    static let maximumImageBytes = 420 * 1024
    static let cooldown: TimeInterval = 60

    private let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Threading", isDirectory: true)
        .appendingPathComponent("MobileDebugIncidents", isDirectory: true)
    private var lastCaptureAt: Date?
    private var pendingCapture = false
    private weak var model: RemoteAppModel?

    func attach(_ model: RemoteAppModel) {
        self.model = model
    }

    func bridgeWasEnabled() {
        model?.sendMobileDebugHelloIfConnected()
    }

    func captureIfNeeded() {
        guard MobileDebugBridgeStatus.shared.isEnabled,
              UIApplication.shared.applicationState == .active,
              !pendingCapture else { return }
        let now = Date()
        if let lastCaptureAt, now.timeIntervalSince(lastCaptureAt) < Self.cooldown { return }
        pendingCapture = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            defer { self.pendingCapture = false }
            guard MobileDebugBridgeStatus.shared.isEnabled,
                  let image = MobileScreenCapture.currentScreen(),
                  let data = image.mobileDebugJPEG(maximumBytes: Self.maximumImageBytes) else {
                return
            }
            do {
                try FileManager.default.createDirectory(
                    at: self.directory,
                    withIntermediateDirectories: true
                )
                let slot = Int(now.timeIntervalSince1970 / Self.cooldown) % Self.maximumImages
                let name = "incident-\(slot).jpg"
                try data.write(
                    to: self.directory.appendingPathComponent(name),
                    options: [.atomic]
                )
                self.lastCaptureAt = now
                MobileDebugBridgeStatus.shared.incidentCaptured(at: now)
                self.prune()
                self.model?.sendMobileDebugIncidentIfConnected()
            } catch {
                MobileDebugBridgeStatus.shared.failed(error)
            }
        }
    }

    func latestJPEG() -> Data? {
        guard let urls = try? RemoteBoundedDirectoryReader.shallowContents(
            of: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            maximumEntries: Self.maximumImages * 3
        ) else { return nil }
        let candidates = urls.compactMap { url -> (URL, Date)? in
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
        guard let newest = candidates.max(by: { $0.1 < $1.1 }),
              let data = try? Data(contentsOf: newest.0, options: [.mappedIfSafe]),
              data.count <= Self.maximumImageBytes else { return nil }
        return data
    }

    var retainedIncidentCount: Int {
        let urls = (try? RemoteBoundedDirectoryReader.shallowContents(
            of: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            maximumEntries: Self.maximumImages * 3
        )) ?? []
        return urls.prefix(Self.maximumImages + 1).filter {
            $0.pathExtension.lowercased() == "jpg"
        }.count
    }

    private func prune() {
        guard let urls = try? RemoteBoundedDirectoryReader.shallowContents(
            of: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            maximumEntries: Self.maximumImages * 3
        ) else { return }
        let ordered = urls.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhs > rhs
        }
        for url in ordered.dropFirst(Self.maximumImages) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension RemoteAppModel {
    func sendMobileDebugHelloIfConnected() {
        guard let task = mobileDebugAuthenticatedEventsTask else { return }
        sendMobileDebugHello(on: task)
    }

    func sendMobileDebugIncidentIfConnected() {
        guard let task = mobileDebugAuthenticatedEventsTask,
              MobileDebugBridgeStatus.shared.isEnabled,
              activeHost?.isOwnerDevice == true,
              activeHost?.activeEndpointKind == RemoteHostEndpointKind.lan else { return }
        sendMobileDebugSignal(type: "mobileDebugIncident", on: task)
    }

    func sendMobileDebugHello(on task: URLSessionWebSocketTask) {
        guard MobileDebugBridgeStatus.shared.isEnabled,
              activeHost?.isOwnerDevice == true,
              activeHost?.activeEndpointKind == RemoteHostEndpointKind.lan else { return }
        sendMobileDebugSignal(type: "mobileDebugHello", on: task)
    }

    func performMobileDebugCapture(
        _ request: RemoteMobileDebugCaptureRequestDTO,
        hostID: String
    ) async {
        guard MobileDebugBridgeStatus.shared.isEnabled,
              activeHostID == hostID,
              activeHost?.isOwnerDevice == true,
              activeHost?.activeEndpointKind == RemoteHostEndpointKind.lan,
              let client else { return }

        let screenshot: (Data, String)?
        switch request.screenshotPolicy {
        case .none:
            screenshot = nil
        case .latestIncident:
            screenshot = MobileDebugIncidentRecorder.shared.latestJPEG().map { ($0, "incident") }
        case .current:
            screenshot = MobileScreenCapture.currentScreen()?
                .mobileDebugJPEG(maximumBytes: MobileDebugIncidentRecorder.maximumImageBytes)
                .map { ($0, "current") }
        }

        let records = Array(MobileDiagnostics.journal.records().suffix(
            RemoteDiagnosticUploadPolicy.maximumRecordsPerUpload
        ))
        guard !records.isEmpty else { return }
        let info = Bundle.main.infoDictionary
        let capture = RemoteMobileDebugCaptureDTO(
            captureID: UUID().uuidString.lowercased(),
            requestID: request.requestID,
            capturedAt: Self.mobileDebugTimestamp(Date()),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info?["CFBundleVersion"] as? String ?? "?",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: Self.mobileDebugMachineIdentifier(),
            applicationState: Self.mobileDebugApplicationState(
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
            let response = try await client.uploadMobileDebugCapture(capture)
            guard response.captureID == capture.captureID else {
                throw RemoteClientError.invalidResponse
            }
            MobileDebugBridgeStatus.shared.uploaded()
        } catch {
            MobileDebugBridgeStatus.shared.failed(error)
        }
    }

    private func sendMobileDebugSignal(type: String, on task: URLSessionWebSocketTask) {
        let message = RemoteClientMessage(type: type, state: RemoteHostEndpointKind.lan)
        guard let data = try? JSONEncoder().encode(message) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private static func mobileDebugApplicationState(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func mobileDebugMachineIdentifier() -> String {
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private static func mobileDebugTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension UIImage {
    func mobileDebugJPEG(maximumBytes: Int) -> Data? {
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

struct MobileDebugBridgeView: View {
    @Environment(\.remoteTheme) private var theme
    @ObservedObject private var status = MobileDebugBridgeStatus.shared

    var body: some View {
        List {
            ThemedSettingsSection {
                Toggle(isOn: $status.isEnabled) {
                    // localization-ignore: Debug-only developer copy must stay out of Release.
                    Text(verbatim: "Debug bridge")
                }
                debugRow("Build", value: "Debug only")
                debugRow("Route", value: "Paired Mac · local network")
            } header: {
                // localization-ignore: Debug-only developer copy must stay out of Release.
                Text(verbatim: "Automatic checkups")
            } footer: {
                // localization-ignore: Debug-only developer copy must stay out of Release.
                Text(verbatim:
                    "When this iPhone reaches its paired Mac over the local network, it sends "
                        + "bounded connection evidence automatically. Release builds contain "
                        + "none of this bridge."
                )
            }

            ThemedSettingsSection {
                debugRow("Last upload", value: status.lastUploadAt?.formatted() ?? "Not yet")
                debugRow(
                    "Error screenshots",
                    value: String(MobileDebugIncidentRecorder.shared.retainedIncidentCount)
                )
                if let lastFailureCode = status.lastFailureCode {
                    debugRow("Last failure", value: lastFailureCode)
                }
            } header: {
                // localization-ignore: Debug-only developer copy must stay out of Release.
                Text(verbatim: "Evidence")
            } footer: {
                // localization-ignore: Debug-only developer copy must stay out of Release.
                Text(verbatim:
                    "Screenshots are captured only at error boundaries, kept in a three-image "
                        + "ring, and sent only to the paired owner Mac. Prompts, terminal output, "
                        + "paths, credentials and notification text are not logged."
                )
            }

            ThemedSettingsSection {
                // localization-ignore: Debug-only developer copy must stay out of Release.
                Text(verbatim: "Check up on my iOS app usage.")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            } header: {
                // localization-ignore: Debug-only developer copy must stay out of Release.
                Text(verbatim: "Agent prompt")
            } footer: {
                // localization-ignore: Debug-only developer copy must stay out of Release.
                Text(verbatim: "The agent will say whether it used live or cached phone evidence.")
            }
        }
        .themedSettingsPage(theme)
        // localization-ignore: Debug-only developer copy must stay out of Release.
        .navigationTitle(Text(verbatim: "Debug bridge"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func debugRow(_ title: String, value: String) -> some View {
        HStack {
            Text(verbatim: title)
            Spacer()
            Text(verbatim: value)
                .foregroundStyle(theme.secondaryLabel)
                .multilineTextAlignment(.trailing)
        }
    }
}
#endif
