import AppKit

/// Holds a component's existing AppKit content and an optional host-rendered replacement.
///
/// The default subtree is retained rather than reconstructed. Disabling an extension or
/// rejecting its replacement therefore restores the exact native UI immediately.
@MainActor
final class ComponentContentContainer: NSView {
    let defaultContent: NSView
    private(set) var replacementContent: NSView?
    var onReplacementChanged: ((NSView?) -> Void)?
    private var defaultConstraints: [NSLayoutConstraint] = []
    private var replacementConstraints: [NSLayoutConstraint] = []

    init(defaultContent: NSView) {
        self.defaultContent = defaultContent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        defaultContent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(defaultContent)
        defaultConstraints = constraintsPinningToEdges(defaultContent)
        NSLayoutConstraint.activate(defaultConstraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installReplacement(_ replacement: NSView?) {
        install(replacement, includesDefaultContent: false)
    }

    /// Installs an around-hook tree whose `.proceed` chain already contains `defaultContent`.
    func installComposition(_ composition: NSView) {
        install(composition, includesDefaultContent: true)
    }

    /// Runs a re-parenting of the content and hands the caret back afterwards.
    ///
    /// Removing a view from its window makes AppKit hand the first responder back to the
    /// window — silently, without the view ever hearing `resignFirstResponder`. In the
    /// composer that reads as the caret vanishing mid-sentence from a prompt still drawing
    /// its focus ring. Resolving a hook chain is not something the user did, so it may not
    /// move the caret.
    func preservingFocus(_ body: () -> Void) {
        let window = self.window
        let focused = window?.firstResponder as? NSView
        let heldFocus = focused.map { $0.isDescendant(of: self) } ?? false

        body()

        guard heldFocus,
              let focused,
              focused.window === window,
              window?.firstResponder !== focused else { return }
        window?.makeFirstResponder(focused)
    }

    /// Detaches the native subtree before a new hook chain places it in a `.proceed` slot.
    func prepareDefaultContentForComposition() {
        NSLayoutConstraint.deactivate(defaultConstraints)
        defaultContent.removeFromSuperview()
        defaultContent.isHidden = false
    }

    private func install(
        _ replacement: NSView?,
        includesDefaultContent: Bool
    ) {
        NSLayoutConstraint.deactivate(replacementConstraints)
        replacementConstraints = []
        if let replacementContent,
           defaultContent.isDescendant(of: replacementContent) {
            defaultContent.removeFromSuperview()
        }
        replacementContent?.removeFromSuperview()
        replacementContent = replacement

        guard let replacement else {
            if defaultContent.superview !== self {
                defaultContent.removeFromSuperview()
                addSubview(defaultContent)
            }
            NSLayoutConstraint.activate(defaultConstraints)
            defaultContent.isHidden = false
            onReplacementChanged?(nil)
            return
        }

        // A hidden view's constraints remain active in AppKit. Detach the native subtree from
        // this container before installing the replacement, or its fixed/intrinsic size still
        // dictates the replacement's size. Session identity exposes this directly: the native
        // 16pt mark may legally be replaced by a wider provider/account HStack.
        NSLayoutConstraint.deactivate(defaultConstraints)
        replacement.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replacement)
        replacementConstraints = constraintsPinningToEdges(replacement)
        NSLayoutConstraint.activate(replacementConstraints)
        defaultContent.isHidden = !includesDefaultContent
        onReplacementChanged?(replacement)
    }

    private func constraintsPinningToEdges(_ child: NSView) -> [NSLayoutConstraint] {
        [
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor)
        ]
    }
}
