import AppKit

/// The standing transcript, status and reply hierarchy shared by both conversation hosts.
/// Transient rails and overlays remain siblings supplied by the host.
@MainActor
final class ConversationPaneContentView: NSView {
    private var transcript: NSView?
    private var status: NSView?
    private var composer: NSView?

    func mount(transcript: NSView, status: NSView, composer: NSView) {
        precondition(self.transcript == nil, "conversation content is already mounted")
        self.transcript = transcript
        self.status = status
        self.composer = composer
        for child in [transcript, status, composer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
    }

    func constrain(transcriptTop: NSLayoutConstraint,
                   composerBottom: NSLayoutYAxisAnchor,
                   columnCap: NSLayoutConstraint,
                   columnWidth: NSLayoutConstraint) {
        guard let transcript, let status, let composer else {
            preconditionFailure("conversation content must be mounted before constraining")
        }
        NSLayoutConstraint.activate(ConversationPaneLayout.constraints(
            in: self, transcript: transcript, status: status, composer: composer,
            transcriptTop: transcriptTop, composerBottom: composerBottom,
            columnCap: columnCap, columnWidth: columnWidth))
    }
}
