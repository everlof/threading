import AppKit
import SwiftTerm

/// Find bar for searching terminal content.
final class FindBarView: NSView {

    // MARK: - Constants

    private enum Layout {
        static let height: CGFloat = 32
        static let padding: CGFloat = 8
        static let spacing: CGFloat = 4
        static let searchFieldWidth: CGFloat = 200
    }

    // MARK: - Properties

    weak var terminalView: TerminalView?
    var onClose: (() -> Void)?

    private var matchCount: Int = 0
    private var currentMatchIndex: Int = 0

    // MARK: - UI Elements

    private lazy var searchField: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.target = self
        field.action = #selector(searchTextChanged)
        field.delegate = self
        return field
    }()

    private lazy var resultsLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = Design.Text.secondary
        return label
    }()

    private lazy var previousButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")!, target: self, action: #selector(findPrevious))
        button.bezelStyle = .inline
        button.isBordered = false
        return button
    }()

    private lazy var nextButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")!, target: self, action: #selector(findNext))
        button.bezelStyle = .inline
        button.isBordered = false
        return button
    }()

    private lazy var closeButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!, target: self, action: #selector(closeFindBar))
        button.bezelStyle = .inline
        button.isBordered = false
        return button
    }()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Design.Surface.ground.cgColor

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = Layout.spacing
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        searchField.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(searchField)
        stackView.addArrangedSubview(resultsLabel)
        stackView.addArrangedSubview(previousButton)
        stackView.addArrangedSubview(nextButton)
        stackView.addArrangedSubview(closeButton)

        addSubview(stackView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Layout.height),

            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),

            searchField.widthAnchor.constraint(equalToConstant: Layout.searchFieldWidth)
        ])
    }

    // MARK: - Public Methods

    func focus() {
        window?.makeFirstResponder(searchField)
    }

    func clear() {
        searchField.stringValue = ""
        matchCount = 0
        currentMatchIndex = 0
        updateResultsLabel()
    }

    // MARK: - Search

    private func performSearch() {
        let searchText = searchField.stringValue
        guard !searchText.isEmpty else {
            matchCount = 0
            currentMatchIndex = 0
            updateResultsLabel()
            return
        }

        // Note: SwiftTerm's SearchService is internal, so full search is not available
        // This is a placeholder - search highlighting would require SwiftTerm modifications
        // For now, just show that search is active
        matchCount = 0
        currentMatchIndex = 0
        updateResultsLabel()
    }

    private func updateResultsLabel() {
        if searchField.stringValue.isEmpty {
            resultsLabel.stringValue = ""
        } else if matchCount == 0 {
            resultsLabel.stringValue = "No results"
        } else {
            resultsLabel.stringValue = "\(currentMatchIndex) of \(matchCount)"
        }
    }

    // MARK: - Actions

    @objc private func searchTextChanged() {
        performSearch()
    }

    @objc private func findNext() {
        guard matchCount > 0 else { return }
        currentMatchIndex = (currentMatchIndex % matchCount) + 1
        updateResultsLabel()
    }

    @objc private func findPrevious() {
        guard matchCount > 0 else { return }
        currentMatchIndex = currentMatchIndex > 1 ? currentMatchIndex - 1 : matchCount
        updateResultsLabel()
    }

    @objc private func closeFindBar() {
        clear()
        onClose?()
    }
}

// MARK: - NSSearchFieldDelegate

extension FindBarView: NSSearchFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        performSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            findNext()
            return true
        } else if commandSelector == #selector(cancelOperation(_:)) {
            closeFindBar()
            return true
        }
        return false
    }
}
