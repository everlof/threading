import Foundation

/// What the application calls itself, read from the bundle rather than written down.
///
/// The name reaches text the user reads — a settings subtitle, the name a transition preview
/// morphs a style's name into — and a literal in each of those is one more place to miss when
/// the product is renamed. `CFBundleDisplayName` is what the Finder shows when a bundle sets
/// it, `CFBundleName` is what every bundle has, and the process name is the honest answer for
/// a binary running outside a bundle.
enum AppInfo {

    static var name: String {
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
    static var buildChannel: BuildChannel {
        BuildChannel(infoValue: Bundle.main.infoDictionary?["ThreadingBuildChannel"])
    }
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
enum BuildChannel: String, CaseIterable {
    case dev
    case nightly
    case beta
    case release

    init(infoValue: Any?) {
        self = (infoValue as? String).flatMap(BuildChannel.init(rawValue:)) ?? .dev
    }
}
