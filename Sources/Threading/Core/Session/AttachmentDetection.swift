import Foundation

/// The content policy shared by main agents, children, live streams and transcript replay.
/// Only completed assistant prose is a reference. Thinking and tool inputs/results are not.
enum AttachmentDetection {
    static func assistantTexts(in event: StreamEvent) -> [String] {
        switch event {
        case .assistantMessage(let blocks):
            return blocks.compactMap {
                guard case .text(let text) = $0, !text.isEmpty else { return nil }
                return text
            }
        case .turnFinished(let text, _, _):
            return text.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        default:
            return []
        }
    }

    @MainActor
    static func record(
        texts: [String],
        sessionID: SessionID,
        projectRoot: URL,
        context: AttachmentReferenceContext = .main,
        store: SessionAttachmentStore = .shared,
        shouldAdmit: @escaping @MainActor () -> Bool
    ) async {
        guard !texts.isEmpty, shouldAdmit() else { return }
        let resolution = await AttachmentDetectionWorker.shared.resolve(
            texts: texts, projectRoot: projectRoot, currentDirectory: nil
        )
        guard !resolution.isEmpty, !Task.isCancelled else { return }
        _ = await store.recordScanned(
            resolved: resolution, sessionID: sessionID, projectRoot: projectRoot,
            context: context, shouldAdmit: shouldAdmit
        )
    }
}

/// One preparation lane for structured output, regardless of which agent produced it. It reads
/// at most one bounded transcript tail at a time and resolves paths off the main actor.
actor AttachmentDetectionWorker {
    static let shared = AttachmentDetectionWorker()

    struct TranscriptSignature: Equatable, Sendable {
        let url: URL
        let size: Int
        let modifiedAt: Date?
        let projectRoot: URL
        let currentDirectory: URL?
    }

    struct PreparedTranscript: Sendable {
        let resolution: AttachmentReferenceDetector.Resolution
        let signature: TranscriptSignature?
        let didReadTranscript: Bool
    }

    func transcriptReferences(
        at transcript: URL?,
        lookup: TerminalTranscriptAttachmentObserver.TranscriptURLLookup?,
        kind: AgentKind,
        isChild: Bool,
        lastAssistantMessage: String?,
        projectRoot: URL,
        currentDirectory: URL?,
        previousSignature: TranscriptSignature? = nil
    ) -> PreparedTranscript {
        guard !Task.isCancelled else {
            return .init(resolution: .init(), signature: nil, didReadTranscript: false)
        }
        let url = transcript ?? lookup?()
        let signature = url.flatMap { url -> TranscriptSignature? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                return nil
            }
            return .init(url: url, size: values.fileSize ?? 0, modifiedAt: values.contentModificationDate,
                         projectRoot: projectRoot, currentDirectory: currentDirectory)
        }
        if let signature, signature == previousSignature, lastAssistantMessage == nil {
            return .init(resolution: .init(), signature: signature, didReadTranscript: false)
        }
        var texts = url.map {
            TranscriptReplay.latestAssistantTexts(
                at: $0, kind: kind, scanLimit: TranscriptAttachmentDefaults.transcriptScanBytes,
                isChild: isChild
            )
        } ?? []
        if let lastAssistantMessage, !lastAssistantMessage.isEmpty {
            texts.append(lastAssistantMessage)
        }
        return .init(
            resolution: resolve(texts: texts, projectRoot: projectRoot, currentDirectory: currentDirectory),
            signature: signature, didReadTranscript: url != nil
        )
    }

    func resolve(
        texts: [String], projectRoot: URL, currentDirectory: URL?
    ) -> AttachmentReferenceDetector.Resolution {
        guard !texts.isEmpty, !Task.isCancelled else { return .init() }
        // Bound the scan itself, including a single enormous completed assistant message.
        var remaining = TranscriptAttachmentDefaults.transcriptScanBytes
        var parts: [String] = []
        for text in texts.reversed() {
            guard remaining > 1 else { break }
            let bytes = Data(text.utf8.prefix(remaining - 1))
            parts.append(String(decoding: bytes, as: UTF8.self))
            remaining -= bytes.count + 1
        }
        return AttachmentReferenceDetector.resolve(
            text: parts.reversed().joined(separator: "\n"),
            projectRoot: projectRoot, currentDirectory: currentDirectory
        )
    }
}
