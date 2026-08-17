import Foundation

/// What a build can say about itself, assembled once for the surfaces that ask.
///
/// Two of them do. The sidebar's channel mark is hovered by whoever wonders what `DEV` means, and
/// the About window is opened by whoever wants the whole answer. Both would otherwise read the
/// bundle themselves, and a second reader is a second place for the spelling to drift.
///
/// Every reading is taken rather than written down. The one that is not on the bundle is the
/// **build date**, and it is the executable's modification time for `BuildFingerprint`'s reason: a
/// build the release pipeline did not stamp carries `0.0.0 (0.0.0)` whatever it is, so when it was
/// linked is the only thing separating this build from the one before it — which is precisely what
/// a development mark is being asked. It costs one `stat`, on a surface a person just opened.
struct BuildDetails: Equatable {

    // MARK: - Properties

    /// One labelled reading. The label is localized copy; the value is a reading, and is not.
    struct Entry: Equatable {
        let label: String
        let value: String
    }

    let channel: BuildChannel

    /// The version pair, spelled the way `AppInfo` spells it everywhere else.
    let versionSummary: String

    /// Configuration, build date, system and architecture, in reading order.
    ///
    /// The channel is **not** here, on either surface that draws these: the sidebar's Help Tag
    /// already opens with the sentence the mark stands for, and the About window sets the same
    /// mark beside the version. A row repeating it would say the thing twice and, on a release
    /// build, name a channel whose whole design is to be the one that goes unmarked.
    ///
    /// A reading nobody can take is **left out** rather than filled in with a word meaning
    /// "missing": a build date the filesystem would not give up is one fewer line, not a line
    /// saying Unknown.
    let entries: [Entry]

    // MARK: - Initialization

    init(
        channel: BuildChannel = AppInfo.buildChannel,
        versionSummary: String = AppInfo.versionSummary,
        configuration: String = BuildDetails.configuration,
        built: String? = BuildDetails.formatted(BuildDetails.executableModifiedAt()),
        system: String = BuildDetails.systemVersion,
        architecture: String = BuildDetails.architecture
    ) {
        self.channel = channel
        self.versionSummary = versionSummary

        var entries: [Entry] = [
            Entry(label: L10n.string("Configuration"), value: configuration)
        ]
        if let built, !built.isEmpty {
            entries.append(Entry(label: L10n.string("Built"), value: built))
        }
        entries.append(Entry(label: L10n.string("System"), value: system))
        entries.append(Entry(label: L10n.string("Architecture"), value: architecture))
        self.entries = entries
    }

    static var current: BuildDetails { BuildDetails() }

    // MARK: - Public Methods

    /// The version pair as a labelled line, for a surface with no headline to carry it in.
    var versionEntry: Entry {
        Entry(label: L10n.string("Version"), value: versionSummary)
    }

    /// The multi-line Help Tag a build mark wears: what the abbreviation means, then every
    /// detail behind it.
    ///
    /// The whole answer rather than a longer hint. Three letters in a footer is the least a build
    /// can say about itself, and hovering them is the one gesture anybody makes to find out more;
    /// stopping at the version would leave that gesture still owing an answer. A release build
    /// has no headline sentence, because it wears no mark to explain — the lines alone remain
    /// useful to whichever surface asks for them.
    var helpTag: String {
        var lines: [String] = []
        if let spoken = channel.spokenName {
            lines.append(spoken)
            lines.append("")
        }
        lines += ([versionEntry] + entries).map { "\($0.label): \($0.value)" }
        return lines.joined(separator: "\n")
    }

    // MARK: - Readings

    /// Which configuration produced this binary. Not the same question as the channel: a nightly
    /// is a Release build, and a locally built `dev` is usually a Debug one — but nothing stops
    /// somebody archiving Release locally, and a report that conflates the two sends whoever
    /// reads it looking for an optimiser bug in a debug build.
    ///
    /// Untranslated, like `architecture`: these are the build system's own configuration names,
    /// and a report is read against Xcode rather than against the reader's locale.
    static var configuration: String {
#if DEBUG
        "Debug"
#else
        "Release"
#endif
    }

    /// The architecture this slice was compiled for. Stated at compile time rather than read
    /// from `uname`, which answers for the process and so cannot tell a native build from the
    /// same build translated.
    static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    /// The running system, composed rather than taken from `operatingSystemVersionString` —
    /// which reads `Version 26.1 (Build 25C65)` and would put the word "Version" in a row whose
    /// label already says System.
    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "macOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 {
            text += ".\(version.patchVersion)"
        }
        return text
    }

    /// When the executable was last written — see the type's own note for why that is the build
    /// date here. `nil` when the filesystem will not say, which drops the line.
    static func executableModifiedAt() -> Date? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return try? executable
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    /// A date in the reader's own locale, at the precision a build date is useful to: the day,
    /// and the time of day that tells two of the same day's builds apart.
    static func formatted(_ date: Date?) -> String? {
        date?.formatted(date: .abbreviated, time: .shortened)
    }
}
