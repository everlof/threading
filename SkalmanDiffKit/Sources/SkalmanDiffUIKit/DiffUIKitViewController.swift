#if canImport(UIKit)
import SkalmanDiffCore
import UIKit

/// A virtualized, read-only diff surface. Every visible line is a reusable collection-view
/// cell; a 10,000-line document therefore does not create a 10,000-view hierarchy.
public final class DiffUIKitViewController: UIViewController {
    private enum Item {
        case fileHeader
        case hunk(Int)
        case line(hunk: Int, line: Int)
        case note(String)
    }

    public var onExpansionChange: ((Set<String>) -> Void)?
    public var onRefresh: (() -> Void)?

    private var document: DiffDocument
    private var expandedPaths: Set<String>
    private var theme: DiffUIKitTheme
    private var items: [[Item]] = []
    private var tokenCache: [String: [[[DiffSyntaxToken]]]] = [:]
    private var lastLayoutWidth: CGFloat = 0

    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let summaryView = DiffSummaryPillView()
    private let jumpButton = UIButton(type: .system)
    private let refreshControl = UIRefreshControl()

    public init(
        document: DiffDocument,
        expandedPaths: Set<String>,
        theme: DiffUIKitTheme
    ) {
        self.document = document
        self.expandedPaths = expandedPaths
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
        rebuildItems()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.ground

        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 0, left: 16, bottom: 12, right: 16)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = theme.ground
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.contentInset = UIEdgeInsets(top: 14, left: 0, bottom: 62, right: 0)
        collectionView.verticalScrollIndicatorInsets.bottom = 54
        collectionView.register(
            DiffFileHeaderCell.self,
            forCellWithReuseIdentifier: DiffFileHeaderCell.reuseIdentifier
        )
        collectionView.register(
            DiffHunkHeaderCell.self,
            forCellWithReuseIdentifier: DiffHunkHeaderCell.reuseIdentifier
        )
        collectionView.register(
            DiffLineCell.self,
            forCellWithReuseIdentifier: DiffLineCell.reuseIdentifier
        )
        collectionView.register(
            DiffNoteCell.self,
            forCellWithReuseIdentifier: DiffNoteCell.reuseIdentifier
        )
        refreshControl.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
        collectionView.refreshControl = refreshControl
        view.addSubview(collectionView)

        summaryView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryView)

        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.setImage(UIImage(systemName: "arrow.down"), for: .normal)
        jumpButton.accessibilityLabel = "Scroll to the end of the diff"
        jumpButton.addTarget(self, action: #selector(scrollToEnd), for: .touchUpInside)
        jumpButton.layer.shadowOpacity = 0.28
        jumpButton.layer.shadowRadius = 10
        jumpButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.addSubview(jumpButton)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            summaryView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            summaryView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            summaryView.heightAnchor.constraint(equalToConstant: 36),

            jumpButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: summaryView.topAnchor, constant: -8),
            jumpButton.widthAnchor.constraint(equalToConstant: 40),
            jumpButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        applyTheme()
        updateScrollControls()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collectionView.bounds.width
        guard abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        layout.invalidateLayout()
        updateScrollControls()
        DispatchQueue.main.async { [weak self] in
            self?.updateScrollControls()
        }
    }

    public func update(
        document: DiffDocument,
        expandedPaths: Set<String>,
        theme: DiffUIKitTheme,
        isRefreshing: Bool
    ) {
        let documentChanged = document != self.document
        let expansionChanged = expandedPaths != self.expandedPaths
        self.document = document
        self.expandedPaths = expandedPaths
        self.theme = theme
        if documentChanged {
            tokenCache.removeAll(keepingCapacity: true)
        }
        if documentChanged || expansionChanged {
            rebuildItems()
        }
        if !isRefreshing {
            refreshControl.endRefreshing()
        }
        applyTheme()
        if documentChanged || expansionChanged {
            collectionView.reloadData()
        } else {
            collectionView.reloadItems(at: collectionView.indexPathsForVisibleItems)
        }
        updateScrollControls()
        DispatchQueue.main.async { [weak self] in
            self?.updateScrollControls()
        }
    }

    private func rebuildItems() {
        items = document.files.map { file in
            guard expandedPaths.contains(file.path) else { return [.fileHeader] }
            guard !file.hunks.isEmpty else {
                return [
                    .fileHeader,
                    .note(file.change == .binary
                        ? "Binary file — no textual preview."
                        : "No changed lines to display."),
                ]
            }

            var result: [Item] = [.fileHeader]
            for hunkIndex in file.hunks.indices {
                result.append(.hunk(hunkIndex))
                result.append(contentsOf: file.hunks[hunkIndex].lines.indices.map {
                    .line(hunk: hunkIndex, line: $0)
                })
            }
            if file.isTruncated {
                result.append(.note("Preview shortened on this device."))
            }
            return result
        }
    }

    private func tokens(file: DiffFile, hunkIndex: Int, lineIndex: Int) -> [DiffSyntaxToken] {
        if tokenCache[file.path] == nil {
            tokenCache[file.path] = file.hunks.map {
                DiffSyntax.tokens(for: $0.lines, path: file.path)
            }
        }
        return tokenCache[file.path]?[safe: hunkIndex]?[safe: lineIndex] ?? []
    }

    private func applyTheme() {
        guard isViewLoaded else { return }
        view.backgroundColor = theme.ground
        collectionView.backgroundColor = theme.ground
        summaryView.configure(summary: document.summary, theme: theme)

        jumpButton.tintColor = theme.label
        jumpButton.backgroundColor = theme.surface
        jumpButton.layer.cornerRadius = 20
        jumpButton.layer.borderWidth = theme.borderWidth
        jumpButton.layer.borderColor = theme.border.cgColor
        jumpButton.layer.shadowColor = theme.ground.cgColor
    }

    @objc private func refreshRequested() {
        onRefresh?()
    }

    @objc private func scrollToEnd() {
        let bottom = max(
            -collectionView.adjustedContentInset.top,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: bottom),
            animated: true
        )
    }

    private func updateScrollControls() {
        guard isViewLoaded else { return }
        let visibleBottom = collectionView.contentOffset.y
            + collectionView.bounds.height
            - collectionView.adjustedContentInset.bottom
        let isAtBottom = collectionView.contentSize.height <= visibleBottom + 4
        UIView.animate(
            withDuration: 0.16,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.jumpButton.alpha = isAtBottom ? 0 : 1
            self.jumpButton.transform = isAtBottom
                ? CGAffineTransform(scaleX: 0.84, y: 0.84)
                : .identity
        }
        jumpButton.isUserInteractionEnabled = !isAtBottom
    }

    private func styleCard(_ cell: UICollectionViewCell, item: Int, itemCount: Int) {
        // Adjacent cells each contribute half a rule. A full border on both cells makes hunk
        // boundaries twice as heavy as the card outline, especially on 3× phone displays.
        cell.layer.borderWidth = theme.borderWidth == 0
            ? 0
            : max(0.5, theme.borderWidth / 2)
        cell.layer.borderColor = theme.border.cgColor
        cell.layer.cornerRadius = theme.cardRadius
        cell.layer.masksToBounds = true
        switch (item, item == itemCount - 1) {
        case (0, true):
            cell.layer.maskedCorners = [
                .layerMinXMinYCorner, .layerMaxXMinYCorner,
                .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
            ]
        case (0, false):
            cell.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case (_, true):
            cell.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        default:
            cell.layer.cornerRadius = 0
            cell.layer.maskedCorners = []
        }
    }
}

