import AppKit
import Foundation
import ThreadingRemoteKit

enum DeveloperIssueReportKind: String, Sendable {
    case problem
    case improvement
}

struct DeveloperIssueReportDraft: Equatable, Sendable {
    let kind: DeveloperIssueReportKind
    let title: String
    let details: String

    var description: String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = details.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = ["Kind: \(kind.rawValue)"]
        if !heading.isEmpty { parts.append("Title: \(heading)") }
        if !body.isEmpty { parts.append(body) }
        return parts.joined(separator: "\n\n")
    }
}

enum DeveloperIssueReportComposer {
    static let maximumTitleCharacters = 80

    static func title(fromNote note: String, fallback: String) -> String {
        let firstLine = note
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return fallback }
        guard firstLine.count > maximumTitleCharacters else { return firstLine }
        return String(firstLine.prefix(maximumTitleCharacters)) + "…"
    }

    static func environment(
        info: [String: Any]? = Bundle.main.infoDictionary,
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return L10n.format("Threading %@ (%@) · %@", version, build, operatingSystem)
    }
}

enum DeveloperIssueReportSubmission: Equatable, Sendable {
    case delivered(reference: String)
    case queued
    case failed(message: String)
}

/// The Mac's single route into the private support inbox.
///
/// UI contributes reviewed prose and, for an inspector report, one small screenshot preview.
/// Diagnostics come from the content-free journal and are built at the moment of submission.
@MainActor
struct MacIssueReportSubmitter {
    typealias DiagnosticsProvider = @MainActor () async throws -> PublicIssueReportDiagnosticsDTO

    private let diagnosticsProvider: DiagnosticsProvider
    private let outbox: MacIssueReportOutbox

    init(
        diagnosticsProvider: @escaping DiagnosticsProvider,
        outbox: MacIssueReportOutbox = .shared
    ) {
        self.diagnosticsProvider = diagnosticsProvider
        self.outbox = outbox
    }

    func submit(
        trigger: String,
        draft: DeveloperIssueReportDraft,
        screenshot: NSImage? = nil
    ) async -> DeveloperIssueReportSubmission {
        let description = draft.description.publicReportPrefix(
            maximumUTF8Bytes: PublicIssueReportPolicy.maximumDescriptionBytes
        )
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(message: L10n.string("Write a title or some details first."))
        }

        MacRemoteDiagnostics.record(.issueReportSubmissionStarted, fields: [
            .reason: trigger,
            .surface: "developerInbox",
        ])

        do {
            let preview = try screenshot.map { try Self.previewJPEG(from: $0) }
            let submission = PublicIssueReportSubmissionDTO(
                id: UUID().uuidString.lowercased(),
                createdAt: ISO8601DateFormatter().string(from: Date()),
                trigger: trigger,
                description: description,
                diagnostics: try await diagnosticsProvider(),
                screenshotPreviewBase64: preview?.base64EncodedString(),
                screenshotMediaType: preview == nil ? nil : "image/jpeg"
            )
            guard PublicIssueReportPolicy.accepts(submission) else {
                throw MacIssueReportError.invalidPackage
            }

            switch try await outbox.enqueueAndDeliver(submission) {
            case .delivered(let receipt):
                MacRemoteDiagnostics.record(.issueReportSubmissionSucceeded, fields: [
                    .reason: trigger,
                    .result: "delivered",
                    .surface: "developerInbox",
                ])
                return .delivered(reference: receipt.reference)
            case .queued:
                MacRemoteDiagnostics.record(
                    .issueReportSubmissionDeferred,
                    level: .warning,
                    fields: [
                        .reason: trigger,
                        .result: "queued",
                        .surface: "developerInbox",
                    ]
                )
                return .queued
            }
        } catch {
            MacRemoteDiagnostics.record(
                .issueReportSubmissionFailed,
                level: .error,
                fields: [
                    .reason: trigger,
                    .result: "failed",
                    .surface: "developerInbox",
                ]
            )
            ThreadingLogger.remote.error(
                "Private issue report submission failed: \(String(describing: type(of: error)), privacy: .public)"
            )
            let message = (error as? MacIssueReportError)?.errorDescription
                ?? L10n.string("Threading couldn’t prepare the private report. Nothing was sent.")
            return .failed(message: message)
        }
    }

    private static func previewJPEG(from image: NSImage) throws -> Data {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > 0 else { throw MacIssueReportError.screenshotEncoding }

        for dimension: CGFloat in [480, 400, 320, 260, 220] {
            let scale = min(1, dimension / longestSide)
            let size = NSSize(
                width: max(1, floor(image.size.width * scale)),
                height: max(1, floor(image.size.height * scale))
            )
            let resized = NSImage(size: size)
            resized.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(
                in: NSRect(origin: .zero, size: size),
                from: NSRect(origin: .zero, size: image.size),
                operation: .copy,
                fraction: 1
            )
            resized.unlockFocus()
            guard let tiff = resized.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { continue }
            for quality in [0.55, 0.42, 0.32, 0.24, 0.18] {
                if let data = bitmap.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: quality]
                ), data.count <= PublicIssueReportPolicy.maximumScreenshotPreviewBytes {
                    return data
                }
            }
        }
        throw MacIssueReportError.screenshotEncoding
    }
}

