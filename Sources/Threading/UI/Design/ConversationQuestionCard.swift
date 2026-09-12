import AppKit

/// Host-owned question form. One bounded page is mounted at a time; selections are values keyed
/// by the original question ID. No option is selected or submitted on the user's behalf.
final class ConversationQuestionCard: NSView, NSTextFieldDelegate {
    let request: ConversationQuestionRequest
    private(set) var answers: [String: String] = [:]
    private(set) var page = 0
    var onLayoutChange: (() -> Void)?
    private var completion: (([String: String]?) -> Void)?
    private let column = NSStackView()
    private let body = NSStackView()
    private let progress = NSTextField(labelWithString: "")
    private let other = ThemedTextField(string: "")
    private var optionButtons: [ConversationChoiceRow] = []
    private lazy var back = ThemedButton(title: L10n.string("Back"), target: self, action: #selector(previousQuestion))
    private lazy var next = ThemedButton(title: "", target: self, action: #selector(nextQuestion))
    private lazy var cancel = ThemedButton(title: L10n.string("Cancel"), target: self, action: #selector(cancelQuestion))

    init(request: ConversationQuestionRequest, completion: @escaping ([String: String]?) -> Void) {
        self.request = request
        self.completion = completion
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("conversation.question.\(request.id.uuidString)")
        applySurface(fill: Design.Surface.panel, radius: .control, border: Design.Surface.border)
        for stack in [column, body] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = Design.Spacing.medium
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        let header = ConversationDecisionHeader(
            title: L10n.string("A question for you"),
            detail: request.blocksTurn ? L10n.string("The agent is waiting for your answer.")
                : L10n.string("You can answer while work continues."),
            symbol: "questionmark.bubble"
        )
        progress.applyFont(.caption, in: .conversation)
        progress.textColor = Design.Text.secondary
        next.setAccessibilityIdentifier("conversation.question.submit")
        back.setAccessibilityIdentifier("conversation.question.back")
        cancel.setAccessibilityIdentifier("conversation.question.cancel")
        next.emphasis = .primary
        cancel.emphasis = .tertiary
        other.placeholderString = L10n.string("Write your answer…")
        other.delegate = self
        other.applyFont(.body, in: .conversation)
        other.setAccessibilityLabel(L10n.string("Your answer"))
        let actions = ControlRowView(leading: [cancel, progress], trailing: [back, next])
        for view in [header, body, actions] {
            column.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.inset),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.inset),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset)
        ])
        showPage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func showPage() {
        for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
        optionButtons.removeAll()
        let question = request.questions[page]
        let title = NSTextField(wrappingLabelWithString: question.prompt)
        title.applyFont(.body, in: .conversation)
        title.textColor = Design.Text.label
        addBody(title)
        for (index, option) in question.options.enumerated() {
            let button = ConversationChoiceRow(title: option.label, detail: option.detail)
            button.setAccessibilityIdentifier("conversation.question.option.\(question.id).\(index)")
            button.onSelect = { [weak self] in self?.selectOption(index) }
            button.onMove = { [weak self] offset in
                guard let self else { return }
                let destination = (index + offset + optionButtons.count) % optionButtons.count
                window?.makeFirstResponder(optionButtons[destination])
                selectOption(destination)
            }
            optionButtons.append(button)
            addBody(button)
        }
        other.stringValue = answers[question.id].flatMap { value in
            question.options.contains { $0.label == value } ? nil : value
        } ?? ""
        if question.allowsOther { addBody(other) }
        progress.stringValue = L10n.format("Question %lld of %lld", Int64(page + 1), Int64(request.questions.count))
        back.isHidden = page == 0
        next.title = page == request.questions.count - 1 ? L10n.string("Send answer") : L10n.string("Next")
        refreshSelection()
        onLayoutChange?()
    }

    private func addBody(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    private func selectOption(_ index: Int) {
        let question = request.questions[page]
        answers[question.id] = question.options[index].label
        other.stringValue = ""
        refreshSelection()
    }

    func controlTextDidChange(_ notification: Notification) {
        answers[request.questions[page].id] = other.stringValue
        refreshSelection()
    }

    private func refreshSelection() {
        let question = request.questions[page]
        let answer = answers[question.id]
        for (index, button) in optionButtons.enumerated() {
            let selected = answer == question.options[index].label
            button.isSelected = selected
        }
        next.isEnabled = answer.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.utf8.prefix(ConversationQuestionRequest.Limits.answerBytes + 1).count <= ConversationQuestionRequest.Limits.answerBytes
        } ?? false
    }

    @objc private func previousQuestion() { page -= 1; showPage(); focusQuestion() }
    @objc private func nextQuestion() {
        guard next.isEnabled else { return }
        if page < request.questions.count - 1 { page += 1; showPage(); focusQuestion() }
        else { submit(answers) }
    }
    @objc private func cancelQuestion() { finish(nil) }

    private func focusQuestion() {
        let target: NSView = optionButtons.first.map { $0 as NSView } ?? other
        window?.makeFirstResponder(target)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// The same validation gates tests, keyboard activation and the visible Send answer action.
    func submit(_ answers: [String: String]) {
        guard request.accepts(answers) else { return }
        finish(answers)
    }

    private func finish(_ answers: [String: String]?) {
        let callback = completion
        completion = nil
        callback?(answers)
    }

    func cancelRequest() { finish(nil) }

    /// Server settlement/teardown invalidates the action without sending a stale response.
    func invalidate() { completion = nil }
}

/// Shared anatomy for an inline decision, while each owner keeps its distinct semantics.
final class ConversationDecisionHeader: NSView {
    init(title: String, detail: String, symbol: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let glyph = GlyphView()
        glyph.setSymbol(symbol, slot: Design.Symbol.control, role: .control, weight: .medium)
        glyph.tint = Design.Surface.accent
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.applyFont(.subheading, in: .conversation)
        heading.textColor = Design.Text.label
        let explanation = NSTextField(wrappingLabelWithString: detail)
        explanation.applyFont(.caption, in: .conversation)
        explanation.textColor = Design.Text.secondary
        let text = NSStackView(views: [heading, explanation])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.tight
        for view in [glyph, text] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: Design.Symbol.control),
            glyph.heightAnchor.constraint(equalToConstant: Design.Symbol.control),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.topAnchor.constraint(equalTo: text.topAnchor),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: Design.Spacing.medium),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
            heading.widthAnchor.constraint(equalTo: text.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
