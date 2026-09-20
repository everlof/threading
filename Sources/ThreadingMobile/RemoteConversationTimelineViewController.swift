import ThreadingRemoteKit
import QuartzCore
import SwiftUI
import UIKit

// MARK: - SwiftUI boundary

struct RemoteConversationTimelineView: UIViewControllerRepresentable {
    let connection: RemoteSessionConnection
    let theme: RemoteThemePalette
    let initialViewport: (progress: Double?, followsBottom: Bool)?
    let onViewportChange: (Double, Bool) -> Void

    func makeUIViewController(context: Context) -> RemoteConversationTimelineViewController {
        RemoteConversationTimelineViewController(
            connection: connection,
            theme: theme,
            initialViewport: initialViewport,
            onViewportChange: onViewportChange
        )
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

    func documents(for sources: [String]) -> [RemoteMarkdownDocument] {
        sources.map(document(for:))
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

final class RemoteConversationLayoutInvalidationContext:
    UICollectionViewLayoutInvalidationContext {
    /// Set by the paths that have already corrected the cached geometry themselves. A full
    /// rebuild stands every unmeasured row back up at the estimate, so those paths must keep
    /// the map they just wrote rather than have `prepare()` throw it away.
    var preservesCachedGeometry = false
    var clearsHeightCache = false
}

/// A conversation is one vertically stacked column. UIKit's general-purpose self-sizing layouts
/// revisit large internal preferred-size maps whenever a visible row discovers its height. This
/// layout stores discovered heights by stable diffable identifier and shifts the following cached
/// frames directly, so scrolling work is proportional to mounted rows rather than total history.
final class RemoteConversationLayout: UICollectionViewLayout {
    override class var invalidationContextClass: AnyClass {
        RemoteConversationLayoutInvalidationContext.self
    }

    var itemIdentifier: ((IndexPath) -> AnyHashable?)?

    private let estimatedRowHeight: CGFloat
    private let spacing: CGFloat
    private let sectionInsets: UIEdgeInsets
    private var itemAttributes: [UICollectionViewLayoutAttributes] = []
    private var identifiers: [AnyHashable] = []
    private var baseOrigins: [CGFloat] = []
    private var itemHeights: [CGFloat] = []
    /// A Fenwick difference tree. A height change adds one suffix adjustment in O(log n), and
    /// each requested frame resolves its current origin in O(log n).
    private var suffixAdjustmentTree: [CGFloat] = []
    private var heightByIdentifier: [AnyHashable: CGFloat] = [:]
    private var calculatedContentSize = CGSize.zero
    private var availableWidth: CGFloat = 0
    private var needsFullRebuild = true

    init(
        estimatedRowHeight: CGFloat,
        spacing: CGFloat = MobileDesign.Spacing.large,
        sectionInsets: UIEdgeInsets = UIEdgeInsets(
            top: MobileDesign.Spacing.large,
            left: MobileDesign.Spacing.large,
            bottom: MobileDesign.Spacing.large,
            right: MobileDesign.Spacing.large
        )
    ) {
        self.estimatedRowHeight = estimatedRowHeight
        self.spacing = spacing
        self.sectionInsets = sectionInsets
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let itemCount = collectionView.numberOfItems(inSection: 0)
        let width = max(
            1,
            collectionView.bounds.width
                - collectionView.adjustedContentInset.left
                - collectionView.adjustedContentInset.right
                - sectionInsets.left
                - sectionInsets.right
        )
        if abs(availableWidth - width) > 0.5 {
            availableWidth = width
            heightByIdentifier.removeAll(keepingCapacity: true)
            needsFullRebuild = true
        }
        guard needsFullRebuild || itemAttributes.count != itemCount else { return }

        itemAttributes.removeAll(keepingCapacity: true)
        identifiers.removeAll(keepingCapacity: true)
        baseOrigins.removeAll(keepingCapacity: true)
        itemHeights.removeAll(keepingCapacity: true)
        itemAttributes.reserveCapacity(itemCount)
        identifiers.reserveCapacity(itemCount)
        baseOrigins.reserveCapacity(itemCount)
        itemHeights.reserveCapacity(itemCount)
        suffixAdjustmentTree = Array(repeating: 0, count: itemCount + 1)
        var activeIdentifiers = Set<AnyHashable>()
        activeIdentifiers.reserveCapacity(itemCount)
        var y = sectionInsets.top
        for item in 0..<itemCount {
            let indexPath = IndexPath(item: item, section: 0)
            let identifier = stableIdentifier(for: indexPath)
            activeIdentifiers.insert(identifier)
            identifiers.append(identifier)
            let height = heightByIdentifier[identifier] ?? estimatedRowHeight
            baseOrigins.append(y)
            itemHeights.append(height)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            attributes.frame = CGRect(
                x: sectionInsets.left,
                y: y,
                width: width,
                height: height
            )
            itemAttributes.append(attributes)
            y += height + spacing
        }
        heightByIdentifier = heightByIdentifier.filter {
            activeIdentifiers.contains($0.key)
        }
        calculatedContentSize = CGSize(
            width: collectionView.bounds.width,
            height: max(0, y - (itemCount == 0 ? 0 : spacing) + sectionInsets.bottom)
        )
        needsFullRebuild = false
    }

    override var collectionViewContentSize: CGSize {
        calculatedContentSize
    }

    override func layoutAttributesForElements(
        in rect: CGRect
    ) -> [UICollectionViewLayoutAttributes]? {
        guard !itemAttributes.isEmpty else { return [] }
        var lower = 0
        var upper = itemAttributes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if itemFrame(at: middle).maxY < rect.minY {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var index = lower
        while index < itemAttributes.count {
            let attributes = itemAttributes[index]
            let frame = itemFrame(at: index)
            if frame.minY > rect.maxY { break }
            attributes.frame = frame
            if frame.intersects(rect) { result.append(attributes) }
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, itemAttributes.indices.contains(indexPath.item) else {
            return nil
        }
        let attributes = itemAttributes[indexPath.item]
        attributes.frame = itemFrame(at: indexPath.item)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return abs(collectionView.bounds.width - newBounds.width) > 0.5
    }

    override func invalidationContext(
        forBoundsChange newBounds: CGRect
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if let context = context as? RemoteConversationLayoutInvalidationContext,
           let collectionView,
           abs(collectionView.bounds.width - newBounds.width) > 0.5 {
            context.clearsHeightCache = true
        }
        return context
    }

    override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> Bool {
        abs(preferredAttributes.size.height - originalAttributes.size.height) > 0.5
    }

    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(
            forPreferredLayoutAttributes: preferredAttributes,
            withOriginalAttributes: originalAttributes
        )
        guard let context = context as? RemoteConversationLayoutInvalidationContext else {
            return context
        }
        context.preservesCachedGeometry = true
        let index = originalAttributes.indexPath.item
        guard applyMeasuredHeight(preferredAttributes.size.height, at: index, into: context)
        else { return context }
        context.invalidateItems(at: invalidatedIndexPaths(from: index))
        return context
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        if let context = context as? RemoteConversationLayoutInvalidationContext {
            if context.clearsHeightCache {
                heightByIdentifier.removeAll(keepingCapacity: true)
            }
            if !context.preservesCachedGeometry {
                needsFullRebuild = true
            }
        } else {
            needsFullRebuild = true
        }
        super.invalidateLayout(with: context)
    }

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        needsFullRebuild = true
        super.prepare(forCollectionViewUpdates: updateItems)
    }

    func resetHeightCache() {
        heightByIdentifier.removeAll(keepingCapacity: true)
        needsFullRebuild = true
        invalidateLayout()
    }

    /// Re-measures rows whose content just changed, from the cells still mounted for them.
    ///
    /// The obvious alternative — forget the cached heights and rebuild — is what shipped, and it
    /// is why a streaming answer could leave the transcript blank. Forgetting stands the row back
    /// up at `estimatedRowHeight`, so a reply taller than the viewport collapsed by thousands of
    /// points on every chunk. A reader inside that row is then past the end of the content, where
    /// no cell is mounted, so nothing is left on screen to measure its way back and the collapse
    /// is permanent. Measuring here keeps a real height on the row at all times, and costs
    /// O(changed) rather than a rebuild of the whole history per chunk.
    func remeasureMountedItems(at indexPaths: [IndexPath]) {
        guard let collectionView, !indexPaths.isEmpty else { return }
        let context = RemoteConversationLayoutInvalidationContext()
        context.preservesCachedGeometry = true
        var invalidated: Set<IndexPath> = []
        for indexPath in indexPaths.sorted() where indexPath.section == 0 {
            let index = indexPath.item
            guard itemAttributes.indices.contains(index),
                  let cell = collectionView.cellForItem(at: indexPath) else { continue }
            let probe = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            probe.frame = itemFrame(at: index)
            let measured = cell.preferredLayoutAttributesFitting(probe).size.height
            guard applyMeasuredHeight(measured, at: index, into: context) else { continue }
            invalidated.formUnion(invalidatedIndexPaths(from: index))
        }
        guard !invalidated.isEmpty else { return }
        context.invalidateItems(at: Array(invalidated))
        invalidateLayout(with: context)
    }

    /// The row that replaces the streaming row starts from the height the streaming row was
    /// measured at rather than from the estimate. Both draw the same answer, so the outgoing
    /// measurement is the closest thing to the truth until the incoming cell mounts and reports
    /// its own — and starting from the estimate would drop the content out from under a reader
    /// sitting at the end of exactly that answer.
    func adoptHeight(of source: AnyHashable, for identifier: AnyHashable) {
        guard heightByIdentifier[identifier] == nil,
              let height = heightByIdentifier[source] else { return }
        heightByIdentifier[identifier] = height
    }

    /// A batch update that shrinks the content must not leave the viewport past the new end.
    /// UIKit clamps an offset it invalidated itself; it takes this answer for one a custom
    /// layout invalidated, and the default returns the proposal untouched.
    override func targetContentOffset(
        forProposedContentOffset proposedContentOffset: CGPoint
    ) -> CGPoint {
        guard let collectionView else { return proposedContentOffset }
        let minimum = -collectionView.adjustedContentInset.top
        let maximum = max(
            minimum,
            calculatedContentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        return CGPoint(
            x: proposedContentOffset.x,
            y: min(max(proposedContentOffset.y, minimum), maximum)
        )
    }

    /// Writes one row's newly measured height into the cached geometry, shifting everything
    /// below it. Returns whether the height actually moved.
    private func applyMeasuredHeight(
        _ measured: CGFloat,
        at index: Int,
        into context: RemoteConversationLayoutInvalidationContext
    ) -> Bool {
        guard itemAttributes.indices.contains(index) else { return false }
        let newHeight = max(1, ceil(measured))
        let oldFrame = itemFrame(at: index)
        let delta = newHeight - itemHeights[index]
        guard abs(delta) > 0.5 else { return false }

        heightByIdentifier[identifiers[index]] = newHeight
        itemHeights[index] = newHeight
        itemAttributes[index].frame = itemFrame(at: index)
        addSuffixAdjustment(from: index + 1, delta: delta)
        calculatedContentSize.height += delta
        context.contentSizeAdjustment.height += delta
        // Only a row that ends above the viewport moves what the reader is looking at. A row
        // the viewport is inside grows at its bottom, below the visible text, so following its
        // growth with the offset would march a streaming answer up off the screen instead.
        if let collectionView,
           oldFrame.maxY <= collectionView.contentOffset.y
               + collectionView.adjustedContentInset.top {
            context.contentOffsetAdjustment.y += delta
        }
        return true
    }

    /// The changed row and the mounted rows after it, whose origins have just moved.
    private func invalidatedIndexPaths(from index: Int) -> [IndexPath] {
        var result = [IndexPath(item: index, section: 0)]
        if let collectionView {
            result.append(contentsOf: collectionView.indexPathsForVisibleItems.filter {
                $0.section == 0 && $0.item > index
            })
        }
        return result
    }

    private func stableIdentifier(for indexPath: IndexPath) -> AnyHashable {
        itemIdentifier?(indexPath) ?? AnyHashable(indexPath)
    }

    private func itemFrame(at index: Int) -> CGRect {
        CGRect(
            x: sectionInsets.left,
            y: baseOrigins[index] + suffixAdjustment(at: index),
            width: availableWidth,
            height: itemHeights[index]
        )
    }

    private func addSuffixAdjustment(from start: Int, delta: CGFloat) {
        guard start < itemAttributes.count else { return }
        var treeIndex = start + 1
        while treeIndex < suffixAdjustmentTree.count {
            suffixAdjustmentTree[treeIndex] += delta
            treeIndex += treeIndex & -treeIndex
        }
    }

    private func suffixAdjustment(at index: Int) -> CGFloat {
        var result: CGFloat = 0
        var treeIndex = index + 1
        while treeIndex > 0 {
            result += suffixAdjustmentTree[treeIndex]
            treeIndex -= treeIndex & -treeIndex
        }
        return result
    }

#if DEBUG
    func geometryFailureCount() -> Int {
        var failures = 0
        var previousMaxY: CGFloat?
        for index in itemAttributes.indices {
            let frame = itemFrame(at: index)
            if !frame.minY.isFinite || !frame.height.isFinite || frame.height <= 0 {
                failures += 1
            }
            if let previousMaxY,
               abs(frame.minY - previousMaxY - spacing) > 0.5 {
                failures += 1
            }
            previousMaxY = frame.maxY
        }
        let expectedHeight = previousMaxY.map { $0 + sectionInsets.bottom }
            ?? sectionInsets.top + sectionInsets.bottom
        if abs(expectedHeight - calculatedContentSize.height) > 0.5 {
            failures += 1
        }
        return failures
    }
#endif
}

@MainActor
final class RemoteConversationTimelineViewController: UIViewController {
    private enum Item: Hashable {
        case history
        case row(String)
        case streaming
        case permission(String)
        case question(String)
    }

    private let connection: RemoteSessionConnection
    private let initialViewport: (progress: Double?, followsBottom: Bool)?
    private let onViewportChange: (Double, Bool) -> Void
    private var theme: RemoteThemePalette
    private var collectionView: UICollectionView!
    private let latestButton = MobileFloatingScrollToEndButton(
        accessibilityLabel: MobileL10n.string("Jump to latest message"),
        accessibilityIdentifier: "conversation-scroll-to-latest"
    )
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var storeObserver: UUID?
    private var parsedDocuments: [String: RemoteMarkdownDocument] = [:]
    private var markdownSources: [String: String] = [:]
    private var expandedRows: Set<String> = []
    private var hasAppliedInitialSnapshot = false
    private var hasHistoryItem = false
    private var hasStreamingItem = false
    private var permissionItemID: String?
    private var questionItemIDs: [String] = []
    private var questionDrafts: [String: MobileConversationQuestionDraft] = [:]
    private var needsInitialBottomPosition = true
    private var isInitialBottomPositionScheduled = false
    private var hasTimelineAppeared = false
    private var contentSizeObserver: NSObjectProtocol?
    private var contentHeightObservation: NSKeyValueObservation?
    private var viewportSaveWorkItem: DispatchWorkItem?
    private static let markdownPrefetchBatchSize = 64

    init(
        connection: RemoteSessionConnection,
        theme: RemoteThemePalette,
        initialViewport: (progress: Double?, followsBottom: Bool)?,
        onViewportChange: @escaping (Double, Bool) -> Void
    ) {
        self.connection = connection
        self.theme = theme
        self.initialViewport = initialViewport
        self.onViewportChange = onViewportChange
#if DEBUG
        if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
            == "conversation-tool-expanded" {
            expandedRows = ["content-tool-error"]
        }
#endif
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
#if DEBUG
        MobileConversationPerformanceProbe.timelineViewLoadStarted()
#endif
        configureCollectionView()
        configureDataSource()
        observeContentHeight()
        observeStoreIfNeeded()
        contentSizeObserver = NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.conversationLayout.resetHeightCache()
                self?.reconfigureVisibleContent()
            }
        }
        applySnapshot(scrollToBottom: initialViewport?.followsBottom != false)
        prefetchMarkdown()
#if DEBUG
        MobileConversationPerformanceProbe.timelineViewLoadEnded()
#endif
    }

    isolated deinit {
        if let contentSizeObserver {
            NotificationCenter.default.removeObserver(contentSizeObserver)
        }
        contentHeightObservation?.invalidate()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        saveViewport()
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
        hasTimelineAppeared = true
        positionInitialBottomAfterLayout()
        reportPerformanceFirstPaintIfReady()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionInitialBottomAfterLayout()
    }

    func updateTheme(_ theme: RemoteThemePalette) {
        guard self.theme != theme else { return }
        self.theme = theme
        view.backgroundColor = theme.uiGround
        collectionView.backgroundColor = theme.uiGround
        applyLatestButtonTheme()
        reconfigureVisibleContent()
    }

    /// The viewport may never come to rest past the end of the content.
    ///
    /// Rotation and a Dynamic Type change both throw away every measured height, so a long
    /// history re-estimates down to a fraction of its real length while the reader is somewhere
    /// inside it. UIKit clamps a stale offset when it owns the shrink; a custom layout's shrink
    /// leaves it, and a viewport past the end mounts no cell, so the transcript has nothing left
    /// on screen to measure its way back with. The check is O(1) and steps aside for the offsets
    /// a finger is legitimately holding out of bounds.
    private func observeContentHeight() {
        contentHeightObservation = collectionView.observe(
            \.contentSize,
            options: [.new]
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.clampViewportWithinContent() }
        }
    }

    private func clampViewportWithinContent() {
        guard hasAppliedInitialSnapshot, !needsInitialBottomPosition else { return }
        guard !collectionView.isTracking,
              !collectionView.isDragging,
              !collectionView.isDecelerating else { return }
        let minimum = -collectionView.adjustedContentInset.top
        let maximum = max(
            minimum,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        guard collectionView.contentOffset.y > maximum + 0.5 else { return }
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: maximum),
            animated: false
        )
    }

