import AppKit
import ThreadingExtensionKit

/// A complete host-rendered Settings page contributed by one extension.
final class ExtensionSettingsViewController: NSViewController {
    private let registeredPage: RegisteredExtensionSettingsPage

    init(page: RegisteredExtensionSettingsPage) {
        self.registeredPage = page
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // The extension's strings arrive already localized by its own resolver, so the header
        // must not pass them through the app's catalogue — see the localization-domain split
        // in design-system.md.
        let body = ExtensionSettingsListView(
            baseSections: [],
            extensionSections: registeredPage.page.sections.map {
                ExtensionSettingsRenderer.sectionModel(
                    extensionIdentifier: registeredPage.extensionIdentifier,
                    extensionName: registeredPage.extensionName,
                    sectionID: $0.id,
                    title: $0.title,
                    fields: $0.fields,
                    prefixesTitleWithExtension: false
                )
            }
        )
        view = SettingsUI.listPage(
            title: registeredPage.page.title,
            summary: registeredPage.extensionName,
            body: body,
            localizes: false
        )
    }
}

/// Cheap value state for one settings section supplied by an extension.
///
/// The public extension contract bounds one owner at 128 fields, but a built-in host page can
/// aggregate several owners. Keeping those fields as values lets one table own the viewport
/// across section boundaries instead of turning each extension into one enormous virtual row.
struct ExtensionSettingsSectionModel {
    let extensionIdentifier: String
    let sectionID: String
    let visibleTitle: String?
    let fields: [ExtensionSettingField]

    var accessibilityIdentifier: String {
        "settings.extension.\(extensionIdentifier).section.\(sectionID)"
    }
}

@MainActor
enum ExtensionSettingsRenderer {
    static func hostSectionModels(
        for page: ExtensionHostSettingsPage
    ) -> [ExtensionSettingsSectionModel] {
        ExtensionSettingsRegistry.shared.sections(for: page).map {
            sectionModel(
                extensionIdentifier: $0.extensionIdentifier,
                extensionName: $0.extensionName,
                sectionID: $0.section.id,
                title: $0.section.title,
                fields: $0.section.fields,
                prefixesTitleWithExtension: true
            )
        }
    }

    static func sectionModel(
        extensionIdentifier: String,
        extensionName: String,
        sectionID: String,
        title: String?,
        fields: [ExtensionSettingField],
        prefixesTitleWithExtension: Bool
    ) -> ExtensionSettingsSectionModel {
        let visibleTitle: String?
        if prefixesTitleWithExtension {
            visibleTitle = title.map { "\(extensionName) — \($0)" } ?? extensionName
        } else {
            visibleTitle = title
        }
        return ExtensionSettingsSectionModel(
            extensionIdentifier: extensionIdentifier,
            sectionID: sectionID,
            visibleTitle: visibleTitle,
            fields: fields
        )
    }

    /// One materialized field. The wrapper owns the handler for exactly as long as the recycled
    /// cell owns the control; `NSControl.target` itself is not an ownership boundary.
    static func fieldRow(
        in section: ExtensionSettingsSectionModel,
        fieldIndex: Int
    ) -> NSView {
        guard section.fields.indices.contains(fieldIndex) else { return NSView() }
        let field = section.fields[fieldIndex]
        let handler = ExtensionSettingActionTarget(
            extensionIdentifier: section.extensionIdentifier,
            field: field
        )
        let control = handler.makeControl()
        control.setAccessibilityIdentifier(
            "settings.extension.\(section.extensionIdentifier).\(field.id)"
        )
        let content = SettingsUI.row(
            title: field.title,
            subtitle: field.description,
            control: control,
            localizes: false
        )
        let row = RetainingExtensionSettingRow(content: content, handler: handler)
        if fieldIndex == 0, section.visibleTitle == nil {
            row.setAccessibilityIdentifier(section.accessibilityIdentifier)
        }
        return row
    }
}

/// `NSControl.target` is not an ownership boundary. One materialized row retains its action
/// target for exactly as long as the recycled control remains in the hierarchy.
private final class RetainingExtensionSettingRow: NSView {
    private let handler: ExtensionSettingActionTarget

