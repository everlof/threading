import ThreadingRemoteKit
import UIKit

/// Value state outlives a recycled cell, and is pruned as soon as the host settles its request.
@MainActor
final class MobileConversationQuestionDraft {
    var answers: [String: String] = [:]
    var page = 0
}

/// Native inline form: one bounded page, explicit submission, no default answer.
final class MobileConversationQuestionCard: UIView, UITextFieldDelegate {
    let requestID: String
    private var request: RemoteQuestionRequestDTO
    private let draft: MobileConversationQuestionDraft
    private var theme: RemoteThemePalette
    private let column = UIStackView()
    private let body = UIStackView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progress = UILabel()
    private let other = UITextField()
    private let back = UIButton(type: .system)
    private let advanceButton = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private var choices: [UIButton] = []
    private let answer: ([String: String]?) -> Void
    var onLayoutChange: (() -> Void)?

    init(request: RemoteQuestionRequestDTO, draft: MobileConversationQuestionDraft,
         theme: RemoteThemePalette, answer: @escaping ([String: String]?) -> Void) {
        self.request = request; requestID = request.id; self.draft = draft
        self.theme = theme; self.answer = answer
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "conversation.question.\(request.id)"
        for stack in [column, body] {
            stack.axis = .vertical; stack.spacing = MobileDesign.Spacing.medium
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        for (label, style) in [(titleLabel, UIFont.TextStyle.headline), (detailLabel, .subheadline), (progress, .caption1)] {
            label.font = .preferredFont(forTextStyle: style)
            label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0
        }
        titleLabel.text = MobileL10n.string("A question for you")
        titleLabel.accessibilityTraits.insert(.header)

        other.font = .preferredFont(forTextStyle: .body)
        other.adjustsFontForContentSizeCategory = true
        other.placeholder = MobileL10n.string("Write your answer…")
        other.accessibilityLabel = MobileL10n.string("Your answer")
        other.accessibilityIdentifier = "conversation.question.other"
        other.borderStyle = .none
        other.layer.cornerRadius = theme.controlRadius
        other.leftView = UIView(frame: CGRect(x: 0, y: 0, width: MobileDesign.Spacing.medium, height: 1))
        other.leftViewMode = .always
        other.delegate = self
        other.addAction(UIAction { [weak self] _ in self?.textChanged() }, for: .editingChanged)
        other.heightAnchor.constraint(greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget).isActive = true
        for button in [back, advanceButton, cancel] { MobileButtonHaptics.install(on: button) }
        back.addAction(UIAction { [weak self] _ in self?.movePage(-1) }, for: .touchUpInside)
        advanceButton.addAction(UIAction { [weak self] _ in self?.advance() }, for: .touchUpInside)
        cancel.addAction(UIAction { [weak self] _ in self?.finish(nil) }, for: .touchUpInside)
        advanceButton.accessibilityIdentifier = "conversation.question.submit"
        back.accessibilityIdentifier = "conversation.question.back"
        cancel.accessibilityIdentifier = "conversation.question.cancel"
        // A vertical action group survives compact phones and accessibility Dynamic Type.
        for view in [titleLabel, detailLabel, body, progress, back, advanceButton, cancel] { column.addArrangedSubview(view) }
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: MobileDesign.Spacing.inset),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MobileDesign.Spacing.inset),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MobileDesign.Spacing.inset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MobileDesign.Spacing.inset)
        ])
        showPage()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(request: RemoteQuestionRequestDTO, theme: RemoteThemePalette) {
        let changed = self.request != request
        self.request = request; self.theme = theme
        if changed { showPage() } else { applyTheme() }
    }

    private func showPage() {
        guard request.isValid else { return }
        draft.page = min(draft.page, request.questions.count - 1)
        for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
        choices.removeAll()
        let question = request.questions[draft.page]
        let prompt = UILabel()
        prompt.text = question.prompt; prompt.font = .preferredFont(forTextStyle: .body)
        prompt.adjustsFontForContentSizeCategory = true; prompt.numberOfLines = 0
        prompt.textColor = theme.uiLabel; prompt.accessibilityTraits.insert(.header)
        body.addArrangedSubview(prompt)
        for (index, option) in question.options.enumerated() {
            let button = UIButton(type: .system)
            button.accessibilityIdentifier = "conversation.question.option.\(question.id).\(index)"
            button.accessibilityLabel = option.label
            button.accessibilityHint = option.detail
            button.titleLabel?.numberOfLines = 0
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in
                guard let self, request.canAnswer else { return }
                draft.answers[question.id] = option.label; other.text = ""
                refreshSelection()
            }, for: .touchUpInside)
            MobileButtonHaptics.install(on: button)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget).isActive = true
            choices.append(button); body.addArrangedSubview(button)
        }
        other.text = draft.answers[question.id].flatMap { value in
            question.options.contains { $0.label == value } ? nil : value
        } ?? ""
        if question.allowsOther { body.addArrangedSubview(other) }
        progress.text = MobileL10n.string("Question %lld of %lld", Int64(draft.page + 1), Int64(request.questions.count))
        back.isHidden = draft.page == 0
        applyTheme()
    }

    private func applyTheme() {
        applyRemoteSurface(fill: theme.uiPanel, radius: theme.panelRadius,
                           border: theme.uiBorder, borderWidth: theme.borderWidth, glow: theme.glow)
        for label in body.arrangedSubviews.compactMap({ $0 as? UILabel }) { label.textColor = theme.uiLabel }
        titleLabel.textColor = theme.uiLabel
        detailLabel.text = MobileL10n.string(!request.canAnswer ? "This question is read only on this device."
            : request.blocksTurn ? "The agent is waiting for your answer." : "You can answer while work continues.")
        detailLabel.textColor = theme.uiSecondaryLabel
        progress.textColor = theme.uiSecondaryLabel
        other.textColor = theme.uiLabel; other.backgroundColor = theme.uiControlResting
        other.layer.cornerRadius = theme.controlRadius
        other.attributedPlaceholder = NSAttributedString(string: MobileL10n.string("Write your answer…"), attributes: [.foregroundColor: theme.uiTertiaryLabel])
        other.tintColor = theme.uiAccent; other.isEnabled = request.canAnswer
        other.keyboardAppearance = MobileKeyboardAppearance.over(theme.uiGround)
        style(back, title: MobileL10n.string("Back"))
        style(advanceButton, title: MobileL10n.string(draft.page == request.questions.count - 1 ? "Send answer" : "Next"), primary: true)
        style(cancel, title: MobileL10n.string("Cancel"))
        cancel.isEnabled = request.canAnswer
        refreshSelection()
    }

    private func style(_ button: UIButton, title: String, primary: Bool = false) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = primary ? theme.uiAccent : theme.uiControlResting
        config.baseForegroundColor = primary ? theme.uiAccentForeground : theme.uiLabel
        config.cornerStyle = .fixed; config.background.cornerRadius = theme.controlRadius
        config.contentInsets = NSDirectionalEdgeInsets(top: MobileDesign.Spacing.medium, leading: MobileDesign.Spacing.medium,
                                                       bottom: MobileDesign.Spacing.medium, trailing: MobileDesign.Spacing.medium)
        button.configuration = config
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
    }

    private func refreshSelection() {
        let question = request.questions[draft.page]
        for (index, button) in choices.enumerated() {
            let option = question.options[index]
            let selected = draft.answers[question.id] == option.label
            style(button, title: option.label)
            var config = button.configuration!
            config.subtitle = option.detail.isEmpty ? nil : option.detail
            config.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
            config.imagePadding = MobileDesign.Spacing.medium
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                pointSize: MobileDesign.Size.minimumTapTarget - 2 * MobileDesign.Spacing.medium,
                weight: .regular
            )
            config.background.strokeColor = selected ? theme.uiAccent : theme.uiBorder
            config.background.strokeWidth = theme.borderWidth
            button.configuration = config
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
            button.isEnabled = request.canAnswer
        }
        let value = draft.answers[question.id] ?? ""
        let canReviewNextPage = !request.canAnswer && draft.page + 1 < request.questions.count
        advanceButton.isHidden = !request.canAnswer && !canReviewNextPage
        advanceButton.isEnabled = canReviewNextPage || (request.canAnswer && value.utf8.prefix(8001).count <= 8000
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private func textChanged() {
        draft.answers[request.questions[draft.page].id] = other.text ?? ""
        refreshSelection()
    }
    private func movePage(_ offset: Int) {
        endEditing(true); draft.page += offset; showPage(); onLayoutChange?()
        UIAccessibility.post(notification: .layoutChanged, argument: body.arrangedSubviews.first)
    }
    private func advance() {
        guard advanceButton.isEnabled else { return }
        if draft.page + 1 < request.questions.count { movePage(1) }
        else if request.accepts(draft.answers) { finish(draft.answers) }
    }
    private func finish(_ answers: [String: String]?) {
        guard request.canAnswer else { return }
        endEditing(true)
        answer(answers)
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder(); return false
    }
}

final class RemoteConversationQuestionCell: UICollectionViewCell {
    static let reuseIdentifier = "RemoteConversationQuestionCell"
    private var card: MobileConversationQuestionCard?
    override func prepareForReuse() {
        super.prepareForReuse(); card?.removeFromSuperview(); card = nil
    }
    func configure(request: RemoteQuestionRequestDTO, draft: MobileConversationQuestionDraft,
                   theme: RemoteThemePalette, answer: @escaping ([String: String]?) -> Void,
                   layoutChanged: @escaping () -> Void) {
        if let card, card.requestID == request.id {
            card.update(request: request, theme: theme); return
        }
        card?.removeFromSuperview()
        let view = MobileConversationQuestionCard(request: request, draft: draft, theme: theme, answer: answer)
        view.onLayoutChange = layoutChanged
        contentView.addSubview(view); card = view
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor), view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }
}
