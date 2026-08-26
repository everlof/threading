import Foundation

/// The installed generation shared by Threading and the PTY host embedded inside it.
///
/// Protocol versions answer whether two processes can communicate. This value answers the
/// separate upgrade question: whether the already-running daemon came from the app bundle now
/// on disk. Releases move the two bundle versions; the local autoinstaller deliberately leaves
/// those at `0.0.0`, so its source revision is the generation that distinguishes one installed
/// commit from the next.
public enum PTYHostGeneration {
    public static let unknown = "?"

    public static func string(
        shortVersion: String?,
        bundleVersion: String?,
        sourceRevision: String?
    ) -> String {
        let short = nonempty(shortVersion) ?? unknown
        let bundle = nonempty(bundleVersion) ?? unknown
        let version = "\(short) (\(bundle))"
        guard let revision = nonempty(sourceRevision) else { return version }
        return "\(version) @\(revision)"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
