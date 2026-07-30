import Foundation
import ThreadingExtensionKit

/// An extension's declared version, compared component by component.
///
/// Deliberately not a full semantic-version implementation: the only question asked of it is
/// "is this the same, newer, older, or not comparable", and a manifest may legitimately carry a
/// version string this cannot order. Guessing an order for `1.0-beta` versus `1.0` would be
/// worse than saying so.
struct ExtensionVersion: Equatable {
    enum Comparison: Equatable {
        case same
        case newer
        case older
        /// At least one side is not a dotted sequence of integers.
        case incomparable
    }

    let raw: String
    private let components: [Int]?

    init(_ raw: String) {
        self.raw = raw
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.map { Int($0) }
        components = numbers.allSatisfy { $0 != nil } && !numbers.isEmpty
            ? numbers.compactMap { $0 }
            : nil
    }

    /// How `self` relates to `other`.
    func compared(to other: ExtensionVersion) -> Comparison {
        guard let mine = components, let theirs = other.components else {
            return raw == other.raw ? .same : .incomparable
        }
        // Trailing zeros are not a difference: 1.2 and 1.2.0 are the same release.
        let width = max(mine.count, theirs.count)
        for index in 0..<width {
            let left = index < mine.count ? mine[index] : 0
            let right = index < theirs.count ? theirs[index] : 0
            if left != right {
                return left > right ? .newer : .older
            }
        }
        return .same
    }
}

/// What replacing an installed extension with a candidate would change.
///
/// The point of computing this before acting is the capability delta. `HANDOFF.md` requires a
/// capability change to be visible before an update is enabled, and an update is exactly where
/// that is easiest to miss: the user approved a panel extension last month and today's version
/// also wants `network.client` and `storage.secrets`.
struct ExtensionUpdatePlan: Equatable {
    let identifier: String
    let installedVersion: String
    let candidateVersion: String
    let versionChange: ExtensionVersion.Comparison
    let installedDataVersion: Int
    let candidateDataVersion: Int
    /// Sorted for a stable presentation; a set would render in a different order each time.
    let addedCapabilities: [ExtensionCapability]
    let removedCapabilities: [ExtensionCapability]
    /// Companion presence, background activation, and OS-facing capabilities are approved
    /// independently from the WebAssembly core's host authority.
    let addedCompanionAuthorities: [String]
    let removedCompanionAuthorities: [String]
    /// A hash of the source package's contents when the plan was made.
    ///
    /// Part of the plan's identity, so `update(from:approving:)` refuses a source whose *code*
    /// changed even when its manifest did not. Without it the re-check notices a different
    /// capability set and nothing else.
    let sourceDigest: String?

    /// Whether a user has to say yes again.
    ///
    /// Only *added* authority requires it. Losing a capability needs no approval — nobody has to
    /// consent to an extension asking for less — and a version alone changes nothing the user
    /// agreed to.
    var requiresApproval: Bool {
        !addedCapabilities.isEmpty || !addedCompanionAuthorities.isEmpty
    }

    /// True when the candidate is not newer, which is worth showing rather than refusing: a
    /// deliberate rollback is legitimate, and a silent one is how an old vulnerable build comes
    /// back.
    var isReinstallOrRollback: Bool {
        versionChange != .newer
    }

    /// How the plan reads to the person deciding.
    ///
    /// Kept apart from the view controller because this is the sentence the whole feature
    /// exists for, and a sentence assembled inside an `NSAlert` call is a sentence no test ever
    /// reads. Named `confirmation` rather than `description` so it is obvious this is
    /// user-facing text and not a debug dump.
    struct Confirmation: Equatable {
        let title: String
        let message: String
        /// The affirmative button. It names the risk when there is one, because "OK" beside a
        /// list of new permissions is a button people press without reading.
        let acceptTitle: String
    }

    func confirmation(name: String) -> Confirmation {
        var lines: [String] = []

        switch versionChange {
        case .newer:
            lines.append("Version \(installedVersion) → \(candidateVersion).")
        case .older:
            lines.append(
                "This is a downgrade: version \(installedVersion) → \(candidateVersion)."
            )
        case .same:
            lines.append("Reinstalling version \(candidateVersion).")
        case .incomparable:
            lines.append(
                "Version \(installedVersion) → \(candidateVersion), which Threading cannot "
                    + "order — check that this is the build you meant."
            )
        }

        if !addedCapabilities.isEmpty {
            lines.append(
                "It asks for permissions the installed version does not have:\n"
                    + addedCapabilities.map { "  • \($0.rawValue)" }.joined(separator: "\n")
            )
        }
        if !removedCapabilities.isEmpty {
            lines.append(
                "It gives up: " + removedCapabilities.map(\.rawValue).joined(separator: ", ")
            )
        }
        if !addedCompanionAuthorities.isEmpty {
            lines.append(
                "Its advanced companion asks for:\n"
                    + addedCompanionAuthorities.map { "  • \($0)" }.joined(separator: "\n")
            )
        }
        if !removedCompanionAuthorities.isEmpty {
            lines.append(
                "Its companion gives up:\n"
                    + removedCompanionAuthorities.map { "  • \($0)" }.joined(separator: "\n")
            )
        }
        if candidateDataVersion > installedDataVersion {
            lines.append(
                "Stored data schema \(installedDataVersion) → \(candidateDataVersion). "
                    + "The extension migrates before it becomes available."
            )
        }
        // Said plainly, because the alternative people assume is that updating resets things.
        lines.append("Its settings, stored data and secrets are kept.")

        return Confirmation(
            title: requiresApproval
                ? "Update “\(name)” and grant new permissions?"
                : "Update “\(name)”?",
            message: lines.joined(separator: "\n\n"),
            acceptTitle: requiresApproval ? "Grant and Update" : "Update"
        )
    }

    init(
        installed: ExtensionManifest,
        candidate: ExtensionManifest,
        sourceDigest: String? = nil
    ) {
        self.sourceDigest = sourceDigest
        identifier = installed.identifier
        installedVersion = installed.version
        candidateVersion = candidate.version
        installedDataVersion = installed.dataVersion
        candidateDataVersion = candidate.dataVersion
        versionChange = ExtensionVersion(candidate.version)
            .compared(to: ExtensionVersion(installed.version))
        addedCapabilities = candidate.capabilities
            .subtracting(installed.capabilities)
            .sorted { $0.rawValue < $1.rawValue }
        removedCapabilities = installed.capabilities
            .subtracting(candidate.capabilities)
            .sorted { $0.rawValue < $1.rawValue }
        let installedCompanionAuthorities = Self.companionAuthorities(
            installed.companions
        )
        let candidateCompanionAuthorities = Self.companionAuthorities(
            candidate.companions
        )
        addedCompanionAuthorities = candidateCompanionAuthorities
            .subtracting(installedCompanionAuthorities)
            .sorted()
        removedCompanionAuthorities = installedCompanionAuthorities
            .subtracting(candidateCompanionAuthorities)
            .sorted()
    }

    private static func companionAuthorities(
        _ companions: [ExtensionCompanion]
    ) -> Set<String> {
        Set(companions.flatMap { companion in
            var values = ["\(companion.id): native companion app"]
            if companion.activation == .whileExtensionEnabled {
                values.append("\(companion.id): run while enabled")
            }
            values.append(contentsOf: companion.capabilities.map {
                "\(companion.id): \($0.rawValue)"
            })
            return values
        })
    }
}
