import AppKit
import ThreadingExtensionKit

/// Theme Options on the Current Theme page: the settings of the extension that ships the active
/// theme, beside the theme they shape.
///
/// A theme extension's options — "Perimeter comets: on/off" on its window overlay — are part of
/// how the theme looks, and the person looking at the theme should not have to know which
/// Settings page an extension filed them under. The fields are not copies: each row is the same
/// host-rendered control `ExtensionSettingsRenderer` builds for the extension's own Settings page,
/// reading and writing the same store, so a change here is a change there, and a host-applied
/// field reaches the surface on its next frame.
///
/// Absent — hidden and empty — when the active theme is not contributed by an extension, or its
/// extension is disabled or declares no settings. Rebuilt only when the owning extension or its
/// declaration changes, never on a value change (the rows follow those themselves). One owner's
/// contribution is bounded at `ExtensionSettingsContribution.maximumFields` rows, which is why a
/// retained stack is acceptable here where the aggregating Settings pages virtualize.
@MainActor
final class CurrentThemeOptionsSection: NSView {

    // MARK: - Properties

    private struct Shown: Equatable {
        let extensionIdentifier: String
        let extensionName: String
        let settings: ExtensionSettingsContribution
    }

    private var shown: Shown?

    /// The extension whose options are on show, for tests.
    var extensionIdentifierForTesting: String? { shown?.extensionIdentifier }

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setAccessibilityIdentifier("current-theme.options")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Shows `theme`'s extension options, or nothing when it has none to show.
    func show(for theme: AppTheme) {
        let next = Self.owner(of: theme)
        guard next != shown else { return }
        shown = next
        subviews.forEach { $0.removeFromSuperview() }
        guard let next else {
            isHidden = true
            return
        }

        let content = SettingsUI.section(
            "Theme Options",
            cards(for: next),
            help: HelpTopic(
                title: L10n.string("Theme Options"),
                paragraphs: [L10n.format(
                    "These options come from “%@”, the extension that ships this theme. They are the same settings as on its Settings page, so a change here applies there too.",
                    next.extensionName
                )]
            )
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        isHidden = false
    }

    // MARK: - Private Methods

    /// The enabled extension that contributes `theme` and declares settings. The settings come
    /// from the registry, already localized and present only while the extension is enabled —
    /// the same gate its Settings page has.
    private static func owner(of theme: AppTheme) -> Shown? {
        guard let contribution = ExtensionAppearanceRegistry.shared.contributions.first(where: {
            $0.themes.contains { $0.id == theme.id }
        }),
              let settings = ExtensionSettingsRegistry.shared.settings(
                for: contribution.extensionIdentifier
              ),
              !settings.fields.isEmpty else { return nil }
        return Shown(
            extensionIdentifier: contribution.extensionIdentifier,
            extensionName: contribution.extensionName,
            settings: settings
        )
    }

    /// One card per declared section, in declaration order — a page's sections first, then the
    /// sections it appends to built-in pages — each headed by its own title when it has one.
    private func cards(for owner: Shown) -> NSView {
        let sections: [(id: String, title: String?, fields: [ExtensionSettingField])] =
            owner.settings.pages.flatMap(\.sections).map { ($0.id, $0.title, $0.fields) }
            + owner.settings.sections.map { ($0.id, $0.title, $0.fields) }

        let cards = sections.map { section -> NSView in
            let model = ExtensionSettingsRenderer.sectionModel(
                extensionIdentifier: owner.extensionIdentifier,
                extensionName: owner.extensionName,
                sectionID: section.id,
                title: section.title,
                fields: section.fields,
                prefixesTitleWithExtension: false
            )
            var rows: [NSView] = []
            if sections.count > 1, let title = model.visibleTitle {
                // The extension's own words, already localized by its resolver.
                rows.append(SettingsUI.fullRow(SettingsUI.caption(title, localizes: false)))
            }
            rows += section.fields.indices.map {
                ExtensionSettingsRenderer.fieldRow(in: model, fieldIndex: $0)
            }
            let card = SettingsCard(rows: rows)
            card.setAccessibilityIdentifier("current-theme.options.\(section.id)")
            return card
        }

        let stack = NSStackView(views: cards)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        for card in cards {
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
}
