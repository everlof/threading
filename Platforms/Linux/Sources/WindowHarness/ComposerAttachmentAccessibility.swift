#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge

/// Mirrors only mounted image tiles into the native AT-SPI tree. Identity and removal remain
/// host-owned; the Design strip supplies the same visible frames it draws in the window.
@MainActor
enum ComposerAttachmentAccessibility {
    static func publish(window: OpaquePointer, strip: LinuxPromptAttachmentStrip,
                        owner: String?, scope: Int32, root: NSView,
                        originX: Int, topInset: Int = 0) {
        if let owner {
            owner.withCString { tw_accessibility_attachments_begin(window, scope, $0) }
        } else {
            tw_accessibility_attachments_begin(window, scope, nil)
        }
        let scale = WorkspaceDisplay.scale
        func pixels(_ rect: NSRect) -> (Int32, Int32, Int32, Int32) {
            (Int32(originX + Int((rect.minX * scale).rounded())),
             Int32(topInset + Int(((root.bounds.height - rect.maxY) * scale).rounded())),
             Int32((rect.width * scale).rounded()),
             Int32((rect.height * scale).rounded()))
        }
        if owner != nil {
            for tile in strip.accessibleTiles(in: root) {
                let bounds = pixels(tile.bounds)
                let remove = pixels(tile.removeBounds)
                let label = String(decoding: tile.name.utf8.prefix(240), as: UTF8.self)
                tile.id.withCString { id in
                    label.withCString { name in
                        _ = tw_accessibility_attachments_add(window, id, name,
                            bounds.0, bounds.1, bounds.2, bounds.3,
                            remove.0, remove.1, remove.2, remove.3)
                    }
                }
            }
        }
        tw_accessibility_attachments_end(window)
    }
}
#endif
