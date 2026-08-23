import Foundation
import ThreadingRemoteKit
import UIKit
import UniformTypeIdentifiers

// MARK: - File

/// One item taken off the system pasteboard, in the shape ``ComposerAttachmentTray`` stages.
struct ComposerClipboardFile: Equatable {
    let data: Data
    let name: String
    let type: UTType
}

// MARK: - Clipboard

/// The system pasteboard, read the way a composer needs it.
///
/// A phone's clipboard is where a picture, a log excerpt or a file from another app already is,
/// and it was the one door the composer did not have: the pickers reach Photos and Files, and
/// something copied out of a web page or a message is in neither until somebody saves it
/// somewhere first. Pasting text has always worked, because that is the text view's own paste —
/// pasting a *picture* did nothing at all, since an image has no text to insert.
///
/// **Asking what the pasteboard holds is not the same as reading it.** Since iOS 16 reading a
/// *value* raises the system's paste notification, while the `has…` flags and the type list are
/// metadata and raise nothing. Availability — whether an entry is offered at all — is therefore
/// answered from the metadata, and the value is read only once somebody has chosen the entry.
/// A control that prompted merely by being drawn would teach people to refuse the prompt.
@MainActor
struct ComposerClipboard {

    // MARK: - Constants

    /// As many items as one message can carry.
    ///
    /// The pasteboard's item count comes from whatever another app put there, so it is bounded
    /// *before* anything is read rather than after: the tray would refuse the ninth file, but
    /// only once its bytes had already been copied out of the pasteboard server.
    static let maximumItems = RemoteAttachmentUploadLimits.maximumPerMessage

    /// Image encodings in the order they are worth keeping, then everything the host's
    /// attachments pane will accept. First match on an item wins, so a picture offered as both
    /// PNG and JPEG travels as the PNG it was captured as rather than being re-encoded.
    private static let attachableTypes: [UTType] = {
        var types: [UTType] = [.png, .jpeg, .heic, .gif, .tiff, .bmp, .webP]
        types.append(contentsOf: ComposerAttachmentSources.documentTypes)
        return types.reduce(into: []) { unique, type in
            guard !unique.contains(type) else { return }
            unique.append(type)
        }
    }()

    /// The identifiers `hasFiles` asks about. A file copied in another app is on the pasteboard
    /// as a URL rather than as bytes, so it is part of the question even though it is read a
    /// different way.
    private static let attachableIdentifiers: [String] =
        attachableTypes.map(\.identifier) + [UTType.fileURL.identifier]

    // MARK: - Properties

    /// Whether the pasteboard is holding something a message could carry as a file.
    var hasFiles: Bool {
        pasteboard.hasImages || pasteboard.contains(pasteboardTypes: Self.attachableIdentifiers)
    }

    /// Whether the pasteboard is holding text.
    var hasText: Bool { pasteboard.hasStrings }

    /// Whether there is anything here at all worth offering.
    var hasContent: Bool { hasFiles || hasText }

    private let pasteboard: UIPasteboard

    // MARK: - Initialization

    /// The one clipboard a person has. Not a stored singleton: `UIPasteboard.general` is itself
    /// the shared object, and holding a copy of this wrapper would only make it easier to read
    /// the pasteboard somewhere the person did not ask for it.
    static var general: ComposerClipboard { ComposerClipboard(pasteboard: .general) }

    init(pasteboard: UIPasteboard) {
        self.pasteboard = pasteboard
    }

    // MARK: - Public Methods

    /// Reads the pasteboard's items as files to stage, in the order they were put there.
    ///
    /// Returns empty when nothing on it can be carried, which is also the answer for a
    /// text-only clipboard: text belongs in the draft, not in the attachment strip.
    func files() -> [ComposerClipboardFile] {
        guard let identifiersPerItem = pasteboard.types(forItemSet: nil) else { return [] }
        var files: [ComposerClipboardFile] = []
        for (index, identifiers) in identifiersPerItem.enumerated() {
            guard files.count < Self.maximumItems else { break }
            guard let file = file(at: index, offering: Set(identifiers)) else { continue }
            files.append(file)
        }
        return files
    }

    /// The pasteboard's text, or nil when there is none the terminal could take.
    ///
    /// A clipboard can be holding a whole file, and a raw terminal write carries no
    /// acknowledgement, so an oversized paste would go into silence. Refusing it here is what
    /// lets the caller say so.
    func text() -> String? {
        guard pasteboard.hasStrings, let string = pasteboard.string,
              !string.isEmpty, RemoteTerminalPaste.fits(string) else { return nil }
        return string
    }

    /// Whether the pasteboard's text is too large for one terminal write. Distinguishes "there
    /// was nothing" from "there was too much", which are different things to tell somebody.
    func holdsOversizedText() -> Bool {
        guard pasteboard.hasStrings, let string = pasteboard.string, !string.isEmpty else {
            return false
        }
        return !RemoteTerminalPaste.fits(string)
    }

    // MARK: - Private Methods

    private func file(at index: Int, offering identifiers: Set<String>) -> ComposerClipboardFile? {
        if let type = Self.attachableTypes.first(where: { identifiers.contains($0.identifier) }),
           let data = data(of: type, at: index), !data.isEmpty {
            return ComposerClipboardFile(data: data, name: name(for: type), type: type)
        }
        guard identifiers.contains(UTType.fileURL.identifier) else { return nil }
        return fileFromURL(at: index)
    }

    private func data(of type: UTType, at index: Int) -> Data? {
        pasteboard.data(
            forPasteboardType: type.identifier,
            inItemSet: IndexSet(integer: index)
        )?.first
    }

    /// A file copied in another app arrives as a URL rather than as bytes, which is the one
    /// case where the size is knowable before the read: an oversized file is refused without
    /// ever being pulled into memory. The pasteboard's own items offer no such question.
    private func fileFromURL(at index: Int) -> ComposerClipboardFile? {
        guard let encoded = data(of: .fileURL, at: index),
              let url = URL(dataRepresentation: encoded, relativeTo: nil),
              url.isFileURL else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        guard let size = values?.fileSize, size > 0,
              size <= RemoteAttachmentUploadLimits.maximumBytesPerFile,
              let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension),
              let data = try? Data(contentsOf: url) else { return nil }
        return ComposerClipboardFile(data: data, name: url.lastPathComponent, type: type)
    }

    /// A pasted item carries no name of its own, so it is given one that says where it came
    /// from. Deliberately not localized: this becomes a real filename in the workspace, and an
    /// agent asked to open it should be reading the same name the person was shown.
    private func name(for type: UTType) -> String {
        let stem = UUID().uuidString.prefix(8).lowercased()
        return "pasted-\(stem).\(type.preferredFilenameExtension ?? "dat")"
    }
}
