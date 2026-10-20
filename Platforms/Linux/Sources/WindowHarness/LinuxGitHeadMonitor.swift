#if os(Linux)
import Foundation
import Glibc
import LinuxWindowBridge
@testable import CoreSlice

/// One inotify descriptor watches the Git directories of added checkouts. Git normally replaces
/// HEAD by renaming HEAD.lock, so watching the file inode would stop after the first switch.
/// Registration, event parsing and control-file reads stay on one worker; the window takes only
/// changed, bounded project values from this monitor.
final class LinuxGitHeadMonitor: @unchecked Sendable {
    struct Entry: Sendable {
        let id: String
        let path: String
        let gitDirectory: String
    }

    enum Reading: Sendable {
        case checkout(LinuxGitCheckout)
        case unavailable
    }

    private struct Configuration: Sendable {
        let entries: [Entry]
        let baseline: [String: LinuxGitCheckout]
    }

    private let lock = NSLock()
    private var nextConfiguration: Configuration?
    private var pending: [String: Reading] = [:]
    private var stopped = false
    private let tracesEvents = ProcessInfo.processInfo.environment["THREADING_LINUX_HEAD_TRACE"] == "1"
    private let wakeIdentity: UInt64

    init(wakeIdentity: UInt64) {
        self.wakeIdentity = wakeIdentity
        DispatchQueue.global(qos: .utility).async { [self] in run() }
    }

    func configure(entries: [Entry], baseline: [String: LinuxGitCheckout]) {
        lock.lock()
        nextConfiguration = Configuration(entries: entries, baseline: baseline)
        lock.unlock()
    }

    func takeChanges() -> [String: Reading] {
        lock.lock(); defer { lock.unlock() }
        let changes = pending
        pending.removeAll(keepingCapacity: true)
        return changes
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private func run() {
        let descriptor = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard descriptor >= 0 else {
            trace("open failed errno=\(errno)")
            return
        }
        defer { _ = Glibc.close(descriptor) }

        var entriesByWatch: [Int32: [Entry]] = [:]
        var watchByDirectory: [String: Int32] = [:]
        var current: [String: LinuxGitCheckout] = [:]
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while true {
            lock.lock()
            let shouldStop = stopped
            let configuration = nextConfiguration
            nextConfiguration = nil
            lock.unlock()
            if shouldStop { return }
            if let configuration {
                let groups = Dictionary(grouping: configuration.entries, by: \.gitDirectory)
                for (directory, watch) in Array(watchByDirectory) where groups[directory] == nil {
                    _ = inotify_rm_watch(descriptor, watch)
                    entriesByWatch.removeValue(forKey: watch)
                    watchByDirectory.removeValue(forKey: directory)
                }
                for (directory, entries) in groups {
                    let watch: Int32
                    if let existing = watchByDirectory[directory] { watch = existing }
                    else {
                        let mask = UInt32(IN_MOVED_TO | IN_CLOSE_WRITE | IN_DELETE_SELF
                                          | IN_MOVE_SELF)
                        watch = directory.withCString { inotify_add_watch(descriptor, $0, mask) }
                        guard watch >= 0 else {
                            trace("watch failed errno=\(errno)")
                            continue
                        }
                        watchByDirectory[directory] = watch
                    }
                    entriesByWatch[watch] = entries
                }
                current = configuration.baseline
                trace("configured entries=\(configuration.entries.count) watches=\(watchByDirectory.count)")
                lock.lock(); pending.removeAll(keepingCapacity: true); lock.unlock()
                // Reading after registration closes the gap between discovery and arming.
                for entry in configuration.entries {
                    publish(entry, current: &current)
                }
            }

            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard Glibc.poll(&poller, 1, 100) > 0, poller.revents & Int16(POLLIN) != 0 else {
                continue
            }
            var changedWatches = Set<Int32>()
            var overflowed = false
            // Drain a bounded burst. An overflow resynchronizes the registered catalogue.
            for _ in 0..<4 {
                let length = buffer.withUnsafeMutableBytes {
                    Glibc.read(descriptor, $0.baseAddress, $0.count)
                }
                guard length > 0 else { break }
                var offset = 0
                while offset + MemoryLayout<inotify_event>.size <= length {
                    let event = buffer.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: offset, as: inotify_event.self)
                    }
                    let nameStart = offset + MemoryLayout<inotify_event>.size
                    let end = nameStart + Int(event.len)
                    guard end <= length else { break }
                    if event.mask & UInt32(IN_Q_OVERFLOW) != 0 {
                        overflowed = true
                    } else if event.mask & UInt32(IN_DELETE_SELF | IN_MOVE_SELF | IN_IGNORED) != 0 {
                        changedWatches.insert(event.wd)
                    } else if event.mask & UInt32(IN_MOVED_TO | IN_CLOSE_WRITE) != 0 {
                        let name = buffer[nameStart..<end].prefix { $0 != 0 }
                        if name.elementsEqual("HEAD".utf8) { changedWatches.insert(event.wd) }
                    }
                    offset = end
                }
            }
            if overflowed { changedWatches.formUnion(entriesByWatch.keys) }
            if !changedWatches.isEmpty { trace("HEAD events watches=\(changedWatches.count)") }
            for watch in changedWatches {
                guard let entries = entriesByWatch[watch] else { continue }
                for entry in entries { publish(entry, current: &current) }
            }
        }
    }

    private func publish(_ entry: Entry, current: inout [String: LinuxGitCheckout]) {
        let observed = LinuxGitCheckout.read(at: entry.path)
        let previous = current[entry.id]
        guard observed?.root != previous?.root || observed?.identity != previous?.identity
            || observed?.repositoryIdentity != previous?.repositoryIdentity
            || observed?.branch != previous?.branch else { return }
        let reading: Reading
        if let observed {
            current[entry.id] = observed
            reading = .checkout(observed)
        } else {
            current.removeValue(forKey: entry.id)
            reading = .unavailable
        }
        lock.lock(); pending[entry.id] = reading; lock.unlock()
        trace("changed id=\(entry.id) branch=\(observed?.branch ?? "(detached or missing)")")
        _ = tw_worker_wake(wakeIdentity)
    }

    private func trace(_ message: String) {
        guard tracesEvents else { return }
        FileHandle.standardError.write(Data("HEAD_MONITOR \(message)\n".utf8))
    }
}
#endif
