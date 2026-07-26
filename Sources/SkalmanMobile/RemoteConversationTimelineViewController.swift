import SkalmanRemoteKit
import SwiftUI
import UIKit

// MARK: - SwiftUI boundary

struct RemoteConversationTimelineView: UIViewControllerRepresentable {
    let connection: RemoteSessionConnection
    let theme: RemoteThemePalette

    func makeUIViewController(context: Context) -> RemoteConversationTimelineViewController {
        RemoteConversationTimelineViewController(connection: connection, theme: theme)
    }

    func updateUIViewController(
        _ controller: RemoteConversationTimelineViewController,
        context: Context
    ) {
        controller.updateTheme(theme)
    }
}

// MARK: - Cached markdown model

private struct RemoteMarkdownDocument: Sendable {
    struct Block: Sendable {
        enum Kind: Sendable {
            case prose([Run])
            case code(language: String, body: String)
        }

        let kind: Kind
    }

    struct Run: Sendable {
        struct Style: OptionSet, Sendable {
            let rawValue: Int

            static let strong = Style(rawValue: 1 << 0)
            static let emphasis = Style(rawValue: 1 << 1)
            static let code = Style(rawValue: 1 << 2)
        }

        let text: String
        let style: Style
    }

    let blocks: [Block]
}

/// Parsing is isolated from the main actor and cached by source. UIKit styling happens later,
/// after a document has become a small run list rather than raw markdown.
private actor RemoteMarkdownDocumentCache {
    static let shared = RemoteMarkdownDocumentCache()

    private var documents: [String: RemoteMarkdownDocument] = [:]

    func document(for source: String) -> RemoteMarkdownDocument {
        if let cached = documents[source] { return cached }
        let document = Self.parse(source)
        documents[source] = document
        return document
    }

    private static func parse(_ source: String) -> RemoteMarkdownDocument {
        let lines = source.components(separatedBy: "\n")
        var blocks: [RemoteMarkdownDocument.Block] = []
        var prose: [String] = []
        var code: [String] = []
        var language = ""
        var isInFence = false

        func flushProse() {
            let text = prose.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.init(kind: .prose(parseInline(text))))
            }
            prose.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            blocks.append(.init(kind: .code(
                language: language,
                body: code.joined(separator: "\n")
            )))
            code.removeAll(keepingCapacity: true)
            language = ""
        }

        for line in lines {
            if line.hasPrefix("```") {
                if isInFence {
                    flushCode()
                } else {
                    flushProse()
                    language = String(line.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                }
                isInFence.toggle()
            } else if isInFence {
                code.append(line)
            } else {
                prose.append(line)
            }
        }

        if isInFence {
            prose.append("```" + language)
            prose.append(contentsOf: code)
        }
        flushProse()
        return RemoteMarkdownDocument(blocks: blocks)
    }

    private static func parseInline(_ source: String) -> [RemoteMarkdownDocument.Run] {
        let characters = Array(source)
        var runs: [RemoteMarkdownDocument.Run] = []
        var buffer = ""
        var style: RemoteMarkdownDocument.Run.Style = []
        var index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(.init(text: buffer, style: style))
            buffer = ""
        }

        while index < characters.count {
            if characters[index] == "`" {
                flush()
                style.formSymmetricDifference(.code)
                index += 1
            } else if index + 1 < characters.count,
                      characters[index] == "*", characters[index + 1] == "*" {
                flush()
                style.formSymmetricDifference(.strong)
                index += 2
            } else if characters[index] == "*" {
                flush()
                style.formSymmetricDifference(.emphasis)
                index += 1
            } else {
                buffer.append(characters[index])
                index += 1
            }
        }
        flush()
        return runs
    }
}

// MARK: - Collection controller

@MainActor
final class RemoteConversationTimelineViewController: UIViewController {
    private enum Item: Hashable {
        case history
        case row(String)
        case streaming
        case permission(String)
    }

    private let connection: RemoteSessionConnection
    private var theme: RemoteThemePalette
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var storeObserver: UUID?
    private var parsedDocuments: [String: RemoteMarkdownDocument] = [:]
    private var markdownSources: [String: String] = [:]
    private var expandedRows: Set<String> = []
    private var hasAppliedInitialSnapshot = false
    private var hasHistoryItem = false
    private var hasStreamingItem = false
    private var permissionItemID: String?
    private var needsInitialBottomPosition = true
    private var contentSizeObserver: NSObjectProtocol?

