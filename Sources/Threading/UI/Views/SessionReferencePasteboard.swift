import AppKit

// MARK: - Session Reference Pasteboard

/// The one pasteboard type a dragged sidebar session travels as.
///
/// The drag carries only the session's id, on a type of Threading's own. Not a `.string` beside
/// it: a plain-text flavour would make every text field in the app a destination — the rename
/// field, the commit message, the search box — and each would take a paragraph of tool names
/// meant for an agent, not for a person. With one private type, only the surfaces that
/// registered for it accept the drop and everything else refuses it visibly, which is the
/// honest answer for a reference that means nothing outside a session's input.
///
/// The facts are resolved at the drop (`SessionReference.live`), so what lands is true then;
/// see `SessionReferenceReader` for why the same row says different things on different
/// sessions.
enum SessionReferencePasteboard {

    static let type = NSPasteboard.PasteboardType(SessionReferencePasteboardDefaults.typeIdentifier)

    /// The item a sidebar row writes when it is dragged.
    static func item(for sessionID: SessionID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(sessionID.uuidString.lowercased(), forType: type)
        return item
    }

    /// The sessions a pasteboard names, in the order they were dragged.
    static func sessionIDs(from pasteboard: NSPasteboard) -> [SessionID] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.string(forType: type).flatMap(SessionID.init(uuidString:))
        }
    }

    /// Whether `sessionIDs` would find anything — answered per movement of the gesture, so it
    /// reads the type list rather than the items.
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [type]) != nil
    }
}

enum SessionReferencePasteboardDefaults {
    /// Reverse-DNS under the app's own bundle identifier, so no other app's type collides.
    static let typeIdentifier = "codes.threading.session-reference"
}
