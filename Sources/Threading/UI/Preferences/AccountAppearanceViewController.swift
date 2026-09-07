import AppKit
import ThreadingRemoteKit
import UniformTypeIdentifiers

/// A fixed-schema editor for one login (or shared defaults), created only on explicit opening.
/// The host owns persistence, image admission, routing, accessibility and dismissal.
final class AccountAppearanceViewController: NSViewController, NSTextFieldDelegate {
    private let account: AgentAccount?
    private let store: AccountPreferencesStore
    private let automaticName: String
    var onChange: (() -> Void)?
    private var preferences: AccountAppearancePreferences
    private let scope = ThemedPopUp()
    private let mode = ThemedPopUp()
    private let name = ThemedTextField(string: "")
    private let shortName = ThemedTextField(string: "")
    private let badgeText = ThemedTextField(string: "")
    private let background = ThemedTextField(string: "")
    private let foreground = ThemedTextField(string: "")
    private let backgroundSwatch = ThemeSwatchView()
    private let foregroundSwatch = ThemeSwatchView()
    private var flags: [(WritableKeyPath<AccountAppearance, Bool?>, ThemedPopUp)] = []
    private var previewImages: [NSImageView] = []
    private var previewLabels: [NSTextField] = []
    private var previewCaptions: [NSTextField] = []
    private var previewDetails: [NSTextField] = []
    private static let previewSurfaces: [AccountAppearanceSurface?] = [
        .sidebar, .chooser, .details, .usage, .notifications, nil
    ]
    private static let surfaceTitles = ["Sidebar", "Chooser", "Details", "Usage", "Notifications"]
    private let events = AppEventObservations()
    private static let modes = [nil, "automatic", "text", "emoji", "image", "none"]
    private var selectedSurface: AccountAppearanceSurface? {
        let index = scope.indexOfSelectedItem - 1
        return AccountAppearanceSurface.allCases.indices.contains(index)
            ? AccountAppearanceSurface.allCases[index] : nil
    }
    private var style: AccountAppearance {
        get {
            selectedSurface.flatMap { preferences.surfaces?[$0.rawValue] }
                ?? (selectedSurface == nil ? preferences.shared : nil) ?? AccountAppearance()
        }
        set {
            if let selectedSurface {
                var surfaces = preferences.surfaces ?? [:]
                surfaces[selectedSurface.rawValue] = newValue
                preferences.surfaces = surfaces
            } else { preferences.shared = newValue }
        }
    }

