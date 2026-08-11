import Foundation

// MARK: - Defaults

enum LegacyApplicationSupportDefaults {
    /// What the Application Support directory was called before the app was renamed.
    static let directoryName = "Skalman"

    /// The database beside it. The name changed with the app, so adopting the directory is not
    /// enough on its own — the file has to arrive under the name the new build opens.
    static let databaseName = "skalman.db"

    /// SQLite keeps its write-ahead log and shared-memory index beside the database, and a
    /// database copied without them loses every committed transaction still in the journal.
    static let databaseSidecarSuffixes = ["-wal", "-shm"]

    static let lockFileName = "skalman.lock"

    /// Written into the new directory once the adoption has run, so it runs once and a user who
    /// deliberately started over is not handed the old state back on the next launch.
    static let markerFileName = ".adopted-from-skalman"
}

// MARK: - Migration

/// Adopts the Application Support directory the app kept under its previous name.
///
/// The rename moved every store to `Application Support/Threading` and renamed the database with
/// it, and nothing carried the old directory across — so the first launch after it came up on an
/// empty store, with the projects, sessions, panels, per-session settings, extensions and usage
/// history all still sitting in `Application Support/Skalman`. It does not read as data loss,
/// which is what makes it dangerous: the app looks new rather than broken, and the user's next
/// actions write over the top of an empty store while the real one goes stale beside it.
///
/// **The gate is that the new store has no projects.** That is the one signal that says the new
/// location has never really been used, and it is what makes adopting the old one safe: there is
/// nothing there to lose. A store with projects in it is left alone entirely — a user who has
/// moved on must never have an old directory reappear over their work.
///
/// Inside that gate the legacy copy wins each conflict, because anything in the new directory was
/// produced by a build that had already lost its state: an empty `settings/`, a couple of panels,
/// a usage history that starts today. Files that exist *only* in the new directory are kept, so a
/// genuinely new install that happens to sit beside an old one keeps whatever it has.
///
/// Copies rather than moves. The old directory is left exactly as it was, so a bad adoption costs
/// a directory of disk rather than the only copy of anything, and the old build — which may still
/// be running from someone's Xcode — keeps the files it has open.
enum LegacyApplicationSupportMigration {

    struct Outcome: Equatable {
        var adoptedFileCount = 0
        var adoptedDatabase = false

        var didAdoptAnything: Bool { adoptedFileCount > 0 || adoptedDatabase }
    }

    // MARK: - Entry Point