    private func observeStoreIfNeeded() {
        guard storeObserver == nil else { return }
        storeObserver = connection.conversationStore.observe { [weak self] change in
            self?.apply(change)
        }
    }

    private func configureCollectionView() {
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: RemoteConversationLayout(
                estimatedRowHeight: MobileDesign.Size.conversationEstimatedRowHeight
            )
        )
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = theme.uiGround
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        for reuseIdentifier in RemoteConversationRowCell.reuseIdentifiers {
            collectionView.register(
                RemoteConversationRowCell.self,
                forCellWithReuseIdentifier: reuseIdentifier
            )
        }
        collectionView.register(RemoteConversationQuestionCell.self,
                                forCellWithReuseIdentifier: RemoteConversationQuestionCell.reuseIdentifier)
        collectionView.register(
            RemoteConversationPermissionCell.self,
            forCellWithReuseIdentifier: RemoteConversationPermissionCell.reuseIdentifier
        )
        collectionView.register(
            RemoteConversationHistoryCell.self,
            forCellWithReuseIdentifier: RemoteConversationHistoryCell.reuseIdentifier
        )
        view.addSubview(collectionView)
        latestButton.addAction(UIAction { [weak self] _ in
            self?.scrollToBottom(animated: true, cancellingUserMotion: true)
        }, for: .touchUpInside)
        view.addSubview(latestButton)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            latestButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -MobileDesign.Spacing.inset
            ),
            latestButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -MobileDesign.Spacing.inset
            ),
            latestButton.widthAnchor.constraint(
                equalToConstant: MobileDesign.Size.floatingScrollTarget
            ),
            latestButton.heightAnchor.constraint(
                equalToConstant: MobileDesign.Size.floatingScrollTarget
            ),
        ])
        view.backgroundColor = theme.uiGround
        applyLatestButtonTheme()
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else { return nil }
#if DEBUG
            MobileConversationPerformanceProbe.visibleCellWillConfigure(
                collectionWidth: collectionView.bounds.width
            )
