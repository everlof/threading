import AppKit

/// Deterministic, bounded gallery fixture kept beside `AgentWorkSummaryView`.
@MainActor
enum AgentWorkSummaryGalleryStory {
    static func makeView() -> NSView {
        // Heat decay and action retention use one fixed moment so light and dark evidence render
        // the same component state.
        let now = Date(timeIntervalSinceReferenceDate: 776_000_000)
        let files = (0..<2_400).map { index in
            "Sources/Feature\(index / 120)/Area\(index / 24)/file-\(index).swift"
        }
        let atlas = RepositoryFileAtlas(files: files)
        let firstID = SessionID()
        let secondID = SessionID()
        var first = AgentSessionWorkTrace()
        first.sessionTitle = L10n.string("Refactor sidebar")
        first.agentLabel = "Codex"
        var second = AgentSessionWorkTrace()
        second.sessionTitle = L10n.string("Harden tests")
        second.agentLabel = "Claude"

        for index in stride(from: 90, through: 1_080, by: 19) {
            _ = first.recordFile(
                .read,
                path: files[index],
                root: nil,
                at: now.addingTimeInterval(-TimeInterval(index % 70))
            )
            if index.isMultiple(of: 3) {
                _ = first.recordFile(
                    .edit,
                    path: files[index],
                    root: nil,
                    at: now.addingTimeInterval(-TimeInterval(index % 35))
                )
            }
        }
        for index in stride(from: 720, through: 1_900, by: 29) {
            _ = second.recordFile(
                .edit,
                path: files[index],
                root: nil,
                at: now.addingTimeInterval(-TimeInterval(index % 60))
            )
        }
        for index in 0..<12 {
            first.recordAction(
                category: index.isMultiple(of: 3) ? .shell : .filesystem,
                operation: index.isMultiple(of: 3) ? "exec" : "Read",
                at: now.addingTimeInterval(-TimeInterval(index * 3)),
                sessionID: firstID
            )
            second.recordAction(
                category: index.isMultiple(of: 4) ? .subagent : .network,
                operation: index.isMultiple(of: 4) ? "Agent" : "WebSearch",
                at: now.addingTimeInterval(-TimeInterval(index * 4 + 1)),
                sessionID: secondID
            )
        }

        let traces = [firstID: first, secondID: second]
        let presentation = AgentWorkPresentation.project(
            AgentProjectWorkAggregate(traces: traces),
            traces: traces,
            projectID: ProjectID(),
            atlas: atlas,
            detailed: true
        )
        let summary = AgentWorkSummaryView()
        summary.setClock { now }
        summary.setPresentation(presentation)
        // One realistic review width keeps evidence independent of host text fitting.
        summary.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return summary
    }
}
