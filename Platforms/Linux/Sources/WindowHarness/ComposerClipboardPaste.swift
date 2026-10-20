#if os(Linux)
import AppKit
import Foundation
import Glibc
import LinuxWindowBridge

/// Clipboard selection conversion can wait on another X11 client and transfer a large image.
/// Keep it on a serial worker, then deliver the result through the window's bounded mailbox.
@MainActor
enum ComposerClipboardPaste {
    private static let queue = DispatchQueue(label: "threading.linux.composer-clipboard",
                                             qos: .userInitiated)

    static func paste(into editor: NSTextView, attachments: LinuxPromptAttachmentStrip,
                      wakeIdentity: UInt64) {
        guard let generation = attachments.beginClipboardRead() else { return }
        let anchor = ComposerPasteAnchor(text: editor.string, selection: editor.selectedRange())
        let wayland = tw_clipboard_is_wayland() != 0
        queue.async { [weak editor, weak attachments] in
            let paths = localFileURLs(wayland: wayland)
            let image = paths.isEmpty ? pastedImagePath(wayland: wayland) : nil
            NSWindowWorkerDelivery.shared.deliver { [weak editor, weak attachments] in
                guard let attachments else {
                    if let image { _ = unlink(image) }
                    return
                }
                defer { attachments.finishClipboardRead(generation: generation) }
                guard attachments.pasteGeneration == generation, let editor else {
                    if let image { _ = unlink(image) }
                    return
                }
                if !paths.isEmpty || image != nil {
                    for path in paths.prefix(32) {
                        _ = attachments.addDroppedPath(path, wakeIdentity: wakeIdentity)
                    }
                    if let image { _ = attachments.addDroppedPath(image, wakeIdentity: wakeIdentity) }
                } else {
                    let currentText = editor.string
                    guard let selection = anchor.selection(in: currentText) else { return }
                    let laterSelection = editor.selectedRange()
                    let preserveLaterSelection = currentText != anchor.text
                        || laterSelection != anchor.selection
                    editor.setSelectedRange(selection)
                    editor.paste(nil)
                    if preserveLaterSelection {
                        let insertedLength = editor.string.utf16.count
                            - currentText.utf16.count + selection.length
                        editor.setSelectedRange(ComposerPasteAnchor.laterSelection(
                            laterSelection, afterReplacing: selection,
                            insertedUTF16Length: insertedLength))
                    }
                }
            }
        }
    }

    nonisolated private static func localFileURLs(wayland: Bool) -> [String] {
        guard let data = readTarget("text/uri-list", wayland: wayland), data.count <= 65_536,
              let list = String(data: data, encoding: .utf8) else { return [] }
        return list.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#"), let url = URL(string: String(line)),
                  url.isFileURL, url.host == nil || url.host == "localhost" else { return nil }
            return url.path
        }
    }

    nonisolated private static func pastedImagePath(wayland: Bool) -> String? {
        if let png = readTarget("image/png", wayland: wayland), png.count >= 8,
           png.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) {
            return writeClipboardImage(png, extension: "png")
        }
        if let tiff = readTarget("image/tiff", wayland: wayland), tiff.count >= 4,
           tiff.prefix(4).elementsEqual([73, 73, 42, 0])
            || tiff.prefix(4).elementsEqual([77, 77, 0, 42]) {
            var png: UnsafeMutablePointer<UInt8>?
            var length: Int32 = 0
            let converted = tiff.withUnsafeBytes { raw in
                tw_attachment_tiff_to_png(raw.bindMemory(to: UInt8.self).baseAddress,
                                           Int32(raw.count), &png, &length)
            }
            guard converted == 0, let png, length > 0 else { return nil }
            defer { tw_clipboard_free(png) }
            return writeClipboardImage(Data(bytes: png, count: Int(length)), extension: "png")
        }
        return nil
    }

    nonisolated private static func writeClipboardImage(_ image: Data,
                                                        extension suffix: String) -> String? {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-attachment-\(UUID().uuidString).\(suffix)").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return nil }
        var written = 0
        let complete = image.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while written < image.count {
                let count = Glibc.write(descriptor, base.advanced(by: written), image.count - written)
                if count <= 0 { return false }
                written += count
            }
            return true
        }
        let closed = close(descriptor) == 0
        if !complete || !closed { _ = unlink(path); return nil }
        return path
    }

    nonisolated private static func readTarget(_ target: String, wayland: Bool) -> Data? {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length: Int32 = 0
        let status = target.withCString { name in
            wayland ? tw_clipboard_read_wayland_target(name, &bytes, &length)
                : tw_clipboard_read_target(name, &bytes, &length)
        }
        guard status == 0, let bytes, length > 0 else { return nil }
        defer { tw_clipboard_free(bytes) }
        return Data(bytes: bytes, count: Int(length))
    }
}
#endif
