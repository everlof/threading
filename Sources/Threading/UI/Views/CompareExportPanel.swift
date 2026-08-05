import AppKit

/// The save panel a comparison is exported through, and the format choice inside it.
///
/// The choice is an accessory on the panel rather than two menu items, because it is a property
/// of the *save* and not a second command: the user has already decided to export, and what is
/// left is whether the recipient gets one file to double-click or a folder with the originals in
/// it. Beside the name field is also where a file format has lived in every document-based app
/// for thirty years.
///
/// One object per presentation, held by the caller for as long as the sheet is up — the same
/// shape as the display pane's menu session, and for the same reason: the pop-up's target has to
/// outlive the call that opened the panel.
@MainActor
final class CompareExportPanel: NSObject {

    private enum Layout {
        static let width: CGFloat = 340
        static let height: CGFloat = Design.Size.chipHeight + Design.Spacing.medium * 2
        static let popUpWidth: CGFloat = 190
    }

    // MARK: - Properties

    private let panel = NSSavePanel()
    private let popUp = ThemedPopUp()
    private let suggestedName: String
    private var format: CompareExportFormat = .singlePage

    // MARK: - Initialization

    private init(suggestedName: String) {
        self.suggestedName = suggestedName
        super.init()
    }

    // MARK: - Public Methods

    /// Asks where to write the export, and in which format. The returned session must be held
    /// until the sheet closes.
    ///
    /// `completion` runs only when the user commits — a cancel is silence rather than a nil
    /// result, since there is nothing for a caller to do about it.
    @discardableResult
    static func present(
        suggestedName: String,
        from view: NSView,
        completion: @escaping (URL, CompareExportFormat) -> Void
    ) -> CompareExportPanel {
        let session = CompareExportPanel(suggestedName: suggestedName)
        session.begin(from: view, completion: completion)
        return session
    }

    // MARK: - Private Methods

    private func begin(from view: NSView, completion: @escaping (URL, CompareExportFormat) -> Void) {
        panel.message = L10n.string("Export this comparison as a page anyone can open.")
        panel.canCreateDirectories = true
        // The extension is the format, and the format is a control on this panel: hidden, the
        // pop-up would be the only place the answer appears, one glance from the name carrying it.
        panel.isExtensionHidden = false

        for candidate in CompareExportFormat.allCases {
            popUp.addItem(ThemedMenuItem(title: candidate.title, representedValue: candidate))
        }
        popUp.selectItem(at: CompareExportFormat.allCases.firstIndex(of: format) ?? 0)
        popUp.target = self
        popUp.action = #selector(formatChanged)
        panel.accessoryView = makeAccessory()

        apply(format)

        // The format is read when the panel closes, never captured as it opens: the pop-up
        // exists precisely to change it while the sheet is up.
        let decided: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = self.panel.url else { return }
            completion(url, self.format)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: decided)
        } else {
            decided(panel.runModal())
        }
    }

    @objc private func formatChanged() {
        guard let chosen = popUp.selectedItem?.representedValue as? CompareExportFormat else {
            return
        }
        format = chosen
        apply(chosen)
    }

    /// Retypes the panel for the chosen format.
    ///
    /// Both halves are needed: the content type is what the panel *accepts*, and the name field
    /// is what it shows. Setting only the type leaves a `.html` in the field under a pop-up that
    /// says zip — and the file is then written with the name the field showed.
    private func apply(_ format: CompareExportFormat) {
        let typed = (panel.nameFieldStringValue as NSString).deletingPathExtension
        let stem = typed.isEmpty ? suggestedName : typed
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(stem).\(format.fileExtension)"
    }

    /// The accessory: one labelled row, sized in points because a save panel measures its
    /// accessory by frame rather than laying it out.
    private func makeAccessory() -> NSView {
        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height)
        )
        let label = NSTextField(labelWithString: L10n.string("Format:"))
        label.applyFont(.body)
        label.textColor = Design.Text.secondary
        label.translatesAutoresizingMaskIntoConstraints = false
        popUp.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(popUp)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(
                equalTo: popUp.leadingAnchor, constant: -Design.Spacing.small
            ),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popUp.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            popUp.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popUp.widthAnchor.constraint(equalToConstant: Layout.popUpWidth)
        ])
        return container
    }
}
