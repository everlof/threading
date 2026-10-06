import CryptoKit
import Foundation
import ImageIO
import ThreadingRemoteKit
import UniformTypeIdentifiers

enum AgentProblemReportPolicy {
    static let maximumImageBytes = 8 * 1_024 * 1_024
    static let maximumPathBytes = 4_096
    static let maximumReportsPerHour = 10
    static let rateWindow: TimeInterval = 3_600
    static let identityNamespace = "threading-agent-problem-v1"
}

struct AgentProblemReportReceipt: Codable, Sendable {
    enum Status: String, Codable, Sendable { case delivered, queued, saved, failed }

    let status: Status
    let reportID: String
    let reference: String?
    let recordPath: String?
    let duplicate: Bool
    let message: String

    private enum CodingKeys: String, CodingKey {
        case status, reference, duplicate, message
        case reportID = "report_id"
        case recordPath = "record_path"
    }
}

enum AgentProblemReportRefusal: Error, Sendable {
    case missingDescription
    case titleTooLong
    case reportTooLarge
    case tooManyImages
    case invalidImagePath
    case remoteImages
    case unreadableImage
    case busy
    case rateLimited
    case preparationFailed

    var message: String {
        switch self {
        case .missingDescription: return "Provide a nonempty title and description of the Threading problem."
        case .titleTooLong: return "The report title must be at most 80 characters."
        case .reportTooLarge: return "The complete report must fit 10240 UTF-8 bytes. Shorten the report and its evidence."
        case .tooManyImages: return "A report can attach at most four images."
        case .invalidImagePath: return "image_paths must contain absolute local file paths, each at most 4096 UTF-8 bytes."
        case .remoteImages: return "A remote-host session cannot attach image_paths on the Mac. Include sanitized text evidence instead."
        case .unreadableImage: return "An attachment is not a readable, bounded PNG/JPEG image of at most 8 MiB. Nothing was filed."
        case .busy: return "Another agent report is being prepared or delivered. Retry after it finishes. Nothing was filed by this call."
        case .rateLimited: return "Threading accepts at most ten new agent reports per hour. This call filed nothing; report each defect once."
        case .preparationFailed: return "Threading could not prepare the report. Nothing was filed."
        }
    }
}

/// The agent route shares Help's submitter and outbox, but never reads a conversation or takes
/// a screenshot. One admission bounds all worker work; ten timestamps bound the rate ledger.
@MainActor
final class AgentProblemReportService {
    private let submitter: MacIssueReportSubmitter
    private let environment: String
    private let now: () -> Date
    private var isSubmitting = false
    private var submissions: [Date] = []

    init(
        submitter: MacIssueReportSubmitter,
        environment: String = DeveloperIssueReportComposer.environment(),
        now: @escaping () -> Date = Date.init
    ) {
        self.submitter = submitter
        self.environment = environment
        self.now = now
    }

    func report(
        _ arguments: ReportProblemArguments,
        for sessionID: SessionID,
        isRemote: Bool = false
    ) async -> Result<AgentProblemReportReceipt, AgentProblemReportRefusal> {
        let draft: DeveloperIssueReportDraft
        do {
            draft = try compose(arguments, isRemote: isRemote)
        } catch let refusal as AgentProblemReportRefusal {
            return .failure(refusal)
        } catch {
            return .failure(.preparationFailed)
        }

        guard !isSubmitting else { return .failure(.busy) }
        isSubmitting = true
        defer { isSubmitting = false }

        let prepared: PreparedAgentProblemReport
        do {
            prepared = try await Task.detached(priority: .utility) {
                try PreparedAgentProblemReport.prepare(
                    draft: draft, sessionID: sessionID, imagePaths: arguments.imagePaths ?? []
                )
            }.value
        } catch let refusal as AgentProblemReportRefusal {
            return .failure(refusal)
        } catch {
            return .failure(.preparationFailed)
        }

        let result = await submit(prepared)
        await Task.detached(priority: .utility) { prepared.removeTemporaryFiles() }.value
        return result
    }