    /// Runs the adoption at most once, before anything opens a store.
    @discardableResult
    static func runIfNeeded(
        applicationSupport: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0],
        fileManager: FileManager = .default
    ) -> Outcome {
        let legacy = applicationSupport.appendingPathComponent(
            LegacyApplicationSupportDefaults.directoryName,
            isDirectory: true
        )
        let current = applicationSupport.appendingPathComponent(
            ProjectIconDefaults.applicationDirectoryName,
            isDirectory: true
        )
        let marker = current.appendingPathComponent(
            LegacyApplicationSupportDefaults.markerFileName
        )

        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: marker.path),
              currentStoreIsUnused(in: current, fileManager: fileManager) else {
            return Outcome()
        }

        // Before either copy: on a genuine first launch after the rename nothing has created
        // this yet, and a copy into a directory that does not exist fails rather than making it.
        try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)

        var outcome = Outcome()
        outcome.adoptedFileCount = adoptFiles(
            from: legacy,
            to: current,
            fileManager: fileManager
        )
        let legacyDatabase = legacy.appendingPathComponent(
            LegacyApplicationSupportDefaults.databaseName
        )
        let legacyHasDatabase = fileManager.fileExists(atPath: legacyDatabase.path)
        outcome.adoptedDatabase = adoptDatabase(
            from: legacy,
            to: current,
            fileManager: fileManager
        )

        // The marker is what makes this one-shot, so it is withheld when the one thing worth
        // adopting did not arrive — a full disk or a torn hot copy should get another launch,
        // not be recorded as a migration that happened.
        if legacyHasDatabase && !outcome.adoptedDatabase {
            ThreadingLogger.storage.error(
                "Leaving the pre-rename adoption unmarked so the next launch tries again"
            )
        } else {
            fileManager.createFile(atPath: marker.path, contents: nil)
        }

        if outcome.didAdoptAnything {
            ThreadingLogger.storage.info(
                """
                Adopted \(outcome.adoptedFileCount, privacy: .public) file(s) and \
                \(outcome.adoptedDatabase ? "the database" : "no database", privacy: .public) \
                from the pre-rename Application Support directory
                """
            )
        }
        return outcome
    }

    // MARK: - Private Methods

    /// Whether the current location holds a store that has never had a project in it.
    ///
    /// A missing database is the ordinary first-launch answer. An existing one is *opened* rather
    /// than measured by size, because an empty schema and a full one differ only in their pages —
    /// and the build that created this file wrote a 1MB journal without ever storing a project.
    private static func currentStoreIsUnused(
        in current: URL,
        fileManager: FileManager
    ) -> Bool {
        let database = current.appendingPathComponent(SQLiteDefaults.databaseName)
        guard fileManager.fileExists(atPath: database.path) else { return true }

        // Scoped so the handle is closed before anything copies over the file.
        do {
            return try ProjectDatabase(url: database).isEmpty()
        } catch {
            // An unreadable store is not evidence that the user has work here, but it is also
            // not something to overwrite on a guess. `StateManager` owns quarantining it.
            ThreadingLogger.storage.error(
                """
                Could not read the current store while considering the pre-rename directory: \
                \(error.localizedDescription, privacy: .private(mask: .hash))
                """
            )
            return false
        }
    }

    /// Copies the legacy tree in, creating directories as it goes and letting the legacy copy win
    /// each conflict. Returns how many files were written.
    private static func adoptFiles(
        from legacy: URL,
        to current: URL,
        fileManager: FileManager
    ) -> Int {
        // Enumerated by path rather than by URL: the URL enumerator hands back resolved paths, so
        // under a symlinked root — `/var/folders` on any Mac — subtracting the directory's own
        // path to get a relative one takes off the wrong number of characters.
        guard let walker = fileManager.enumerator(atPath: legacy.path) else { return 0 }

        var adopted = 0
        for case let relative as String in walker {
            let source = legacy.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  shouldAdopt(relativePath: relative) else { continue }

            let destination = current.appendingPathComponent(relative)
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
                adopted += 1
            } catch {
                ThreadingLogger.storage.error(
                    """
                    Could not adopt \(relative, privacy: .private(mask: .hash)) from the pre-rename directory: \
                    \(error.localizedDescription, privacy: .private(mask: .hash))
                    """
                )
            }
        }
        return adopted
    }

    /// The database and its journal, under the name this build opens.
    ///
    /// Validated by opening the result: a hot copy of a database another process is still writing
    /// can arrive torn. There is nothing to restore if it did — the gate above established that
    /// the store here was empty — so a failed adoption removes the copy and leaves the app to
    /// start fresh, exactly as it would have without this.
    private static func adoptDatabase(
        from legacy: URL,
        to current: URL,
        fileManager: FileManager
    ) -> Bool {
        let source = legacy.appendingPathComponent(LegacyApplicationSupportDefaults.databaseName)
        guard fileManager.fileExists(atPath: source.path) else { return false }

        let destination = current.appendingPathComponent(SQLiteDefaults.databaseName)
        var written: [URL] = []

        // The journal first has nothing to attach to, so the order is database then sidecars.
        for suffix in [""] + LegacyApplicationSupportDefaults.databaseSidecarSuffixes {
            let from = URL(fileURLWithPath: source.path + suffix)
            let to = URL(fileURLWithPath: destination.path + suffix)
            do {
                if fileManager.fileExists(atPath: to.path) {
                    try fileManager.removeItem(at: to)
                }
                guard fileManager.fileExists(atPath: from.path) else { continue }
                try fileManager.copyItem(at: from, to: to)
                written.append(to)
            } catch {
                ThreadingLogger.storage.error(
                    """
                    Could not adopt the pre-rename database: \
                    \(error.localizedDescription, privacy: .private(mask: .hash))
                    """
                )
                written.forEach { try? fileManager.removeItem(at: $0) }
                return false
            }
        }

        // Opened *and* read: opening a torn file can succeed on its header alone, and the
        // question being asked is whether the projects arrived.
        guard (try? ProjectDatabase(url: destination).load()) != nil else {
            ThreadingLogger.storage.error(
                "The pre-rename database did not read back after being copied; leaving a fresh store"
            )
            written.forEach { try? fileManager.removeItem(at: $0) }
            return false
        }
        return true
    }

    /// The database is copied by `adoptDatabase` under a different name; the lock belongs to
    /// whichever process holds it; the journals belong to the processes that wrote them; and a
    /// `.migrated` file is one an earlier migration already retired, so carrying it over would
    /// only re-litter the new directory.
    private static func shouldAdopt(relativePath: String) -> Bool {
        // The lock and the database sit at the root, so they are matched by their whole relative
        // path — a file that merely shares one of those names further down is ordinary content.
        if relativePath == LegacyApplicationSupportDefaults.lockFileName { return false }

        // `Logs/` is a record of what other processes did, not state the user owns, and adopting
        // it does active harm on both counts. The launch marker is the sharp end: copied across,
        // `EventLog` reads it seconds later as "Previous launch did not quit cleanly" and
        // attributes it to a pid, a start time and a version belonging to the app under its old
        // name. Measured on 30 July 2026 — the real adoption reported the pre-rename launch of
        // the evening before as this launch's unclean exit, and matched it to a `Threading-*.ips`
        // written by an unrelated process. The journals are the other count: this launch's own is
        // already open for appending by the time the adoption runs, and replacing a file under an
        // open descriptor detaches every record written after it, silently. Nothing is lost —
        // the legacy directory is copied rather than moved, so the old journals stay readable
        // where they were written.
        if (relativePath as NSString).pathComponents.first == EventLogDefaults.directoryName {
            return false
        }
        if (relativePath as NSString).pathExtension == SQLiteDefaults.migratedSuffix {
            return false
        }

        let databaseNames = [""] + LegacyApplicationSupportDefaults.databaseSidecarSuffixes
        return !databaseNames.contains {
            relativePath == LegacyApplicationSupportDefaults.databaseName + $0
        }
    }
}
