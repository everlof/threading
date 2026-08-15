import AppKit

/// Deterministic gallery fixture kept beside `ConversationHandoffView`.
@MainActor
enum ConversationHandoffGalleryStory {
    /// The shortest path that shows the origin, direct source, and a compacted middle section.
    static func makeView() -> NSView {
        let endpoints = [
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: .claude,
                model: "claude-opus-4-1",
                title: nil
            ),
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: .codex,
                model: "gpt-5",
                title: nil
            ),
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: .claude,
                model: "claude-opus-4-1",
                title: nil
            )
        ]
        guard let handoff = ConversationHandoff(
            endpoints: endpoints,
            omittedEndpointCount: 1
        ) else { return NSView() }

        return ConversationHandoffView(
            handoff: handoff,
            canOpenSource: true,
            onOpenSource: nil
        )
    }
}
