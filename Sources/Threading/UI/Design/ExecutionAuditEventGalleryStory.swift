import AppKit

/// Deterministic gallery fixture kept beside `ExecutionAuditEventView`.
@MainActor
enum ExecutionAuditEventGalleryStory {
    private static let rowWidth: CGFloat = 460
    private static let durationMilliseconds = 128

    /// Shows the ledger's resting and selected states across its three event sources without
    /// requiring a live session or audit store.
    static func makeView() -> NSView {
        let rows: [NSView] = [
            (ExecutionAuditRecord.Source.providerStream, false),
            (ExecutionAuditRecord.Source.threadingMCP, false),
            (ExecutionAuditRecord.Source.permissionBroker, true)
        ].map { source, isSelected in
            let view = ExecutionAuditEventView()
            view.configure(record: record(source: source), isSelected: isSelected)
            view.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            return view
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        return stack
    }

    private static func record(source: ExecutionAuditRecord.Source) -> ExecutionAuditRecord {
        let shape: (
            category: ExecutionAuditRecord.Category,
            phase: ExecutionAuditRecord.Phase,
            operation: String,
            summary: String,
            fidelity: ExecutionAuditRecord.Fidelity
        )
        switch source {
        case .providerStream:
            shape = (.tool, .completed, "Edit", "Design.swift, 2 hunks", .exact)
        case .threadingMCP:
            shape = (
                .browser,
                .progressed,
                "browser_click",
                "Sign in, #submit",
                .canonicalized
            )
        case .permissionBroker:
            shape = (.permission, .allowed, "Bash", "git status", .exactWithRedactions)
        }

        return ExecutionAuditRecord(
            id: UUID(),
            sessionID: SessionID(),
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            source: source,
            provider: nil,
            category: shape.category,
            phase: shape.phase,
            operation: shape.operation,
            callID: nil,
            summary: shape.summary,
            input: nil,
            output: nil,
            durationMilliseconds: durationMilliseconds,
            fidelity: shape.fidelity,
            redactions: [],
            previousDigest: nil,
            digest: ""
        )
    }
}
