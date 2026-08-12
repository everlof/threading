import AppKit
@preconcurrency import UserNotifications

// MARK: - Notification Sound

/// One sound a notification can carry, named the way macOS resolves it.
///
/// `UNNotificationSound(named:)` takes a **file name**, not a path: the system looks the name up
/// itself, in the app bundle and then in the three `Sounds` directories. So the file name is the
/// identity here, and the URL is carried alongside only so the settings picker can play a
/// preview without repeating the search.
struct NotificationSound: Equatable, Hashable, Sendable {

    /// The file name, extension included. This is the token macOS resolves, and the value
    /// stored in preferences.
    let fileName: String

    /// Where the search found it. Preview playback reads this; delivery never does.
    let url: URL

    /// True when the file was found in the folder Add a Sound writes to, which is the first
    /// search path. The picker groups those apart from the ones macOS ships.
    let isUserInstalled: Bool

    /// What the picker calls it: the name without its extension, the way System Settings lists
    /// alert sounds. Never localized — it is a file's own name.
    var displayName: String {
        (fileName as NSString).deletingPathExtension
    }
}

// MARK: - Notification Sound Library

/// Finds the sounds macOS will play, in the order macOS searches for them.
///
/// Two entry points on purpose, because they have different costs and different callers:
/// `resolve(fileName:)` runs when a notification is about to post and does at most three
/// `stat`s for one name; `available()` lists whole directories and runs only when the settings
/// picker is being built. Neither is cached — the directories hold a few dozen entries between
/// them, and a cache would answer with a sound the user had just deleted.
enum NotificationSoundLibrary {

    /// The extensions `UNNotificationSound` documents: uncompressed or IMA4 audio in an AIFF,
    /// WAV or CAF container. Anything else is refused at the file picker rather than accepted
    /// and then silently not played.
    static let supportedExtensions: Set<String> = ["aiff", "aif", "wav", "caf"]

    /// The user's own folder first, matching the order macOS resolves a name in: a sound the
    /// user added shadows a system one of the same name, and the picker must agree with that
    /// or it would preview a different file than the notification plays.
    static var searchPaths: [URL] {
        [userSoundsDirectory,
         URL(fileURLWithPath: "/Library/Sounds", isDirectory: true),
         URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)]
    }

    /// Where an added sound is copied. `~/Library/Sounds` is not Threading's folder — it is the
    /// one macOS reads for every app, and the only writable place a `UNNotificationSound` name
    /// resolves in for an unsandboxed app. Measured on macOS 26.5: a name that resolves nowhere
    /// posts the banner in silence, with no fallback, which is why `resolve` is checked before
    /// a sound is handed over.
    static var userSoundsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Sounds", isDirectory: true)
    }

    /// Every sound the picker can offer, deduplicated by name with the earliest search path
    /// winning, sorted by display name within each directory's group.
    ///
    /// `directories` is a parameter rather than a fixed read of the machine so a test can put
    /// a known folder in front of it. Production always passes the default.
    static func available(in directories: [URL] = searchPaths) -> [NotificationSound] {
        var seen: Set<String> = []
        var result: [NotificationSound] = []

        for (index, directory) in directories.enumerated() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let sounds = names
                .filter { supportedExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .filter { seen.insert($0).inserted }
                .map {
                    NotificationSound(
                        fileName: $0,
                        url: directory.appendingPathComponent($0),
                        isUserInstalled: index == 0
                    )
                }
            result.append(contentsOf: sounds.sorted { $0.displayName < $1.displayName })
        }
        return result
    }

    /// The one name a notification is about to ask for, or nil when the file is gone.
    static func resolve(
        fileName: String,
        in directories: [URL] = searchPaths
    ) -> NotificationSound? {
        for (index, directory) in directories.enumerated() {
            let url = directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            return NotificationSound(fileName: fileName, url: url, isUserInstalled: index == 0)
        }
        return nil
    }
}

// MARK: - Suggested Sounds

/// The handful offered above the rest.
///
/// Every sound macOS ships is in the picker, but a list of fourteen is a list nobody reads to
/// the end of, and the fourteen are not equally suited: several are novelty stings from 1991
/// (`Sosumi` is a joke about a lawsuit) and a couple are loud enough to be startling. These
/// five are the short, mid-bright, unstartling ones — the shape notification-sound guidance
/// keeps arriving at, and the shape of the sounds people actually keep in chat apps.
///
/// Names, not files: nothing is shipped in the bundle, so a macOS release that drops one of
/// these simply drops it from the group, and the full list below carries whatever remains.
enum SuggestedNotificationSounds {
    static let fileNames = [
        "Submarine.aiff",
        "Glass.aiff",
        "Purr.aiff",
        "Ping.aiff",
        "Tink.aiff",
    ]

    /// The suggested ones first, in the order above, then everything else as found.
    static func partition(
        _ sounds: [NotificationSound]
    ) -> (suggested: [NotificationSound], rest: [NotificationSound]) {
        let byName = Dictionary(sounds.map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })
        let suggested = fileNames.compactMap { byName[$0] }
        let suggestedNames = Set(suggested.map(\.fileName))
        return (suggested, sounds.filter { !suggestedNames.contains($0.fileName) })
    }
}

// MARK: - Custom Notification Sound

