import Foundation

/// The delegate of an editable `NSTextField`. Linux has no selector dispatch yet, so AppKit's
/// `control(_:textView:doCommandBy:)` is not part of this contract.
@MainActor
public protocol NSTextFieldDelegate: AnyObject {
    func controlTextDidBeginEditing(_ obj: Notification)
    func controlTextDidChange(_ obj: Notification)
    func controlTextDidEndEditing(_ obj: Notification)
}

public extension NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {}
    func controlTextDidChange(_ obj: Notification) {}
    func controlTextDidEndEditing(_ obj: Notification) {}
}

extension NSControl {
    public static let textDidBeginEditingNotification = Notification.Name("NSControlTextDidBeginEditingNotification")
    public static let textDidChangeNotification = Notification.Name("NSControlTextDidChangeNotification")
    public static let textDidEndEditingNotification = Notification.Name("NSControlTextDidEndEditingNotification")
}

/// How editing ended, as AppKit reports it under the `NSTextMovement` user-info key.
public enum NSTextMovement: Int, Sendable {
    case other = 0
    case `return` = 0x10
    case tab = 0x11
    case backtab = 0x12
}

/// The single-line `NSTextView` that edits one field for one editing session. It sits inside
/// the field over its cell's drawing rect and leaves when editing ends, as AppKit's field
/// editor does; the field draws its own text only while no editor covers it.
@MainActor
final class NSTextFieldEditor: NSTextView {
    weak var field: NSTextField?
    /// AppKit reports the beginning of editing at the first change, not at focus.
    var hasEdited = false
    /// How the session is ending, recorded before focus moves so the end notice can say.
    var endingMovement = NSTextMovement.other

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText(), let field else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 36, 76: field.editorDidReturn()
        case 48: field.editorDidTab(backward: event.modifierFlags.contains(.shift))
        default: super.keyDown(with: event)
        }
    }

    /// One line: a typed or pasted line break becomes a space, as it does in AppKit's field.
    override func insertText(_ value: Any, replacementRange: NSRange) {
        let text = (value as? String) ?? (value as? NSAttributedString)?.string ?? ""
        let line = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        super.insertText(line, replacementRange: replacementRange)
    }

    override func didChangeText() { field?.editorTextDidChange() }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        field?.endEditingSession()
        return true
    }
}

extension NSTextField {
    /// The field editor while this field is editing.
    public func currentEditor() -> NSText? { fieldEditor }

    /// Asked by the window when focus lands on this field; answers the editor to focus instead.
    func beginEditingSession() -> NSTextView? {
        guard isEnabled, isEditable, window != nil else { return nil }
        if let fieldEditor { return fieldEditor }
        let editor = NSTextFieldEditor(frame: editingRect)
        editor.field = self
        editor.font = font
        editor.textColor = textColor
        editor.insertionPointColor = textColor ?? .labelColor
        editor.drawsBackground = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.size = NSSize(width: 1_000_000, height: editingRect.height)
        editor.string = stringValue
        editor.setSelectedRange(NSRange(location: 0, length: (stringValue as NSString).length))
        fieldEditor = editor
        addSubview(editor)
        needsDisplay = true
        return editor
    }

    func editorTextDidChange() {
        guard let fieldEditor else { return }
        if !fieldEditor.hasEdited {
            fieldEditor.hasEdited = true
            delegate?.controlTextDidBeginEditing(notice(NSControl.textDidBeginEditingNotification))
        }
        stringValue = fieldEditor.string
        let change = notice(NSControl.textDidChangeNotification)
        textDidChange(change)
        delegate?.controlTextDidChange(change)
    }

    /// AppKit ends the edit, sends the action, and keeps the editor with its text selected.
    func editorDidReturn() {
        guard let fieldEditor else { return }
        if fieldEditor.hasEdited {
            fieldEditor.hasEdited = false
            delegate?.controlTextDidEndEditing(notice(NSControl.textDidEndEditingNotification,
                                                      movement: .return))
        }
        action?()
        fieldEditor.selectAll(nil)
    }

    func editorDidTab(backward: Bool) {
        guard let fieldEditor, let window else { return }
        fieldEditor.endingMovement = backward ? .backtab : .tab
        let next = backward ? previousValidKeyView : nextValidKeyView
        _ = window.makeFirstResponder(next)
    }

    /// Commits and removes the editor; the field draws its text again.
    func endEditingSession() {
        guard let fieldEditor else { return }
        stringValue = fieldEditor.string
        let ended = fieldEditor.hasEdited
            ? notice(NSControl.textDidEndEditingNotification, movement: fieldEditor.endingMovement) : nil
        self.fieldEditor = nil
        fieldEditor.removeFromSuperview()
        needsDisplay = true
        if let ended {
            textDidEndEditing(ended)
            delegate?.controlTextDidEndEditing(ended)
        }
    }

    /// Ends editing without a notice, keeping the editor's text, as AppKit's `abortEditing`.
    @discardableResult
    public func abortEditing() -> Bool {
        guard let fieldEditor else { return false }
        self.fieldEditor = nil
        stringValue = fieldEditor.string
        fieldEditor.removeFromSuperview()
        if window?.firstResponder === fieldEditor { _ = window?.makeFirstResponder(nil) }
        needsDisplay = true
        return true
    }

    var editingRect: NSRect { cell?.drawingRect(forBounds: bounds) ?? bounds }


    /// One line of the field's font. An editable field has no intrinsic width in AppKit; its
    /// width is the layout's to give, and a themed field states its own taller well.
    var editableIntrinsicSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: ceil((font ?? .systemFont(ofSize: 13)).boundingRectForFont.height))
    }

    func layoutFieldEditor() {
        fieldEditor?.frame = editingRect
    }

    /// The field's own text while no editor covers it, and its placeholder whenever it is empty,
    /// as AppKit keeps it under an empty field editor until the first keystroke.
    func drawEditableContent() {
        let rect = editingRect
        let font = self.font ?? .systemFont(ofSize: 13)
        let text = fieldEditor?.string ?? stringValue
        if text.isEmpty, fieldEditor?.hasMarkedText() != true,
           let placeholder = placeholderAttributedString?.string ?? placeholderString,
           !placeholder.isEmpty {
            var attributes = placeholderAttributedString?.attributes(at: 0, effectiveRange: nil) ?? [:]
            if attributes[.font] == nil { attributes[.font] = font }
            if attributes[.foregroundColor] == nil {
                attributes[.foregroundColor] = NSColor.placeholderTextColor
            }
            placeholder.draw(in: rect, withAttributes: attributes)
        } else if fieldEditor == nil, !stringValue.isEmpty {
            stringValue.draw(in: rect, withAttributes: [.font: font,
                                                        .foregroundColor: textColor ?? .labelColor])
        }
    }

    private func notice(_ name: Notification.Name, movement: NSTextMovement? = nil) -> Notification {
        var info: [AnyHashable: Any] = [:]
        if let fieldEditor { info["NSFieldEditor"] = fieldEditor }
        if let movement { info["NSTextMovement"] = movement.rawValue }
        return Notification(name: name, object: self, userInfo: info)
    }
}