#endif
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
                    withReuseIdentifier: RemoteConversationRowCell.reuseIdentifier(
                        for: row.kind
                    ),
                    for: indexPath
                ) as! RemoteConversationRowCell
                cell.configure(
                    row: row,
                    markdown: parsedDocuments[id],
                    isExpanded: expandedRows.contains(id),
                    theme: theme,
                    toggleExpansion: { [weak self] in self?.toggleRow(id) }
                )
                if row.kind == .assistant, parsedDocuments[id] == nil {
                    prepareMarkdown(for: row)
                }
                return cell

            case .streaming:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: RemoteConversationRowCell.streamingReuseIdentifier,
                    for: indexPath
                ) as! RemoteConversationRowCell
                cell.configureStreaming(
                    connection.conversationStore.state.streamingText,
                    theme: theme
                )
                return cell

            case .question(let id):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: RemoteConversationQuestionCell.reuseIdentifier, for: indexPath
                ) as! RemoteConversationQuestionCell
                configureQuestion(cell, id: id)
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
        conversationLayout.itemIdentifier = { [weak self] indexPath in
            self?.dataSource.itemIdentifier(for: indexPath).map(AnyHashable.init)
        }
    }

    private func apply(_ change: RemoteConversationStore.Change) {
        let nearBottom = isNearBottom
        switch change {
        case .unchanged:
            break

        case .reset(let updated):
            let state = connection.conversationStore.state
            let activeIDs = Set(state.rows.map(\.id))
            let assistantSources = Dictionary(uniqueKeysWithValues: state.rows.compactMap { row in
                row.kind == .assistant ? (row.id, row.text ?? "") : nil
            })
            for (id, source) in markdownSources
            where assistantSources[id] != source {
                markdownSources[id] = nil
                parsedDocuments[id] = nil
            }
            expandedRows.formIntersection(activeIDs)
            applySnapshot(
                reconfiguring: Set(updated),
                scrollToBottom: !hasAppliedInitialSnapshot || nearBottom
            )
            prefetchMarkdown()

        case .delta(
            let inserted,
            let updated,
            let streamingChanged,
            let permissionChanged,
            let questionsChanged,
            _,
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
                || questionItemIDs != state.questions.map(\.id)

            if structureChanged {
                applySnapshot(
                    reconfiguring: Set(updated),
                    scrollToBottom: nearBottom && (!inserted.isEmpty || questionsChanged || permissionChanged)
                )
            } else {
                var items = updated.map(Item.row)
                if streamingChanged, hasStreamingItem {
                    items.append(.streaming)
                }
                if permissionChanged, let desiredPermissionID {
                    items.append(.permission(desiredPermissionID))
                }
                if questionsChanged { items.append(contentsOf: state.questions.map { .question($0.id) }) }
                if historyChanged, hasHistoryItem {
                    items.append(.history)
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
        snapshot.appendItems(state.questions.map { .question($0.id) })
        return snapshot
    }

    private func applySnapshot(
        reconfiguring ids: Set<String> = [],
        reconfiguringSynthetic: Bool = false,
        scrollToBottom: Bool = false
    ) {
        var snapshot = makeSnapshot()
        adoptStreamingHeightIfHandingOff()
#if DEBUG
        let profilesInitialSnapshot = !hasAppliedInitialSnapshot
        if profilesInitialSnapshot {
            MobileConversationPerformanceProbe.initialSnapshotApplyStarted()
        }
#endif
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
        dataSource.apply(snapshot, animatingDifferences: hasAppliedInitialSnapshot && !UIAccessibility.isReduceMotionEnabled) { [weak self] in
            guard let self else { return }
#if DEBUG
            if profilesInitialSnapshot {
                MobileConversationPerformanceProbe.initialSnapshotApplied()
            }
#endif
            self.hasAppliedInitialSnapshot = true
#if DEBUG
            MobileConversationPerformanceProbe.conversationSnapshotApplied(
                self.collectionView
            )
#endif
            if scrollToBottom {
                if self.needsInitialBottomPosition {
                    self.positionInitialBottomAfterLayout()
                } else {
                    self.scrollToBottom()
                }
            }
        }
    }

    /// Streaming ends by dropping the streaming row and leaving the finished answer as the last
    /// row. Those are two identities, so the incoming row would otherwise begin at the estimate
    /// and take the whole answer's height out of the content under a reader who is — by
    /// construction, because they were watching it arrive — sitting at the end of it.
    private func adoptStreamingHeightIfHandingOff() {
        let state = connection.conversationStore.state
        guard hasStreamingItem,
              state.streamingText.isEmpty,
              state.permission == nil,
              state.questions.isEmpty,
              let tailID = state.rows.last?.id else { return }
        conversationLayout.adoptHeight(
            of: AnyHashable(Item.streaming),
            for: AnyHashable(Item.row(tailID))
        )
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
        let candidates = connection.conversationStore.state.rows.reversed().compactMap {
            row -> (id: String, source: String)? in
            guard row.kind == .assistant, ids == nil || ids?.contains(row.id) == true else {
                return nil
            }
            let source = row.text ?? ""
            guard parsedDocuments[row.id] == nil, markdownSources[row.id] != source else {
                return nil
            }
            markdownSources[row.id] = source
            return (row.id, source)
        }
        guard !candidates.isEmpty else { return }

        // Warm the newest content first, but amortize actor hops and main-actor resumptions. A
        // task per historical response floods cold open with thousands of tiny completions before
        // a long conversation has appeared.
        Task { [weak self] in
            for start in stride(
                from: 0,
                to: candidates.count,
                by: Self.markdownPrefetchBatchSize
            ) {
                let end = min(start + Self.markdownPrefetchBatchSize, candidates.count)
                let batch = Array(candidates[start..<end])
                let documents = await RemoteMarkdownDocumentCache.shared.documents(
                    for: batch.map(\.source)
                )
                guard let self else { return }
                var changedItems: [Item] = []
                for (candidate, document) in zip(batch, documents)
                where self.markdownSources[candidate.id] == candidate.source {
                    self.parsedDocuments[candidate.id] = document
                    changedItems.append(.row(candidate.id))
                }
                let shouldFollowBottom = self.isNearBottom
                let changedVisibleContent = self.reconfigure(changedItems)
                if shouldFollowBottom, changedVisibleContent {
                    // The first pass discovers the formatted height; the second consumes that
                    // invalidation before resolving the final bottom offset.
                    self.collectionView.layoutIfNeeded()
                    self.scrollToBottom()
                    self.collectionView.layoutIfNeeded()
                    self.scrollToBottom()
                }
                await Task.yield()
            }
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
            let changedVisibleContent = self.reconfigure([.row(row.id)])
            if shouldFollowBottom, changedVisibleContent {
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
        questionItemIDs = state.questions.map(\.id)
        let active = Set(questionItemIDs)
        questionDrafts = questionDrafts.filter { active.contains($0.key) }
    }

    @discardableResult
    private func reconfigure(_ items: [Item]) -> Bool {
        var changedVisibleItems: [IndexPath] = []
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
                changedVisibleItems.append(indexPath)

            case .streaming:
                guard let cell = cell as? RemoteConversationRowCell else { continue }
                cell.configureStreaming(
                    connection.conversationStore.state.streamingText,
                    theme: theme
                )
                changedVisibleItems.append(indexPath)

            case .question(let id):
                guard let cell = cell as? RemoteConversationQuestionCell else { continue }
                configureQuestion(cell, id: id)
                changedVisibleItems.append(indexPath)

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
                changedVisibleItems.append(indexPath)
            }
        }
        conversationLayout.remeasureMountedItems(at: changedVisibleItems)
        return !changedVisibleItems.isEmpty
    }

    private func configureQuestion(_ cell: RemoteConversationQuestionCell, id: String) {
        guard let request = connection.conversationStore.state.questions.first(where: { $0.id == id }) else { return }
        let draft = questionDrafts[id] ?? MobileConversationQuestionDraft()
        questionDrafts[id] = draft
        cell.configure(request: request, draft: draft, theme: theme, answer: { [weak self] answers in
            self?.connection.answerQuestion(request, answers: answers)
        }, layoutChanged: { [weak self] in
            guard let self, let indexPath = dataSource.indexPath(for: .question(id)) else {
                return
            }
            conversationLayout.remeasureMountedItems(at: [indexPath])
        })
    }

    private var conversationLayout: RemoteConversationLayout {
        collectionView.collectionViewLayout as! RemoteConversationLayout
    }

    private var isNearBottom: Bool {
        let remaining = collectionView.contentSize.height
            - collectionView.contentOffset.y
            - collectionView.bounds.height
        return remaining < MobileDesign.Size.conversationBottomTolerance
    }

    private func scrollToBottom(
        animated: Bool = false,
        cancellingUserMotion: Bool = false
    ) {
        guard let item = dataSource.snapshot().itemIdentifiers.last,
              let indexPath = dataSource.indexPath(for: item) else { return }
        if cancellingUserMotion {
            MobileScrollMotion.cancel(in: collectionView)
        }
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
        setLatestButtonVisible(false)
    }

    private func applyLatestButtonTheme() {
        latestButton.applyTheme(theme)
    }

    private func setLatestButtonVisible(_ visible: Bool) {
        latestButton.setPresented(visible)
    }

    private func positionInitialBottomAfterLayout() {
        guard needsInitialBottomPosition,
              hasAppliedInitialSnapshot,
              collectionView.bounds.width > 1,
              collectionView.bounds.height > 1 else { return }
        guard !isInitialBottomPositionScheduled else { return }
        isInitialBottomPositionScheduled = true
#if DEBUG
        MobileConversationPerformanceProbe.initialBottomSettleScheduled()
#endif
        positionFromContinuity()

        // `applySnapshot` runs from the child's `viewDidLoad`, before the parent has installed
        // the timeline's constraints. Forcing layout from the diffable completion therefore
        // used to create visible cells at a one-point width, then throw those heights away and
        // create them again after the real width arrived. The first valid layout establishes the
        // estimated bottom without nesting another layout pass. Settle measured visible heights
        // once on the next turn; repeated layout/view-appearance callbacks share this task.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.needsInitialBottomPosition else {
                self.isInitialBottomPositionScheduled = false
                return
            }
            self.collectionView.layoutIfNeeded()
            self.positionFromContinuity()
            // Positioning can expose one more estimated row at the viewport boundary. Consume
            // that row's measured height before declaring the initial viewport settled.
            self.collectionView.layoutIfNeeded()
            self.positionFromContinuity()
            self.needsInitialBottomPosition = false
            self.isInitialBottomPositionScheduled = false
            // A persisted non-following viewport is semantically away from the live edge even
            // when short final rows happen to fall inside the normal near-bottom tolerance.
            // Keep the affordance visible until the person explicitly returns to the end.
            self.setLatestButtonVisible(
                self.initialViewport?.followsBottom == false || !self.isNearBottom
            )
#if DEBUG
            MobileConversationPerformanceProbe.initialBottomSettled()
#endif
            self.reportPerformanceFirstPaintIfReady()
        }
    }

    private func reportPerformanceFirstPaintIfReady() {
#if DEBUG
        guard hasTimelineAppeared, !needsInitialBottomPosition else { return }
        MobileConversationPerformanceProbe.timelineDidAppear(collectionView)
#endif
    }

    private func positionFromContinuity() {
        guard initialViewport?.followsBottom == false,
              let progress = initialViewport?.progress else {
            scrollToBottom()
            return
        }
        let minimumOffset = -collectionView.adjustedContentInset.top
        let maximumOffset = max(
            minimumOffset,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        collectionView.setContentOffset(
            CGPoint(
                x: collectionView.contentOffset.x,
                y: minimumOffset + (maximumOffset - minimumOffset) * min(max(progress, 0), 1)
            ),
            animated: false
        )
    }

    private func scheduleViewportSave() {
        viewportSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveViewport() }
        viewportSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func saveViewport() {
        guard isViewLoaded, hasAppliedInitialSnapshot else { return }
        viewportSaveWorkItem?.cancel()
        viewportSaveWorkItem = nil
        let minimumOffset = -collectionView.adjustedContentInset.top
        let maximumOffset = max(
            minimumOffset,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        let available = maximumOffset - minimumOffset
        let progress = available > 0
            ? Double(min(max((collectionView.contentOffset.y - minimumOffset) / available, 0), 1))
            : 1
        onViewportChange(progress, isNearBottom)
    }
}

extension RemoteConversationTimelineViewController: UICollectionViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        needsInitialBottomPosition = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if hasAppliedInitialSnapshot, !needsInitialBottomPosition {
            setLatestButtonVisible(!isNearBottom)
        }
        if scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking {
            needsInitialBottomPosition = false
            scheduleViewportSave()
        }
        guard scrollView.isDragging,
              scrollView.contentOffset.y < MobileDesign.Size.conversationHistoryTrigger else {
            return
        }
        connection.loadEarlierConversation()
    }
}

#if DEBUG
/// Simulator-only performance fixture plumbing. Production conversation code does not schedule
/// synthetic scrolling; the probe is reachable only through the existing DEBUG demo launch gate.
@MainActor
enum MobileConversationPerformanceProbe {
    private struct Fixture {
        let mode: String
        let sourceRows: Int
        let mountedRows: Int
        let startedAt: TimeInterval
        let generationMilliseconds: Double
        let storeMilliseconds: Double
        let reconnect: (() -> Bool)?
    }

    private static var fixture: Fixture?
    private static var didReportFirstPaint = false
    private static var scrollDriver: ScrollDriver?
    private static var timelineViewLoadStartedAt: TimeInterval?
    private static var timelineViewLoadEndedAt: TimeInterval?
    private static var initialSnapshotStartedAt: TimeInterval?
    private static var initialSnapshotAppliedAt: TimeInterval?
    private static var initialBottomSettledAt: TimeInterval?
    private static var invalidWidthCellConfigurations = 0
    private static var initialBottomSettleTasks = 0
    private static var restoredDraftAssignments = 0
    private static var reconnectStartedAt: TimeInterval?
    private static var reconnectDispatchMilliseconds = 0.0
    private static var reconnectAwaitsSnapshot = false
    private static var reconnectSettleScheduled = false
    private static var reconnectSnapshotReset = false

    static func fixtureDidLoad(
        mode: String,
        sourceRows: Int,
        mountedRows: Int,
        startedAt: TimeInterval,
        generationMilliseconds: Double,
        storeMilliseconds: Double,
        reconnect: (() -> Bool)?
    ) {
        // `simctl launch --stdout/--stderr` is not reliable for detached UIKit apps on every
        // simulator runtime. Keep the machine-readable copy in the app container as well so the
        // CLI harness can always collect it after sampling.
        try? Data().write(to: reportURL, options: .atomic)
        fixture = Fixture(
            mode: mode,
            sourceRows: sourceRows,
            mountedRows: mountedRows,
            startedAt: startedAt,
            generationMilliseconds: generationMilliseconds,
            storeMilliseconds: storeMilliseconds,
            reconnect: reconnect
        )
        didReportFirstPaint = false
        scrollDriver?.stop()
        scrollDriver = nil
        timelineViewLoadStartedAt = nil
        timelineViewLoadEndedAt = nil
        initialSnapshotStartedAt = nil
        initialSnapshotAppliedAt = nil
        initialBottomSettledAt = nil
        invalidWidthCellConfigurations = 0
        initialBottomSettleTasks = 0
        restoredDraftAssignments = 0
        reconnectStartedAt = nil
        reconnectDispatchMilliseconds = 0
        reconnectAwaitsSnapshot = false
        reconnectSettleScheduled = false
        reconnectSnapshotReset = false
    }

    static func timelineViewLoadStarted() {
        timelineViewLoadStartedAt = ProcessInfo.processInfo.systemUptime
    }

    static func timelineViewLoadEnded() {
        timelineViewLoadEndedAt = ProcessInfo.processInfo.systemUptime
    }

    static func initialSnapshotApplyStarted() {
        initialSnapshotStartedAt = ProcessInfo.processInfo.systemUptime
    }

    static func initialSnapshotApplied() {
        initialSnapshotAppliedAt = ProcessInfo.processInfo.systemUptime
    }

    static func initialBottomSettleScheduled() {
        initialBottomSettleTasks += 1
    }

    static func initialBottomSettled() {
        initialBottomSettledAt = ProcessInfo.processInfo.systemUptime
    }

    static func restoredDraftWillAssign() {
        restoredDraftAssignments += 1
    }

    static func conversationSnapshotApplied(_ collectionView: UICollectionView) {
        guard reconnectStartedAt != nil, reconnectAwaitsSnapshot else { return }
        reconnectAwaitsSnapshot = false
        scheduleReconnectSettle(collectionView)
    }

    static func visibleCellWillConfigure(collectionWidth: CGFloat) {
        if collectionWidth <= 1 {
            invalidWidthCellConfigurations += 1
        }
    }

    static func timelineDidAppear(_ collectionView: UICollectionView) {
        guard let fixture, !didReportFirstPaint else { return }
        didReportFirstPaint = true

        // Diffable application and self-sizing both settle asynchronously. Reporting on the next
        // main turn includes that first real cell layout rather than only view-controller setup.
        DispatchQueue.main.async {
            collectionView.layoutIfNeeded()
            let visibleIndices = collectionView.indexPathsForVisibleItems.map(\.item).sorted()
            let lastItemIndex = collectionView.numberOfItems(inSection: 0) - 1
            let bottomError = max(
                0,
                collectionView.contentSize.height
                    - collectionView.contentOffset.y
                    - collectionView.bounds.height
            )
            let firstPaintMilliseconds = (
                ProcessInfo.processInfo.systemUptime - fixture.startedAt
            ) * 1_000
            let timelineViewLoadMilliseconds = elapsedMilliseconds(
                from: timelineViewLoadStartedAt,
                to: timelineViewLoadEndedAt
            )
            let initialSnapshotMilliseconds = elapsedMilliseconds(
                from: initialSnapshotStartedAt,
                to: initialSnapshotAppliedAt
            )
            let initialBottomSettleMilliseconds = elapsedMilliseconds(
                from: initialSnapshotAppliedAt,
                to: initialBottomSettledAt
            )
            report(
                "THREADING_PERF ios-conversation-cold-open "
                    + "mode=\(fixture.mode) source_rows=\(fixture.sourceRows) "
                    + "mounted_rows=\(fixture.mountedRows) "
                    + "visible_cells=\(collectionView.visibleCells.count) "
                    + "first_visible_index=\(visibleIndices.first ?? -1) "
                    + "last_visible_index=\(visibleIndices.last ?? -1) "
                    + "last_item_index=\(lastItemIndex) "
                    + "bottom_error=\(milliseconds(bottomError)) "
                    + "fixture_ms=\(milliseconds(fixture.generationMilliseconds)) "
                    + "store_ms=\(milliseconds(fixture.storeMilliseconds)) "
                    + "timeline_load_ms=\(milliseconds(timelineViewLoadMilliseconds)) "
                    + "snapshot_apply_ms=\(milliseconds(initialSnapshotMilliseconds)) "
                    + "bottom_settle_ms=\(milliseconds(initialBottomSettleMilliseconds)) "
                    + "invalid_width_cells=\(invalidWidthCellConfigurations) "
                    + "settle_tasks=\(initialBottomSettleTasks) "
                    + "draft_assignments=\(restoredDraftAssignments) "
                    + "first_paint_ms=\(milliseconds(firstPaintMilliseconds))"
            )

            if fixture.mode == "conversation-reconnect-stress" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    startReconnect(in: collectionView)
                }
                return
            }

            guard fixture.mode == "conversation-scroll-stress" else { return }
            let duration = ProcessInfo.processInfo.environment[
                "THREADING_MOBILE_CONVERSATION_SCROLL_SECONDS"
            ].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 8
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(750))
                guard scrollDriver == nil else { return }
                let driver = ScrollDriver(
                    collectionView: collectionView,
                    sourceRows: fixture.sourceRows,
                    duration: duration
                )
                scrollDriver = driver
                driver.start()
            }
        }
    }

    private static func startReconnect(in collectionView: UICollectionView) {
        guard let fixture, let reconnect = fixture.reconnect,
              reconnectStartedAt == nil else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        reconnectStartedAt = startedAt
        // Set this before dispatching the synchronous store notification. Diffable normally
        // completes later, but the benchmark should not depend on that implementation detail.
        reconnectAwaitsSnapshot = true
        let expectsSnapshot = reconnect()
        reconnectDispatchMilliseconds = (
            ProcessInfo.processInfo.systemUptime - startedAt
        ) * 1_000
        reconnectSnapshotReset = expectsSnapshot
        if !expectsSnapshot {
            reconnectAwaitsSnapshot = false
            scheduleReconnectSettle(collectionView)
        }
    }

    private static func scheduleReconnectSettle(_ collectionView: UICollectionView) {
        guard let fixture, !reconnectSettleScheduled else { return }
        reconnectSettleScheduled = true
        DispatchQueue.main.async { [weak collectionView] in
            guard let collectionView, let startedAt = reconnectStartedAt else { return }
            let layoutStartedAt = ProcessInfo.processInfo.systemUptime
            collectionView.layoutIfNeeded()
            let layoutEndedAt = ProcessInfo.processInfo.systemUptime
            CATransaction.flush()
            let displayEndedAt = ProcessInfo.processInfo.systemUptime

            // The outer conversation controller coalesces phase publications onto a main turn.
            // Let that render and any diffable completion commit before reading final geometry.
            DispatchQueue.main.async { [weak collectionView] in
                guard let collectionView else { return }
                let finalLayoutStartedAt = ProcessInfo.processInfo.systemUptime
                collectionView.layoutIfNeeded()
                let finalLayoutEndedAt = ProcessInfo.processInfo.systemUptime
                CATransaction.flush()
                let settledAt = ProcessInfo.processInfo.systemUptime
                let visibleIndices = collectionView.indexPathsForVisibleItems
                    .map(\.item)
                    .sorted()
                let bottomError = max(
                    0,
                    collectionView.contentSize.height
                        - collectionView.contentOffset.y
                        - collectionView.bounds.height
                )
                let geometryFailures = (
                    collectionView.collectionViewLayout as? RemoteConversationLayout
                )?.geometryFailureCount() ?? -1
                let layoutMilliseconds = (
                    layoutEndedAt - layoutStartedAt
                        + finalLayoutEndedAt - finalLayoutStartedAt
                ) * 1_000
                let displayMilliseconds = (
                    displayEndedAt - layoutEndedAt
                        + settledAt - finalLayoutEndedAt
                ) * 1_000
                report([
                    "THREADING_PERF ios-conversation-reconnect",
                    "source_rows=\(fixture.sourceRows)",
                    "snapshot_reset=\(reconnectSnapshotReset ? 1 : 0)",
                    "dispatch_ms=\(milliseconds(reconnectDispatchMilliseconds))",
                    "layout_ms=\(milliseconds(layoutMilliseconds))",
                    "display_ms=\(milliseconds(displayMilliseconds))",
                    "total_ms=\(milliseconds((settledAt - startedAt) * 1_000))",
                    "visible_cells=\(collectionView.visibleCells.count)",
                    "first_visible_index=\(visibleIndices.first ?? -1)",
                    "last_visible_index=\(visibleIndices.last ?? -1)",
                    "bottom_error=\(milliseconds(bottomError))",
                    "geometry_failures=\(geometryFailures)",
                ].joined(separator: " "))
            }
        }
    }

    private static func finished(_ driver: ScrollDriver) {
        if scrollDriver === driver {
            scrollDriver = nil
        }
    }

    private static func elapsedMilliseconds(
        from start: TimeInterval?,
        to end: TimeInterval?
    ) -> Double {
        guard let start, let end else { return 0 }
        return max(0, (end - start) * 1_000)
    }

    private static func milliseconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func report(_ line: String) {
        let data = Data((line + "\n").utf8)
        FileHandle.standardError.write(data)
        if let handle = try? FileHandle(forWritingTo: reportURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // The stderr copy is still useful when running directly from Xcode.
            }
        } else {
            try? data.write(to: reportURL, options: .atomic)
        }
    }

    private static var reportURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-conversation-performance.log")
    }

    @MainActor
    private final class ScrollDriver: NSObject {
        private weak var collectionView: UICollectionView?
        private let sourceRows: Int
        private let duration: TimeInterval
        private var displayLink: CADisplayLink?
        private var startedAt: TimeInterval = 0
        private var previousTick: TimeInterval?
        private var frameGaps: [Double] = []
        private var workDurations: [Double] = []
        private var framesOver16Milliseconds = 0
        private var framesOver33Milliseconds = 0
        private var peakVisibleCells = 0
        private var initialJumpMilliseconds = 0.0
        private var initialTopIndex = -1

        init(collectionView: UICollectionView, sourceRows: Int, duration: TimeInterval) {
            self.collectionView = collectionView
            self.sourceRows = sourceRows
            self.duration = duration
        }

        func start() {
            guard let collectionView else { return }
            collectionView.layoutIfNeeded()
            let jumpStarted = ProcessInfo.processInfo.systemUptime
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: 0),
                animated: false
            )
            collectionView.layoutIfNeeded()
            initialJumpMilliseconds = (
                ProcessInfo.processInfo.systemUptime - jumpStarted
            ) * 1_000
            initialTopIndex = topVisibleIndex(in: collectionView)
            peakVisibleCells = collectionView.visibleCells.count
            startedAt = ProcessInfo.processInfo.systemUptime
            previousTick = nil
            let link = CADisplayLink(target: self, selector: #selector(tick))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick() {
            guard let collectionView else {
                finish()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - startedAt
            if let previousTick {
                let gap = (now - previousTick) * 1_000
                frameGaps.append(gap)
                if gap > 16.7 { framesOver16Milliseconds += 1 }
                if gap > 33.3 { framesOver33Milliseconds += 1 }
            }
            previousTick = now
            guard elapsed < duration else {
                finish()
                return
            }

            let progress = min(1, elapsed / duration)
            let travel = progress <= 0.5 ? progress * 2 : (1 - progress) * 2
            let maximumOffset = max(
                0,
                collectionView.contentSize.height - collectionView.bounds.height
            )
            let workStarted = ProcessInfo.processInfo.systemUptime
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: maximumOffset * travel),
                animated: false
            )
            collectionView.layoutIfNeeded()
            workDurations.append(
                (ProcessInfo.processInfo.systemUptime - workStarted) * 1_000
            )
            peakVisibleCells = max(peakVisibleCells, collectionView.visibleCells.count)
        }

        private func finish() {
            stop()
            guard let collectionView else {
                MobileConversationPerformanceProbe.finished(self)
                return
            }
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: 0),
                animated: false
            )
            collectionView.layoutIfNeeded()
            let finalTopIndex = topVisibleIndex(in: collectionView)
            let geometryFailures = (
                collectionView.collectionViewLayout as? RemoteConversationLayout
            )?.geometryFailureCount() ?? -1
            MobileConversationPerformanceProbe.report(
                "THREADING_PERF ios-conversation-scroll "
                    + "source_rows=\(sourceRows) frames=\(workDurations.count) "
                    + "jump_to_top_ms=\(milliseconds(initialJumpMilliseconds)) "
                    + "jump_top_index=\(initialTopIndex) "
                    + "work_p50_ms=\(milliseconds(percentile(workDurations, 0.50))) "
                    + "work_p95_ms=\(milliseconds(percentile(workDurations, 0.95))) "
                    + "frame_gap_p95_ms=\(milliseconds(percentile(frameGaps, 0.95))) "
                    + "frames_over_16_7=\(framesOver16Milliseconds) "
                    + "frames_over_33_3=\(framesOver33Milliseconds) "
                    + "peak_visible_cells=\(peakVisibleCells) "
                    + "final_top_index=\(finalTopIndex) "
                    + "geometry_failures=\(geometryFailures)"
            )
            MobileConversationPerformanceProbe.finished(self)
        }

        private func topVisibleIndex(in collectionView: UICollectionView) -> Int {
            collectionView.indexPathsForVisibleItems.map(\.item).min() ?? -1
        }

        private func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
            return sorted[min(max(index, 0), sorted.count - 1)]
        }

        private func milliseconds(_ value: Double) -> String {
            String(format: "%.3f", value)
        }
    }
}
#endif