    init(
        content: NSView,
        handler: ExtensionSettingActionTarget
    ) {
        self.handler = handler
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// One scroll owner for fixed built-in sections and arbitrarily many extension fields.
///
/// Built-in sections remain coarse rows because their cardinality is fixed and their controllers
/// often retain specific controls. Extension captions and fields are cheap row identities; AppKit
/// materializes only the visible field controls and releases their action targets on reuse.
@MainActor
final class ExtensionSettingsListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum PresentationRow {
        case baseSection(Int)
        case extensionCaption(Int)
        case extensionField(section: Int, field: Int)
    }

    private let baseSections: [NSView]
    private let extensionSections: [ExtensionSettingsSectionModel]
    private let presentationRows: [PresentationRow]

    private lazy var tableView: ThemedGroupedTableView = {
        let table = ThemedGroupedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("ExtensionSettingsContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = ExtensionSettingsListDefaults.estimatedRowHeight
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        return table
    }()

    private lazy var scrollView: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = tableView
        return scroll
    }()

    init(
        baseSections: [NSView],
        extensionSections: [ExtensionSettingsSectionModel]
    ) {
        self.baseSections = baseSections
        self.extensionSections = extensionSections
        presentationRows = Self.makePresentationRows(
            baseSectionCount: baseSections.count,
            extensionSections: extensionSections
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        updateCardDecorations()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ThemedVirtualTableCell)?.setColumnWidth(width)
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        presentationRows.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard presentationRows.indices.contains(tableRow) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ExtensionSettingsVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier
        host.install(
            content(for: presentationRows[tableRow]),
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Size.glowGutter,
            topInset: topInset(for: presentationRows[tableRow]),
            bottomInset: bottomInset(forRowAt: tableRow)
        )
        return host
    }

    private static func makePresentationRows(
        baseSectionCount: Int,
        extensionSections: [ExtensionSettingsSectionModel]
    ) -> [PresentationRow] {
        var rows = (0..<baseSectionCount).map(PresentationRow.baseSection)
        for (sectionIndex, section) in extensionSections.enumerated() {
            if section.visibleTitle != nil {
                rows.append(.extensionCaption(sectionIndex))
            }
            rows.append(contentsOf: section.fields.indices.map {
                .extensionField(section: sectionIndex, field: $0)
            })
        }
        return rows
    }

    private func content(for row: PresentationRow) -> NSView {
        switch row {
        case .baseSection(let index):
            return baseSections.indices.contains(index) ? baseSections[index] : NSView()
        case .extensionCaption(let sectionIndex):
            guard extensionSections.indices.contains(sectionIndex),
                  let title = extensionSections[sectionIndex].visibleTitle else { return NSView() }
            let caption = SettingsUI.caption(title, localizes: false)
            caption.setAccessibilityIdentifier(
                extensionSections[sectionIndex].accessibilityIdentifier
            )
            return caption
        case .extensionField(let sectionIndex, let fieldIndex):
            guard extensionSections.indices.contains(sectionIndex) else { return NSView() }
            return ExtensionSettingsRenderer.fieldRow(
                in: extensionSections[sectionIndex],
                fieldIndex: fieldIndex
            )
        }
    }

    private func topInset(for row: PresentationRow) -> CGFloat {
        switch row {
        case .baseSection, .extensionCaption:
            return Design.Spacing.large
        case .extensionField(let sectionIndex, let fieldIndex):
            guard fieldIndex == 0, extensionSections.indices.contains(sectionIndex) else {
                return 0
            }
            return extensionSections[sectionIndex].visibleTitle == nil ? Design.Spacing.large : 0
        }
    }

    private func bottomInset(forRowAt row: Int) -> CGFloat {
        guard presentationRows.indices.contains(row) else { return 0 }
        if case .extensionCaption = presentationRows[row] {
            return Design.Spacing.small
        }
        return row == presentationRows.count - 1 ? Design.Spacing.large : 0
    }

    private func updateCardDecorations() {
        var boundsBySection: [Int: (first: Int, last: Int)] = [:]
        for (rowIndex, row) in presentationRows.enumerated() {
            guard case .extensionField(let sectionIndex, _) = row else { continue }
            if var bounds = boundsBySection[sectionIndex] {
                bounds.last = rowIndex
                boundsBySection[sectionIndex] = bounds
            } else {
                boundsBySection[sectionIndex] = (rowIndex, rowIndex)
            }
        }
        tableView.cardDecorations = boundsBySection.sorted { $0.key < $1.key }.map {
            let section = extensionSections[$0.key]
            return ThemedTableCardDecoration(
                rows: $0.value.first...$0.value.last,
                topInset: section.visibleTitle == nil ? Design.Spacing.large : 0,
                bottomInset: $0.value.last == presentationRows.count - 1
                    ? Design.Spacing.large
                    : 0
            )
        }
    }

    var virtualRowCount: Int { presentationRows.count }

    var materializedRowCount: Int {
        var count = 0
        tableView.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }
}

private enum ExtensionSettingsListDefaults {
    static let estimatedRowHeight: CGFloat = 64
}

@MainActor
private final class ExtensionSettingActionTarget: NSObject {
    private let extensionIdentifier: String
    private let field: ExtensionSettingField
    private weak var control: NSControl?

