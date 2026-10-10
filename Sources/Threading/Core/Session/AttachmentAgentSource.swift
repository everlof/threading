import Foundation

/// A provider-neutral reference owner. A nil thread identifies the main agent; child identities
/// come from the session's canonical subagent timeline, never from a filename or display name.
struct AttachmentAgentSource: Codable, Equatable, Sendable {
    let threadID: String?
    let name: String?

    static let main = AttachmentAgentSource(threadID: nil, name: nil)
    static let maximumChildren = 64
    static let maximumNameScalars = 160

    init(threadID: String?, name: String?) {
        self.threadID = threadID
        self.name = name.map { String($0.unicodeScalars.prefix(Self.maximumNameScalars)) }
    }

    static func merged(_ older: [Self], _ newer: [Self]) -> [Self] {
        var children: [Self] = []
        var seen: Set<String> = []
        let all = older + newer
        for source in all.reversed() {
            guard let id = source.threadID, seen.insert(id).inserted else { continue }
            children.append(source)
            if children.count == maximumChildren { break }
        }
        return (all.contains { $0.threadID == nil } ? [.main] : []) + children.reversed()
    }
}

/// Attribution travels with the scan, including when a refused outside path is admitted later.
struct AttachmentReferenceContext: Equatable, Sendable {
    var sources: [AttachmentAgentSource]
    var turnID: String?

    static let main = AttachmentReferenceContext(sources: [.main])

    func merging(_ newer: Self) -> Self {
        Self(sources: AttachmentAgentSource.merged(sources, newer.sources),
             turnID: newer.turnID ?? turnID)
    }
}