// MARK: - Reusable row cell

private final class RemoteConversationRowCell: UICollectionViewCell {
    private static let reuseIdentifierBase = "RemoteConversationRowCell"
    static let streamingReuseIdentifier = "\(reuseIdentifierBase).streaming"
    static let reuseIdentifiers = [
        "\(reuseIdentifierBase).user",
        "\(reuseIdentifierBase).assistant",
        "\(reuseIdentifierBase).thinking",
        "\(reuseIdentifierBase).tool",
        "\(reuseIdentifierBase).notice",
        streamingReuseIdentifier,
    ]

    static func reuseIdentifier(for kind: RemoteConversationRowKind) -> String {
        switch kind {
        case .user: return "\(reuseIdentifierBase).user"
        case .assistant: return "\(reuseIdentifierBase).assistant"
        case .thinking: return "\(reuseIdentifierBase).thinking"
        case .tool: return "\(reuseIdentifierBase).tool"
        default: return "\(reuseIdentifierBase).notice"
        }
    }

    private var hostedView: UIView?

    override func prepareForReuse() {
        super.prepareForReuse()
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let preferred = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        let target = CGSize(
            width: layoutAttributes.size.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        preferred.size.height = ceil(contentView.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
        return preferred
    }

    func configure(
        row: RemoteConversationRowDTO,
        markdown: RemoteMarkdownDocument?,
        isExpanded: Bool,
        theme: RemoteThemePalette,
        toggleExpansion: @escaping () -> Void
    ) {
        switch row.kind {
        case .user:
            if let view = hostedView as? RemoteUserMessageView {
                view.configure(
                    text: row.text ?? "",
                    context: row.contextAttachments ?? [],
                    theme: theme
                )
            } else {
                install(RemoteUserMessageView(
                    text: row.text ?? "",
                    context: row.contextAttachments ?? [],
                    theme: theme
                ))
            }
        case .assistant:
            if let view = hostedView as? RemoteAssistantMessageView {
                view.configure(source: row.text ?? "", document: markdown, theme: theme)
            } else {
                install(RemoteAssistantMessageView(
                    source: row.text ?? "",
                    document: markdown,
                    theme: theme
                ))
            }
        case .thinking:
            install(RemoteExpandableMessageView(
                title: "Reasoning",
                text: row.text ?? "",
                isExpanded: isExpanded,
                theme: theme,
                toggle: toggleExpansion
            ))
        case .tool:
            if let view = hostedView as? RemoteToolMessageView {
                view.configure(
                    row: row,
                    isExpanded: isExpanded,
                    theme: theme,
                    toggle: toggleExpansion
                )
            } else {
                install(RemoteToolMessageView(
                    row: row,
                    isExpanded: isExpanded,
                    theme: theme,
                    toggle: toggleExpansion
                ))
            }
        default:
            install(RemoteNoticeMessageView(row: row, theme: theme))
        }
    }

    func configureStreaming(_ text: String, theme: RemoteThemePalette) {
        if let view = hostedView as? RemoteStreamingMessageView {
            view.configure(text: text, theme: theme)
        } else {
            install(RemoteStreamingMessageView(text: text, theme: theme))
        }
    }

    private func install(_ view: UIView) {
        if hostedView === view { return }
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

/// The stable one-line contract for a collapsed remote tool call.
///
/// A `UIButton.Configuration` with a title and subtitle lays those values out as a two-line card.
/// That made every completed tool consume the same vertical space as transcript prose even though
/// its result was still collapsed. This control keeps the 44-point hit target while assigning the
/// tool, subject, outcome and disclosure to explicit horizontal columns. Only the subject yields.
final class RemoteToolDisclosureControl: UIControl {
    private static let toggleActionIdentifier = UIAction.Identifier(
        "RemoteToolDisclosureControl.toggle"
    )

    private let toolImageView = UIImageView()
    private let toolLabel = UILabel()
    private let summaryLabel = UILabel()
    private let outcomeImageView = UIImageView()
    private let disclosureImageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        toolImageView.translatesAutoresizingMaskIntoConstraints = false
        toolImageView.contentMode = .scaleAspectFit
        toolImageView.setContentHuggingPriority(.required, for: .horizontal)
        toolImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        toolLabel.numberOfLines = 1
        toolLabel.adjustsFontForContentSizeCategory = true
        toolLabel.setContentHuggingPriority(.required, for: .horizontal)
        toolLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        summaryLabel.numberOfLines = 1
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        outcomeImageView.translatesAutoresizingMaskIntoConstraints = false
        outcomeImageView.contentMode = .scaleAspectFit
        outcomeImageView.setContentHuggingPriority(.required, for: .horizontal)
        outcomeImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        disclosureImageView.translatesAutoresizingMaskIntoConstraints = false
        disclosureImageView.contentMode = .scaleAspectFit
        disclosureImageView.setContentHuggingPriority(.required, for: .horizontal)
        disclosureImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [
            toolImageView,
            toolLabel,
            summaryLabel,
            outcomeImageView,
            disclosureImageView,
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = MobileDesign.Spacing.small
        stack.isUserInteractionEnabled = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(
                greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget
            ),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            toolImageView.widthAnchor.constraint(equalToConstant: 16),
            toolImageView.heightAnchor.constraint(equalToConstant: 16),
            outcomeImageView.widthAnchor.constraint(equalToConstant: 16),
            outcomeImageView.heightAnchor.constraint(equalToConstant: 16),
            disclosureImageView.widthAnchor.constraint(equalToConstant: 12),
            disclosureImageView.heightAnchor.constraint(equalToConstant: 12),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        MobileButtonHaptics.install(on: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        row: RemoteConversationRowDTO,
        isExpanded: Bool,
        theme: RemoteThemePalette,
        toggle: @escaping () -> Void
    ) {
        let toolName = row.toolName ?? MobileL10n.string("Tool")
        let summary = row.summary ?? MobileL10n.string("Working…")
        let hasDetails = row.result?.isEmpty == false

        toolImageView.image = UIImage(systemName: RemoteToolMessageView.symbol(
            for: row.toolName
        ))
        toolImageView.tintColor = theme.uiSecondaryLabel

        toolLabel.font = .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        toolLabel.textColor = theme.uiSecondaryLabel
        toolLabel.text = toolName

        let summaryDescriptor = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: .subheadline
        )
        summaryLabel.font = UIFont(
            descriptor: toolName.localizedCaseInsensitiveCompare("bash") == .orderedSame
                ? (summaryDescriptor.withDesign(.monospaced) ?? summaryDescriptor)
                : summaryDescriptor,
            size: 0
        )
        summaryLabel.textColor = theme.uiLabel
        summaryLabel.text = summary

        if row.isError {
            outcomeImageView.image = UIImage(systemName: "xmark.circle.fill")
            outcomeImageView.tintColor = theme.uiNegative
            outcomeImageView.isHidden = false
        } else if row.result == nil {
            outcomeImageView.image = UIImage(systemName: "ellipsis")
            outcomeImageView.tintColor = theme.uiSecondaryLabel
            outcomeImageView.isHidden = false
        } else {
            outcomeImageView.image = nil
            outcomeImageView.isHidden = true
        }

        disclosureImageView.image = UIImage(
            systemName: isExpanded ? "chevron.down" : "chevron.right"
        )
        disclosureImageView.tintColor = theme.uiSecondaryLabel
        disclosureImageView.isHidden = !hasDetails
        isEnabled = hasDetails
        accessibilityTraits = hasDetails ? .button : .staticText
        alpha = hasDetails || row.result == nil ? 1 : 0.7

        accessibilityLabel = "\(toolName), \(summary)"
        accessibilityValue = hasDetails
            ? MobileL10n.string(isExpanded ? "Expanded" : "Collapsed")
            : nil
        if row.result == nil {
            accessibilityHint = MobileL10n.string("Tool is running")
        } else if hasDetails {
            accessibilityHint = isExpanded
                ? MobileL10n.string("Hides tool output")
                : MobileL10n.string("Shows tool output")
        } else {
            accessibilityHint = MobileL10n.string("Tool completed without output")
        }

        removeAction(identifiedBy: Self.toggleActionIdentifier, for: .touchUpInside)
        if hasDetails {
            addAction(UIAction(identifier: Self.toggleActionIdentifier) { _ in
                toggle()
            }, for: .touchUpInside)
        }
    }
}

private final class RemoteUserMessageView: UIView {
    private let bubble = UIView()
    private var hasConfigured = false
    private let contextStack = UIStackView()
    private let messageTextView: UITextView

    init(
        text: String,
        context: [RemoteConversationContextAttachmentDTO] = [],
        theme: RemoteThemePalette
    ) {
        // Install the first static value while selection is disabled. Assigning text after a
        // selectable UITextView exists makes UIKit initialize dictation services even though
        // transcript rows are never editable.
        messageTextView = Self.textView(
            text: text,
            font: .preferredFont(forTextStyle: .body),
            color: theme.uiLabel
        )
        super.init(frame: .zero)
        contextStack.axis = .horizontal
        contextStack.alignment = .center
        contextStack.spacing = MobileDesign.Spacing.small

        let content = UIStackView(arrangedSubviews: [contextStack, messageTextView])
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = MobileDesign.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(content)
        addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: MobileDesign.Spacing.pane * 2
            ),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(
                equalTo: bubble.leadingAnchor,
                constant: MobileDesign.Spacing.inset
            ),
            content.trailingAnchor.constraint(
                equalTo: bubble.trailingAnchor,
                constant: -MobileDesign.Spacing.inset
            ),
            content.topAnchor.constraint(
                equalTo: bubble.topAnchor,
                constant: MobileDesign.Spacing.medium
            ),
            content.bottomAnchor.constraint(
                equalTo: bubble.bottomAnchor,
                constant: -MobileDesign.Spacing.medium
            ),
        ])
        configure(text: text, context: context, theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        text: String,
        context: [RemoteConversationContextAttachmentDTO] = [],
        theme: RemoteThemePalette
    ) {
        if hasConfigured {
            // Recycled rows benefit from TextKit's contiguous compatibility path during rapid
            // scrolling. Leave newly created rows on TextKit 2 so large cold mounts stay cheap.
            _ = messageTextView.layoutManager
        }
        hasConfigured = true
        bubble.applyRemoteSurface(
            fill: theme.uiControlResting,
            radius: theme.panelRadius
        )
        configureContext(context, theme: theme)
        messageTextView.font = .preferredFont(forTextStyle: .body)
        messageTextView.textColor = theme.uiLabel
        if messageTextView.text != text {
            messageTextView.text = text
            messageTextView.selectedRange = NSRange(location: 0, length: 0)
        }
    }

    private func configureContext(
        _ context: [RemoteConversationContextAttachmentDTO],
        theme: RemoteThemePalette
    ) {
        contextStack.arrangedSubviews.forEach {
            contextStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let references = context.filter { $0.kind == .reference }.count
        let comments = context.filter { $0.kind == .comment }.count
        if references > 0 {
            contextStack.addArrangedSubview(contextPill(
                symbol: "quote.bubble",
                text: references == 1
                    ? MobileL10n.string("1 reference")
                    : MobileL10n.string("%lld references", Int64(references)),
                theme: theme
            ))
        }
        if comments > 0 {
            contextStack.addArrangedSubview(contextPill(
                symbol: "text.bubble",
                text: comments == 1
                    ? MobileL10n.string("1 comment")
                    : MobileL10n.string("%lld comments", Int64(comments)),
                theme: theme
            ))
        }
        contextStack.isHidden = contextStack.arrangedSubviews.isEmpty
    }

    private func contextPill(
        symbol: String,
        text: String,
        theme: RemoteThemePalette
    ) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = theme.uiSecondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = theme.uiLabel
        label.text = text
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = MobileDesign.Spacing.small
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(
            top: MobileDesign.Spacing.small,
            left: MobileDesign.Spacing.medium,
            bottom: MobileDesign.Spacing.small,
            right: MobileDesign.Spacing.medium
        )
        stack.applyRemoteSurface(fill: theme.uiSurface, radius: theme.controlRadius)
        stack.accessibilityLabel = text
        return stack
    }

    fileprivate static func textView(
        text: String,
        font: UIFont,
        color: UIColor,
        selectionEnabled: Bool = true
    ) -> UITextView {
        let view = UITextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isEditable = false
        // Initial static content belongs before selection activation. Selection remains enabled
        // for the finished transcript surface, but UIKit does not mistake construction for an
        // editable selection change and cold-load input services.
        view.isSelectable = false
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.font = font
        view.textColor = color
        if !text.isEmpty {
            view.text = text
        }
        view.isSelectable = selectionEnabled
        return view
    }
}

private final class RemoteAssistantMessageView: UIStackView {
    private var hasConfigured = false

    init(
        source: String,
        document: RemoteMarkdownDocument?,
        theme: RemoteThemePalette
    ) {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .fill
        spacing = MobileDesign.Spacing.inset
        configure(source: source, document: document, theme: theme)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        source: String,
        document: RemoteMarkdownDocument?,
        theme: RemoteThemePalette
    ) {
        let isReused = hasConfigured
        hasConfigured = true
        guard let document else {
            if arrangedSubviews.count == 1,
               let streaming = arrangedSubviews[0] as? RemoteStreamingMessageView {
                streaming.configure(text: source, theme: theme)
            } else {
                removeArrangedContent()
                addArrangedSubview(RemoteStreamingMessageView(text: source, theme: theme))
            }
            return
        }

        let canReuseProse = document.blocks.count == arrangedSubviews.count
            && document.blocks.allSatisfy {
                if case .prose = $0.kind { return true }
                return false
            }
            && arrangedSubviews.allSatisfy { $0 is UITextView }
        if canReuseProse {
            for (block, view) in zip(document.blocks, arrangedSubviews) {
                guard case .prose(let runs) = block.kind,
                      let textView = view as? UITextView else { continue }
                if isReused {
                    _ = textView.layoutManager
                }
                configure(textView, runs: runs, theme: theme)
            }
            return
        }

        removeArrangedContent()
        for block in document.blocks {
            switch block.kind {
            case .prose(let runs):
                let textView = RemoteUserMessageView.textView(
                    text: "",
                    font: Self.proseFont(),
                    color: theme.uiLabel,
                    selectionEnabled: false
                )
                configure(textView, runs: runs, theme: theme)
                textView.isSelectable = true
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

    private func configure(
        _ textView: UITextView,
        runs: [RemoteMarkdownDocument.Run],
        theme: RemoteThemePalette
    ) {
        textView.textColor = theme.uiLabel
        textView.attributedText = Self.attributed(runs, theme: theme)
        if textView.isSelectable {
            textView.selectedRange = NSRange(location: 0, length: 0)
        }
        textView.accessibilityLabel = runs.map(\.text).joined()
    }

    private func removeArrangedContent() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private static func proseFont() -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .callout)
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
        languageLabel.text = language.isEmpty ? MobileL10n.string("code") : language

        let copy = RemoteExpandedHitButton(type: .system)
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        copy.tintColor = theme.uiSecondaryLabel
        copy.accessibilityLabel = MobileL10n.string("Copy code")
        MobileButtonHaptics.install(on: copy)
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
            header.heightAnchor.constraint(equalToConstant: 36),
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
            copy.widthAnchor.constraint(equalToConstant: 32),
            copy.heightAnchor.constraint(equalToConstant: 32),
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

/// Keeps visually compact inline actions reachable without making their containing chrome tall.
private final class RemoteExpandedHitButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let minimum = MobileDesign.Size.minimumTapTarget
        let horizontal = max(0, (minimum - bounds.width) / 2)
        let vertical = max(0, (minimum - bounds.height) / 2)
        return bounds.insetBy(dx: -horizontal, dy: -vertical).contains(point)
    }
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
        var configuration = UIButton.Configuration.plain()
        configuration.title = MobileL10n.string(title)
        configuration.image = UIImage(
            systemName: isExpanded ? "chevron.down" : "chevron.right"
        )
        configuration.imagePadding = MobileDesign.Spacing.small
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.tintColor = theme.uiSecondaryLabel
        button.setTitleColor(theme.uiSecondaryLabel, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityValue = MobileL10n.string(isExpanded ? "Expanded" : "Collapsed")
        MobileButtonHaptics.install(on: button)
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

final class RemoteToolMessageView: UIView {
    private let stack = UIStackView()
    private let disclosure = RemoteToolDisclosureControl()
    private var resultTextView: UITextView?

    init(
        row: RemoteConversationRowDTO,
        isExpanded: Bool,
        theme: RemoteThemePalette,
        toggle: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        stack.addArrangedSubview(disclosure)
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
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        configure(row: row, isExpanded: isExpanded, theme: theme, toggle: toggle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        row: RemoteConversationRowDTO,
        isExpanded: Bool,
        theme: RemoteThemePalette,
        toggle: @escaping () -> Void
    ) {
        applyRemoteSurface(
            fill: theme.uiPanel,
            radius: theme.panelRadius,
            border: theme.uiBorder,
            borderWidth: theme.borderWidth,
            glow: theme.glow
        )
        disclosure.configure(
            row: row,
            isExpanded: isExpanded,
            theme: theme,
            toggle: toggle
        )

        if isExpanded, let result = row.result, !result.isEmpty {
            let textView: UITextView
            if let resultTextView {
                textView = resultTextView
            } else {
                textView = RemoteUserMessageView.textView(
                    text: result,
                    font: Self.codeFont(),
                    color: theme.uiSecondaryLabel
                )
                textView.textContainerInset = UIEdgeInsets(
                    top: MobileDesign.Spacing.tight,
                    left: 0,
                    bottom: MobileDesign.Spacing.small,
                    right: 0
                )
                resultTextView = textView
            }
            textView.font = Self.codeFont()
            textView.textColor = row.isError ? theme.uiNegative : theme.uiSecondaryLabel
            if textView.text != result {
                textView.text = result
                textView.selectedRange = NSRange(location: 0, length: 0)
            }
            if textView.superview == nil {
                stack.addArrangedSubview(textView)
            }
        } else if let resultTextView, resultTextView.superview != nil {
            stack.removeArrangedSubview(resultTextView)
            resultTextView.removeFromSuperview()
        }
    }

    private static func codeFont() -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .caption1)
            .withDesign(.monospaced)
        return UIFont(
            descriptor: descriptor ?? .preferredFontDescriptor(withTextStyle: .caption1),
            size: 0
        )
    }

    static func symbol(for toolName: String?) -> String {
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
        label.text = row.text ?? MobileL10n.string("Notice")
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

/// Streaming content stays a lightweight multiline label. The reusable collection cell supplies
/// its actual width when asking Auto Layout for a preferred height, so token growth wraps without
/// teaching this leaf view anything about collection geometry.
private final class RemoteStreamingMessageView: UILabel {

    init(text: String, theme: RemoteThemePalette) {
        super.init(frame: .zero)
        numberOfLines = 0
        adjustsFontForContentSizeCategory = true
        accessibilityLabel = MobileL10n.string("Agent is responding")
        configure(text: text, theme: theme)
        startBreathingIfAppropriate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, theme: RemoteThemePalette) {
        font = RemoteAssistantMessageView.proseFontForStreaming
        textColor = theme.uiSecondaryLabel
        if self.text != text {
            self.text = text
            invalidateIntrinsicContentSize()
        }
    }

    private func startBreathingIfAppropriate() {
        guard !UIAccessibility.isReduceMotionEnabled,
              ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"] == nil
        else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.58
        animation.toValue = 1
        animation.duration = 0.82
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "remoteStreamingBreathing")
    }
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
            border: theme.uiBorder,
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
        title.text = MobileL10n.string("Permission needed")
        title.accessibilityTraits.insert(.header)
        stack.addArrangedSubview(title)
        let explanation = UILabel()
        explanation.numberOfLines = 0
        explanation.font = .preferredFont(forTextStyle: .subheadline)
        explanation.adjustsFontForContentSizeCategory = true
        explanation.textColor = theme.uiSecondaryLabel
        explanation.text = MobileL10n.string("Allow %@?", permission.toolName)
        stack.addArrangedSubview(explanation)

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
                title: MobileL10n.string("Deny"),
                fill: theme.uiControlResting,
                foreground: theme.uiNegative,
                radius: theme.controlRadius,
                action: { decide(false) }
            ))
            buttons.addArrangedSubview(Self.actionButton(
                title: MobileL10n.string("Allow"),
                fill: theme.uiAccent,
                foreground: theme.uiAccentForeground,
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
            notice.text = MobileL10n.string("Review this request on the Mac.")
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
        MobileButtonHaptics.install(on: button)
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
        case .addition:
            color = theme.uiDiffAdded
            marker = "+"
        case .removal:
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
        configuration.title = MobileL10n.string(
            isLoading ? "Loading earlier messages…" : "Load earlier messages"
        )
        configuration.image = UIImage(systemName: isLoading ? "clock.arrow.circlepath" : "arrow.up")
        configuration.imagePadding = MobileDesign.Spacing.small
        configuration.baseForegroundColor = theme.uiSecondaryLabel
        let button = UIButton(configuration: configuration)
        MobileButtonHaptics.install(on: button)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = !isLoading
        button.accessibilityHint = MobileL10n.string(
            "Loads the previous part of this conversation"
        )
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

extension UIView {
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
        // Reconfiguration and live theme switching both reuse the same row. The helper owns one
        // outline, so replace its previous instance instead of stacking another border and glow
        // over it on every result, expansion or palette update.
        subviews.compactMap { $0 as? RemoteSurfaceBorderView }.forEach {
            $0.removeFromSuperview()
        }
        if let border, borderWidth > 0 {
            let outline = RemoteSurfaceBorderView()
            outline.update(
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

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let traits = [UIFontDescriptor.TraitKey.weight: weight]
        return UIFont(descriptor: fontDescriptor.addingAttributes([
            .traits: traits,
        ]), size: pointSize)
    }
}

/// A distinct identity lets surface reconfiguration remove only the outline it owns.
/// All drawing and theme updates belong to the shared outline implementation.
private final class RemoteSurfaceBorderView: MobileThemeOutlineView {}
