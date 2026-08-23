import AppKit
import UniformTypeIdentifiers

/// A file a drag **promises** rather than carries.
///
/// Finder puts `public.file-url` on the pasteboard because the file is already on disk under a
/// path it can name. Photos, Messages, Mail and a Safari `<video>` cannot: what they offer is a
/// promise to write the file if somebody accepts the drop. Threading registered only the URL
/// flavour, so every one of those drags was refused — the terminal, the composer and the
/// attachments list alike — and a clip dragged out of Photos looked like a broken drop while the
/// same file dragged from Finder worked.
///
/// **Reading the promise costs the drag nothing.** The content types are on the pasteboard from
/// the moment the drag starts, so a destination answers `draggingUpdated` from `contentTypes(in:)`
/// without a file existing anywhere. Only an accepted drop writes bytes, which is the rule
/// `AttachmentComparisonDrop` already states for pixels: a drag is answered on every frame of the
/// pointer's travel, and a frame may not leave a trace.
///
/// **Ask the promise what it is, never what it is called.** `NSFilePromiseReceiver.fileNames` is
/// empty until the files have been written — measured, on a promise this process wrote and read
/// back itself — while `fileTypes` carries the UTI from the start. A destination that admits only
/// some kinds of file therefore filters on the type here and on the delivered path afterwards.
///
/// Every drop receives into a directory of its own, so the file keeps the name its owner gave it
/// without two drops of `IMG_0001.mov` becoming one. That is the custody `TerminalDropImage` keeps
/// for a converted image and for the same reason: the name is half of what the person dropping it
/// will recognise.
enum DroppedFilePromise {

    /// The types a destination registers to be offered promised files at all.
    ///
    /// AppKit decides from a view's registration whether it sees a drag, so a surface that omits
    /// these is not refusing promises — it is never asked about them.
    static var readableTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(rawValue:))
    }

    /// Whether this pasteboard is promising files, asked without reading them.
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self])
    }

    /// What the promised files are, in the drag's own order — enough for a destination that takes
    /// only some kinds to decide before any of them exists. No file is touched.
    static func contentTypes(in pasteboard: NSPasteboard) -> [UTType] {
        receivers(in: pasteboard)
            .flatMap(\.fileTypes)
            .compactMap { UTType($0) }
    }

    /// Writes out everything this pasteboard promises and answers with the paths.
    ///
    /// Returns false when the pasteboard promises nothing, and then `completion` is never called —
    /// so a destination can try this after its own file and image routes and fall through to
    /// whatever it does for a drag it cannot use.
    ///
    /// **The answer arrives after the drop.** The source writes the bytes on its own schedule, so
    /// `performDragOperation` returns long before the paths exist. Callers treat `completion` as a
    /// late arrival on an input the user may have moved on from: hold the destination weakly, and
    /// re-check whatever the drop was gated on.
    @MainActor
    @discardableResult
    static func receive(
        from pasteboard: NSPasteboard,
        completion: @escaping @MainActor ([String]) -> Void
    ) -> Bool {
        let promised = accepted(receivers(in: pasteboard))
        guard !promised.isEmpty else { return false }
        guard let destination = makeDestinationDirectory() else { return false }

        let collector = DroppedFilePromiseCollector(
            expected: promised.map { max($0.fileNames.count, 1) },
            completion: completion
        )

        for (index, receiver) in promised.enumerated() {
            receiver.receivePromisedFiles(
                atDestination: destination,
                options: [:],
                operationQueue: collector.queue
            ) { url, error in
                // A path and a description, never the `Error` itself: this hop leaves the
                // promise's own queue, and only values that can cross it may be captured.
                let path = url.path
                let failure = error?.localizedDescription
                Task { @MainActor in
                    collector.received(path: path, failure: failure, at: index)
                }
            }
        }
        return true
    }

    // MARK: - Private Methods

    private static func receivers(in pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver] ?? []
    }

    /// As many receivers as fit under the file ceiling, whole ones only.
    ///
    /// A drag's promise count comes from another application, so it is unbounded here and every
    /// promise is a copy onto this disk. The cap counts receivers rather than files because a
    /// receiver delivers all of its files or none — and what it excludes is logged, because a
    /// truncation nobody is told about reads as "that was everything the drag had".
    ///
    /// A receiver that names nothing still counts as one file: an unnamed promise is the ordinary
    /// case, not an empty one.
    private static func accepted(_ receivers: [NSFilePromiseReceiver]) -> [NSFilePromiseReceiver] {
        var taken: [NSFilePromiseReceiver] = []
        var files = 0
        for receiver in receivers {
            let count = max(receiver.fileNames.count, 1)
            guard files + count <= DroppedFilePromiseDefaults.maximumFiles else { break }
            taken.append(receiver)
            files += count
        }
        if taken.count != receivers.count {
            ThreadingLogger.session.notice(
                """
                A dropped promise carried \(receivers.count, privacy: .public) sources; \
                receiving \(taken.count, privacy: .public) under the \
                \(DroppedFilePromiseDefaults.maximumFiles, privacy: .public)-file ceiling
                """
            )
        }
        return taken
    }

    /// Its own directory per drop, so the promised file keeps its own name.
    private static func makeDestinationDirectory() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(DroppedFilePromiseDefaults.directoryPrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            ThreadingLogger.session.error(
                """
                Could not make a directory for a dropped promise: \
                \(error.localizedDescription, privacy: .private(mask: .hash))
                """
            )
            return nil
        }
    }
}

