import AppKit
import Foundation
import ThreadingRemoteKit

enum DeveloperIssueReportKind: String, Sendable {
    case problem
    case improvement
}

struct DeveloperIssueReportDraft: Equatable, Sendable {

    /// The same report as it reads to someone standing on **this machine**, which is a different
    /// document from the one that may be sent.
    ///
    /// `details` above is reviewed prose with the capture's path stripped, because a temporary
    /// file here means nothing to an intake service. A path is also the one form of a picture an
    /// agent can act on, and the local record is read by exactly that: a person in Finder, or an
    /// agent with `cat`. So both readings are kept, and only one of them is ever encoded.
    struct Local: Equatable, Sendable {
        let details: String
        let screenshotURL: URL?
    }

    let kind: DeveloperIssueReportKind
    let title: String
    let details: String
    let local: Local?

    init(
        kind: DeveloperIssueReportKind,
        title: String,
        details: String,
        local: Local? = nil
    ) {
        self.kind = kind
        self.title = title
        self.details = details
        self.local = local
    }

    /// The record as a reader opens it: a heading, what kind of report it is and when, then the
    /// whole capture with its screenshot path intact. Markdown because the reader is as likely to
    /// be an agent as a person, and neither of them should need a decoder to triage a folder.
    func recordMarkdown(createdAt: String) -> String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (local?.details ?? details)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !heading.isEmpty { parts.append("# \(heading)") }
        parts.append("\(kind.rawValue) · \(createdAt)")
        if !body.isEmpty { parts.append(body) }
        return parts.joined(separator: "\n\n") + "\n"
    }

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

    /// Written to the outbox, with nothing configured to send it to — the ordinary outcome for a
    /// build whose intake endpoint was never stated. Distinct from `queued`, which is a report
    /// that *is* addressed to a service and did not reach it: promising a retry that no
    /// configuration can ever perform is how two reports once sat on disk for two days while the
    /// sheet said they were on their way.
    case saved(records: Int)

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

        // The record is written first and unconditionally, and nothing below this line can lose
        // it: the bounded package is a *projection* of the report for a service that has an
        // opinion about size, while this is the report. A capture too large to send is still a
        // capture worth keeping.
        let id = UUID().uuidString.lowercased()
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let record = MacIssueReportRecord(
            id: id,
            markdown: draft.recordMarkdown(createdAt: createdAt),
            screenshotURL: draft.local?.screenshotURL
        )

        do {
            let saved = try await outbox.save(record)

            // No endpoint means no attempt, rather than an attempt that cannot succeed. The
            // package is not even built: a preview downscaled for a service nobody stated is
            // work done for nothing, and a status line promising a retry would be a lie the
            // configuration can never make true.
            guard await outbox.isDeliveryConfigured else {
                MacRemoteDiagnostics.record(.issueReportSubmissionDeferred, fields: [
                    .reason: trigger,
                    .result: "saved",
                    .surface: "developerInbox",
                ])
                return .saved(records: saved)
            }

            let preview = try screenshot.map { try Self.previewJPEG(from: $0) }
            let submission = PublicIssueReportSubmissionDTO(
                id: id,
                createdAt: createdAt,
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
            case .saved(let records):
                MacRemoteDiagnostics.record(.issueReportSubmissionDeferred, fields: [
                    .reason: trigger,
                    .result: "saved",
                    .surface: "developerInbox",
                ])
                return .saved(records: records)
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
    case saved(records: Int)
}

/// What a report leaves on this machine: the whole capture as prose, and the picture at the size
/// it was taken.
///
/// Deliberately not the wire package's shape. That one is bounded because an intake service is
/// entitled to an opinion about size; this one is read by a person in Finder or an agent with
/// `cat`, neither of whom is helped by a 480-point JPEG of the interface they are trying to
/// review. A UI defect is often a few pixels, and downscaling it away is the one thing the record
/// must not do.
struct MacIssueReportRecord: Sendable {
    let id: String
    let markdown: String
    let screenshotURL: URL?
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

/// Where a report is written before anything is sent, and what is left behind afterwards.
///
/// Two directories, because they answer different questions.
///
/// `Outbox/<id>/` is the **record**: the report as it reads to someone standing on this machine,
/// the capture beside it at the size it was taken, and the receipt once there is one. Delivery
/// never deletes it, and nothing here reads the folder as a whole beyond counting it for a status
/// line — a person opens it in Finder, an agent reads it with `cat`. It therefore has no count
/// bound: filing a hundred of these and having an agent triage them is the point, not an abuse of
/// the feature.
///
/// `Pending/<id>.json` is the **delivery queue**: the bounded wire package, present only while
/// there is an endpoint to send it to and it has not arrived. It keeps the old guarantee that a
/// lost response is safe, because the next attempt uses the same UUID and the service returns the
/// first receipt.
///
/// Nothing in either directory is ever opened as instructions.
actor MacIssueReportOutbox {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let shared = MacIssueReportOutbox()

    /// The delivery queue's bound. Only reports actually addressed to a service are counted by
    /// it, which is why it can be generous: the common case on a developer's machine is that
    /// nothing is configured and nothing is ever queued.
    private static let maximumPendingReports = 500
    private static let maximumDirectoryEntries = maximumPendingReports * 4

    /// How far the record folder is counted before the count stops being exact. The number is a
    /// courtesy in a status line rather than a fact anything depends on, and an unbounded
    /// directory walk to make it exact would be the one place this design scans the archive.
    private static let maximumCountedRecords = 999

    private static let recordsDirectoryName = "Outbox"
    private static let pendingDirectoryName = "Pending"
    private static let recordMarkdownName = "report.md"
    private static let recordSubmissionName = "submission.json"
    private static let recordReceiptName = "receipt.json"
    private static let recordScreenshotName = "screenshot"
    private static let defaultScreenshotExtension = "png"

    private let directory: URL
    private let endpoint: URL?
    private let transport: Transport
    private var activeReportIDs: Set<String> = []
    private var hasMigratedLooseRecords = false

    private var recordsDirectory: URL {
        directory.appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
    }

    private var pendingDirectory: URL {
        directory.appendingPathComponent(Self.pendingDirectoryName, isDirectory: true)
    }

    /// Whether this build has somewhere to send a report.
    ///
    /// **A configured endpoint, not a compiled-in default.** There is deliberately no fallback
    /// URL: a build that never stated an intake has nowhere to send to, and saying so is the
    /// whole difference between an outbox and a promise. `./dev` states the loopback intake and
    /// a shipping build states its own through Info.plist, so the two configurations that mean
    /// to deliver both do, and the everyday developer build stops pretending it does.
    var isDeliveryConfigured: Bool { endpoint != nil }

    /// The same question asked before there is an actor to ask, because a **button title**
    /// depends on it and a title resolved one hop later is a control that renames itself after
    /// the sheet is already on screen. Reads the two sources the shared instance reads, so the
    /// answer cannot disagree with what the outbox will then do.
    nonisolated static var isDeliveryConfigured: Bool { configuredEndpoint() != nil }

    nonisolated static func configuredEndpoint(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL? {
        #if DEBUG
        let developmentEndpoint = environment["THREADING_REPORT_INTAKE_URL"]
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
        #else
        let developmentEndpoint: URL? = nil
        #endif
        return developmentEndpoint
            ?? (infoDictionary?["ThreadingReportIntakeURL"] as? String)
                .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    init(
        directory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("IssueReports", isDirectory: true),
        endpoint: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        transport: Transport? = nil
    ) {
        self.directory = directory
        self.endpoint = endpoint
            ?? Self.configuredEndpoint(environment: environment, infoDictionary: infoDictionary)
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MacIssueReportError.unreadableResponse
            }
            return (data, http)
        }
    }

    // MARK: - The Record

    /// Writes one report to disk and answers how many are now there.
    ///
    /// Throws only when the report itself cannot be written. A missing capture does not: the
    /// prose is the report and the picture is evidence beside it, and losing the whole filing
    /// because a temporary file was swept is the wrong trade.
    @discardableResult
    func save(_ record: MacIssueReportRecord) throws -> Int {
        try prepareDirectories()
        migrateLooseRecordsIfNeeded()

        let folder = recordFolder(for: record.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(record.markdown.utf8).write(
            to: folder.appendingPathComponent(Self.recordMarkdownName),
            options: .atomic
        )

        if let source = record.screenshotURL {
            let name = source.pathExtension.isEmpty
                ? Self.defaultScreenshotExtension
                : source.pathExtension
            let destination = folder
                .appendingPathComponent(Self.recordScreenshotName)
                .appendingPathExtension(name)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: source, to: destination)
        }

        return recordCount()
    }

    /// The folder a person is sent to, and an agent is pointed at.
    nonisolated var recordsLocation: URL {
        directory.appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
    }

    // MARK: - Delivery

    func enqueueAndDeliver(
        _ submission: PublicIssueReportSubmissionDTO
    ) async throws -> MacIssueReportDeliveryResult {
        guard PublicIssueReportPolicy.accepts(submission) else {
            throw MacIssueReportError.invalidPackage
        }
        try prepareDirectories()
        migrateLooseRecordsIfNeeded()
        guard endpoint != nil else { return .saved(records: recordCount()) }

        let destination = pendingURL(for: submission.id)
        guard try pendingURLs().count < Self.maximumPendingReports
                || FileManager.default.fileExists(atPath: destination.path) else {
            throw MacIssueReportError.outboxFull
        }
        try JSONEncoder().encode(submission).write(to: destination, options: .atomic)

        do {
            guard let receipt = try await deliverExclusively(submission) else { return .queued }
            complete(submission.id, with: receipt)
            return .delivered(receipt)
        } catch let error as MacIssueReportError where error.shouldRemainQueued {
            return .queued
        } catch is URLError {
            return .queued
        } catch {
            // The package was refused rather than undelivered, so retrying it changes nothing.
            // The *record* stays: what was wrong is the projection, not the report.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func flush() async {
        guard endpoint != nil else { return }
        do {
            try prepareDirectories()
            migrateLooseRecordsIfNeeded()
            for url in try pendingURLs() {
                guard let submission = PublicIssueReportPolicy.submission(at: url) else {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                do {
                    guard let receipt = try await deliverExclusively(submission) else { continue }
                    complete(submission.id, with: receipt)
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
        guard let endpoint else { return nil }
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

    /// A delivered report leaves the queue and keeps its record, gaining the package that was
    /// sent and the receipt that came back. Delivery is the end of the *queue* entry, not of the
    /// report: the archive is what the author reads afterwards.
    private func complete(_ id: String, with receipt: PublicIssueReportReceiptDTO) {
        let folder = recordFolder(for: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let submission = folder.appendingPathComponent(Self.recordSubmissionName)
        try? FileManager.default.removeItem(at: submission)
        try? FileManager.default.moveItem(at: pendingURL(for: id), to: submission)

        if let encoded = try? JSONEncoder().encode(receipt) {
            try? encoded.write(
                to: folder.appendingPathComponent(Self.recordReceiptName),
                options: .atomic
            )
        }
        try? FileManager.default.removeItem(at: pendingURL(for: id))
    }

    // MARK: - Storage

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: recordsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: pendingDirectory,
            withIntermediateDirectories: true
        )
    }

    /// The first shape this directory had was one loose `<id>.json` per undelivered report, which
    /// is the queue and the archive in one place. Those files are real reports somebody filed, so
    /// they are converted rather than left behind — and re-queued only if this build has an
    /// endpoint, because a report filed against a service that was never configured is a note to
    /// its author rather than mail.
    private func migrateLooseRecordsIfNeeded() {
        guard !hasMigratedLooseRecords else { return }
        hasMigratedLooseRecords = true

        let loose: [URL]
        do {
            loose = try RemoteBoundedDirectoryReader.shallowContents(
                of: recordsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                maximumEntries: Self.maximumDirectoryEntries
            ).filter { $0.pathExtension == "json" }
        } catch {
            return
        }

        for url in loose {
            let id = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil,
                  let submission = PublicIssueReportPolicy.submission(at: url) else { continue }

            let folder = recordFolder(for: id)
            guard (try? FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )) != nil else { continue }

            let markdown = DeveloperIssueReportDraft(
                kind: .problem,
                title: "",
                details: submission.description
            ).recordMarkdown(createdAt: submission.createdAt)
            try? Data(markdown.utf8).write(
                to: folder.appendingPathComponent(Self.recordMarkdownName),
                options: .atomic
            )

            if endpoint != nil, let encoded = try? JSONEncoder().encode(submission) {
                try? encoded.write(to: pendingURL(for: id), options: .atomic)
            }
            try? FileManager.default.moveItem(
                at: url,
                to: folder.appendingPathComponent(Self.recordSubmissionName)
            )
        }
    }

    private func pendingURLs() throws -> [URL] {
        let urls: [URL]
        do {
            urls = try RemoteBoundedDirectoryReader.shallowContents(
                of: pendingDirectory,
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

    /// Bounded on purpose, and inexact past its bound: see `maximumCountedRecords`.
    func recordCount() -> Int {
        do {
            return try RemoteBoundedDirectoryReader.shallowContents(
                of: recordsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                maximumEntries: Self.maximumCountedRecords
            ).count
        } catch RemoteDirectoryEnumerationError.entryLimitExceeded {
            return Self.maximumCountedRecords
        } catch {
            return 0
        }
    }

    private func recordFolder(for reportID: String) -> URL {
        recordsDirectory.appendingPathComponent(reportID, isDirectory: true)
    }

    private func pendingURL(for reportID: String) -> URL {
        pendingDirectory.appendingPathComponent("\(reportID).json")
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
