import ThreadingRemoteKit
import UIKit

/// The composer's model, effort, permission and speed settings as one line of compact chips
/// beneath the prompt. The text field is the subject, so each chip shows only its current value
/// behind a glyph naming the setting; the setting's name lives in the menu title and the
/// accessibility label. The line scrolls sideways instead of wrapping, so larger text sizes
/// make the chips taller but never add rows above the keyboard. Catalogues stay as values until
/// a menu is opened.
@MainActor
final class MobileConversationSettingsView: UIView {
    var onChoose: ((RemoteConversationConfigurationDTO.Setting, String?) -> Void)?
    private let scrollView = UIScrollView()
    private let chipStack = UIStackView()
    private var buttons: [RemoteConversationConfigurationDTO.Setting: UIButton] = [:]
    private var configuration: RemoteConversationConfigurationDTO?
    private var palette: RemoteThemePalette?
    private var allowsChanges = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.clipsToBounds = false
        addSubview(scrollView)
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipStack.axis = .horizontal
        chipStack.alignment = .center
        chipStack.spacing = MobileDesign.Spacing.tight
        scrollView.addSubview(chipStack)
        for setting in RemoteConversationConfigurationDTO.Setting.allCases {
            let button = UIButton(type: .system)
            button.showsMenuAsPrimaryAction = true
            button.isHidden = true
            button.accessibilityIdentifier = "conversation.setting.\(setting.rawValue)"
            button.heightAnchor.constraint(
                greaterThanOrEqualToConstant: MobileDesign.Size.composerSettingChip
            ).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            MobileButtonHaptics.install(on: button, activationEvent: .menuActionTriggered)
            buttons[setting] = button
            chipStack.addArrangedSubview(button)
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            chipStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            chipStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            chipStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _: UITraitCollection) in
            guard let palette = view.palette else { return }
            view.palette = nil
            view.update(view.configuration, theme: palette, allowsChanges: view.allowsChanges)
        }
        isHidden = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The chip for `setting`, while the host offers it.
    func chip(for setting: RemoteConversationConfigurationDTO.Setting) -> UIButton? {
        buttons[setting].flatMap { $0.isHidden ? nil : $0 }
    }

    func update(_ configuration: RemoteConversationConfigurationDTO?, theme: RemoteThemePalette, allowsChanges: Bool) {
        guard self.configuration != configuration || palette != theme || self.allowsChanges != allowsChanges else { return }
        self.configuration = configuration
        palette = theme
        self.allowsChanges = allowsChanges
        let controls = configuration?.controls ?? []
        isHidden = controls.isEmpty
        let offered = Set(controls.map(\.setting))
        for (setting, button) in buttons where !offered.contains(setting) { button.isHidden = true }
        for control in controls {
            guard let button = buttons[control.setting] else { continue }
            configure(button, for: control, theme: theme, canChange: allowsChanges && control.isEnabled)
        }
    }

    private func configure(
        _ button: UIButton,
        for control: RemoteConversationConfigurationDTO.Control,
        theme: RemoteThemePalette,
        canChange: Bool
    ) {
        let ink = canChange ? theme.uiLabel : theme.uiSecondaryLabel
        var style = UIButton.Configuration.plain()
        style.attributedTitle = AttributedString(NSAttributedString(
            string: control.title,
            attributes: [.font: theme.chromeFont(forTextStyle: .caption1), .foregroundColor: ink]
        ))
        style.image = UIImage(systemName: symbol(control.setting))
        style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .caption2)
        style.imageColorTransformer = UIConfigurationColorTransformer { _ in theme.uiSecondaryLabel }
        style.imagePadding = MobileDesign.Spacing.tight
        style.titleLineBreakMode = .byTruncatingTail
        style.cornerStyle = .fixed
        style.background.cornerRadius = theme.controlRadius
        style.background.backgroundColor = theme.uiControlResting
        style.contentInsets = .init(
            top: MobileDesign.Spacing.tight, leading: MobileDesign.Spacing.small,
            bottom: MobileDesign.Spacing.tight, trailing: MobileDesign.Spacing.small
        )
        button.configuration = style
        button.layer.cornerRadius = theme.controlRadius
        button.layer.cornerCurve = .continuous
        button.isEnabled = canChange
        button.isHidden = false
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

    private func label(_ setting: RemoteConversationConfigurationDTO.Setting) -> String {
        switch setting {
        case .model: MobileL10n.string("Model")
        case .effort: MobileL10n.string("Effort")
        case .permissions: MobileL10n.string("Permissions")
        case .speed: MobileL10n.string("Speed")
        }
    }

    private func symbol(_ setting: RemoteConversationConfigurationDTO.Setting) -> String {
        switch setting {
        case .model: "cpu"
        case .effort: "brain"
        case .permissions: "lock.shield"
        case .speed: "bolt"
        }
    }
}
