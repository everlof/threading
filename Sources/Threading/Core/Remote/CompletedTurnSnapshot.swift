import Foundation

/// The only final-response text notification delivery is allowed to inspect.
///
/// Providers capture this value at their own completed-turn boundary. Delivery never reads a
/// transcript, terminal screen, or model-generated summary. The retained prefix is process-local
/// and bounded before it enters the store.
struct CompletedTurnSnapshot: Equatable, Sendable {
    let sessionID: SessionID
    let generation: UInt64
    let finalAssistantText: String?
}

@MainActor
protocol CompletedTurnSnapshotProviding: AnyObject {
    func snapshot(sessionID: SessionID, generation: UInt64) -> CompletedTurnSnapshot?
}

/// Provider-neutral, bounded, in-memory handoff between lifecycle capture and notification
/// delivery. One value per live session makes lookup O(1) and prevents transcript cardinality
/// from entering the delivery path.
@MainActor
final class CompletedTurnSnapshotStore: CompletedTurnSnapshotProviding {
    static let shared = CompletedTurnSnapshotStore()

    /// The store is process-local support state, not a transcript cache. If an abnormal runtime
    /// leaves more sessions behind than the app can legitimately keep live, evicting the oldest
    /// generation makes its pending completion fail closed to no notification.
    static let maximumTrackedSessions = 256

    private struct State {
        var generation: UInt64 = 0
        var snapshot: CompletedTurnSnapshot?
    }

    static let maximumCapturedUTF8Bytes = 64 * 1_024
    private var states: [SessionID: State] = [:]
    /// Allocated across the process rather than inside each session. Removing a session must not
    /// let an old accepted delivery and a later incarnation of that session share generation 1.
    private var lastAllocatedGeneration: UInt64 = 0

    var trackedSessionCount: Int { states.count }

    @discardableResult
    func beginTurn(sessionID: SessionID) -> UInt64 {
        admit(sessionID)
        let generation = allocateGeneration()
        states[sessionID] = State(generation: generation, snapshot: nil)
        return generation
    }

    func captureCompletedTurn(
        sessionID: SessionID,
        finalAssistantText: String?,
        isReliable: Bool = true
    ) {
        admit(sessionID)
        var state = states[sessionID]
            ?? State(generation: allocateGeneration(), snapshot: nil)
        let bounded = isReliable
            ? finalAssistantText.flatMap(Self.boundedPrefix)
            : nil
        state.snapshot = CompletedTurnSnapshot(
            sessionID: sessionID,
            generation: state.generation,
            finalAssistantText: bounded
        )
        states[sessionID] = state
    }

    func currentGeneration(sessionID: SessionID) -> UInt64 {
        states[sessionID]?.generation ?? 0
    }

    func snapshot(sessionID: SessionID, generation: UInt64) -> CompletedTurnSnapshot? {
        guard let state = states[sessionID], state.generation == generation else { return nil }
        return state.snapshot
    }

    func remove(sessionID: SessionID) {
        states[sessionID] = nil
    }

    private func admit(_ sessionID: SessionID) {
        guard states[sessionID] == nil,
              states.count >= Self.maximumTrackedSessions,
              let oldest = states.min(by: { $0.value.generation < $1.value.generation })?.key
        else { return }
        states[oldest] = nil
    }

    private func allocateGeneration() -> UInt64 {
        // At one allocation per nanosecond this takes more than five centuries. Trapping is safer
        // than silently creating an ABA token if the invariant is ever violated by corrupted
        // process state.
        precondition(lastAllocatedGeneration < .max, "turn generation space exhausted")
        lastAllocatedGeneration += 1
        return lastAllocatedGeneration
    }

    private static func boundedPrefix(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard text.utf8.count > maximumCapturedUTF8Bytes else { return text }
        var bytes = text.utf8.prefix(maximumCapturedUTF8Bytes)
        while String(bytes: bytes, encoding: .utf8) == nil, !bytes.isEmpty {
            bytes = bytes.dropLast()
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

/// Produces consented lock-screen copy from a captured final response.
enum TurnCompletionPreviewFormatter {
    static let maximumUTF8Bytes = 320

    static func preview(from text: String?) -> String? {
        guard let text else { return nil }
        let cleanedLines = lines(from: text)

        var paragraph: [String] = []
        var usefulLines: [String] = []
        var insideFence = false
        for original in cleanedLines {
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            if isFence(trimmed) {
                insideFence.toggle()
                if !paragraph.isEmpty { break }
                continue
            }
            guard !insideFence else { continue }
            let clean = stripMarkdown(from: trimmed)
            if clean.isEmpty {
                if !paragraph.isEmpty { break }
            } else {
                usefulLines.append(clean)
                paragraph.append(clean)
            }
        }

        let candidate = paragraph.isEmpty
            ? usefulLines.first
            : paragraph.joined(separator: " ")
        guard let candidate else { return nil }
        let collapsed = collapseWhitespace(removeUnsafeScalars(candidate))
        guard !collapsed.isEmpty else { return nil }
        return truncateAtWordBoundary(collapsed, maximumBytes: maximumUTF8Bytes)
    }

    private static func lines(from value: String) -> [String] {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func isFence(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    private static func stripMarkdown(from value: String) -> String {
        var result = removeUnsafeScalars(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, !isFence(result) else { return "" }

        result = replacing(
            #"!?(?:\[)([^\]]+)(?:\])\([^\)]*\)"#,
            in: result,
            with: "$1"
        )
        result = replacing(#"<[^>]+>"#, in: result, with: " ")
        result = replacing(#"^\s{0,3}(?:#{1,6}\s+|>\s*|[-+*]\s+|\d+[.)]\s+)"#,
                           in: result, with: "")
        result = replacing(#"^\s*[-*_]{3,}\s*$"#, in: result, with: "")
        for pattern in [
            #"\*\*([^*]+)\*\*"#, #"__([^_]+)__"#, #"~~([^~]+)~~"#,
            #"\*([^*]+)\*"#, #"_([^_]+)_"#,
        ] {
            result = replacing(pattern, in: result, with: "$1")
        }
        result = result.replacingOccurrences(of: "`", with: "")
        return collapseWhitespace(result)
    }

    private static func replacing(
        _ pattern: String,
        in value: String,
        with template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: template
        )
    }

    private static func removeUnsafeScalars(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            if scalar.value == 0x0A || scalar.value == 0x09 { return true }
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            return !isBidirectionalFormatting(scalar.value)
        })
    }

    private static func isBidirectionalFormatting(_ value: UInt32) -> Bool {
        switch value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func truncateAtWordBoundary(
        _ value: String,
        maximumBytes: Int
    ) -> String? {
        guard value.utf8.count > maximumBytes else { return value }
        let marker = "…"
        let available = maximumBytes - marker.utf8.count
        var result = ""
        for word in value.split(separator: " ") {
            let candidate = result.isEmpty ? String(word) : result + " " + word
            guard candidate.utf8.count <= available else { break }
            result = candidate
        }
        guard !result.isEmpty else { return nil }
        return result + marker
    }
}
