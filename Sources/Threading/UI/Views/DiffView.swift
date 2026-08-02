import AppKit
import NativeDiffAppKit
import NativeDiffCore

/// Threading's theme/default adapter around the package renderer.
///
/// Git loading, staging and app theming stay in the app. The actual line rendering, syntax
/// highlighting, wrapping and sizing live in NativeDiffKit and are shared with the UIKit view.
final class DiffView: DiffAppKitView {
    private let appEvents = AppEventObservations()
    private var observesTheme = false
    private var contextLines: [DiffLine] = []
    private var contextPath: String?
    private var contextMenuSession: AnyObject?

    var onAddContextAttachment: ((ConversationContextAttachment) -> Void)?
    var onRequestComment: ((ConversationContextAttachment) -> Void)?

    convenience init(lines: [DiffLine], path: String? = nil, wraps: Bool = true) {
        self.init(
            lines: lines,
            path: path,
            configuration: .init(
                displayCap: DiffDefaults.displayCap,
                showsNumbers: false,
                wraps: wraps,
                lineCharacterLimit: GitReviewDefaults.lineCharacterCap,
                numberWidth: GitReviewDefaults.lineNumberWidth,
                gutterWidth: DiffDefaults.gutterWidth,
                verticalInset: 1
            ),
            theme: .threading()
        )
        contextLines = Array(lines.prefix(max(DiffDefaults.displayCap, 0)))
        contextPath = path
        beginObservingTheme()
    }

    convenience init(
        gitLines: [GitDiffLine],
        displayCap: Int,
        path: String? = nil,
        wraps: Bool = true
    ) {
        self.init(
            lines: gitLines,
            path: path,
            configuration: .init(
                displayCap: displayCap,
                showsNumbers: true,
                wraps: wraps,
                lineCharacterLimit: GitReviewDefaults.lineCharacterCap,
                numberWidth: GitReviewDefaults.lineNumberWidth,
                gutterWidth: DiffDefaults.gutterWidth,
                verticalInset: 1
            ),
            theme: .threading()
        )
        contextLines = Array(gitLines.prefix(max(displayCap, 0)))
        contextPath = path
        beginObservingTheme()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard onAddContextAttachment != nil || onRequestComment != nil,
              let index = lineIndex(at: convert(event.locationInWindow, from: nil)),
              let reference = contextAttachment(atDisplayedLine: index) else {
            super.rightMouseDown(with: event)
            return
        }
        presentContextMenu(for: reference, at: event.locationInWindow)
    }

    private func lineIndex(at point: NSPoint) -> Int? {
        arrangedSubviews.enumerated().first { _, row in
            row.frame.contains(point)
        }?.offset
    }

    private func presentContextMenu(
        for reference: ConversationContextAttachment,
        at windowPoint: NSPoint
    ) {
        guard contextMenuSession == nil else { return }
        var entries: [ThemedMenuEntry] = []
        if onAddContextAttachment != nil {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Add line to chat"),
                onChoose: { [weak self] in self?.onAddContextAttachment?(reference) }
            )))
        }
        if onRequestComment != nil {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Comment on line…"),
                onChoose: { [weak self] in self?.onRequestComment?(reference) }
            )))
        }
        contextMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 180),
            from: self,
            anchor: .pointer(windowPoint),
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.contextMenuSession = nil }
        )
    }

    /// The anchor corresponding to a rendered row. Kept as a small test seam because the
    /// package view owns line layout, while Threading owns the durable source locator.
    func contextAttachment(atDisplayedLine index: Int) -> ConversationContextAttachment? {
        guard contextLines.indices.contains(index) else { return nil }
        let line = contextLines[index]
        let number = line.newNumber ?? line.oldNumber
        let path = contextPath ?? L10n.string("Code change")
        let title = number.map { "\(path):\($0)" } ?? path
        return ConversationContextAttachment(
            kind: .reference,
            source: .code,
            title: title,
            excerpt: line.text,
            locator: contextPath,
            lineStart: number,
            lineEnd: number
        )
    }

    private func beginObservingTheme() {
        guard !observesTheme else { return }
        observesTheme = true
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applyCurrentTheme()
        }
        // The washes are measured against the ground, and in a conversation that ground is the
        // *terminal palette's* background — which moves when the selected session does, with the
        // app theme sitting perfectly still. Without this a diff kept the previous session's
        // tint until something else repainted it.
        appEvents.observe(WindowBackdropDidChange.self) { [weak self] _ in
            self?.applyCurrentTheme()
        }
    }

    /// Re-themes in the view's **own** effective appearance.
    ///
    /// The package freezes each row's wash onto a layer (`.cgColor`), which resolves a dynamic
    /// colour in whatever drawing appearance is ambient — from a notification handler, that is
    /// whatever AppKit last had in hand. Under an adaptive theme that painted the dark
    /// variant's washes into a light window. The text labels resolve at draw and were right
    /// all along, which is what made the slabs read as the theme being broken.
    ///
    /// The same appearance decides what the *ground* resolves to, which is why it is measured
    /// in here rather than passed in from a caller that has no drawing appearance in force.
    private func applyCurrentTheme() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            update(theme: .threading(on: resolvedGround()))
        }
    }

    /// Rows built before the view joined a window froze their washes in the ambient
    /// appearance; both hooks re-resolve them in the appearance the view actually wears.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        applyCurrentTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCurrentTheme()
    }
}

@MainActor
private extension DiffAppKitTheme {

    /// The renderer's theme, with every colour that depends on the ground resolved against the
    /// one this diff is actually drawn on — see `Design.Diff.on(_:)`.
    static func threading(on ground: NSColor = Design.Surface.ground) -> DiffAppKitTheme {
        let diff = Design.Diff.on(ground)

        return DiffAppKitTheme(
            font: Design.Typography.code(),
            label: Design.Text.label,
            secondaryLabel: Design.Text.secondary,
            tertiaryLabel: Design.Text.tertiary,
            added: diff.added,
            removed: diff.removed,
            addedBackground: diff.addedWash,
            removedBackground: diff.removedWash,
            syntaxKeyword: Design.Syntax.keyword,
            syntaxType: Design.Syntax.type,
            syntaxString: Design.Syntax.string,
            syntaxNumber: Design.Syntax.number,
            syntaxComment: Design.Syntax.comment
        )
    }
}
