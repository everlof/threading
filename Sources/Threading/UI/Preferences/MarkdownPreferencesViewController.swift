import AppKit
import UniformTypeIdentifiers

/// The OS owns this preference. A button makes the one-time opt-in explicit and the row reads
/// the real handler whenever visited; launching Threading never sets or reasserts a default.
@MainActor
enum MarkdownFileAssociation {
    static let typeIdentifier = "net.daringfireball.markdown"
    static var contentType: UTType { UTType(importedAs: typeIdentifier, conformingTo: .plainText) }
    static let mcTypeIdentifier = "codes.threading.markdown-mc"
    static var mcContentType: UTType {
        UTType(filenameExtension: "mc") ?? UTType(exportedAs: mcTypeIdentifier, conformingTo: .plainText)
    }

    static var isDefault: Bool {
        isDefault(for: contentType)
    }

    static func isDefault(for type: UTType) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: type)?.standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL
    }

    static func register(_ type: UTType) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
    }

    nonisolated static func accepts(_ url: URL) -> Bool {
        url.isFileURL && ["md", "markdown", "mc"].contains(url.pathExtension.lowercased())
    }
}

final class MarkdownPreferencesViewController: NSViewController {
    private lazy var defaultButton = SettingsUI.button("Make Default", target: self, action: #selector(makeDefault))
    private lazy var mcButton = SettingsUI.button("Make Default", target: self, action: #selector(makeMCDefault))

    override func loadView() {
        view = NSView()
        let row = SettingsUI.row(
            title: "Open Markdown files in Threading",
            subtitle: "Choose Threading as the default app for .md files.",
            help: SettingsUI.help(
                "Markdown files",
                "This is opt-in. macOS may ask you to confirm the change. To choose another app later, "
                    + "use Finder's Get Info → Open With → Change All."
            ),
            control: defaultButton
        )
        let mcRow = SettingsUI.row(
            title: "Open .mc files in Threading",
            subtitle: "Treat .mc files as Markdown documents.",
            help: SettingsUI.help(
                "Markdown files",
                "This is opt-in. macOS may ask you to confirm the change. To choose another app later, "
                    + "use Finder's Get Info → Open With → Change All."
            ),
            control: mcButton
        )
        let page = SettingsUI.page(title: "Markdown", sections: [SettingsUI.section(nil, SettingsCard(rows: [row, mcRow]))])
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func refresh() {
        for (button, type) in [(defaultButton, MarkdownFileAssociation.contentType), (mcButton, MarkdownFileAssociation.mcContentType)] {
            let enabled = MarkdownFileAssociation.isDefault(for: type)
            button.title = enabled ? L10n.string("Default App") : L10n.string("Make Default")
            button.isEnabled = !enabled
        }
    }

    @objc private func makeDefault() {
        register(MarkdownFileAssociation.contentType, button: defaultButton)
    }

    @objc private func makeMCDefault() {
        register(MarkdownFileAssociation.mcContentType, button: mcButton)
    }

    private func register(_ type: UTType, button: ThemedButton) {
        button.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do { try await MarkdownFileAssociation.register(type) }
            catch {
                if let window = view.window { ThemedAlert(error: error).beginSheetModal(for: window) }
            }
            refresh()
        }
    }
}