    init(connection: RemoteSessionConnection, theme: RemoteThemePalette) {
        self.connection = connection
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()
        observeStoreIfNeeded()
        contentSizeObserver = NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconfigureVisibleContent() }
        }
        applySnapshot(scrollToBottom: true)
        prefetchMarkdown()
    }

    deinit {
        if let contentSizeObserver {
            NotificationCenter.default.removeObserver(contentSizeObserver)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        connection.conversationStore.removeObserver(storeObserver)
        storeObserver = nil
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let wasDetached = storeObserver == nil
        observeStoreIfNeeded()
        if wasDetached, isViewLoaded {
            applySnapshot()
            prefetchMarkdown()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        positionInitialBottomAfterLayout()
    }

    func updateTheme(_ theme: RemoteThemePalette) {
        guard self.theme != theme else { return }
        self.theme = theme
        view.backgroundColor = theme.uiGround
        collectionView.backgroundColor = theme.uiGround
        reconfigureVisibleContent()
    }

    private func observeStoreIfNeeded() {
        guard storeObserver == nil else { return }
        storeObserver = connection.conversationStore.observe { [weak self] change in
            self?.apply(change)
        }
    }

    private func configureCollectionView() {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(MobileDesign.Size.conversationEstimatedRowHeight)
        ))
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: .init(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(MobileDesign.Size.conversationEstimatedRowHeight)
            ),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = MobileDesign.Spacing.large
        section.contentInsets = .init(
            top: MobileDesign.Spacing.large,
            leading: MobileDesign.Spacing.large,
            bottom: MobileDesign.Spacing.large,
            trailing: MobileDesign.Spacing.large
        )

        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout(section: section)
        )
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = theme.uiGround
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.register(
            RemoteConversationRowCell.self,
            forCellWithReuseIdentifier: RemoteConversationRowCell.reuseIdentifier
        )
        collectionView.register(
            RemoteConversationPermissionCell.self,
            forCellWithReuseIdentifier: RemoteConversationPermissionCell.reuseIdentifier
        )
        collectionView.register(
            RemoteConversationHistoryCell.self,
            forCellWithReuseIdentifier: RemoteConversationHistoryCell.reuseIdentifier
        )
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.backgroundColor = theme.uiGround
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else { return nil }
            switch item {
            case .history:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: RemoteConversationHistoryCell.reuseIdentifier,
                    for: indexPath
                ) as! RemoteConversationHistoryCell
                cell.configure(
                    isLoading: connection.conversationStore.isLoadingEarlier,
                    theme: theme,
                    load: { [weak self] in self?.connection.loadEarlierConversation() }
                )
                return cell

            case .row(let id):
                guard let row = connection.conversationStore.row(withID: id) else { return nil }
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: RemoteConversationRowCell.reuseIdentifier,
                    for: indexPath
                ) as! RemoteConversationRowCell
                cell.configure(
                    row: row,
                    markdown: parsedDocuments[id],
                    isExpanded: expandedRows.contains(id),
                    theme: theme,
                    toggleExpansion: { [weak self] in self?.toggleRow(id) }
                )
                if row.kind == "assistant", parsedDocuments[id] == nil {
                    prepareMarkdown(for: row)
                }
                return cell

            case .streaming:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: RemoteConversationRowCell.reuseIdentifier,
                    for: indexPath
                ) as! RemoteConversationRowCell
                cell.configureStreaming(
                    connection.conversationStore.state.streamingText,
                    theme: theme
                )
                return cell

            case .permission:
                guard let permission = connection.conversationStore.state.permission else {
                    return nil
                }
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: RemoteConversationPermissionCell.reuseIdentifier,
                    for: indexPath
                ) as! RemoteConversationPermissionCell
                cell.configure(
                    permission: permission,
                    theme: theme,
                    decide: { [weak self] allow in
                        self?.connection.decidePermission(permission, allow: allow)
                    }
                )
                return cell
            }
        }
    }

    private func apply(_ change: RemoteConversationStore.Change) {
        let nearBottom = isNearBottom
        switch change {
        case .reset:
            parsedDocuments.removeAll(keepingCapacity: true)
            markdownSources.removeAll(keepingCapacity: true)
            expandedRows.removeAll(keepingCapacity: true)
            applySnapshot(scrollToBottom: !hasAppliedInitialSnapshot || nearBottom)
            prefetchMarkdown()

        case .delta(
            let inserted,
            let updated,
            let streamingChanged,
            let permissionChanged,
            let historyChanged
        ):
            for id in updated {
                parsedDocuments[id] = nil
                markdownSources[id] = nil
            }
            let state = connection.conversationStore.state
            let desiredPermissionID = state.permission?.id
            let desiredHistoryItem = state.hasEarlier
                || connection.conversationStore.isLoadingEarlier
            let structureChanged = !inserted.isEmpty
                || (historyChanged && hasHistoryItem != desiredHistoryItem)
                || hasStreamingItem != !state.streamingText.isEmpty
                || permissionItemID != desiredPermissionID

            if structureChanged {
                applySnapshot(
                    reconfiguring: Set(updated),
                    scrollToBottom: nearBottom && !inserted.isEmpty
                )
            } else {
                var items = updated.map(Item.row)
                if streamingChanged, hasStreamingItem {
                    items.append(.streaming)
                }
                if permissionChanged, let desiredPermissionID {
                    items.append(.permission(desiredPermissionID))
                }
                reconfigure(items)
            }
            prefetchMarkdown(ids: Set(inserted + updated))

        case .prepended:
            applyPrependingSnapshot()
            prefetchMarkdown()

        case .loadingChanged:
            applySnapshot(reconfiguringSynthetic: true)
        }
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<Int, Item> {
        let state = connection.conversationStore.state
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        if state.hasEarlier || connection.conversationStore.isLoadingEarlier {
            snapshot.appendItems([.history])
        }
        snapshot.appendItems(state.rows.map { .row($0.id) })
        if !state.streamingText.isEmpty {
            snapshot.appendItems([.streaming])
        }
        if let permission = state.permission {
            snapshot.appendItems([.permission(permission.id)])
        }
        return snapshot
    }

    private func applySnapshot(
        reconfiguring ids: Set<String> = [],
        reconfiguringSynthetic: Bool = false,
        scrollToBottom: Bool = false
    ) {
        var snapshot = makeSnapshot()
        recordSyntheticState()
        let existing = Set(snapshot.itemIdentifiers)
        let rowItems = ids.map(Item.row).filter(existing.contains)
        if !rowItems.isEmpty {
            snapshot.reconfigureItems(rowItems)
        }
        if reconfiguringSynthetic {
            let synthetic = snapshot.itemIdentifiers.filter {
                if case .row = $0 { return false }
                return true
            }
            snapshot.reconfigureItems(synthetic)
        }
        dataSource.apply(snapshot, animatingDifferences: hasAppliedInitialSnapshot) { [weak self] in
            guard let self else { return }
            self.hasAppliedInitialSnapshot = true
            if scrollToBottom {
                if self.needsInitialBottomPosition {
                    self.positionInitialBottomAfterLayout()
                } else {
                    self.scrollToBottom()
                }
            }
        }
    }

    private func applyPrependingSnapshot() {
        let visible = collectionView.indexPathsForVisibleItems
            .sorted()
            .compactMap { indexPath -> (Item, CGFloat)? in
                guard let item = dataSource.itemIdentifier(for: indexPath),
                      case .row = item,
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                    return nil
                }
                return (item, attributes.frame.minY - collectionView.contentOffset.y)
            }
            .first

        let snapshot = makeSnapshot()
        recordSyntheticState()
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, let visible,
                  let indexPath = self.dataSource.indexPath(for: visible.0) else { return }
            self.collectionView.layoutIfNeeded()
            guard let attributes = self.collectionView.layoutAttributesForItem(at: indexPath)
            else { return }
            self.collectionView.setContentOffset(
                CGPoint(
                    x: self.collectionView.contentOffset.x,
                    y: attributes.frame.minY - visible.1
                ),
                animated: false
            )
        }
    }

    private func reconfigureVisibleContent() {
        let items = collectionView.indexPathsForVisibleItems.compactMap {
            dataSource.itemIdentifier(for: $0)
        }
        reconfigure(items)
    }

    private func toggleRow(_ id: String) {
        if expandedRows.contains(id) {
            expandedRows.remove(id)
        } else {
            expandedRows.insert(id)
        }
        let item = Item.row(id)
        reconfigure([item])
    }

    private func prefetchMarkdown(ids: Set<String>? = nil) {
        for row in connection.conversationStore.state.rows
        where row.kind == "assistant" && (ids == nil || ids?.contains(row.id) == true) {
            prepareMarkdown(for: row)
        }
    }

    private func prepareMarkdown(for row: RemoteConversationRowDTO) {
        let source = row.text ?? ""
        guard parsedDocuments[row.id] == nil, markdownSources[row.id] != source else { return }
        markdownSources[row.id] = source
        Task { [weak self] in
            let document = await RemoteMarkdownDocumentCache.shared.document(for: source)
            guard let self, self.markdownSources[row.id] == source else { return }
            let shouldFollowBottom = self.isNearBottom
            self.parsedDocuments[row.id] = document
            self.reconfigure([.row(row.id)])
            if shouldFollowBottom {
                self.collectionView.layoutIfNeeded()
                self.scrollToBottom()
            }
        }
    }

    private func recordSyntheticState() {
        let state = connection.conversationStore.state
        hasHistoryItem = state.hasEarlier || connection.conversationStore.isLoadingEarlier
        hasStreamingItem = !state.streamingText.isEmpty
        permissionItemID = state.permission?.id
    }

    private func reconfigure(_ items: [Item]) {
        var changedVisibleHeight = false
        for item in items {
            guard let indexPath = dataSource.indexPath(for: item),
                  let cell = collectionView.cellForItem(at: indexPath) else {
                // Off-screen cells are configured from current store state when dequeued.
                continue
            }
            switch item {
            case .history:
                guard let cell = cell as? RemoteConversationHistoryCell else { continue }
                cell.configure(
                    isLoading: connection.conversationStore.isLoadingEarlier,
                    theme: theme,
                    load: { [weak self] in self?.connection.loadEarlierConversation() }
                )

            case .row(let id):
                guard let cell = cell as? RemoteConversationRowCell,
                      let row = connection.conversationStore.row(withID: id) else { continue }
                cell.configure(
                    row: row,
                    markdown: parsedDocuments[id],
                    isExpanded: expandedRows.contains(id),
                    theme: theme,
                    toggleExpansion: { [weak self] in self?.toggleRow(id) }
                )
                changedVisibleHeight = true

            case .streaming:
                guard let cell = cell as? RemoteConversationRowCell else { continue }
                cell.configureStreaming(
                    connection.conversationStore.state.streamingText,
                    theme: theme
                )
                changedVisibleHeight = true

            case .permission:
                guard let cell = cell as? RemoteConversationPermissionCell,
                      let permission = connection.conversationStore.state.permission else {
                    continue
                }
                cell.configure(
                    permission: permission,
                    theme: theme,
                    decide: { [weak self] allow in
                        self?.connection.decidePermission(permission, allow: allow)
                    }
                )
                changedVisibleHeight = true
            }
        }
        if changedVisibleHeight {
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    private var isNearBottom: Bool {
        let remaining = collectionView.contentSize.height
            - collectionView.contentOffset.y
            - collectionView.bounds.height
        return remaining < MobileDesign.Size.conversationBottomTolerance
    }

    private func scrollToBottom() {
        guard let item = dataSource.snapshot().itemIdentifiers.last,
              let indexPath = dataSource.indexPath(for: item) else { return }
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: false)
    }

    private func positionInitialBottomAfterLayout() {
        guard needsInitialBottomPosition, hasAppliedInitialSnapshot else { return }
        collectionView.layoutIfNeeded()
        scrollToBottom()
        // Self-sizing cells replace their estimated heights during the first layout pass.
        // Re-anchor once on the next pass; after this, normal near-bottom logic owns scrolling.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.needsInitialBottomPosition else { return }
            self.collectionView.layoutIfNeeded()
            self.scrollToBottom()
            self.needsInitialBottomPosition = false
        }
    }
}

