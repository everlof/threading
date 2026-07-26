#if canImport(UIKit)
import UIKit

public struct DiffUIKitTheme {
    public let ground: UIColor
    public let surface: UIColor
    public let panel: UIColor
    public let border: UIColor
    public let label: UIColor
    public let secondaryLabel: UIColor
    public let tertiaryLabel: UIColor
    public let added: UIColor
    public let removed: UIColor
    public let addedBackground: UIColor
    public let removedBackground: UIColor
    public let syntaxKeyword: UIColor
    public let syntaxType: UIColor
    public let syntaxString: UIColor
    public let syntaxNumber: UIColor
    public let syntaxComment: UIColor
    public let cardRadius: CGFloat
    public let borderWidth: CGFloat

    public init(
        ground: UIColor,
        surface: UIColor,
        panel: UIColor,
        border: UIColor,
        label: UIColor,
        secondaryLabel: UIColor,
        tertiaryLabel: UIColor,
        added: UIColor,
        removed: UIColor,
        addedBackground: UIColor,
        removedBackground: UIColor,
        syntaxKeyword: UIColor,
        syntaxType: UIColor,
        syntaxString: UIColor,
        syntaxNumber: UIColor,
        syntaxComment: UIColor,
        cardRadius: CGFloat = 10,
        borderWidth: CGFloat = 1
    ) {
        self.ground = ground
        self.surface = surface
        self.panel = panel
        self.border = border
        self.label = label
        self.secondaryLabel = secondaryLabel
        self.tertiaryLabel = tertiaryLabel
        self.added = added
        self.removed = removed
        self.addedBackground = addedBackground
        self.removedBackground = removedBackground
        self.syntaxKeyword = syntaxKeyword
        self.syntaxType = syntaxType
        self.syntaxString = syntaxString
        self.syntaxNumber = syntaxNumber
        self.syntaxComment = syntaxComment
        self.cardRadius = cardRadius
        self.borderWidth = borderWidth
    }
}
#endif
