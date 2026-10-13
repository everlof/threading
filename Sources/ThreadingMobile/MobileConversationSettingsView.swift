import ThreadingRemoteKit
import UIKit

/// Four fixed composer controls. Catalogues stay as values until a menu is opened; larger text
/// sizes put each control on its own row rather than squeezing away its value or tap target.
@MainActor
final class MobileConversationSettingsView: UIStackView {
    var onChoose: ((RemoteConversationConfigurationDTO.Setting, String?) -> Void)?
    private var buttons: [RemoteConversationConfigurationDTO.Setting: UIButton] = [:]
    private var configuration: RemoteConversationConfigurationDTO?
    private var palette: RemoteThemePalette?
    private var allowsChanges = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = MobileDesign.Spacing.tight
        isLayoutMarginsRelativeArrangement = true
        directionalLayoutMargins = .init(
            top: MobileDesign.Spacing.small, leading: MobileDesign.Spacing.inset,
            bottom: MobileDesign.Spacing.tight, trailing: MobileDesign.Spacing.inset
        )
        for setting in RemoteConversationConfigurationDTO.Setting.allCases {
            let button = UIButton(type: .system)
            button.showsMenuAsPrimaryAction = true
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.accessibilityIdentifier = "conversation.setting.\(setting.rawValue)"
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget).isActive = true
            MobileButtonHaptics.install(on: button, activationEvent: .menuActionTriggered)
            buttons[setting] = button
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _: UITraitCollection) in
            let configuration = view.configuration
            let palette = view.palette
            view.palette = nil
            if let palette { view.update(configuration, theme: palette, allowsChanges: view.allowsChanges) }
            view.rebuildRows()
        }
        isHidden = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ configuration: RemoteConversationConfigurationDTO?, theme: RemoteThemePalette, allowsChanges: Bool) {
        let needsLayout = self.configuration?.controls.map(\.setting) != configuration?.controls.map(\.setting)
        guard self.configuration != configuration || palette != theme || self.allowsChanges != allowsChanges else { return }
        self.configuration = configuration
        palette = theme
        self.allowsChanges = allowsChanges
        isHidden = configuration?.controls.isEmpty != false
        for control in configuration?.controls ?? [] {
            guard let button = buttons[control.setting] else { continue }
            let canChange = allowsChanges && control.isEnabled
            var style = UIButton.Configuration.plain()
            style.title = control.title
            style.subtitle = label(control.setting)
            style.titleAlignment = .leading
            style.cornerStyle = .fixed
            style.background.cornerRadius = theme.controlRadius
            style.background.backgroundColor = theme.uiControlResting
            style.contentInsets = .init(
                top: MobileDesign.Spacing.tight, leading: MobileDesign.Spacing.small,
                bottom: MobileDesign.Spacing.tight, trailing: MobileDesign.Spacing.small
            )
            style.attributedTitle = AttributedString(NSAttributedString(
                string: control.title,
                attributes: [.font: theme.chromeFont(forTextStyle: .footnote),
                             .foregroundColor: canChange ? theme.uiLabel : theme.uiSecondaryLabel]
            ))
            style.attributedSubtitle = AttributedString(NSAttributedString(
                string: label(control.setting),
                attributes: [.font: theme.chromeFont(forTextStyle: .caption2), .foregroundColor: theme.uiSecondaryLabel]
            ))
            button.configuration = style
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.titleLabel?.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 1
            button.layer.cornerRadius = theme.controlRadius
            button.layer.cornerCurve = .continuous
            button.isEnabled = canChange
            button.accessibilityLabel = "\(label(control.setting)), \(control.title)"
            button.accessibilityHint = control.isEnabled ? nil : MobileL10n.string("This setting cannot be changed right now.")
            button.menu = UIMenu(title: label(control.setting), children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(control.choices.map { choice in
                    let action = UIAction(title: choice.title, state: choice.isSelected ? .on : .off) { [weak self] _ in
                        self?.onChoose?(control.setting, choice.value)
                    }
                    action.subtitle = choice.detail
                    return action
                })
            }])
        }
        if needsLayout { rebuildRows() }
    }

    private func rebuildRows() {
        arrangedSubviews.forEach {
            removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let controls = configuration?.controls ?? []
        let columns = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 1 : 2
        for offset in stride(from: 0, to: controls.count, by: columns) {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = MobileDesign.Spacing.tight
            for control in controls.dropFirst(offset).prefix(columns) {
                if let button = buttons[control.setting] { row.addArrangedSubview(button) }
            }
            addArrangedSubview(row)
        }
    }

    private func label(_ setting: RemoteConversationConfigurationDTO.Setting) -> String {
        switch setting {
        case .model: MobileL10n.string("Model")
        case .effort: MobileL10n.string("Effort")
        case .permissions: MobileL10n.string("Permissions")
        case .speed: MobileL10n.string("Speed")
        }
    }
}