// MARK: - Collector

/// Holds one drop's promises open until the last file lands, and answers in the drag's own order.
///
/// Ordered by slot rather than by arrival: several sources write concurrently, and a drop of three
/// files whose paths came back smallest-first would arrive in an order the person dropping them
/// never chose. A source that fails its promise leaves an empty slot rather than shifting every
/// path after it.
///
/// Internal rather than private because it is the half of a promise drop that can be tested at
/// all: fulfilment needs a real drag session between two processes, while what this does with the
/// answers is ordinary logic.
@MainActor
final class DroppedFilePromiseCollector {

    /// Retained here because the promise machinery does not own it: the queue has to outlive
    /// `receive(from:completion:)` returning, and dies with the last file it delivered.
    let queue: OperationQueue

    private var slots: [[String]]
    private var outstanding: [Int]
    private var completion: (@MainActor ([String]) -> Void)?

    init(expected: [Int], completion: @escaping @MainActor ([String]) -> Void) {
        queue = OperationQueue()
        queue.name = DroppedFilePromiseDefaults.queueName
        queue.qualityOfService = .userInitiated
        slots = Array(repeating: [], count: expected.count)
        outstanding = expected
        self.completion = completion
    }

    func received(path: String, failure: String?, at index: Int) {
        guard slots.indices.contains(index) else { return }

        if let failure {
            ThreadingLogger.session.error(
                "A dropped file was promised and not delivered: \(failure, privacy: .private(mask: .hash))"
            )
        } else {
            slots[index].append(path)
        }

        guard outstanding[index] > 0 else {
            // A promise that named fewer files than it wrote. The paths are already recorded
            // above; there is no second answer to give, because the first one has been acted on.
            ThreadingLogger.session.notice("A dropped promise delivered more files than it named")
            return
        }
        outstanding[index] -= 1

        guard outstanding.allSatisfy({ $0 == 0 }) else { return }
        let paths = slots.flatMap { $0 }
        // Cleared before the call: an owner that drops again from inside its own completion gets
        // a second collector rather than a second answer out of this one.
        let answer = completion
        completion = nil
        guard !paths.isEmpty else { return }
        answer?(paths)
    }
}

// MARK: - Defaults

enum DroppedFilePromiseDefaults {

    /// Files one drop will write out. A drag from a photo library can carry a whole album
    /// selection, and each promise is a copy onto this disk.
    static let maximumFiles = 32

    static let directoryPrefix = "threading-drop-"
    static let queueName = "codes.threading.dropped-file-promise"
}