extension DiffUIKitViewController: UICollectionViewDataSource {
    public func numberOfSections(in collectionView: UICollectionView) -> Int {
        document.files.count
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        items[safe: section]?.count ?? 0
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let file = document.files[indexPath.section]
        let item = items[indexPath.section][indexPath.item]
        let cell: UICollectionViewCell

        switch item {
        case .fileHeader:
            let header = collectionView.dequeueReusableCell(
                withReuseIdentifier: DiffFileHeaderCell.reuseIdentifier,
                for: indexPath
            ) as! DiffFileHeaderCell
            header.configure(
                file: file,
                expanded: expandedPaths.contains(file.path),
                theme: theme
            )
            cell = header

        case .hunk(let hunkIndex):
            let header = collectionView.dequeueReusableCell(
                withReuseIdentifier: DiffHunkHeaderCell.reuseIdentifier,
                for: indexPath
            ) as! DiffHunkHeaderCell
            header.configure(hunk: file.hunks[hunkIndex], theme: theme)
            cell = header

        case .line(let hunkIndex, let lineIndex):
            let lineCell = collectionView.dequeueReusableCell(
                withReuseIdentifier: DiffLineCell.reuseIdentifier,
                for: indexPath
            ) as! DiffLineCell
            lineCell.configure(
                line: file.hunks[hunkIndex].lines[lineIndex],
                tokens: tokens(file: file, hunkIndex: hunkIndex, lineIndex: lineIndex),
                theme: theme
            )
            cell = lineCell

        case .note(let text):
            let note = collectionView.dequeueReusableCell(
                withReuseIdentifier: DiffNoteCell.reuseIdentifier,
                for: indexPath
            ) as! DiffNoteCell
            note.configure(text: text, theme: theme)
            cell = note
        }

        styleCard(cell, item: indexPath.item, itemCount: items[indexPath.section].count)
        return cell
    }
}

extension DiffUIKitViewController: UICollectionViewDelegateFlowLayout {
    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = max(1, collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right)
        let file = document.files[indexPath.section]
        switch items[indexPath.section][indexPath.item] {
        case .fileHeader:
            return CGSize(width: width, height: file.directory.isEmpty ? 50 : 58)
        case .hunk:
            return CGSize(width: width, height: 34)
        case .line(let hunkIndex, let lineIndex):
            return CGSize(
                width: width,
                height: DiffLineCell.height(
                    for: file.hunks[hunkIndex].lines[lineIndex].text,
                    width: width
                )
            )
        case .note:
            return CGSize(width: width, height: 44)
        }
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item == 0 else { return }
        let path = document.files[indexPath.section].path
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
        }
        rebuildItems()
        collectionView.reloadSections(IndexSet(integer: indexPath.section))
        onExpansionChange?(expandedPaths)
        DispatchQueue.main.async { [weak self] in self?.updateScrollControls() }
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollControls()
    }
}

private final class DiffSummaryPillView: UIView {
    private let filesLabel = UILabel()
    private let addedLabel = UILabel()
    private let removedLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 9
        [filesLabel, addedLabel, removedLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            stack.addArrangedSubview($0)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(summary: DiffSummary, theme: DiffUIKitTheme) {
        filesLabel.text = "\(summary.files) \(summary.files == 1 ? "file" : "files")"
        filesLabel.textColor = theme.secondaryLabel
        addedLabel.text = "+\( Self.compact(summary.added))"
        addedLabel.textColor = theme.added
        removedLabel.text = "−\(Self.compact(summary.removed))"
        removedLabel.textColor = theme.removed
        backgroundColor = theme.surface
        layer.cornerRadius = 18
        layer.borderWidth = theme.borderWidth
        layer.borderColor = theme.border.cgColor
        layer.shadowColor = theme.ground.cgColor
        layer.shadowOpacity = 0.32
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 5)
        accessibilityLabel = "\(summary.files) changed files, \(summary.added) additions, \(summary.removed) deletions"
    }

    private static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