enum MacIssueReportDeliveryResult: Sendable {
    case delivered(PublicIssueReportReceiptDTO)
    case queued
}

enum MacIssueReportError: LocalizedError {
    case invalidPackage
    case outboxFull
    case screenshotEncoding
    case unreadableResponse
    case serviceRejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            return L10n.string("The report did not pass Threading’s privacy checks.")
        case .outboxFull:
            return L10n.string("The private report outbox is full.")
        case .screenshotEncoding:
            return L10n.string("The screenshot could not be made safe for upload.")
        case .unreadableResponse:
            return L10n.string("The report service returned an unreadable response.")
        case .serviceRejected(let status):
            return L10n.format("The report service refused the request (%lld).", status)
        }
    }

    var shouldRemainQueued: Bool {
        switch self {
        case .serviceRejected(let status):
            return status == 408 || status == 429 || status >= 500
        default:
            return false
        }
    }
}

/// A bounded disk handoff makes a lost response safe: the next attempt uses the same UUID and the
/// server returns the first receipt. Nothing in this directory is ever opened as instructions.
actor MacIssueReportOutbox {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let shared = MacIssueReportOutbox()

    private static let maximumPendingReports = 20
    private static let maximumDirectoryEntries = maximumPendingReports * 4
    private let directory: URL
    private let endpoint: URL
    private let transport: Transport
    private var activeReportIDs: Set<String> = []

    init(
        directory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("IssueReports", isDirectory: true)
            .appendingPathComponent("Outbox", isDirectory: true),
        endpoint: URL? = nil,
        transport: Transport? = nil
    ) {
        self.directory = directory
        self.endpoint = endpoint
            ?? (Bundle.main.object(forInfoDictionaryKey: "ThreadingReportIntakeURL") as? String)
                .flatMap(URL.init(string:))
            ?? URL(string: "https://remote.threading.codes/v1/reports")!
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MacIssueReportError.unreadableResponse
            }
            return (data, http)
        }
    }

    func enqueueAndDeliver(
        _ submission: PublicIssueReportSubmissionDTO
    ) async throws -> MacIssueReportDeliveryResult {
        guard PublicIssueReportPolicy.accepts(submission) else {
            throw MacIssueReportError.invalidPackage
        }
        try prepareDirectory()
        let destination = fileURL(for: submission.id)
        guard try pendingURLs().count < Self.maximumPendingReports
                || FileManager.default.fileExists(atPath: destination.path) else {
            throw MacIssueReportError.outboxFull
        }
        try JSONEncoder().encode(submission).write(to: destination, options: .atomic)

        do {
            guard let receipt = try await deliverExclusively(submission) else { return .queued }
            try? FileManager.default.removeItem(at: destination)
            return .delivered(receipt)
        } catch let error as MacIssueReportError where error.shouldRemainQueued {
            return .queued
        } catch is URLError {
            return .queued
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func flush() async {
        do {
            try prepareDirectory()
            for url in try pendingURLs() {
                guard let submission = PublicIssueReportPolicy.submission(at: url) else {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                do {
                    guard try await deliverExclusively(submission) != nil else { continue }
                    try? FileManager.default.removeItem(at: url)
                } catch let error as MacIssueReportError where !error.shouldRemainQueued {
                    try? FileManager.default.removeItem(at: url)
                } catch {
                    return
                }
            }
        } catch {
            ThreadingLogger.remote.error(
                "Private issue report outbox flush failed: \(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }

    private func deliverExclusively(
        _ submission: PublicIssueReportSubmissionDTO
    ) async throws -> PublicIssueReportReceiptDTO? {
        guard activeReportIDs.insert(submission.id).inserted else { return nil }
        defer { activeReportIDs.remove(submission.id) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(submission)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(submission.id, forHTTPHeaderField: "Idempotency-Key")

        let (data, http) = try await transport(request)
        guard (200...299).contains(http.statusCode) else {
            throw MacIssueReportError.serviceRejected(http.statusCode)
        }
        let receipt = try JSONDecoder().decode(PublicIssueReportReceiptDTO.self, from: data)
        guard receipt.reportID == submission.id else {
            throw MacIssueReportError.unreadableResponse
        }
        return receipt
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func pendingURLs() throws -> [URL] {
        let urls: [URL]
        do {
            urls = try RemoteBoundedDirectoryReader.shallowContents(
                of: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                maximumEntries: Self.maximumDirectoryEntries
            )
        } catch RemoteDirectoryEnumerationError.entryLimitExceeded {
            throw MacIssueReportError.outboxFull
        }
        return urls.filter { url in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                  ]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(Self.maximumPendingReports)
        .map { $0 }
    }

    private func fileURL(for reportID: String) -> URL {
        directory.appendingPathComponent("\(reportID).json")
    }
}

private extension String {
    func publicReportPrefix(maximumUTF8Bytes: Int) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maximumUTF8Bytes else { return trimmed }
        var end = trimmed.startIndex
        var used = 0
        while end < trimmed.endIndex {
            let next = trimmed.index(after: end)
            let bytes = trimmed[end..<next].utf8.count
            guard used + bytes <= maximumUTF8Bytes else { break }
            used += bytes
            end = next
        }
        return String(trimmed[..<end])
    }
}