extension RemoteConversationTimelineViewController: UICollectionViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        needsInitialBottomPosition = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging,
              scrollView.contentOffset.y < MobileDesign.Size.conversationHistoryTrigger else {
            return
        }
        connection.loadEarlierConversation()
    }
}

// MARK: - Reusable row cell

private final class RemoteConversationRowCell: UICollectionViewCell {
    static let reuseIdentifier = "RemoteConversationRowCell"

    private var hostedView: UIView?

    override func prepareForReuse() {
        super.prepareForReuse()
        hostedView?.removeFromSuperview()
        hostedView = nil
    }

    func configure(
        row: RemoteConversationRowDTO,
        markdown: RemoteMarkdownDocument?,
        isExpanded: Bool,
        theme: RemoteThemePalette,
        toggleExpansion: @escaping () -> Void
    ) {
        let view: UIView
        switch row.kind {
        case "user":
            view = RemoteUserMessageView(text: row.text ?? "", theme: theme)
        case "assistant":
            view = RemoteAssistantMessageView(
                source: row.text ?? "",
                document: markdown,
                theme: theme
            )
        case "thinking":
            view = RemoteExpandableMessageView(
                title: "Reasoning",
                text: row.text ?? "",
                isExpanded: isExpanded,
                theme: theme,
                toggle: toggleExpansion
            )
        case "tool":
            view = RemoteToolMessageView(
                row: row,
                isExpanded: isExpanded,
                theme: theme,
                toggle: toggleExpansion
            )
        default:
            view = RemoteNoticeMessageView(row: row, theme: theme)
        }
        install(view)
    }

