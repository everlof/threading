import Foundation

/// What the application calls itself, read from the bundle rather than written down.
///
/// The name reaches text the user reads — a settings subtitle, the name a transition preview
/// morphs a style's name into — and a literal in each of those is one more place to miss when
/// the product is renamed. `CFBundleDisplayName` is what the Finder shows when a bundle sets
/// it, `CFBundleName` is what every bundle has, and the process name is the honest answer for
/// a binary running outside a bundle.
public enum AppInfo {

    public static var name: String {
        let info = Bundle.main.infoDictionary
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = info?[key] as? String, !value.isEmpty {
                return value
            }
        }
        return ProcessInfo.processInfo.processName
    }

    /// Which release channel produced this build, stamped into `ThreadingBuildChannel` at
    /// archive time. See `BuildChannel` for why the answer is `.dev` unless a release
    /// deliberately said otherwise.
    public static var buildChannel: BuildChannel {
        BuildChannel(infoValue: Bundle.main.infoDictionary?["ThreadingBuildChannel"])
    }

    /// The human version — `0.0.0` on any build a release did not stamp, which is a useful
    /// tell rather than a bug (see `docs/architecture/releasing.md`).
    public static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? AppInfoDefaults.unknownVersion
    }

    /// The build number beside it, stamped from `CURRENT_PROJECT_VERSION` and standing still for
    /// the same reason on a build nobody released.
    public static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? AppInfoDefaults.unknownVersion
    }

    /// The pair, spelled the one way every surface spells it: `1.4.0 (212)`.
    ///
    /// `EventLog`, the issue submitters and `BuildFingerprint` each built this string themselves
    /// before it had a name. Punctuation rather than copy, so it is composed rather than
    /// localized.
    public static var versionSummary: String {
        "\(marketingVersion) (\(buildNumber))"
    }
}

public enum AppInfoDefaults {
    /// What an unstamped build reports. Matches the project file's own placeholder, so the
    /// fallback and the real default read alike instead of one of them looking like an error.
    public static let unknownVersion = "0.0.0"
}

/// The release channel a build was made for.
///
/// The value travels the same road as the version: `scripts/release.sh` passes
/// `THREADING_CHANNEL` to `xcodebuild archive` and `Info.plist` carries it as
/// `$(THREADING_CHANNEL)`, so the project file never changes per release. Every build made
/// without the injection — a local build, a plain `xcodebuild` — expands the placeholder to the
/// empty string, which lands on `.dev`: a build can no more claim to be a release by accident
/// than it can carry a real version, the same reasoning that made the version placeholder
/// `0.0.0` (see `docs/architecture/releasing.md`).
///
/// A value the enum does not know also lands on `.dev`, because whatever such a build is, it is
/// not one the release pipeline shipped.
public enum BuildChannel: String, CaseIterable {
    case dev
    case nightly
    case beta
    case release

    public init(infoValue: Any?) {
        self = (infoValue as? String).flatMap(BuildChannel.init(rawValue:)) ?? .dev
    }

    /// Whether a build on this channel offers Hosted Direct — Threading Direct's Sign in with
    /// Apple enrollment, hosted rendezvous and TURN, hosted push, hosted device credentials and
    /// the hosted pairing link.
    ///
    /// Remote Access itself ships on every channel. Its local ways in — This network, Through a
    /// VPN, Tailscale and the Tailscale Serve browser convenience — are listeners this Mac binds
    /// and certificates it holds, so a notarized build can pair the Threading iPhone app with
    /// nothing the distribution method withholds. They stay off until the person turns Remote
    /// Access on.
    ///
    /// Hosted Direct cannot ship that way. Enrolling the Mac as a host needs
    /// `com.apple.developer.applesignin`, and that entitlement never reaches a Developer ID
    /// provisioning profile — see `releasing.md`, "Sign in with Apple cannot be shipped by
    /// Developer ID". A public build therefore builds an inert hosted controller: no endpoint, an
    /// in-memory store, no Keychain read of a development build's hosted record and no request to
    /// the hosted service. Its Settings page omits the Hosted Direct row rather than offering a
    /// sign-in button that cannot work.
    ///
    /// `.dev` is the channel every uninjected build lands on, so working on Hosted Direct needs
    /// no flag: build it the ordinary way and it is there.
    public var offersHostedDirect: Bool {
        switch self {
        case .dev: true
        case .nightly, .beta, .release: false
        }
    }

    /// What a channel mark means, spelled out — the honest sentence behind an abbreviation the
    /// sidebar shouts in three letters. `nil` for the release build, which wears no mark at all.
    public var spokenName: String? {
        switch self {
        case .release: nil
        case .nightly: L10n.string("Nightly build")
        case .beta: L10n.string("Beta build")
        case .dev: L10n.string("Development build")
        }
    }
}
