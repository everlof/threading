import AppKit

// MARK: - Emoji Picker View Controller

/// A small popover for choosing an account's icon: a grid of quick picks, a field that takes
/// any emoji (typed, pasted, or from the system picker) and applies it the moment it lands,
/// and — when an icon is set — a way to clear it.
///
/// The grid covers the common case in one click; the field plus the system picker button cover
/// everything else, so the choice is never limited to the two dozen shown.
final class EmojiPickerViewController: NSViewController {

    // MARK: - Properties

    /// Called with the chosen emoji, or nil when the current icon is removed.
    var onPick: ((String?) -> Void)?

    /// Whether a "Remove" control is offered, i.e. an icon is currently set.
    private let showsRemove: Bool

    private let field = ThemedTextField(string: "")

    // MARK: - Initialization

    init(showsRemove: Bool) {
        self.showsRemove = showsRemove
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let grid = makeGrid()

        let divider = SeparatorView()

        let stack = NSStackView(views: [grid, divider, makeInputRow()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.inset, left: Design.Spacing.inset,
            bottom: Design.Spacing.inset, right: Design.Spacing.inset
        )

        view = NSView()
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    // MARK: - Grid

    private func makeGrid() -> NSGridView {
        let columns = EmojiPickerLayout.gridColumns
        let rows = stride(from: 0, to: EmojiPickerDefaults.suggestions.count, by: columns).map { start in
            EmojiPickerDefaults.suggestions[start..<min(start + columns, EmojiPickerDefaults.suggestions.count)]
                .map(makeEmojiCell)
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = EmojiPickerLayout.gridSpacing
        grid.columnSpacing = EmojiPickerLayout.gridSpacing
        return grid
    }

    private func makeEmojiCell(_ emoji: String) -> ThemedButton {
        let button = ThemedButton(title: emoji, target: self, action: #selector(cellClicked(_:)))
        button.isBordered = false
        button.applyFont(.emojiPickerCell)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: EmojiPickerLayout.cellSize),
            button.heightAnchor.constraint(equalToConstant: EmojiPickerLayout.cellSize)
        ])
        return button
    }

    // MARK: - Input Row

    /// A prominent button opening the system Emoji & Symbols picker — which searches by name,
    /// so "coffee" finds ☕ — over a quiet field that also takes a pasted or typed emoji, with
    /// removal beside it when there is an icon to clear.
    private func makeInputRow() -> NSView {
        let browse = ThemedButton(title: EmojiPickerStrings.browse, target: self, action: #selector(browseClicked))
        browse.image = NSImage(systemSymbolName: DesignSymbols.search, accessibilityDescription: nil)?
            .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
        browse.isProminent = true
        browse.translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = EmojiPickerStrings.placeholder
        field.applyFont(.body)
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var fieldViews: [NSView] = [field]
        if showsRemove {
            let remove = ThemedButton(title: EmojiPickerStrings.remove, target: self, action: #selector(removeClicked))
            remove.setContentHuggingPriority(.required, for: .horizontal)
            fieldViews.append(remove)
        }

        let fieldRow = NSStackView(views: fieldViews)
        fieldRow.orientation = .horizontal
        fieldRow.spacing = Design.Spacing.small

        let stack = NSStackView(views: [browse, fieldRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        browse.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        browse.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        fieldRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        fieldRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        return stack
    }

    // MARK: - Actions

    @objc private func cellClicked(_ sender: ThemedButton) {
        onPick?(sender.title)
    }

    /// Opens the system Emoji & Symbols picker, which inserts into the focused field — so a
    /// pick there flows through `controlTextDidChange` and applies like any other.
    @objc private func browseClicked() {
        view.window?.makeFirstResponder(field)
        NSApp.orderFrontCharacterPalette(field)
    }

    @objc private func removeClicked() {
        onPick?(nil)
    }

    /// The first emoji grapheme in a string, or nil — so plain text typed by mistake is ignored
    /// and a multi-scalar emoji (flags, families) survives as one character.
    private func firstEmoji(in string: String) -> String? {
        guard let character = string.first(where: \.isPictographicEmoji) else { return nil }
        return String(character)
    }
}

// MARK: - NSTextFieldDelegate

extension EmojiPickerViewController: NSTextFieldDelegate {

    /// Applies as soon as an emoji lands, whether typed, pasted, or inserted by the system
    /// picker, so choosing never needs a separate confirm step.
    func controlTextDidChange(_ notification: Notification) {
        if let emoji = firstEmoji(in: field.stringValue) {
            onPick?(emoji)
        }
    }
}

// MARK: - Emoji Grid Button

/// Borderless emoji cell with a soft rounded highlight under the pointer, so the grid reads as
/// pickable without two dozen bezels.
// MARK: - Emoji Detection

private extension Character {
    /// Whether this reads as a pictographic emoji, excluding plain ASCII (digits, `#`, `*`)
    /// which carry the emoji property but are not standalone icons.
    var isPictographicEmoji: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation ||
                (scalar.properties.isEmoji && scalar.value > 0x238C)
        }
    }
}

// MARK: - Emoji Picker Defaults

enum EmojiPickerDefaults {
    /// Curated to stay distinguishable at sidebar size: bold shapes, distinct colours.
    static let suggestions = [
        "🤖", "🧠", "✨", "⚡️", "🔥", "🌊",
        "🌙", "⭐️", "🍀", "🌸", "🦊", "🐼",
        "🐙", "🦉", "🐝", "🦄", "🎯", "🎲",
        "🧪", "🔧", "🎨", "🚀", "💎", "🍉"
    ]
}

// MARK: - Emoji Picker Layout

enum EmojiPickerLayout {
    static let gridColumns = 6
    static let gridSpacing: CGFloat = 4
    static let cellSize: CGFloat = 32
    static let emojiFontSize: CGFloat = 19
    static let fieldFontSize: CGFloat = 13
    static let fieldMinWidth: CGFloat = 130
    static let hoverRadius: CGFloat = 7
}

// MARK: - Emoji Picker Strings

enum EmojiPickerStrings {
    static let placeholder = "or paste an emoji"
    static let browse = " Search Emoji…"
    static let remove = "Remove"
}