    func configureStreaming(_ text: String, theme: RemoteThemePalette) {
        install(RemoteStreamingMessageView(text: text, theme: theme))
    }

    private func install(_ view: UIView) {
        hostedView?.removeFromSuperview()
        hostedView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }
}

// MARK: - Row views

private final class RemoteUserMessageView: UIView {
    init(text: String, theme: RemoteThemePalette) {
        super.init(frame: .zero)
        let bubble = UIView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.applyRemoteSurface(
            fill: theme.uiControlResting,
            radius: theme.panelRadius
        )
        let textView = Self.textView(
            text: text,
            font: .preferredFont(forTextStyle: .body),
            color: theme.uiLabel
        )
        bubble.addSubview(textView)
        addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: MobileDesign.Spacing.pane * 2
            ),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            textView.leadingAnchor.constraint(
                equalTo: bubble.leadingAnchor,
                constant: MobileDesign.Spacing.inset
            ),
            textView.trailingAnchor.constraint(
                equalTo: bubble.trailingAnchor,
                constant: -MobileDesign.Spacing.inset
            ),
            textView.topAnchor.constraint(
                equalTo: bubble.topAnchor,
                constant: MobileDesign.Spacing.medium
            ),
            textView.bottomAnchor.constraint(
                equalTo: bubble.bottomAnchor,
                constant: -MobileDesign.Spacing.medium
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    fileprivate static func textView(
        text: String,
        font: UIFont,
        color: UIColor
    ) -> UITextView {
        let view = UITextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.font = font
        view.textColor = color
        view.text = text
        return view
    }
}

private final class RemoteAssistantMessageView: UIStackView {
    init(
        source: String,
        document: RemoteMarkdownDocument?,
        theme: RemoteThemePalette
    ) {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .fill
        spacing = MobileDesign.Spacing.inset

        guard let document else {
            addArrangedSubview(RemoteStreamingMessageView(text: source, theme: theme))
            return
        }
        for block in document.blocks {
            switch block.kind {
            case .prose(let runs):
                let textView = RemoteUserMessageView.textView(
                    text: "",
                    font: Self.proseFont(),
                    color: theme.uiLabel
                )
                textView.attributedText = Self.attributed(runs, theme: theme)
                textView.accessibilityLabel = runs.map(\.text).joined()
                addArrangedSubview(textView)
            case .code(let language, let body):
                addArrangedSubview(RemoteCodeBlockView(
                    language: language,
                    code: body,
                    theme: theme
                ))
            }
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func proseFont() -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        return UIFont(descriptor: descriptor.withDesign(.serif) ?? descriptor, size: 0)
    }

    private static func attributed(
        _ runs: [RemoteMarkdownDocument.Run],
        theme: RemoteThemePalette
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = MobileDesign.Typography.messageLineSpacing

        for run in runs {
            var font = proseFont()
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.style.contains(.strong) { traits.insert(.traitBold) }
            if run.style.contains(.emphasis) { traits.insert(.traitItalic) }
            if !traits.isEmpty,
               let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: descriptor, size: 0)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: theme.uiLabel,
                .paragraphStyle: paragraph,
            ]
            if run.style.contains(.code) {
                font = .preferredFont(forTextStyle: .callout)
                let descriptor = font.fontDescriptor.withDesign(.monospaced)
                    ?? font.fontDescriptor
                attributes[.font] = UIFont(descriptor: descriptor, size: 0)
                attributes[.backgroundColor] = theme.uiControlResting
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }
}

private final class RemoteCodeBlockView: UIView {
    init(language: String, code: String, theme: RemoteThemePalette) {
        super.init(frame: .zero)
        applyRemoteSurface(
            fill: theme.uiSurface,
            radius: theme.panelRadius,
            border: theme.uiBorder,
            borderWidth: theme.borderWidth,
            glow: theme.glow
        )

        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.backgroundColor = theme.uiControlResting
        let languageLabel = UILabel()
        languageLabel.translatesAutoresizingMaskIntoConstraints = false
        languageLabel.font = .preferredFont(forTextStyle: .caption1)
        languageLabel.adjustsFontForContentSizeCategory = true
        languageLabel.textColor = theme.uiSecondaryLabel
        languageLabel.text = language.isEmpty ? "code" : language

        let copy = UIButton(type: .system)
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        copy.tintColor = theme.uiSecondaryLabel
        copy.accessibilityLabel = "Copy code"
        copy.addAction(UIAction { _ in UIPasteboard.general.string = code }, for: .touchUpInside)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceHorizontal = true
        scroll.showsHorizontalScrollIndicator = true
        let codeLabel = UILabel()
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.numberOfLines = 0
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .footnote)
            .withDesign(.monospaced)
        codeLabel.font = UIFont(descriptor: descriptor ?? .preferredFontDescriptor(
            withTextStyle: .footnote
        ), size: 0)
        codeLabel.adjustsFontForContentSizeCategory = true
        codeLabel.textColor = theme.uiLabel
        codeLabel.text = code

