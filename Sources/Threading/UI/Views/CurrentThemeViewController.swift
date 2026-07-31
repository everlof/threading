import AppKit

/// The active app theme as a living workspace document beside the conversation.
///
/// This is intentionally separate from both Settings and the per-session tab list. There is one
/// app chrome for the whole window, while terminal palettes can be assigned at session, project,
/// and default scopes. The document always follows `AppThemeLibrary.current`: a colour changed
/// here repaints the window immediately, and a patch arriving through MCP or an extension's
/// watched document is reflected in these controls without reopening it.
final class CurrentThemeViewController: NSViewController {

    // MARK: - Properties

    private let appEvents = AppEventObservations()
    private let colorEditor = CurrentAppThemeColorEditor()

    private var displayedThemeID: AppThemeID?
    private var selectedVariantKind: AppTheme.VariantKind = .light

    private weak var sourceSubtitle: NSTextField?
    private weak var appearanceSubtitle: NSTextField?
    private weak var materialSubtitle: NSTextField?
    private weak var sidebarSubtitle: NSTextField?
    private weak var terminalSubtitle: NSTextField?

    private lazy var themePopUp: ThemedPopUp = {
        let popUp = SettingsUI.popUp(target: self, action: #selector(themeChanged))
        popUp.setAccessibilityIdentifier("current-theme.theme")
        return popUp
    }()

    private lazy var variantPopUp: ThemedPopUp = {
        let popUp = SettingsUI.popUp(target: self, action: #selector(variantChanged))
        popUp.setAccessibilityIdentifier("current-theme.variant")
        return popUp
    }()

    private lazy var duplicateButton: ThemedButton = {
        let button = SettingsUI.button(
            "Duplicate to Edit",
            target: self,
            action: #selector(duplicateToEdit)
        )
        button.setAccessibilityIdentifier("current-theme.duplicate")
        return button
    }()

    private lazy var validationNote: NSTextField = {
        let note = SettingsUI.note("")
        note.textColor = Design.Status.negative
        note.isHidden = true
        note.setAccessibilityIdentifier("current-theme.validation")
        return note
    }()

    // MARK: - Lifecycle

    override func loadView() {
        let root = CurrentThemeAppearanceObservingView()
        root.onAppearanceChange = { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.reload(followCurrentAppearance: true)
        }
        root.setAccessibilityIdentifier("current-theme")
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()

        colorEditor.onChange = { [weak self] role, color in
            self?.change(color, for: role)
        }

        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.reload(followCurrentAppearance: false)
        }
        appEvents.observe(AppThemeLibraryDidChange.self) { [weak self] _ in
            self?.reload(followCurrentAppearance: false)
        }

        reload(followCurrentAppearance: true)
    }

    // MARK: - Setup

    private func setupUI() {
        let page = SettingsUI.page([
            SettingsUI.heading("Current Theme"),
            SettingsUI.section("Theme", overviewCard()),
            SettingsUI.section("Colors", colorEditor),
            validationNote,
            SettingsUI.section("Edit with an Agent", agentHelpCard())
        ])

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func overviewCard() -> NSView {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Active theme",
                subtitle: "The app-wide chrome shown in this window.",
                control: themePopUp
            ),
            SettingsUI.row(
                title: "Source",
                subtitle: "",
                control: duplicateButton,
                subtitleField: &sourceSubtitle
            ),
            SettingsUI.row(
                title: "Appearance",
                subtitle: "",
                control: variantPopUp,
                subtitleField: &appearanceSubtitle
            ),
            SettingsUI.row(
                title: "Material",
                subtitle: "",
                subtitleField: &materialSubtitle
            ),
            SettingsUI.row(
                title: "Sidebar",
                subtitle: "",
                subtitleField: &sidebarSubtitle
            ),
            SettingsUI.row(
                title: "Paired terminal",
                subtitle: "",
                subtitleField: &terminalSubtitle
            )
        ])
    }

    private func agentHelpCard() -> NSView {
        SettingsCard(rows: [
            SettingsUI.detailRow(
                symbol: "sparkles",
                title: "Describe what looks wrong",
                detail: "Try: “Use Threading’s app-theme MCP tools to make my current theme "
                    + "warmer and soften the sidebar.” The agent can inspect it with "
                    + "get_app_theme, duplicate a locked theme with duplicate_app_theme "
                    + "(apply: true), and make live changes with update_app_theme."
            )
        ])
    }

    // MARK: - Reloading

    /// Re-reads the active value instead of retaining a copy, because an MCP update keeps the
    /// stable ID and replaces the document beneath it.
    private func reload(followCurrentAppearance: Bool) {
        let theme = AppThemeLibrary.current
        let kinds = inspectableKinds(for: theme)
        let themeChanged = displayedThemeID != theme.id

        if followCurrentAppearance || themeChanged || !kinds.contains(selectedVariantKind) {
            let current = theme.variantKind(for: view.effectiveAppearance)
            selectedVariantKind = kinds.contains(current) ? current : kinds[0]
        }
        displayedThemeID = theme.id

        reloadThemePopUp(theme)
        reloadVariantPopUp(kinds)

        let editable = AppThemeLibrary.isCustom(theme)
        duplicateButton.isHidden = editable
        sourceSubtitle?.stringValue = sourceDescription(for: theme)
        appearanceSubtitle?.stringValue = appearanceDescription(for: theme)

        let appearance = appearance(for: selectedVariantKind)
        let variant = theme.variant(selectedVariantKind)
            ?? theme.variant(selectedVariantKind == .light ? .dark : .light)
        let material = variant?.material ?? theme.material(for: appearance)
        materialSubtitle?.stringValue = materialDescription(material)
        sidebarSubtitle?.stringValue = sidebarDescription(variant?.sidebar)

        let terminal = variant?.terminalPalette ?? theme.terminalPalette(for: appearance)
        terminalSubtitle?.stringValue = L10n.format(
            "%@ background · %@ text",
            terminal.background.hexString,
            terminal.foreground.hexString
        )

        colorEditor.show(
            theme,
            variant: selectedVariantKind,
            isEditable: editable
        )
        validationNote.isHidden = true
    }

    private func reloadThemePopUp(_ selected: AppTheme) {
        themePopUp.removeAllItems()
        for theme in AppThemeLibrary.all {
            let suffix: String
            if AppThemeLibrary.isCustom(theme) {
                suffix = L10n.string("Custom")
            } else if let contributor = AppThemeLibrary.contributorName(of: theme) {
                suffix = contributor
            } else {
                suffix = L10n.string("Built-in")
            }
            themePopUp.addItem(
                ThemedMenuItem(
                    title: "\(theme.name) — \(suffix)",
                    representedValue: theme.id.rawValue
                )
            )
        }
        themePopUp.selectItem(
            at: AppThemeLibrary.all.firstIndex { $0.id == selected.id } ?? 0
        )
    }

    private func reloadVariantPopUp(_ kinds: [AppTheme.VariantKind]) {
        variantPopUp.removeAllItems()
        for kind in kinds {
            variantPopUp.addItem(
                ThemedMenuItem(
                    title: variantTitle(kind),
                    representedValue: kind.rawValue
                )
            )
        }
        variantPopUp.selectItem(at: kinds.firstIndex(of: selectedVariantKind) ?? 0)
        variantPopUp.isEnabled = kinds.count > 1
    }

    private func inspectableKinds(for theme: AppTheme) -> [AppTheme.VariantKind] {
        let kinds = theme.isSystem ? AppTheme.VariantKind.allCases : theme.availableVariants
        return kinds.isEmpty ? [theme.variantKind(for: view.effectiveAppearance)] : kinds
    }

    private func sourceDescription(for theme: AppTheme) -> String {
        if AppThemeLibrary.isCustom(theme) {
            return L10n.string("Custom theme · Editable. Color changes apply immediately.")
        }
        if let contributor = AppThemeLibrary.contributorName(of: theme) {
            return L10n.format(
                "Extension “%@” · Locked. Duplicate it to edit a copy.",
                contributor
            )
        }
        return L10n.string("Built-in theme · Locked. Duplicate it to edit a copy.")
    }

    private func appearanceDescription(for theme: AppTheme) -> String {
        let mode: String
        switch theme.mode {
        case .system: mode = L10n.string("Adaptive")
        case .light: mode = L10n.string("Fixed light")
        case .dark: mode = L10n.string("Fixed dark")
        }
        return L10n.format("%@ · Viewing the %@ colors.", mode, variantTitle(selectedVariantKind))
    }

    private func variantTitle(_ kind: AppTheme.VariantKind) -> String {
        switch kind {
        case .light: return L10n.string("Light")
        case .dark: return L10n.string("Dark")
        }
    }

    private func materialDescription(_ material: AppTheme.Material) -> String {
        let typeface: String
        if let family = material.fontFamily {
            typeface = family
        } else {
            switch material.typeface {
            case .standard: typeface = L10n.string("System sans")
            case .serif: typeface = L10n.string("Serif")
            case .rounded: typeface = L10n.string("Rounded")
            case .monospaced: typeface = L10n.string("Monospaced")
            }
        }
        return "\(typeface) · \(points(material.panelRadius)) panels · "
            + "\(points(material.controlRadius)) controls · \(points(material.borderWidth)) rules"
    }

    private func sidebarDescription(_ sidebar: SidebarStyle?) -> String {
        guard let sidebar else {
            return L10n.string("Plain themed surface with the default Threading brand.")
        }

        var parts: [String] = []
        if sidebar.background?.gradient != nil { parts.append(L10n.string("gradient")) }
        if sidebar.background?.image != nil { parts.append(L10n.string("image")) }
        if sidebar.brand != nil { parts.append(L10n.string("custom brand")) }
        return parts.isEmpty
            ? L10n.string("Plain themed surface with the default Threading brand.")
            : parts.joined(separator: " · ")
    }

    private func points(_ value: CGFloat) -> String {
        String(format: "%gpt", Double(value))
    }

    private func appearance(for kind: AppTheme.VariantKind) -> NSAppearance {
        kind.appearance ?? view.effectiveAppearance
    }

    // MARK: - Actions

    @objc private func themeChanged(_ sender: ThemedPopUp) {
        guard let raw = sender.selectedItem?.representedValue as? String,
              let theme = AppThemeLibrary.theme(withID: AppThemeID(raw)) else { return }
        AppThemeLibrary.apply(theme)
    }

    @objc private func variantChanged(_ sender: ThemedPopUp) {
        guard let raw = sender.selectedItem?.representedValue as? String,
              let kind = AppTheme.VariantKind(rawValue: raw) else { return }
        selectedVariantKind = kind
        reload(followCurrentAppearance: false)
    }

    @objc private func duplicateToEdit() {
        let source = AppThemeLibrary.current
        do {
            let copy = try AppThemeLibrary.duplicate(
                source,
                name: AppThemeLibrary.uniqueCopyName(of: source)
            )
            AppThemeLibrary.apply(copy)
        } catch {
            showValidation(error.localizedDescription)
        }
    }

    /// Changes one authored role through the same assembly, validation, store, and repaint path
    /// used by `update_app_theme`. Nothing on the page keeps a side copy after this returns.
    private func change(_ color: NSColor, for role: AppThemeRole) {
        let theme = AppThemeLibrary.current
        guard AppThemeLibrary.isCustom(theme),
              let source = theme.variant(selectedVariantKind) else { return }

        var roles = source.roles
        roles[role] = color.usingColorSpace(.sRGB) ?? color

        var variants = theme.variants
        variants[selectedVariantKind] = AppTheme.Variant(
            roles: roles,
            terminalPalette: source.terminalPalette,
            material: source.material,
            sidebar: source.sidebar
        )

        do {
            let updated = try AppThemeEditing.assemble(
                id: theme.id,
                name: theme.name,
                mode: theme.mode,
                summary: theme.summary,
                variants: variants
            )
            try AppThemeLibrary.update(updated)
        } catch {
            showValidation(error.localizedDescription)
            // The swatch already followed the system colour panel. Put it back on the durable
            // value when validation refuses the proposed document.
            colorEditor.show(
                AppThemeLibrary.current,
                variant: selectedVariantKind,
                isEditable: true
            )
        }
    }

    private func showValidation(_ message: String) {
        validationNote.stringValue = message
        validationNote.isHidden = false
        validationNote.setAccessibilityValue(message)
    }
}

