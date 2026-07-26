#if canImport(UIKit)
import SkalmanDiffCore
import UIKit

final class DiffFileHeaderCell: UICollectionViewCell {
    static let reuseIdentifier = "DiffFileHeaderCell"

    private let glyphLabel = UILabel()
    private let nameLabel = UILabel()
    private let directoryLabel = UILabel()
    private let countsLabel = UILabel()
    private let chevronView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        [glyphLabel, nameLabel, directoryLabel, countsLabel, chevronView].forEach {
            contentView.addSubview($0)
        }
        nameLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        chevronView.contentMode = .scaleAspectFit
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(file: DiffFile, expanded: Bool, theme: DiffUIKitTheme) {
        glyphLabel.text = DiffPresentation.changeGlyph(for: file.change)
        glyphLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        glyphLabel.textColor = theme.secondaryLabel

        nameLabel.text = file.fileName
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = theme.label

        directoryLabel.text = file.directory
        directoryLabel.font = .systemFont(ofSize: 11, weight: .regular)
        directoryLabel.textColor = theme.tertiaryLabel
        directoryLabel.isHidden = file.directory.isEmpty

        let counts = NSMutableAttributedString()
        counts.append(NSAttributedString(string: "+\(file.added)", attributes: [
            .foregroundColor: theme.added,
        ]))
        counts.append(NSAttributedString(string: " −\(file.removed)", attributes: [
            .foregroundColor: theme.removed,
        ]))
        countsLabel.attributedText = counts
        countsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        chevronView.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right")
        chevronView.tintColor = theme.tertiaryLabel
        contentView.backgroundColor = theme.panel

        accessibilityLabel = "\(file.path), \(file.added) additions, \(file.removed) deletions"
        accessibilityValue = expanded ? "Expanded" : "Collapsed"
        accessibilityTraits = .button
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        glyphLabel.frame = CGRect(x: 12, y: 0, width: 18, height: bounds.height)
        chevronView.frame = CGRect(x: bounds.width - 26, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let countsWidth = min(96, countsLabel.sizeThatFits(bounds.size).width)
        countsLabel.frame = CGRect(
            x: chevronView.frame.minX - countsWidth - 8,
            y: 0,
            width: countsWidth,
            height: bounds.height
        )
        let textX: CGFloat = 40
        let textWidth = max(0, countsLabel.frame.minX - textX - 10)
        if directoryLabel.isHidden {
            nameLabel.frame = CGRect(x: textX, y: 0, width: textWidth, height: bounds.height)
        } else {
            nameLabel.frame = CGRect(x: textX, y: 9, width: textWidth, height: 22)
            directoryLabel.frame = CGRect(x: textX, y: 31, width: textWidth, height: 17)
        }
    }
}

final class DiffHunkHeaderCell: UICollectionViewCell {
    static let reuseIdentifier = "DiffHunkHeaderCell"
    private let titleLabel = UILabel()
    private let countsLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(titleLabel)
        contentView.addSubview(countsLabel)
        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        countsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(hunk: DiffHunk, theme: DiffUIKitTheme) {
        titleLabel.text = DiffPresentation.rangeTitle(for: hunk)
        titleLabel.textColor = theme.secondaryLabel
        let summary = hunk.summary
        countsLabel.text = "+\(summary.added) −\(summary.removed)"
        countsLabel.textColor = theme.secondaryLabel
        countsLabel.textAlignment = .right
        contentView.backgroundColor = theme.surface
        isAccessibilityElement = true
        accessibilityLabel = "\(titleLabel.text ?? ""), \(summary.added) additions, \(summary.removed) deletions"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = CGRect(x: 12, y: 0, width: contentView.bounds.width - 112, height: contentView.bounds.height)
        countsLabel.frame = CGRect(
            x: contentView.bounds.width - 104,
            y: 0,
            width: 92,
            height: contentView.bounds.height
        )
    }
}

final class DiffLineCell: UICollectionViewCell {
    static let reuseIdentifier = "DiffLineCell"
    static let font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let numberWidth: CGFloat = 34
    static let markerWidth: CGFloat = 16

    private let numberLabel = UILabel()
    private let markerLabel = UILabel()
    private let codeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        [numberLabel, markerLabel, codeLabel].forEach { contentView.addSubview($0) }
        numberLabel.font = Self.font
        numberLabel.textAlignment = .right
        markerLabel.font = Self.font
        markerLabel.textAlignment = .center
        codeLabel.font = Self.font
        codeLabel.numberOfLines = 0
        codeLabel.lineBreakMode = .byCharWrapping
        codeLabel.isUserInteractionEnabled = true
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        line: DiffLine,
        tokens: [DiffSyntaxToken],
        theme: DiffUIKitTheme
    ) {
        numberLabel.text = line.displayNumber.map(String.init) ?? ""
        numberLabel.textColor = theme.tertiaryLabel

        switch line.kind {
        case .added:
            markerLabel.text = "+"
            markerLabel.textColor = theme.added
            contentView.backgroundColor = theme.addedBackground
        case .removed:
            markerLabel.text = "−"
            markerLabel.textColor = theme.removed
            contentView.backgroundColor = theme.removedBackground
        case .context:
            markerLabel.text = ""
            markerLabel.textColor = theme.secondaryLabel
            contentView.backgroundColor = theme.ground
        }

        let text = line.text.isEmpty ? " " : line.text
        let base = tokens.isEmpty && line.kind != .context
            ? (line.kind == .added ? theme.added : theme.removed)
            : (line.kind == .context ? theme.secondaryLabel : theme.label)
        let value = NSMutableAttributedString(string: text, attributes: [
            .font: Self.font,
            .foregroundColor: base,
        ])
        for token in tokens {
            value.addAttribute(
                .foregroundColor,
                value: syntaxColor(token.role, theme: theme),
                range: NSRange(token.range, in: line.text)
            )
        }
        codeLabel.attributedText = value
        accessibilityLabel = "\(numberLabel.text ?? "") \(markerLabel.text ?? "") \(line.text)"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        numberLabel.frame = CGRect(x: 0, y: 2, width: Self.numberWidth, height: 17)
        markerLabel.frame = CGRect(x: Self.numberWidth, y: 2, width: Self.markerWidth, height: 17)
        codeLabel.frame = CGRect(
            x: Self.numberWidth + Self.markerWidth + 4,
            y: 2,
            width: max(0, contentView.bounds.width - Self.numberWidth - Self.markerWidth - 10),
            height: max(17, contentView.bounds.height - 4)
        )
    }

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let codeWidth = max(1, width - numberWidth - markerWidth - 10)
        let value = text.isEmpty ? " " : text
        let bounds = (value as NSString).boundingRect(
            with: CGSize(width: codeWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return max(21, ceil(bounds.height) + 4)
    }

    private func syntaxColor(_ role: DiffSyntaxRole, theme: DiffUIKitTheme) -> UIColor {
        switch role {
        case .keyword: return theme.syntaxKeyword
        case .type: return theme.syntaxType
        case .string: return theme.syntaxString
        case .number: return theme.syntaxNumber
        case .comment: return theme.syntaxComment
        }
    }
}

final class DiffNoteCell: UICollectionViewCell {
    static let reuseIdentifier = "DiffNoteCell"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(label)
        label.font = .systemFont(ofSize: 12)
        label.numberOfLines = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, theme: DiffUIKitTheme) {
        label.text = text
        label.textColor = theme.tertiaryLabel
        contentView.backgroundColor = theme.ground
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.insetBy(dx: 12, dy: 8)
    }
}
#endif