        addSubview(header)
        header.addSubview(languageLabel)
        header.addSubview(copy)
        addSubview(scroll)
        scroll.addSubview(codeLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(
                greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget
            ),
            languageLabel.leadingAnchor.constraint(
                equalTo: header.leadingAnchor,
                constant: MobileDesign.Spacing.inset
            ),
            languageLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copy.trailingAnchor.constraint(
                equalTo: header.trailingAnchor,
                constant: -MobileDesign.Spacing.small
            ),
            copy.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copy.widthAnchor.constraint(
                greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget
            ),
            copy.heightAnchor.constraint(
                greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget
            ),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            codeLabel.leadingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.leadingAnchor,
                constant: MobileDesign.Spacing.inset
            ),
            codeLabel.trailingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.trailingAnchor,
                constant: -MobileDesign.Spacing.inset
            ),
            codeLabel.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor,
                constant: MobileDesign.Spacing.inset
            ),
            codeLabel.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor,
                constant: -MobileDesign.Spacing.inset
            ),
            codeLabel.heightAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.heightAnchor,
                constant: -MobileDesign.Spacing.pane
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class RemoteExpandableMessageView: UIView {
    init(
        title: String,
        text: String,
        isExpanded: Bool,
        theme: RemoteThemePalette,
        toggle: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = MobileDesign.Spacing.small
        let button = UIButton(type: .system)
        button.contentHorizontalAlignment = .leading
        button.setTitle(title, for: .normal)
        button.setImage(
            UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right"),
            for: .normal
        )
        button.tintColor = theme.uiSecondaryLabel
        button.setTitleColor(theme.uiSecondaryLabel, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityValue = isExpanded ? "Expanded" : "Collapsed"
        button.addAction(UIAction { _ in toggle() }, for: .touchUpInside)
        stack.addArrangedSubview(button)
        if isExpanded {
            stack.addArrangedSubview(RemoteUserMessageView.textView(
                text: text,
                font: .preferredFont(forTextStyle: .footnote),
                color: theme.uiSecondaryLabel
            ))
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(
                greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class RemoteToolMessageView: UIView {
    init(
        row: RemoteConversationRowDTO,
        isExpanded: Bool,
        theme: RemoteThemePalette,
        toggle: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        applyRemoteSurface(
            fill: theme.uiPanel,
            radius: theme.panelRadius,
            border: theme.uiBorder,
            borderWidth: theme.borderWidth,
            glow: theme.glow
        )
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = MobileDesign.Spacing.small

        var configuration = UIButton.Configuration.plain()
        configuration.title = row.summary ?? "Working…"
        configuration.subtitle = row.toolName ?? "Tool"
        configuration.image = UIImage(systemName: Self.symbol(for: row.toolName))
        configuration.imagePadding = MobileDesign.Spacing.medium
        configuration.titleAlignment = .leading
        configuration.baseForegroundColor = theme.uiLabel
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.accessibilityHint = row.result == nil ? "Tool is running" : "Shows tool output"
        button.accessibilityValue = isExpanded ? "Expanded" : "Collapsed"
        button.addAction(UIAction { _ in toggle() }, for: .touchUpInside)
        stack.addArrangedSubview(button)

        if isExpanded, let result = row.result, !result.isEmpty {
            stack.addArrangedSubview(RemoteUserMessageView.textView(
                text: result,
                font: Self.codeFont(),
                color: row.isError ? theme.uiNegative : theme.uiSecondaryLabel
            ))
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: MobileDesign.Spacing.inset
            ),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -MobileDesign.Spacing.inset
            ),
            stack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: MobileDesign.Spacing.medium
            ),
            stack.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -MobileDesign.Spacing.medium
            ),
            button.heightAnchor.constraint(
                greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func codeFont() -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .caption1)
            .withDesign(.monospaced)
        return UIFont(
            descriptor: descriptor ?? .preferredFontDescriptor(withTextStyle: .caption1),
            size: 0
        )
    }

    private static func symbol(for toolName: String?) -> String {
        switch toolName?.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text"
        case "write", "edit", "multiedit": return "square.and.pencil"
        case "websearch", "webfetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }
}

private final class RemoteNoticeMessageView: UIView {
    init(row: RemoteConversationRowDTO, theme: RemoteThemePalette) {
        super.init(frame: .zero)
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .top
        stack.spacing = MobileDesign.Spacing.small
        let image = UIImageView(image: UIImage(
            systemName: row.isError ? "exclamationmark.triangle" : "info.circle"
        ))
        image.tintColor = row.isError ? theme.uiNegative : theme.uiSecondaryLabel
        image.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = row.isError ? theme.uiNegative : theme.uiSecondaryLabel
        label.text = row.text ?? "Notice"
        stack.addArrangedSubview(image)
        stack.addArrangedSubview(label)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class RemoteStreamingMessageView: UIView {
    init(text: String, theme: RemoteThemePalette) {
        super.init(frame: .zero)
        let textView = RemoteUserMessageView.textView(
            text: text,
            font: RemoteAssistantMessageView.proseFontForStreaming,
            color: theme.uiSecondaryLabel
        )
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        accessibilityLabel = "Agent is responding"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private extension RemoteAssistantMessageView {
    static var proseFontForStreaming: UIFont { proseFont() }
}

// MARK: - Permission and history cells

private final class RemoteConversationPermissionCell: UICollectionViewCell {
    static let reuseIdentifier = "RemoteConversationPermissionCell"

    private var hostedView: UIView?

    override func prepareForReuse() {
        super.prepareForReuse()
        hostedView?.removeFromSuperview()
        hostedView = nil
    }

    func configure(
        permission: RemotePermissionRequestDTO,
        theme: RemoteThemePalette,
        decide: @escaping (Bool) -> Void
    ) {
        hostedView?.removeFromSuperview()
        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.applyRemoteSurface(
            fill: theme.uiPanel,
            radius: theme.panelRadius,
            border: theme.uiWarning.withAlphaComponent(0.7),
            borderWidth: theme.borderWidth,
            glow: theme.glow
        )
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = MobileDesign.Spacing.medium

        let title = UILabel()
        title.numberOfLines = 0
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = theme.uiLabel
        title.text = "Allow \(permission.toolName)?"
        stack.addArrangedSubview(title)

        if !permission.summary.isEmpty {
            stack.addArrangedSubview(RemoteUserMessageView.textView(
                text: permission.summary,
                font: Self.codeFont(),
                color: theme.uiLabel
            ))
        }

        if !permission.diff.isEmpty {
            stack.addArrangedSubview(RemotePermissionDiffView(
                lines: permission.diff,
                theme: theme
            ))
        }

        if permission.canDecide {
            let buttons = UIStackView()
            buttons.axis = .horizontal
            buttons.distribution = .fillEqually
            buttons.spacing = MobileDesign.Spacing.medium
            buttons.addArrangedSubview(Self.actionButton(
                title: "Deny",
                fill: theme.uiControlResting,
                foreground: theme.uiNegative,
                radius: theme.controlRadius,
                action: { decide(false) }
            ))
            buttons.addArrangedSubview(Self.actionButton(
                title: "Allow",
                fill: theme.uiAccent,
                foreground: theme.uiGround,
                radius: theme.controlRadius,
                action: { decide(true) }
            ))
            stack.addArrangedSubview(buttons)
        } else {
            let notice = UILabel()
            notice.numberOfLines = 0
            notice.font = .preferredFont(forTextStyle: .subheadline)
            notice.adjustsFontForContentSizeCategory = true
            notice.textColor = theme.uiSecondaryLabel
            notice.text = permission.unavailableReason ?? "Review this request on the Mac."
            stack.addArrangedSubview(notice)
        }

        panel.addSubview(stack)
        contentView.addSubview(panel)
        hostedView = panel
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            panel.topAnchor.constraint(equalTo: contentView.topAnchor),
            panel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(
                equalTo: panel.leadingAnchor,
                constant: MobileDesign.Spacing.inset
            ),
            stack.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor,
                constant: -MobileDesign.Spacing.inset
            ),
            stack.topAnchor.constraint(
                equalTo: panel.topAnchor,
                constant: MobileDesign.Spacing.inset
            ),
            stack.bottomAnchor.constraint(
                equalTo: panel.bottomAnchor,
                constant: -MobileDesign.Spacing.inset
            ),
        ])
    }

    private static func codeFont() -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .subheadline)
            .withDesign(.monospaced)
        return UIFont(
            descriptor: descriptor ?? .preferredFontDescriptor(withTextStyle: .subheadline),
            size: 0
        )
    }

    private static func actionButton(
        title: String,
        fill: UIColor,
        foreground: UIColor,
        radius: CGFloat,
        action: @escaping () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = fill
        configuration.baseForegroundColor = foreground
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = radius
        let button = UIButton(configuration: configuration)
        button.heightAnchor.constraint(
            greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget
        ).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}

/// A permission diff keeps its marker in a fixed column while source text wraps independently.
/// The viewport grows for short edits and becomes scrollable for large ones, so a long line can
/// never strand `+` or `−` on a line of its own.
private final class RemotePermissionDiffView: UIView {
    private let scrollView = UIScrollView()
    private let rows = UIStackView()
    private var viewportHeight: NSLayoutConstraint!

    init(lines: [RemotePermissionDiffLineDTO], theme: RemoteThemePalette) {
        super.init(frame: .zero)
        applyRemoteSurface(fill: theme.uiGround, radius: theme.controlRadius)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = true
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.axis = .vertical
        rows.spacing = 0

        for line in lines {
            rows.addArrangedSubview(Self.row(for: line, theme: theme))
        }

        addSubview(scrollView)
        scrollView.addSubview(rows)
        viewportHeight = heightAnchor.constraint(
            equalToConstant: MobileDesign.Size.permissionDiffMinimumHeight
        )
        NSLayoutConstraint.activate([
            viewportHeight,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            rows.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let fitting = rows.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let target = min(
            MobileDesign.Size.permissionDiffMaximumHeight,
            max(MobileDesign.Size.permissionDiffMinimumHeight, fitting)
        )
        if abs(viewportHeight.constant - target) >= 1 {
            viewportHeight.constant = target
        }
        scrollView.isScrollEnabled = fitting > target
    }

    private static func row(
        for line: RemotePermissionDiffLineDTO,
        theme: RemoteThemePalette
    ) -> UIView {
        let color: UIColor
        let marker: String
        switch line.kind {
        case "addition":
            color = theme.uiDiffAdded
            marker = "+"
        case "removal":
            color = theme.uiDiffRemoved
            marker = "−"
        default:
            color = theme.uiSecondaryLabel
            marker = " "
        }

        let row = UIView()
        row.backgroundColor = color.withAlphaComponent(0.08)
        let markerLabel = UILabel()
        markerLabel.translatesAutoresizingMaskIntoConstraints = false
        markerLabel.font = codeFont()
        markerLabel.adjustsFontForContentSizeCategory = true
        markerLabel.textColor = color
        markerLabel.text = marker
        markerLabel.textAlignment = .center

        let source = RemoteUserMessageView.textView(
            text: line.text.isEmpty ? " " : line.text,
            font: codeFont(),
            color: color
        )
        row.addSubview(markerLabel)
        row.addSubview(source)
        NSLayoutConstraint.activate([
            markerLabel.leadingAnchor.constraint(
                equalTo: row.leadingAnchor,
                constant: MobileDesign.Spacing.small
            ),
            markerLabel.topAnchor.constraint(
                equalTo: row.topAnchor,
                constant: MobileDesign.Spacing.small
            ),
            markerLabel.widthAnchor.constraint(
                equalToConstant: MobileDesign.Size.diffMarkerColumnWidth
            ),
            source.leadingAnchor.constraint(
                equalTo: markerLabel.trailingAnchor,
                constant: MobileDesign.Spacing.small
            ),
            source.trailingAnchor.constraint(
                equalTo: row.trailingAnchor,
                constant: -MobileDesign.Spacing.medium
            ),
            source.topAnchor.constraint(
                equalTo: row.topAnchor,
                constant: MobileDesign.Spacing.small
            ),
            source.bottomAnchor.constraint(
                equalTo: row.bottomAnchor,
                constant: -MobileDesign.Spacing.small
            ),
            markerLabel.firstBaselineAnchor.constraint(equalTo: source.firstBaselineAnchor),
        ])
        return row
    }

    private static func codeFont() -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .subheadline)
            .withDesign(.monospaced)
        return UIFont(
            descriptor: descriptor ?? .preferredFontDescriptor(withTextStyle: .subheadline),
            size: 0
        )
    }
}

private final class RemoteConversationHistoryCell: UICollectionViewCell {
    static let reuseIdentifier = "RemoteConversationHistoryCell"

    private var button: UIButton?

    override func prepareForReuse() {
        super.prepareForReuse()
        button?.removeFromSuperview()
        button = nil
    }

    func configure(
        isLoading: Bool,
        theme: RemoteThemePalette,
        load: @escaping () -> Void
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = isLoading ? "Loading earlier messages…" : "Load earlier messages"
        configuration.image = UIImage(systemName: isLoading ? "clock.arrow.circlepath" : "arrow.up")
        configuration.imagePadding = MobileDesign.Spacing.small
        configuration.baseForegroundColor = theme.uiSecondaryLabel
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = !isLoading
        button.accessibilityHint = "Loads the previous part of this conversation"
        button.addAction(UIAction { _ in load() }, for: .touchUpInside)
        contentView.addSubview(button)
        self.button = button
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            button.heightAnchor.constraint(
                greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget
            ),
        ])
    }
}

private extension UIView {
    func applyRemoteSurface(
        fill: UIColor,
        radius: CGFloat,
        border: UIColor? = nil,
        borderWidth: CGFloat = 0,
        glow: RemoteThemeDTO.Material.Glow? = nil
    ) {
        backgroundColor = fill
        layer.cornerCurve = .continuous
        layer.cornerRadius = radius
        clipsToBounds = true
        if let border, borderWidth > 0 {
            let outline = RemoteSurfaceBorderView(
                color: border,
                radius: radius,
                width: borderWidth,
                glow: glow
            )
            outline.translatesAutoresizingMaskIntoConstraints = false
            outline.isUserInteractionEnabled = false
            outline.layer.zPosition = 1
            addSubview(outline)
            NSLayoutConstraint.activate([
                outline.leadingAnchor.constraint(equalTo: leadingAnchor),
                outline.trailingAnchor.constraint(equalTo: trailingAnchor),
                outline.topAnchor.constraint(equalTo: topAnchor),
                outline.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
}

private final class RemoteSurfaceBorderView: UIView {
    private let color: UIColor
    private let radius: CGFloat
    private let width: CGFloat
    private let glow: RemoteThemeDTO.Material.Glow?

    init(
        color: UIColor,
        radius: CGFloat,
        width: CGFloat,
        glow: RemoteThemeDTO.Material.Glow?
    ) {
        self.color = color
        self.radius = radius
        self.width = width
        self.glow = glow
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        if let glow,
           let glowColor = UIColor(remoteHex: glow.color),
           glow.radius > 0,
           glow.opacity > 0 {
            // UIKit's layer shadow API freezes a CGColor, which would violate live theme
            // updates. Draw a soft inner halo from the current semantic theme instead.
            let glowWidth = min(
                CGFloat(glow.radius),
                MobileDesign.Spacing.tight
            )
            let glowInset = glowWidth / 2
            let glowPath = UIBezierPath(
                roundedRect: rect
                    .insetBy(dx: glowInset, dy: glowInset)
                    .offsetBy(
                        dx: CGFloat(glow.offsetX ?? 0),
                        dy: CGFloat(-(glow.offsetY ?? 0))
                    ),
                cornerRadius: max(0, radius - glowInset)
            )
            glowPath.lineWidth = glowWidth
            glowColor.withAlphaComponent(CGFloat(glow.opacity / 6)).setStroke()
            glowPath.stroke()
        }

        let inset = width / 2
        let path = UIBezierPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            cornerRadius: max(0, radius - inset)
        )
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }
}
