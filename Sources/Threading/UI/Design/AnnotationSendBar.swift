import AppKit

/// The "Send (x)" affordance for pinned annotations, in one place so it looks and behaves the same
/// wherever the product lets a person hand their notes to the agent.
///
/// This is the visual chip only — a primary `ThemedButton` on the shared annotation surface. Each
/// host owns *what* pending means and *how* the notes are delivered, and drives the count through
/// `setPending(count:sending:)`; the keyboard shortcut (⌘Return) is the host's too, because "which
/// surface owns the focus" is a host question. Extracted from the browser's inline send affordance
/// so the two stay identical.
/// A structural container only: it draws nothing itself, laying out the themed surface and the
/// themed button that carry the styling and the interaction.
final class AnnotationSendBar: NSView {
    let sendButton = ThemedButton(title: "", target: nil, action: nil)
    private let surface = BrowserAnnotationSurfaceView(frame: .zero)
    var onSend: (() -> Void)?
    private var pending: (count: Int, sending: Bool) = (0, false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        sendButton.emphasis = .primary
        sendButton.toolTip = L10n.string("Send pending annotations (⌘Return)")
        sendButton.target = self
        sendButton.action = #selector(fire)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        addSubview(sendButton)
        let inset = Design.Spacing.tight
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            sendButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            sendButton.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        setPending(count: 0, sending: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() { onSend?() }

    /// Update the count in the title and hide the bar when there is nothing to send.
    func setPending(count: Int, sending: Bool) {
        pending = (count, sending)
        sendButton.title = L10n.format("Send (%lld)", Int64(count))
        sendButton.isEnabled = !sending
        isHidden = count == 0
    }

    /// Whether there is anything to send — the host checks this before acting on ⌘Return.
    var hasPending: Bool { pending.count > 0 }
}
