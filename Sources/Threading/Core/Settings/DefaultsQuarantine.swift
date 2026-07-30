import Foundation

/// Moves unreadable `UserDefaults` state aside, so that a failed load cannot authorise its own
/// overwrite.
///
/// This is `ProjectStore`'s rule for `projects.json` — quarantine the bytes nobody could read,
/// and permit writes only if that succeeded — applied to the small stores that keep their state
/// as one encoded blob in `UserDefaults`. Those had exactly the shape the document store was
/// fixed for, and worse odds: a decode failure fell through to *defaults*, and the next save —
/// which for a settings store is any ordinary edit — wrote those defaults over bytes nobody had
/// read. One schema change was all it took to erase a user's keyboard bindings or their account
/// names, with nothing anywhere reporting it.
///
/// The distinction that matters is **missing** versus **unreadable**. Missing is the first run
/// and needs no ceremony. Unreadable is data that meant something to whoever wrote it, and the
/// only honest options are to keep it or to say out loud that it could not be kept.
enum DefaultsQuarantine {

    /// Where the unreadable copy of a key is kept.
    ///
    /// One slot per key rather than a timestamped series: a second failure means the first
    /// quarantine has already been superseded by whatever the user did next, and an unbounded
    /// pile of dead blobs in `UserDefaults` is its own small bug.
    static func quarantineKey(for key: String) -> String { "\(key).unreadable" }

    /// Copies the unreadable value aside and confirms the copy landed.
    ///
    /// Returns whether writes to the original key may now proceed. Read back rather than
    /// assumed, because "we saved a backup" is the one claim that must not be taken on trust
    /// immediately before overwriting the original.
    @discardableResult
    static func quarantine(
        _ data: Data,
        forKey key: String,
        in defaults: UserDefaults
    ) -> Bool {
        let destination = quarantineKey(for: key)
        defaults.set(data, forKey: destination)

        guard defaults.data(forKey: destination) == data else {
            ThreadingLogger.session.error(
                """
                Could not quarantine unreadable \(key, privacy: .public); \
                refusing to overwrite it.
                """
            )
            return false
        }

        ThreadingLogger.session.error(
            """
            \(key, privacy: .public) could not be decoded; the previous value is kept at \
            \(destination, privacy: .public).
            """
        )
        return true
    }
}
