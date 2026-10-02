import AppKit

// Only host theme facts are supplied here; SearchMatchLabel.swift is unchanged production code.
@MainActor protocol ThemedComponent: AnyObject {}

@MainActor enum Design {
    enum Typography { enum FontSurface { case chrome } }
    enum FontRole {
        case body
        case emphasizedBody

        var emphasized: FontRole { .emphasizedBody }
        func resolved(in surface: Typography.FontSurface) -> NSFont {
            NSFont.systemFont(ofSize: 13,
                              weight: self == .emphasizedBody ? .semibold : .regular)
        }
    }
    enum Text { static let label = NSColor.black }
    enum Surface { static let searchMatch = NSColor(red: 1, green: 0.85, blue: 0.16, alpha: 1) }
}

struct AppThemeDidChange {}
@MainActor final class AppEventObservations {
    func observe<Event>(_ event: Event.Type, _ handler: @escaping (Event) -> Void) {}
}

// These are the two production Design.swift helpers that surround SearchMatchLabel's AppKit
// field. The fixture keeps that boundary exact while supplying only its theme environment.
extension NSTextField {
    static func label(attributed text: NSAttributedString) -> NSTextField {
        let label = NSTextField(labelWithString: text.string)
        label.font = text.tallestFont ?? label.font
        label.attributedStringValue = text
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

extension NSAttributedString {
    var tallestFont: NSFont? {
        var tallest: NSFont?
        enumerateAttribute(.font, in: NSRange(location: 0, length: length)) { value, _, _ in
            guard let font = value as? NSFont else { return }
            guard let current = tallest else { return tallest = font }
            if font.ascender - font.descender > current.ascender - current.descender {
                tallest = font
            }
        }
        return tallest
    }
}