    init(extensionIdentifier: String, field: ExtensionSettingField) {
        self.extensionIdentifier = extensionIdentifier
        self.field = field
    }

    func makeControl() -> NSControl {
        let value = ExtensionManager.shared.settingValue(
            extensionIdentifier: extensionIdentifier,
            field: field
        )
        let made: NSControl

        switch field.control {
        case .toggle:
            let toggle = SettingsUI.toggle(
                isOn: value.boolValue ?? false,
                target: self,
                action: #selector(valueChanged(_:))
            )
            made = toggle

        case .text(_, let placeholder, _):
            let text = SettingsUI.textField(
                target: self,
                action: #selector(valueChanged(_:))
            )
            text.stringValue = value.stringValue ?? ""
            text.placeholderString = placeholder
            made = text

        case .choice(_, let options):
            let popUp = SettingsUI.popUp(
                target: self,
                action: #selector(valueChanged(_:))
            )
            options.forEach { popUp.addItem(withTitle: $0.title) }
            let selectedID = value.stringValue
            popUp.selectItem(at: options.firstIndex { $0.id == selectedID } ?? 0)
            made = popUp

        case .integer(_, let minimum, let maximum, _):
            let text = SettingsUI.textField(
                target: self,
                action: #selector(valueChanged(_:))
            )
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.allowsFloats = false
            formatter.minimum = NSNumber(value: minimum)
            formatter.maximum = NSNumber(value: maximum)
            text.formatter = formatter
            text.stringValue = String(value.integerValue ?? minimum)
            made = text
        }

        control = made
        return made
    }

    @objc private func valueChanged(_ sender: NSControl) {
        guard let proposedValue = proposedValue(from: sender) else {
            restoreControl()
            return
        }

        sender.isEnabled = false
        ExtensionManager.shared.setSetting(
            extensionIdentifier: extensionIdentifier,
            settingID: field.id,
            value: proposedValue
        ) { [weak self, weak sender] result in
            guard let self else { return }
            sender?.isEnabled = true
            switch result {
            case .success:
                self.restoreControl()
            case .failure(let error):
                self.restoreControl()
                self.present(error)
            }
        }
    }

    private func proposedValue(from sender: NSControl) -> ExtensionJSONValue? {
        switch field.control {
        case .toggle:
            guard let toggle = sender as? ThemedToggle else { return nil }
            return .bool(toggle.state == .on)

        case .text:
            guard let text = sender as? NSTextField else { return nil }
            return .string(text.stringValue)

        case .choice(_, let options):
            guard let popUp = sender as? ThemedPopUp,
                  options.indices.contains(popUp.indexOfSelectedItem) else {
                return nil
            }
            return .string(options[popUp.indexOfSelectedItem].id)

        case .integer(_, let minimum, let maximum, let step):
            guard let text = sender as? NSTextField,
                  let parsed = Int64(text.stringValue) else {
                return nil
            }
            let clamped = min(max(parsed, minimum), maximum)
            let stepped = minimum + ((clamped - minimum) / step) * step
            return .integer(stepped)
        }
    }

    private func restoreControl() {
        guard let control else { return }
        let value = ExtensionManager.shared.settingValue(
            extensionIdentifier: extensionIdentifier,
            field: field
        )
        switch (field.control, control) {
        case (.toggle, let toggle as ThemedToggle):
            toggle.state = value.boolValue == true ? .on : .off
        case (.text, let text as NSTextField):
            text.stringValue = value.stringValue ?? ""
        case (.choice(_, let options), let popUp as ThemedPopUp):
            popUp.selectItem(at: options.firstIndex { $0.id == value.stringValue } ?? 0)
        case (.integer(_, let minimum, _, _), let text as NSTextField):
            text.stringValue = String(value.integerValue ?? minimum)
        default:
            break
        }
    }

    private func present(_ error: Error) {
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Couldn’t Change Extension Setting")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.string("OK"))
        if let window = control?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

private extension ExtensionJSONValue {
    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integerValue: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }
}