/// Copies a sound the user chose into the folder macOS resolves names in.
///
/// A copy rather than a reference, because the name is resolved at delivery time by a system
/// process: a sound left in `~/Downloads` would play until the file moved and then stop, with
/// nothing to say why. The copy is the user's file in the user's folder, so it also appears in
/// System Settings' own alert-sound list, and removing it is a Finder delete rather than an
/// affordance Threading has to own.
enum CustomNotificationSound {

    enum Failure: LocalizedError, Equatable {
        case unsupportedFormat(String)
        case unreadable
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return L10n.format(
                    "macOS plays AIFF, WAV and CAF notification sounds. This file is %@.",
                    ext.isEmpty ? L10n.string("in another format") : ".\(ext)"
                )
            case .unreadable:
                return L10n.string("This file could not be read as a sound.")
            case .copyFailed(let reason):
                return L10n.format("The sound could not be copied to your Sounds folder. %@", reason)
            }
        }
    }

    /// Installs `url` and hands back the sound as the library now sees it.
    ///
    /// An existing file of the same name is never overwritten: it may be a sound the user put
    /// there for something else. Identical content reuses it, different content takes the next
    /// free `name 2` style name, the way a Finder copy does.
    @discardableResult
    static func install(
        _ url: URL,
        into directory: URL = NotificationSoundLibrary.userSoundsDirectory
    ) throws -> NotificationSound {
        let ext = url.pathExtension.lowercased()
        guard NotificationSoundLibrary.supportedExtensions.contains(ext) else {
            throw Failure.unsupportedFormat(ext)
        }
        guard let data = try? Data(contentsOf: url), NSSound(data: data) != nil else {
            throw Failure.unreadable
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw Failure.copyFailed(error.localizedDescription)
        }

        let destination = try freeDestination(for: url, in: directory, matching: data)
        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try data.write(to: destination)
            } catch {
                throw Failure.copyFailed(error.localizedDescription)
            }
        }

        return NotificationSound(
            fileName: destination.lastPathComponent,
            url: destination,
            isUserInstalled: true
        )
    }

    /// The name to write under: the file's own, unless something else already holds it.
    private static func freeDestination(
        for source: URL,
        in directory: URL,
        matching data: Data
    ) throws -> URL {
        let ext = source.pathExtension
        let base = (source.lastPathComponent as NSString).deletingPathExtension
        // A leading dot would install a sound the picker lists but Finder hides, and a name
        // that is nothing but dots and spaces would install one with no name at all.
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let stem = trimmed.isEmpty ? NotificationSoundDefaults.fallbackName : trimmed

        for attempt in 1...NotificationSoundDefaults.maximumNameAttempts {
            let name = attempt == 1 ? stem : "\(stem) \(attempt)"
            let candidate = directory.appendingPathComponent(name).appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
            if (try? Data(contentsOf: candidate)) == data { return candidate }
        }
        throw Failure.copyFailed(L10n.string("Too many sounds of that name are already there."))
    }
}

// MARK: - Sound Player

/// Plays one sound at a time, the next one cutting the last one off.
///
/// One at a time is the behaviour both callers want, for the same reason from opposite ends:
/// clicking down the settings menu should *audition* each sound rather than pile them up, and a
/// program that rings the bell in a loop should not be able to stack a hundred overlapping
/// copies of it. `minimumInterval` is the bell's half of that — a bell storm becomes one bell
/// rather than a wall of noise, and the terminal's output path stays free of unbounded work.
///
/// `NSSound` rather than `UNNotificationSound`, because the point here is to hear the file now:
/// a notification would also mean a banner, a Notification Center entry, and Do Not Disturb
/// deciding whether it happens at all.
@MainActor
final class SoundPlayer {

    private var current: NSSound?
    private var lastPlayed: Date?
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 0) {
        self.minimumInterval = minimumInterval
    }

    func play(_ url: URL) {
        guard admitsPlaybackNow() else { return }
        stop()
        guard let player = NSSound(contentsOf: url, byReference: true) else { return }
        current = player
        player.play()
    }

    /// The system alert sound, which is what a terminal bell has always been and what
    /// `NSSound.beep()` plays. Rate-limited alongside the rest, since it is a bell too.
    func playSystemAlert() {
        guard admitsPlaybackNow() else { return }
        NSSound.beep()
    }

    func stop() {
        current?.stop()
        current = nil
    }

    /// The rate limit itself, and the only part of this class a test can observe: whether a
    /// sound came out is the audio system's business, but whether one was *asked for* is this
    /// object's, and that is what a bell storm turns on.
    @discardableResult
    func admitsPlaybackNow() -> Bool {
        let now = Date()
        if let lastPlayed, now.timeIntervalSince(lastPlayed) < minimumInterval { return false }
        lastPlayed = now
        return true
    }
}

// MARK: - Notification Sound Preview

/// The settings pages' shared audition player. No rate limit: every click is a deliberate ask
/// to hear something, including clicking the same item twice.
@MainActor
enum NotificationSoundPreview {

    private static let player = SoundPlayer()

    static func play(_ sound: NotificationSound) {
        player.play(sound.url)
    }

    /// Auditioning "the system alert sound" has to play the system alert sound, not a file.
    static func playSystemAlert() {
        player.playSystemAlert()
    }

    static func stop() {
        player.stop()
    }
}

// MARK: - Notification Sound Defaults

enum NotificationSoundDefaults {
    /// What an added sound is called when its own name is unusable.
    static let fallbackName = "Custom Alert"

    /// How far the ` 2`, ` 3` suffix search goes before giving up. A folder holding this many
    /// same-named sounds is a folder something else is wrong with.
    static let maximumNameAttempts = 32
}
