import AppKit

/// A bounded form over inspected metadata. The table owns viewport rows; selecting an extension
/// does not start it. Saving records the exact reviewed package digests for later activation.
@MainActor
final class AppearancePackEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Metrics {
        static let width: CGFloat = 560
        static let height: CGFloat = 390
        static let rowHeight: CGFloat = 58
        static let rowID = NSUserInterfaceItemIdentifier("AppearancePackMember")
    }

    private let host: AppearanceActivationHost
    private let original: AppearancePack?
    private let inventory: AppearanceActivationInventory
    private let identifiers: [String]
    private var selected: Set<String>
    private let nameField = ThemedTextField()
    private let themePicker = ThemedPopUp()
    private let table = ThemedTableView()
    private let problem = NSTextField(wrappingLabelWithString: "")
    let content = NSView(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height))

    init(host: AppearanceActivationHost, pack: AppearancePack?) {
        self.host = host
        original = pack
        let inventory = host.inventory()
        self.inventory = inventory
        identifiers = Set(inventory.extensions.keys).union(pack?.extensionIDs ?? []).sorted {
            (inventory.extensions[$0]?.name ?? $0).localizedCaseInsensitiveCompare(
                inventory.extensions[$1]?.name ?? $1
            ) == .orderedAscending
        }
        selected = pack?.extensionIDs ?? []
        super.init()
        build()
    }

    @discardableResult
    static func present(packID: UUID?, in window: NSWindow?, host: AppearanceActivationHost = .shared) -> ThemedAlert? {
        let pack = packID.flatMap { id in host.state?.packs.first { $0.id == id } }
        guard packID == nil || pack != nil else {
            host.presentFailure(AppearanceActivationError.packUnavailable.localizedDescription)
            return nil
        }
        let form = AppearancePackEditor(host: host, pack: pack)
        let alert = ThemedAlert()
        alert.alertStyle = .informational
        alert.messageText = pack == nil ? L10n.string("Create Appearance Pack") : L10n.string("Edit Appearance Pack")
        alert.informativeText = L10n.string("Choose a theme and up to 16 installed extensions. Saving does not enable them. Use the pack from the command palette.")
        alert.accessoryView = form.content
        alert.initialFirstResponder = form.nameField
        alert.addButton(withTitle: L10n.string("Save Pack"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        var prepared: AppearancePack?
        alert.shouldChooseButton = { index in
            guard index == 0 else { return true }
            do {
                let pack = try form.pack()
                prepared = pack
                if let reason = host.unavailableReason(for: .savePack(pack)) {
                    form.problem.stringValue = reason
                    return false
                }
                return true
            } catch {
                form.problem.stringValue = error.localizedDescription
                return false
            }
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == ThemedAlert.firstButtonResponse, let prepared else { return }
            if let reason = host.submit(.savePack(prepared)) { host.presentFailure(reason) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
        return alert
    }

    private func build() {
        let root = content
        nameField.stringValue = original?.name ?? ""
        nameField.placeholderString = L10n.string("Pack name")
        nameField.setAccessibilityLabel(L10n.string("Pack name"))
        nameField.setAccessibilityIdentifier("appearance-pack.name")
        themePicker.setAccessibilityLabel(L10n.string("Pack theme"))
        themePicker.setAccessibilityIdentifier("appearance-pack.theme")
        for section in AppThemeLibrary.sections {
            if let title = section.title { themePicker.addHeader(title) }
            for theme in section.themes {
                themePicker.addItem(ThemedMenuItem(title: theme.name, representedValue: theme.id.rawValue))
            }
        }
        let selectedTheme = original?.themeID ?? AppThemeLibrary.current.id.rawValue
        if let index = themePicker.indexOfItem(where: { ($0.representedValue as? String) == selectedTheme }) {
            themePicker.selectItem(at: index)
        } else {
            themePicker.selectItem(at: -1)
        }
        let nameLabel = label(L10n.string("Name"))
        let themeLabel = label(L10n.string("Theme"))
        let membersLabel = label(L10n.string("Companion extensions"))
        problem.applyFont(.caption)
        problem.textColor = Design.Text.secondary
        problem.setAccessibilityIdentifier("appearance-pack.validation")
        if selected.isEmpty && identifiers.isEmpty {
            problem.stringValue = L10n.string("No extensions are installed. You can still save a theme-only pack.")
        }

        let column = NSTableColumn(identifier: Metrics.rowID)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Metrics.rowHeight
        table.intercellSpacing = .zero
        // Exact-width rows must not also acquire AppKit's automatic inset gutters.
        table.style = .plain
        table.soleColumnFillsBoundsExactly = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.selectionHighlightStyle = .none
        table.delegate = self
        table.dataSource = self
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = table
        // The alert measures its accessory before the clip view has a width. Pin the document
        // to the resulting viewport so AppKit cannot retain the initial column fitting width.
        table.translatesAutoresizingMaskIntoConstraints = false
        table.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let views = [nameLabel, nameField, themeLabel, themePicker, membersLabel, scroll, problem]
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: root.topAnchor),
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: Design.Spacing.small),
            themeLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: Design.Spacing.medium),
            themePicker.topAnchor.constraint(equalTo: themeLabel.bottomAnchor, constant: Design.Spacing.small),
            membersLabel.topAnchor.constraint(equalTo: themePicker.bottomAnchor, constant: Design.Spacing.medium),
            scroll.topAnchor.constraint(equalTo: membersLabel.bottomAnchor, constant: Design.Spacing.small),
            scroll.bottomAnchor.constraint(equalTo: problem.topAnchor, constant: -Design.Spacing.small),
            problem.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            problem.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),
        ] + views.flatMap { [
            $0.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            $0.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ] })
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.applyFont(.detail(weight: .medium))
        label.textColor = Design.Text.label
        return label
    }

    func numberOfRows(in tableView: NSTableView) -> Int { identifiers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard identifiers.indices.contains(row) else { return nil }
        let id = identifiers[row]
        let runtime = inventory.extensions[id]
        let cell = tableView.makeView(withIdentifier: Metrics.rowID, owner: nil) as? AppearancePackMemberCell
            ?? AppearancePackMemberCell()
        cell.identifier = Metrics.rowID
        cell.configure(name: runtime?.name ?? id,
                       detail: runtime?.unavailableReason ?? runtime?.capabilitySummary
                        ?? AppearanceActivationError.extensionUnavailable(id).localizedDescription,
                       selected: selected.contains(id), enabled: runtime?.unavailableReason == nil && runtime?.contentDigest != nil)
        cell.toggle.tag = row
        cell.toggle.target = self
        cell.toggle.action = #selector(toggleMember(_:))
        return cell
    }

    @objc private func toggleMember(_ toggle: ThemedToggle) {
        guard identifiers.indices.contains(toggle.tag) else { return }
        let id = identifiers[toggle.tag]
        if toggle.state == .on {
            guard selected.count < AppearancePack.maximumMembers else {
                toggle.state = .off
                problem.stringValue = L10n.string("A pack can enable at most 16 extensions.")
                return
            }
            selected.insert(id)
        } else { selected.remove(id) }
        problem.stringValue = ""
    }

    private func pack() throws -> AppearancePack {
        guard let themeID = themePicker.selectedItem?.representedValue as? String else {
            throw AppearanceActivationError.themeUnavailable
        }
        let members = try selected.sorted().map { id -> AppearancePack.Member in
            guard let digest = inventory.extensions[id]?.contentDigest else {
                throw AppearanceActivationError.extensionUnavailable(id)
            }
            return .init(identifier: id, contentDigest: digest)
        }
        let revision: UUID
        if let original, original.themeID == themeID, original.orderedMembers == members {
            revision = original.recipeRevision
        } else { revision = UUID() }
        let result = AppearancePack(
            id: original?.id ?? UUID(),
            recipeRevision: revision,
            name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            themeID: themeID, extensions: members
        )
        try result.validate()
        return result
    }
}
