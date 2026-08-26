import Foundation

/// The provider-neutral vocabulary of an update in flight.
///
/// `UpdateUserDriver` translates Sparkle's callbacks into these values and
/// `UpdatePresenter` renders them, so neither side knows the other's types: the presenter
/// never imports Sparkle, and the decisions worth testing — what a found update offers, when a
/// download fraction is honest, what a release-notes payload decodes to — are plain values
/// with no framework standing between them and an assertion.

// MARK: - What the feed offered

/// One update the feed offered, reduced to what the sheet says about it.
struct UpdateVersionInfo: Equatable {
    /// The human version — `displayVersionString`, which the feed may repeat for several
    /// builds. Presentation only; ordering stays Sparkle's.
    let version: String

    /// An information-only item must not be downloaded; the honest offer is its `infoURL`.
    /// Sparkle's own docs note these are sometimes a fallback after a bad ship, so the case
    /// is supported rather than treated as exotic.
    let isInformational: Bool

    /// A critical update is not offered a Skip: skipping suppresses every future prompt for
    /// that version, which is exactly the memory a critical fix must not leave behind.
    let isCritical: Bool

    let infoURL: URL?
    var releaseNotes: UpdateReleaseNotes
}

/// Where the release notes are, which the appcast decides.
///
/// Threading's own feed embeds them in the item description as plain-text Markdown
/// (`sparkle:descriptionFormat="plain-text"` — the contract `scripts/release.sh` will keep),
/// so the common case is `.embedded` and no second fetch happens. Linked notes remain
/// supported because Sparkle downloads them regardless of whose feed it is.
enum UpdateReleaseNotes: Equatable {
    /// The feed carried none.
    case none
    /// Embedded in the appcast item and available the moment the update is shown.
    case embedded(String)
    /// Linked from the appcast; Sparkle is fetching them and one of the two cases below
    /// replaces this.
    case pending
    /// The linked notes arrived.
    case downloaded(String)
    /// The linked notes did not arrive; the sheet says so instead of spinning forever.
    case unavailable

    /// The text a `MarkdownView` renders, or nil while there is nothing to draw.
    var text: String? {
        switch self {
        case .embedded(let text), .downloaded(let text):
            return text
        case .none, .pending, .unavailable:
            return nil
        }
    }
}

/// Decodes a downloaded release-notes payload into renderable text.
///
/// Kept apart from the driver because the interesting part is pure: honour the transport's
/// declared encoding first, fall back through UTF-8 to Latin-1 — the historical default for
/// unlabelled HTTP text — rather than showing "could not be loaded" for bytes that arrived.
enum UpdateReleaseNotesDecoding {

    static func text(from data: Data, encodingName: String?) -> String? {
        if let encodingName,
           let encoding = encoding(named: encodingName),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        )
    }
}

// MARK: - Download arithmetic

/// The running download total, and whether it is honest to draw as a fraction.
///
/// Sparkle warns that the expected length may be invalid, may disagree with what actually
/// arrives, and may be re-announced mid-download. The rules here keep the bar truthful:
/// no expected length means no fraction (the bar reads indeterminate rather than fake), and
/// a total that overshoots a wrong expectation clamps at 1 rather than escaping the bar.
struct UpdateDownloadProgress: Equatable {

    private(set) var expectedLength: UInt64 = 0
    private(set) var receivedLength: UInt64 = 0

    /// A re-announced expectation replaces the old one; the bytes already counted stay.
    mutating func expect(_ length: UInt64) {
        expectedLength = length
    }

    mutating func receive(_ length: UInt64) {
        receivedLength += length
    }

    /// 0…1 when the expectation supports one, nil when only "still downloading" is true.
    var fraction: Double? {
        guard expectedLength > 0 else { return nil }
        return min(Double(receivedLength) / Double(expectedLength), 1)
    }
}

// MARK: - Which feed, and whether to ask it unprompted

/// Where each build channel looks for updates, and whether it may look on a schedule.
///
/// The stable URL is the one in Info.plist (`SUFeedURL`) — the plist stays the single source
/// of truth for it, and this policy only *overrides* the channels that must not read it.
/// Nightlies get their own feed because a nightly's date version (2026.8.6) outranks every
/// 1.x under Sparkle's comparator: in the stable feed a nightly install would permanently
/// outrank stable and stop seeing updates the moment it should return there. See
/// `docs/architecture/releasing.md` and `.github/workflows/nightly.yml`.
enum UpdateFeedPolicy {

