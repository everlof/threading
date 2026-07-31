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
        view = SettingsUI.page(
            registeredPage.page.sections.map {
                ExtensionSettingsRenderer.section(
                    extensionIdentifier: registeredPage.extensionIdentifier,
                    extensionName: registeredPage.extensionName,
                    sectionID: $0.id,
                    title: $0.title,
                    fields: $0.fields,
                    prefixesTitleWithExtension: false
                )
            }
        )
    }
}

@MainActor
enum ExtensionSettingsRenderer {
    static func hostSections(
        for page: ExtensionHostSettingsPage
    ) -> [NSView] {
        ExtensionSettingsRegistry.shared.sections(for: page).map {
            section(
                extensionIdentifier: $0.extensionIdentifier,
                extensionName: $0.extensionName,
                sectionID: $0.section.id,
                title: $0.section.title,
                fields: $0.section.fields,
                prefixesTitleWithExtension: true
            )
        }
    }

    static func section(
        extensionIdentifier: String,
        extensionName: String,
        sectionID: String,
        title: String?,
        fields: [ExtensionSettingField],
        prefixesTitleWithExtension: Bool
    ) -> NSView {
        var handlers: [ExtensionSettingActionTarget] = []
        let rows = fields.map { field -> NSView in
            let handler = ExtensionSettingActionTarget(
                extensionIdentifier: extensionIdentifier,
                field: field
            )
            handlers.append(handler)
            let control = handler.makeControl()
            control.setAccessibilityIdentifier(
                "settings.extension.\(extensionIdentifier).\(field.id)"
            )
            return SettingsUI.row(
                title: field.title,
                subtitle: field.description,
                control: control,
                localizes: false
            )
        }

        let visibleTitle: String?
        if prefixesTitleWithExtension {
            visibleTitle = title.map { "\(extensionName) — \($0)" } ?? extensionName
        } else {
            visibleTitle = title
        }
        let content = SettingsUI.section(
            visibleTitle,
            SettingsCard(rows: rows),
            localizesTitle: false
        )
        return RetainingExtensionSettingsSection(
            content: content,
            handlers: handlers,
            accessibilityIdentifier: "settings.extension.\(extensionIdentifier).section.\(sectionID)"
        )
    }
}

/// `NSControl.target` is not an ownership boundary. The section retains action targets for as
/// long as its controls are in the hierarchy, including sections appended to built-in pages.
private final class RetainingExtensionSettingsSection: NSView {
    private let handlers: [ExtensionSettingActionTarget]

    init(
        content: NSView,
        handlers: [ExtensionSettingActionTarget],
        accessibilityIdentifier: String
    ) {
        self.handlers = handlers
        super.init(frame: .zero)
        setAccessibilityIdentifier(accessibilityIdentifier)
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
