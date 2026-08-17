import Foundation

// MARK: - Scheduled Attachment Store

/// The pictures a scheduled send is carrying, kept somewhere a schedule can rely on.
///
/// **This is the whole of why images can be scheduled at all.** They were refused outright to
/// begin with, and the reason given was sound as far as it went: a pasted screenshot is written
/// into the temporary directory, so a path recorded on Friday can name nothing by Monday. But
/// that is an argument against *keeping the path*, not against keeping the picture. Taking a copy
/// at the moment of scheduling costs one file per image and removes the dependency entirely —
/// the record then names bytes the app owns, and nothing outside it has to survive the wait.
///
/// **Beside the record, not inside it.** `scheduled-messages.json` is a `RecoverableFileStore`
/// whose whole contract is a synchronous verified write on every mutation; inlining megabytes of
/// PNG would make each of those writes proportional to the pictures rather than to the words. So
/// the file keeps the names and this keeps the bytes, in a directory per message id.
///
/// **A slot per image, so no file is ever renamed.** Two screenshots can both be called
/// `Screenshot.png`, and prefixing one of them would break two things that read the name: a
/// pasted image is recognised downstream by its `threading-attachment-` prefix, and the session
/// attachments pane shows a dropped file under the name it already had.
@MainActor
final class ScheduledAttachmentStore {

    // MARK: - Singleton

    static let shared = ScheduledAttachmentStore()

    // MARK: - Properties

    private let root: URL
    private let fileManager: FileManager

    /// Ids this run has taken custody for. Held in memory only, like `ScheduledMessageStore`'s
    /// own claims, and for the same kind of reason: it describes what *this* process is in the
    /// middle of, not what is durable.
    ///
    /// **The sweep would otherwise delete a picture between the two writes that make a scheduled
    /// send.** Custody is taken first and the record is written second, so for a moment the bytes
    /// exist and nothing names them — which is precisely what `retainOnly` is built to remove.
    /// The shared store is constructed lazily, so the first schedule of a run can be what
    /// triggers `load`, and its sweep then arrives inside that gap: the record went to disk
    /// naming two files that had been deleted a microsecond earlier. Found by an end-to-end
    /// composer test, not by anything the unit tests could see, because the two stores are only
    /// wired together in the app.
    private var inFlight: Set<ScheduledMessageID> = []

    // MARK: - Initialization