// MARK: - Color Editor

/// The thirteen roles a theme authors, grouped into the same semantic vocabulary the app and
/// MCP use. Derived roles stay out of the form: editing both a source and its consequence would
/// make the result depend on which control happened to move last.
final class CurrentAppThemeColorEditor: NSView {

    var onChange: ((AppThemeRole, NSColor) -> Void)?

    private struct Group {
        let title: String
        let roles: [AppThemeRole]
    }

    private static let groups = [
        Group(title: "Surfaces", roles: [.ground, .surface, .panel]),
        Group(title: "Ink", roles: [.border, .label, .accent]),
        Group(
            title: "Status",
            roles: [.statusPositive, .statusWarning, .statusNegative]
        ),
        Group(
            title: "Syntax",
            roles: [.syntaxKeyword, .syntaxType, .syntaxString, .syntaxNumber]
        )
    ]

    private var controls: [AppThemeRole: CurrentAppThemeRoleControl] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let sections = Self.groups.map(makeGroup)
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        _ theme: AppTheme,
        variant kind: AppTheme.VariantKind,
        isEditable: Bool
    ) {
        let appearance = kind.appearance ?? effectiveAppearance
        for role in AppThemeRole.authored {
            controls[role]?.show(
                theme.resolved(role, appearance: appearance),
                isEditable: isEditable
            )
        }
    }

    private func makeGroup(_ group: Group) -> NSView {
        let rows = group.roles.map { role in
            let control = CurrentAppThemeRoleControl(role: role)
            control.onChange = { [weak self] color in self?.onChange?(role, color) }
            controls[role] = control
            return SettingsUI.row(
                title: displayName(for: role),
                subtitle: role.wireName,
                control: control
            )
        }
        return SettingsCard(
            rows: [SettingsUI.fullRow(SettingsUI.caption(group.title))] + rows
        )
    }

    private func displayName(for role: AppThemeRole) -> String {
        switch role {
        case .ground: return L10n.string("Window ground")
        case .surface: return L10n.string("Sidebar and panes")
        case .panel: return L10n.string("Panels")
        case .border: return L10n.string("Borders")
        case .label: return L10n.string("Text")
        case .accent: return L10n.string("Accent")
        case .statusPositive: return L10n.string("Positive")
        case .statusWarning: return L10n.string("Warning")
        case .statusNegative: return L10n.string("Negative")
        case .syntaxKeyword: return L10n.string("Keywords")
        case .syntaxType: return L10n.string("Types")
        case .syntaxString: return L10n.string("Strings")
        case .syntaxNumber: return L10n.string("Numbers")
        default:
            // Only `AppThemeRole.authored` enters this editor. Keeping the fallback useful
            // still makes a future authored role legible until it earns tailored copy.
            return role.wireName.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private final class CurrentAppThemeRoleControl: NSView {

    var onChange: ((NSColor) -> Void)?

    private let role: AppThemeRole
    private let swatch = ThemeSwatchView()
    private let hex = NSTextField(labelWithString: "")

    override var intrinsicContentSize: NSSize {
        let labelSize = hex.intrinsicContentSize
        return NSSize(
            width: labelSize.width + Design.Spacing.medium + ThemeEditorLayout.swatch,
            height: max(labelSize.height, ThemeEditorLayout.swatch)
        )
    }

    init(role: AppThemeRole) {
        self.role = role
        super.init(frame: .zero)

        hex.applyFont(.compactCode)
        hex.textColor = Design.Text.secondary
        hex.setContentHuggingPriority(.required, for: .horizontal)

        swatch.setAccessibilityIdentifier("current-theme.color.\(role.wireName)")
        swatch.onChange = { [weak self] color in
            self?.hex.stringValue = color.hexString
            self?.invalidateIntrinsicContentSize()
            self?.onChange?(color)
        }

        let stack = NSStackView(views: [hex, swatch])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ color: NSColor, isEditable: Bool) {
        swatch.setColor(color, name: role.wireName)
        swatch.isEditable = isEditable
        hex.stringValue = color.hexString
        invalidateIntrinsicContentSize()
        swatch.setAccessibilityLabel(
            isEditable
                ? L10n.format("Edit %@ color", role.wireName)
                : L10n.format("%@ color, locked", role.wireName)
        )
    }
}

/// Delivers the one theme change that has no library notification: macOS changing appearance
/// while an adaptive theme remains selected.
private final class CurrentThemeAppearanceObservingView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
