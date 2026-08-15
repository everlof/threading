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
///
/// **The accessory is system chrome, and so are the controls in it.** AppKit does not place an
/// accessory inside the panel's own content: it gives the view a window of its own — an
/// `NSAccessoryViewWindow` exactly as tall as the accessory, whose frame view clips — and hangs
/// that off the panel. An app-owned dropdown opened from inside it therefore has nowhere to go:
/// `ThemedMenuPresenter` lays its overlay out in `source.window!.contentView!.bounds`, which here
/// is a 44-point strip, so the list came out clamped to a two-pixel sliver of its own top border
/// with no way for the user to read or pick anything. Appearance says the same thing: a themed
/// pop-up beside the panel's own name field reads as a control borrowed from another app. Both
/// are why this row is AppKit's, down to the label colour the panel gives its own field labels;
/// `scripts/config/theme-boundary.json` carries the two exceptions that allows, and
/// `docs/THEME_BOUNDARY.md` records the rule.
@MainActor
final class CompareExportPanel: NSObject {

    private enum Layout {
        /// The accessory states its own size: a save panel measures an accessory by frame rather
        /// than laying it out.
        static let width: CGFloat = 340
        static let verticalInset: CGFloat = Design.Spacing.medium
        static let labelGap: CGFloat = Design.Spacing.small
    }

    // MARK: - Properties

    /// The panel, its chooser, and the format they currently agree on. Internal so a test can
    /// read what the accessory is made of and drive a choice through it, which otherwise would
    /// mean putting a modal sheet on screen.
    let panel = NSSavePanel()
    // Approved system-owned save-panel accessory; pinned in theme-boundary.json.
    // swiftlint:disable:next stock_appkit_control
    let chooser = NSPopUpButton()
    private(set) var format: CompareExportFormat = .singlePage

    private let suggestedName: String

    // MARK: - Initialization

    /// `present(suggestedName:from:completion:)` is the ordinary way in; the initializer is
    /// reachable on its own so a test can configure a panel without showing one.
    init(suggestedName: String) {
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

    /// Everything the panel carries before it is shown, kept apart from showing it so the
    /// accessory can be inspected without a sheet.
    func configure() {
        panel.message = L10n.string("Export this comparison as a page anyone can open.")
        panel.canCreateDirectories = true
        // The extension is the format, and the format is a control on this panel: hidden, the
        // pop-up would be the only place the answer appears, one glance from the name carrying it.
        panel.isExtensionHidden = false

        for candidate in CompareExportFormat.allCases {
            chooser.addItem(withTitle: candidate.title)
        }
        chooser.selectItem(at: CompareExportFormat.allCases.firstIndex(of: format) ?? 0)
        chooser.target = self
        chooser.action = #selector(formatChanged)
        panel.accessoryView = makeAccessory()

        // A panel arrives already called Untitled, and `apply` keeps the name the field is
        // showing — which is the point once the user has typed one, and wrong for exactly this
        // first pass. The comparison's own name goes in before the first retype, or the export
        // is offered as Untitled.html with the name it suggested never reaching the panel.
        panel.nameFieldStringValue = suggestedName
        apply(format)
    }

    /// The single point at which a choice becomes the format. Reachable from a test, which
    /// otherwise could only get here through an open menu on a modal sheet.
    func chooseFormat(at index: Int) {
        guard CompareExportFormat.allCases.indices.contains(index) else { return }
        format = CompareExportFormat.allCases[index]
        if chooser.indexOfSelectedItem != index { chooser.selectItem(at: index) }
        apply(format)
    }

    // MARK: - Private Methods

    private func begin(from view: NSView, completion: @escaping (URL, CompareExportFormat) -> Void) {
        configure()

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
        chooseFormat(at: chooser.indexOfSelectedItem)
    }

    /// Retypes the panel for the chosen format.
    ///
    /// Both halves are needed: the content type is what the panel *accepts*, and the name field
    /// is what it shows. Setting only the type leaves a `.html` in the field under a pop-up that
    /// says zip — and the file is then written with the name the field showed.
    private func apply(_ format: CompareExportFormat) {
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(stem).\(format.fileExtension)"
    }

    /// The name to carry across a retype: what the field is showing, minus the extension this
    /// panel put on it.
    ///
    /// Only the two extensions it writes are taken off, rather than whatever
    /// `deletingPathExtension` calls one: a comparison named `v1.2` would come back as `v1`, and
    /// the file would then be written under the shortened name the field was showing.
    private var stem: String {
        let name = panel.nameFieldStringValue
        for candidate in CompareExportFormat.allCases {
            let suffix = ".\(candidate.fileExtension)"
            if name.lowercased().hasSuffix(suffix) {
                return String(name.dropLast(suffix.count))
            }
        }
        return name.isEmpty ? suggestedName : name
    }

    /// The accessory: one labelled row, sized in points because a save panel measures its
    /// accessory by frame rather than laying it out.
    ///
    /// The label takes the panel's own label colour rather than the app's secondary ink, so
    /// "Format:" sits in the same column as "Save As:" and "Where:" and reads at the same weight
    /// as them.
    private func makeAccessory() -> NSView {
        let label = NSTextField(labelWithString: L10n.string("Format:"))
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        chooser.translatesAutoresizingMaskIntoConstraints = false
        // The chooser carries no visible title of its own; the label beside it is its name.
        chooser.setAccessibilityTitleUIElement(label)

        let rowHeight = max(chooser.fittingSize.height, label.fittingSize.height)
        let container = NSView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: Layout.width,
                height: rowHeight + Layout.verticalInset * 2
            )
        )
        container.addSubview(label)
        container.addSubview(chooser)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(
                equalTo: chooser.leadingAnchor, constant: -Layout.labelGap
            ),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            chooser.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            chooser.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }
}