    /// The directory is injectable for `ScheduledMessageStore`'s reason: the test bundle is
    /// hosted in the app, so a store that always resolved Application Support would have a test
    /// deleting the developer's own scheduled pictures.
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let base = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        self.fileManager = fileManager
        self.root = base.appendingPathComponent(
            ScheduledAttachmentDefaults.directoryName,
            isDirectory: true
        )
    }

    // MARK: - Taking Custody

    /// Copies what the composer is holding into this message's own directory.
    ///
    /// **Answers nil rather than a short list.** A send that quietly lost one of three pictures
    /// is worse than one that was refused: the composer still has all three at the moment this is
    /// called, and a refusal it can state is the only outcome that leaves the user able to act.
    /// Anything already copied is removed on the way out, so a refused schedule leaves nothing.
    func take(_ paths: [String], for id: ScheduledMessageID) -> [ScheduledAttachment]? {
        guard !paths.isEmpty else { return [] }
        guard paths.count <= ScheduledAttachmentDefaults.maximumPerMessage else { return nil }

        let directory = self.directory(for: id)
        var taken: [ScheduledAttachment] = []
        var totalBytes = 0
        // Marked before the first byte is written, so the gap before the record exists is never
        // open. `release` is what closes it, and every refusal below goes through `release`.
        inFlight.insert(id)

        for (slot, path) in paths.enumerated() {
            let source = URL(fileURLWithPath: path)
            guard let size = regularFileSize(at: source) else {
                release(id)
                return nil
            }
            totalBytes += size
            guard totalBytes <= ScheduledAttachmentDefaults.maximumTotalBytes else {
                release(id)
                return nil
            }

            let name = Self.safeName(source.lastPathComponent)
            let slotDirectory = directory.appendingPathComponent("\(slot)", isDirectory: true)
            do {
                try fileManager.createDirectory(
                    at: slotDirectory,
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(
                    at: source,
                    to: slotDirectory.appendingPathComponent(name)
                )
            } catch {
                ThreadingLogger.session.error(
                    "Failed to keep a scheduled image: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                release(id)
                return nil
            }
            taken.append(ScheduledAttachment(slot: slot, name: name))
        }
        return taken
    }

    // MARK: - Reading

    /// Where each of a message's pictures actually is, skipping any the filesystem lost.
    func urls(for message: ScheduledMessage) -> [URL] {
        let directory = self.directory(for: message.id)
        return message.attachments.compactMap { attachment in
            let url = directory
                .appendingPathComponent("\(attachment.slot)", isDirectory: true)
                .appendingPathComponent(Self.safeName(attachment.name))
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
    }

    func directory(for id: ScheduledMessageID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - Giving It Back

    /// Hands a composer *copies* of a send's pictures, leaving custody exactly where it is —
    /// the editing loan.
    ///
    /// `detach` moves, because its callers remove the record next. An edit is different: the
    /// record stays in the store and may still fire while its content is being worked on, so it
    /// keeps the bytes it may fire with, and the composer gets what a freshly pasted image is —
    /// a temporary file of its own, held, sent or re-scheduled without this store's directories
    /// ever being named outside it.
    func copies(of message: ScheduledMessage) -> [String] {
        let sources = urls(for: message)
        var paths: [String] = []
        for source in sources {
            let destination = fileManager.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(source.lastPathComponent)
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: destination)
                paths.append(destination.path)
            } catch {
                ThreadingLogger.session.error(
                    "Failed to lend a scheduled image copy: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        return paths
    }

    /// Moves a staged edit's pictures over a message's own.
    ///
    /// The editing commit takes custody of the composer's images under a *fresh* staging id
    /// first — an ordinary `take`, so every ceiling and refusal applies — and only once the
    /// rewritten record has committed do the staged bytes become the message's. A commit that
    /// fails therefore leaves the record's current pictures untouched, and a staging directory
    /// stranded by a crash is an unnamed id `retainOnly` sweeps at the next launch.
    func adopt(_ stagingID: ScheduledMessageID, as id: ScheduledMessageID) {
        let staged = directory(for: stagingID)
        let destination = directory(for: id)
        try? fileManager.removeItem(at: destination)
        if fileManager.fileExists(atPath: staged.path) {
            try? fileManager.moveItem(at: staged, to: destination)
        }
        inFlight.remove(stagingID)
        inFlight.insert(id)
    }

    /// Hands the pictures back to a composer that is taking this send apart again — Edit, and
    /// Send now.
    ///
    /// **Moved to the temporary directory rather than lent in place.** What comes back has to be
    /// exactly what a freshly pasted image is, because that is what the composer it lands in
    /// will do with it: hold a path, send that path, and take custody again if it is scheduled a
    /// second time. Lending our own file would leave the composer pointing into a directory the
    /// very next `remove` deletes.
    func detach(_ message: ScheduledMessage) -> [String] {
        let sources = urls(for: message)
        var paths: [String] = []
        for source in sources {
            let destination = fileManager.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(source.lastPathComponent)
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: source, to: destination)
                paths.append(destination.path)
            } catch {
                ThreadingLogger.session.error(
                    "Failed to hand a scheduled image back: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        release(message.id)
        return paths
    }

    // MARK: - Lifecycle

    /// Drops everything one message was carrying. Called for every way a record leaves the
    /// store, which is why it lives on `ScheduledMessageStore`'s own mutations rather than on
    /// the surfaces that ask for them.
    func release(_ id: ScheduledMessageID) {
        inFlight.remove(id)
        try? fileManager.removeItem(at: directory(for: id))
    }

    /// Drops the directories of messages the store no longer has.
    ///
    /// The sweep for bytes a crash stranded: the record and its pictures are two writes, and a
    /// quit between them leaves a directory nothing names. Bounded by the store's own ceiling
    /// (`ScheduledMessageDefaults.maximumTotal`), so this is a listing of at most a few dozen
    /// directory names at launch.
    func retainOnly(_ ids: Set<ScheduledMessageID>) {
        guard let names = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        // The union, not the argument: a directory whose record has not been written yet is
        // mid-schedule, not stranded. See `inFlight`.
        let kept = Set(ids.union(inFlight).map(\.uuidString))
        for url in names where !kept.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Private Methods

    private func regularFileSize(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else { return nil }
        return size
    }

    /// The last path component and nothing else.
    ///
    /// Applied on the way in *and* on the way out, because the way out reads a name that came
    /// off disk: a hand-edited record naming `../../../etc/passwd` must resolve to a file inside
    /// this message's own slot or to nothing at all.
    private static func safeName(_ name: String) -> String {
        let component = name.components(separatedBy: "/").last ?? name
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else {
            return ScheduledAttachmentDefaults.fallbackName
        }
        return String(trimmed.prefix(ScheduledAttachmentDefaults.maximumNameCharacters))
    }
}

// MARK: - Defaults

enum ScheduledAttachmentDefaults {

    /// Beside `scheduled-messages.json`, one directory per message id.
    static let directoryName = "scheduled-attachments"

    /// How many pictures one send may carry.
    ///
    /// The composer's own strip is a scrolling row of thumbnails with no ceiling, and this is
    /// where one starts to matter: past a handful the message is a file transfer rather than a
    /// prompt, and every one of them is bytes the app now keeps until Monday.
    static let maximumPerMessage = 12

    /// The ceiling across one send's pictures together. A per-image cap is not an aggregate cap,
    /// which is the whole point of the scaling gate: twelve merely large images is a problem the
    /// per-image answer never sees.
    static let maximumTotalBytes = 64 * 1_024 * 1_024

    static let maximumNameCharacters = 128

    /// For a name that survived nothing worth keeping. It still lands in its own slot, so it
    /// collides with nothing.
    static let fallbackName = "image"
}