    private func compose(
        _ arguments: ReportProblemArguments, isRemote: Bool
    ) throws -> DeveloperIssueReportDraft {
        let fields = [arguments.title, arguments.description, arguments.reproductionSteps,
                      arguments.expectedBehavior, arguments.actualBehavior, arguments.evidence]
        let inputBytes = fields.compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
        guard inputBytes <= PublicIssueReportPolicy.maximumDescriptionBytes else {
            throw AgentProblemReportRefusal.reportTooLarge
        }
        let title = arguments.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = arguments.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, !description.isEmpty else { throw AgentProblemReportRefusal.missingDescription }
        guard title.count <= DeveloperIssueReportComposer.maximumTitleCharacters else {
            throw AgentProblemReportRefusal.titleTooLong
        }

        let paths = arguments.imagePaths ?? []
        guard paths.count <= PublicIssueReportPolicy.maximumImagePreviewCount else {
            throw AgentProblemReportRefusal.tooManyImages
        }
        guard !isRemote || paths.isEmpty else { throw AgentProblemReportRefusal.remoteImages }
        guard paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= AgentProblemReportPolicy.maximumPathBytes }) else {
            throw AgentProblemReportRefusal.invalidImagePath
        }

        var parts = ["Reported by an agent through Threading MCP.", description]
        for (heading, text) in [
            ("Reproduction steps", arguments.reproductionSteps),
            ("Expected behavior", arguments.expectedBehavior),
            ("Actual behavior", arguments.actualBehavior),
            ("Evidence", arguments.evidence),
        ] {
            let content = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !content.isEmpty { parts.append("### \(heading)\n\n\(content)") }
        }
        parts.append("### Environment\n\n\(environment)")
        let draft = DeveloperIssueReportDraft(kind: .problem, title: title, details: parts.joined(separator: "\n\n"))
        guard draft.description.utf8.count <= PublicIssueReportPolicy.maximumDescriptionBytes else {
            throw AgentProblemReportRefusal.reportTooLarge
        }
        return draft
    }

    private func submit(
        _ report: PreparedAgentProblemReport
    ) async -> Result<AgentProblemReportReceipt, AgentProblemReportRefusal> {
        if let previous = await submitter.previousSubmission(for: report.id) {
            return .success(receipt(for: report.id, outcome: previous, duplicate: true, recordExists: true))
        }
        let date = now()
        submissions.removeAll { date.timeIntervalSince($0) >= AgentProblemReportPolicy.rateWindow }
        guard submissions.count < AgentProblemReportPolicy.maximumReportsPerHour else {
            return .failure(.rateLimited)
        }
        submissions.append(date)
        let outcome = await submitter.submit(trigger: .manual, draft: report.draft, reportID: report.id)
        let stored = await submitter.previousSubmission(for: report.id)
        return .success(receipt(for: report.id, outcome: outcome, duplicate: false, recordExists: stored != nil))
    }

    private func receipt(
        for id: UUID, outcome: DeveloperIssueReportSubmission, duplicate: Bool, recordExists: Bool
    ) -> AgentProblemReportReceipt {
        let status: AgentProblemReportReceipt.Status
        let reference: String?
        let message: String
        switch outcome {
        case .delivered(let value):
            status = .delivered
            reference = value
            message = "Threading's private support inbox received the report."
        case .queued:
            status = .queued
            reference = nil
            message = "The report is saved locally and queued for delivery. Delivery has not been confirmed."
        case .saved:
            status = .saved
            reference = nil
            message = "The report is saved locally. Delivery to the developer has not been confirmed."
        case .failed:
            status = .failed
            reference = nil
            message = recordExists
                ? "The report remains saved locally, but Threading could not confirm delivery."
                : "Threading could not save the report. Delivery has not been confirmed."
        }
        return AgentProblemReportReceipt(
            status: status, reportID: id.uuidString.lowercased(), reference: reference,
            recordPath: recordExists ? submitter.recordLocation(for: id).path : nil,
            duplicate: duplicate, message: message
        )
    }
}

/// Worker-only image reads, validation, hashing and snapshots. At most four 8 MiB originals are
/// processed sequentially; the submitter sees frozen files rather than paths that may grow.
private struct PreparedAgentProblemReport: Sendable {
    let id: UUID
    let draft: DeveloperIssueReportDraft
    let temporaryDirectory: URL?

    static func prepare(
        draft: DeveloperIssueReportDraft, sessionID: SessionID, imagePaths: [String]
    ) throws -> Self {
        let directory = imagePaths.isEmpty ? nil : FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-agent-report-\(UUID().uuidString)", isDirectory: true)
        var completed = false
        defer { if !completed, let directory { try? FileManager.default.removeItem(at: directory) } }
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var hash = SHA256()
        let identity = [AgentProblemReportPolicy.identityNamespace, sessionID.uuidString, draft.title, draft.details]
        hash.update(data: try JSONEncoder().encode(identity))
        var attachments: [URL] = []
        let policy = BoundedImageDecodePolicy(
            maximumBytes: AgentProblemReportPolicy.maximumImageBytes,
            maximumSourcePixelDimension: BoundedImageDecodePolicy.issueReportPreview.maximumSourcePixelDimension,
            maximumSourcePixelCount: BoundedImageDecodePolicy.issueReportPreview.maximumSourcePixelCount,
            maximumRenderedPixelDimension: BoundedImageDecodePolicy.issueReportPreview.maximumRenderedPixelDimension
        )
        for (index, path) in imagePaths.enumerated() {
            guard let data = try? BoundedFileReader.read(URL(fileURLWithPath: path), maximumBytes: policy.maximumBytes),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  type == UTType.png.identifier || type == UTType.jpeg.identifier,
                  BoundedImageDecoder.thumbnailFrame(data, policy: policy) != nil,
                  let directory else { throw AgentProblemReportRefusal.unreadableImage }
            hash.update(data: Data(SHA256.hash(data: data)))
            let fileExtension = type == UTType.png.identifier ? "png" : "jpg"
            let url = directory.appendingPathComponent("image-\(index).\(fileExtension)")
            try data.write(to: url, options: .atomic)
            attachments.append(url)
        }

        // UUID version 8 carries a SHA-256-derived identity; RFC variant bits remain fixed.
        var bytes = Array(hash.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let groups = [0..<4, 4..<6, 6..<8, 8..<10, 10..<16]
        let name = groups.map { range in bytes[range].map { String(format: "%02x", $0) }.joined() }.joined(separator: "-")
        guard let id = UUID(uuidString: name) else { throw AgentProblemReportRefusal.preparationFailed }
        completed = true
        return Self(
            id: id,
            draft: DeveloperIssueReportDraft(kind: draft.kind, title: draft.title, details: draft.details, attachmentURLs: attachments),
            temporaryDirectory: directory
        )
    }

    func removeTemporaryFiles() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}