    init(account: AgentAccount?, store: AccountPreferencesStore = .shared) {
        self.account = account
        self.store = store
        if let account {
            let automatic = AgentAccount(provider: account.provider, handle: account.handle,
                configPath: account.configPath, displayName: account.discoveredName)
            var siblings = AgentAccountDiscovery.allAccounts(for: account.provider)
                .filter { $0.id != account.id }
            siblings.append(automatic)
            self.automaticName = AccountName.names(for: siblings)[account.id] ?? account.discoveredName
        } else { self.automaticName = "Personal" }
        self.preferences = account.map { store.appearance(for: $0.id) } ?? store.defaultAppearance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let identity: [NSView]
        if let account {
            name.stringValue = store.displayNameOverride(for: account.id) ?? ""
            shortName.stringValue = preferences.shortName ?? ""
            identity = [
                fieldRow("Full name", field: name, placeholder: automaticName),
                fieldRow("Short name", field: shortName, placeholder: L10n.string("Use full name"))
            ]
        } else { identity = [] }
        scope.setAccessibilityIdentifier("account-appearance.scope")
        configure(scope, titles: ["All surfaces", "Sidebar", "Chooser", "Details", "Usage", "Notifications"],
                  action: #selector(scopeChanged))
        configure(mode, titles: ["Inherit", "Automatic", "Text", "Emoji", "Image", "None"],
                  action: #selector(modeChanged))
        let choose = SettingsUI.button("Choose Image…", target: self, action: #selector(chooseImage))
        let reset = SettingsUI.button("Restore this surface", target: self, action: #selector(resetSurface))
        var rows: [NSView] = [
            SettingsUI.row(title: "Apply to", control: scope),
            SettingsUI.row(title: "Badge content", control: mode),
            fieldRow("Text or emoji", field: badgeText, placeholder: L10n.string("Up to 3 characters")),
            SettingsUI.row(title: "Badge image", control: choose),
            colorRow("Background color", field: background, swatch: backgroundSwatch),
            colorRow("Foreground color", field: foreground, swatch: foregroundSwatch)
        ]
        for (title, key) in [
            ("Show badge", \AccountAppearance.showBadge),
            ("Show account name", \AccountAppearance.showName),
            ("Show email", \AccountAppearance.showEmail),
            ("Badge on default account", \AccountAppearance.showDefaultBadge),
            ("Use short name", \AccountAppearance.useShortName)
        ] {
            let popup = ThemedPopUp()
            configure(popup, titles: ["Inherit", "Yes", "No"], action: #selector(visibilityChoiceChanged))
            flags.append((key, popup))
            rows.append(SettingsUI.row(title: title, control: popup))
        }
        rows.append(SettingsUI.row(title: "Inheritance", subtitle: "Blank values follow the shared appearance.", control: reset))
        var previewCells: [NSView] = []
        for title in Self.surfaceTitles + ["iPhone"] {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyDown
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: Design.Size.tabIconSlot).isActive = true
            image.heightAnchor.constraint(equalTo: image.widthAnchor).isActive = true
            let label = NSTextField(labelWithString: "")
            label.applyFont(.body)
            label.textColor = Design.Text.label
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: Design.AccountAppearanceEditor.textWidth).isActive = true
            let line = NSStackView(views: [image, label])
            line.spacing = Design.Spacing.small
            let caption = NSTextField(labelWithString: L10n.string(title))
            caption.applyFont(.caption)
            caption.textColor = Design.Text.secondary
            let detail = NSTextField(labelWithString: "")
            detail.applyFont(.caption)
            detail.textColor = Design.Text.secondary
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let cell = NSStackView(views: [caption, line, detail])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = Design.Spacing.small
            previewImages.append(image)
            previewLabels.append(label)
            previewCaptions.append(caption)
            previewDetails.append(detail)
            label.setAccessibilityIdentifier("account-appearance.preview." + title.lowercased())
            previewCells.append(cell)
        }
        var previewRows: [NSView] = []
        for index in stride(from: 0, to: previewCells.count, by: 2) {
            let pair = NSStackView(views: [previewCells[index], previewCells[index + 1]])
            pair.distribution = .fillEqually
            pair.alignment = .top
            pair.edgeInsets = NSEdgeInsets(top: Design.Spacing.medium, left: Design.Spacing.inset,
                                           bottom: Design.Spacing.medium, right: Design.Spacing.inset)
            pair.spacing = Design.Spacing.medium
            previewRows.append(pair)
        }
        let preview = SettingsUI.section("Preview", SettingsCard(rows: previewRows))
        let form = SettingsUI.page(
            (identity.isEmpty ? [] : [SettingsUI.section("Account name", SettingsCard(rows: identity))])
                + [SettingsUI.section("Appearance", SettingsCard(rows: rows))]
        )
        let content = NSStackView(views: [preview, form])
        content.orientation = .vertical
        content.spacing = Design.Spacing.medium
        content.alignment = .leading
        preview.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        form.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        preview.setContentHuggingPriority(.required, for: .vertical)
        let root = ThemedSurfaceView()
        root.applySurface(fill: Design.Surface.elevated, radius: .fixed(0))
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: Design.Spacing.inset),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Design.Spacing.inset),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Design.Spacing.inset)
        ])
        view = root
        preferredContentSize = NSSize(width: Design.AccountAppearanceEditor.width, height: Design.AccountAppearanceEditor.height)
        events.observe(AccountPreferencesDidChange.self) { [weak self] _ in self?.refreshPreview() }
        refreshFields()
    }

    private func configure(_ popup: ThemedPopUp, titles: [String], action: Selector) {
        titles.forEach { popup.addItem(withTitle: L10n.string($0)) }
        popup.target = self
        popup.action = action
    }

    private func fieldRow(_ title: String, field: ThemedTextField, placeholder: String) -> NSView {
        field.setAccessibilityIdentifier("account-appearance." + title.lowercased().replacingOccurrences(of: " ", with: "-"))
        field.placeholderString = placeholder
        field.delegate = self
        field.applyFont(.body)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Design.AccountAppearanceEditor.textWidth).isActive = true
        return SettingsUI.row(title: title, control: field)
    }

    private func colorRow(_ title: String, field: ThemedTextField, swatch: ThemeSwatchView) -> NSView {
        field.placeholderString = L10n.string("Inherit")
        field.delegate = self
        field.applyFont(.code())
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Design.AccountAppearanceEditor.colorWidth).isActive = true
        swatch.isEditable = true
        swatch.onChange = { [weak self, weak field] color in
            field?.stringValue = color.hexString
            self?.saveFields()
        }
        let automatic = SettingsUI.button("Automatic", target: self, action: #selector(automaticColor(_:)))
        automatic.tag = field === background ? 0 : 1
        let line = NSStackView(views: [field, swatch, automatic])
        line.spacing = Design.Spacing.small
        return SettingsUI.row(title: title, control: line)
    }

    private func refreshFields() {
        let style = style
        mode.selectItem(at: Self.modes.firstIndex(of: style.badgeMode) ?? 0)
        badgeText.stringValue = style.badgeText ?? ""
        background.stringValue = style.backgroundHex ?? ""
        foreground.stringValue = style.foregroundHex ?? ""
        for (key, popup) in flags {
            popup.selectItem(at: style[keyPath: key].map { $0 ? 1 : 2 } ?? 0)
        }
        refreshPreview()
    }

    private func refreshPreview() {
        guard isViewLoaded else { return }
        let sample = account ?? AgentAccount(provider: .codex, handle: .named("preview"),
                                            configPath: "", displayName: "Personal")
        var draft = preferences
        draft.shortName = shortName.stringValue.isEmpty ? nil : shortName.stringValue
        var draftStyle = style
        draftStyle.badgeText = badgeText.stringValue
        draftStyle.backgroundHex = AccountAppearance.normalizedColor(background.stringValue)
        draftStyle.foregroundHex = AccountAppearance.normalizedColor(foreground.stringValue)
        if let selectedSurface {
            var surfaces = draft.surfaces ?? [:]
            surfaces[selectedSurface.rawValue] = draftStyle.normalized()
            draft.surfaces = surfaces
        } else { draft.shared = draftStyle.normalized() }
        let fullName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = AgentAccount(
            provider: sample.provider, handle: sample.handle, configPath: sample.configPath,
            displayName: fullName.isEmpty ? automaticName : fullName,
            displayNameOverride: nil,
            emoji: sample.emoji, isEnabled: sample.isEnabled,
            presentationNameIsResolved: true
        )
        for (index, fixedSurface) in Self.previewSurfaces.enumerated() {
            let surface = fixedSurface ?? selectedSurface ?? .sidebar
            let presentation = AccountPresentation.resolve(current, surface: surface, store: store, draft: account == nil ? nil : draft, defaultsDraft: account == nil ? draft : nil)
            previewImages[index].image = AccountBadge.mark(for: current, surface: surface, store: store, resolved: presentation)
            previewLabels[index].stringValue = presentation.visibleName
            previewLabels[index].setAccessibilityLabel(presentation.name)
            // Notifications display the account label; their icon belongs to the operating system.
            previewImages[index].isHidden = surface == .notifications
            previewDetails[index].stringValue = surface == .notifications
                ? current.provider.displayName
                : (surface == .details || surface == .usage ? presentation.email ?? "" : "")
            previewDetails[index].isHidden = previewDetails[index].stringValue.isEmpty
            previewCaptions[index].applyFont(selectedSurface == surface ? .control : .caption)
            if fixedSurface == nil {
                let titleIndex = AccountAppearanceSurface.allCases.firstIndex(of: surface) ?? 0
                previewCaptions[index].stringValue = L10n.format("%@ — %@", L10n.string("iPhone"),
                                                               L10n.string(Self.surfaceTitles[titleIndex]))
            }
        }
        let selected = AccountPresentation.resolve(current, surface: selectedSurface ?? .details, store: store, draft: account == nil ? nil : draft, defaultsDraft: account == nil ? draft : nil)
        backgroundSwatch.setColor(selected.background, name: L10n.string("Background color"))
        foregroundSwatch.setColor(selected.foreground, name: L10n.string("Foreground color"))
    }

    private func saveFields() {
        if let account {
            store.setDisplayNameOverride(name.stringValue, for: account.id)
            preferences.shortName = shortName.stringValue
        }
        var value = style
        value.badgeText = badgeText.stringValue
        value.backgroundHex = AccountAppearance.normalizedColor(background.stringValue)
        value.foregroundHex = AccountAppearance.normalizedColor(foreground.stringValue)
        style = value
        store.setAppearance(preferences, for: account?.id)
        onChange?()
        refreshPreview()
    }

    func controlTextDidChange(_ notification: Notification) { refreshPreview() }

    func controlTextDidEndEditing(_ notification: Notification) { saveFields() }

    override func viewWillDisappear() {
        view.window?.makeFirstResponder(nil)
        saveFields()
        super.viewWillDisappear()
    }

    @objc private func automaticColor(_ sender: ThemedButton) {
        // localization-ignore: persisted color sentinel, accepted by the hex-color parser
        (sender.tag == 0 ? background : foreground).stringValue = "auto"
        saveFields()
    }

    @objc private func scopeChanged() { refreshFields() }
    @objc private func modeChanged() {
        var value = style
        value.badgeMode = Self.modes[mode.indexOfSelectedItem]
        style = value
        saveFields()
    }
    @objc private func visibilityChoiceChanged() {
        var value = style
        for (key, popup) in flags {
            value[keyPath: key] = popup.indexOfSelectedItem == 0 ? nil : popup.indexOfSelectedItem == 1
        }
        style = value
        saveFields()
    }
    @objc private func resetSurface() {
        if let selectedSurface { preferences.surfaces?[selectedSurface.rawValue] = nil }
        else { preferences.shared = nil }
        store.setAppearance(preferences, for: account?.id)
        refreshFields()
        onChange?()
    }
    @objc private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            AccountImageStore.importImage(url) { [weak self] id in
                guard let self else { return }
                guard let id else {
                    let alert = ThemedAlert()
                    alert.messageText = L10n.string("Could not read image")
                    alert.informativeText = L10n.string("Choose an image smaller than 4 MB.")
                    alert.runModal()
                    return
                }
                var value = style
                value.imageID = id
                value.badgeMode = "image"
                style = value
                store.setAppearance(preferences, for: account?.id)
                refreshFields()
                onChange?()
            }
        }
    }
}