    /// The rolling nightly release's own appcast. `releases/download/nightly/` rather than
    /// `latest/download`, because a prerelease never becomes `latest` — which is also what
    /// keeps nightlies out of the stable feed's URL.
    static let nightlyFeed =
        "https://github.com/everlof/threading/releases/download/nightly/appcast.xml"

    /// The feed override for a channel, or nil to use the shipped `SUFeedURL`.
    static func feedOverride(for channel: BuildChannel) -> String? {
        switch channel {
        case .nightly:
            return nightlyFeed
        case .dev, .beta, .release:
            return nil
        }
    }

    /// Whether the scheduled daily check may run. The user's switch is necessary but not
    /// sufficient: a dev build (version `0.0.0`) is outranked by every release forever, so a
    /// scheduled check would offer it the same "update" daily until the end of time. The
    /// explicit menu command stays available everywhere — turning off background traffic is
    /// not a refusal ever to look.
    static func allowsScheduledChecks(on channel: BuildChannel, userChoice: Bool) -> Bool {
        userChoice && channel != .dev
    }
}

// MARK: - Which builds a person is willing to receive

/// The risk level a *user* subscribes to, which is not the same thing as what their build *is*.
///
/// `BuildChannel` describes an artefact; this describes an appetite. They are separate because a
/// person running a beta may want to go back to stable, and a person running stable may want to
/// try a beta, without either of them reinstalling anything.
///
/// Sparkle carries it: an item in the appcast may be tagged `<sparkle:channel>beta</sparkle:channel>`
/// and is invisible to any updater that does not name that channel. The default is the empty set,
/// so a user who never touches this setting sees only untagged items — stable, by doing nothing.
///
/// **Nightly is deliberately not here.** Its version is the date (`2026.8.26`), which outranks
/// every release Threading will ever ship, so joining is easy and leaving is impossible: Sparkle
/// would find nothing newer on the stable feed and offer nothing, forever. It stays a separate
/// feed reached by installing a nightly build. A control that can strand its user is not a
/// control; see `feedOverride(for:)` above and `.github/workflows/nightly.yml`.
enum UpdateChannelSubscription: String, CaseIterable, Sendable {
    case stable
    case beta

    /// What a build with this channel should default to when the user has expressed no choice.
    ///
    /// The load-bearing case is a *direct download*: somebody handed a beta zip has, by default,
    /// no beta subscription, so every beta item is filtered out and their build never updates
    /// again. That is the common way to end up on a beta, not an exotic one, so the default
    /// follows the build rather than stranding it. Choosing stable afterwards remains possible
    /// and is then a decision rather than an accident.
    static func standard(for channel: BuildChannel) -> UpdateChannelSubscription {
        switch channel {
        case .beta: .beta
        case .dev, .nightly, .release: .stable
        }
    }

    /// The Sparkle channel names this subscription accepts.
    ///
    /// Monotonic by construction: a subscription accepts its own channel and everything more
    /// stable. Stable accepts nothing, which in Sparkle's vocabulary means "untagged items only"
    /// rather than "no items".
    var allowedChannelNames: Set<String> {
        switch self {
        case .stable: []
        case .beta: ["beta"]
        }
    }
}

// MARK: - What the sheet offers

/// The three answers Sparkle understands, minus its type.
enum UpdateChoice {
    case install
    case dismiss
    case skip
}

/// Who asked for the check. A person who chose the menu item is answered on the spot; a
/// scheduled check defers its sheet until the app is active, because a dialog materialising
/// under nobody's hand is how background work turns into an interruption.
enum UpdateCheckOrigin {
    case user
    case scheduled
}

/// What the found sheet offers for a given update — decided here, in a testable value,
/// rather than inline where the buttons are built.
struct UpdateFoundPresentation: Equatable {

    enum PrimaryAction: Equatable {
        /// Begin the ordinary download-and-install flow.
        case install
        /// An information-only item: open `infoURL` and dismiss, never download.
        case learnMore(URL)
    }

    /// nil for the one shape with nothing to offer: an information-only item that carries no
    /// `infoURL`. Sparkle forbids installing those, so pretending Install is available would
    /// be worse than a sheet that only states the fact.
    let primary: PrimaryAction?
    let offersSkip: Bool

    init(info: UpdateVersionInfo) {
        if info.isInformational {
            primary = info.infoURL.map { .learnMore($0) }
        } else {
            primary = .install
        }
        // No Skip for a critical update, and none for an informational one either — there is
        // no downloadable version to skip, only a page to read.
        offersSkip = !info.isCritical && !info.isInformational
    }
}
