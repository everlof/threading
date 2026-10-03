import Foundation

/// Watches one open document for changes made by anything else — an agent rewriting it
/// atomically, an in-place append, `git checkout`, a delete — without a recursive stream over
/// the folder it sits in, which may be the whole home directory.
///
/// Two vnode sources do the noticing: the file's own (in-place writes) and its directory's
/// (entries replaced, renamed or removed, which is what an atomic save looks like — the old
/// inode is left behind, so a file source alone goes deaf after the first one). Every event is
/// coalesced and costs one `stat` on a private queue; the owner hears about it only when the
/// file's signature moved, so unrelated churn in a busy folder reaches no one. The owner then
/// compares bytes, which is what turns its own saves into no-ops.
final class MarkdownDocumentWatcher: @unchecked Sendable {
    private struct Signature: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private static let coalesce: DispatchTimeInterval = .milliseconds(150)

    private let queue = DispatchQueue(label: "codes.threading.markdown.document-watcher", qos: .utility)
    private let path: String
    private let onChange: @MainActor @Sendable () -> Void

    // Owned by `queue`.
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedInode: ino_t?
    private var signature: Signature?
    private var pending: DispatchWorkItem?
    private var isStopped = false

    init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        path = url.path
        self.onChange = onChange
        queue.async { [self] in
            signature = Self.signature(at: path)
            directorySource = source(
                at: (path as NSString).deletingLastPathComponent,
                mask: [.write, .delete, .rename, .revoke]
            )
            armFile()
            // A write between the owner's read and this arming has no event of its own; one
            // comparison now closes that window.
            Task { @MainActor in onChange() }
        }
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
    }

    /// Delivery ends at once; descriptors close on the watcher's queue.
    func stop() {
        queue.async { [self] in
            isStopped = true
            pending?.cancel()
            directorySource?.cancel()
            fileSource?.cancel()
            directorySource = nil
            fileSource = nil
        }
    }

    // MARK: - Private Methods

    private func armFile() {
        fileSource?.cancel()
        fileSource = nil
        var info = stat()
        guard stat(path, &info) == 0 else {
            watchedInode = nil
            return
        }
        watchedInode = info.st_ino
        fileSource = source(at: path, mask: [.write, .extend, .delete, .rename, .revoke])
    }

    private func source(
        at path: String,
        mask: DispatchSource.FileSystemEvent
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: queue
        )
        source.setEventHandler { [weak self] in self?.scheduleCheck() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleCheck() {
        guard !isStopped else { return }
        pending?.cancel()
        let check = DispatchWorkItem { [weak self] in self?.check() }
        pending = check
        queue.asyncAfter(deadline: .now() + Self.coalesce, execute: check)
    }

    private func check() {
        guard !isStopped else { return }
        let current = Self.signature(at: path)
        // Replaced, removed or recreated: follow the name to whichever inode now holds it.
        if current?.inode != watchedInode { armFile() }
        guard current != signature else { return }
        signature = current
        let onChange = onChange
        Task { @MainActor in onChange() }
    }

    private static func signature(at path: String) -> Signature? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Signature(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }
}
