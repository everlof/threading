import Foundation
import ThreadingExtensionKit

/// The deliberately small catalogue shipped by Threading itself.
///
/// This is not a marketplace or a remotely mutable feed. The app binary names each entry and
/// its source repository, while the installable package is a resource covered by the app's code
/// signature. Opening Settings therefore performs no discovery or network request. A Git URL is
/// provenance people can inspect; it is never cloned, built, or executed by Threading.
struct FirstPartyExtensionCatalog: Equatable, Sendable {
    static let maximumEntries = 16

    enum CatalogError: LocalizedError, Equatable {
        case tooManyEntries(maximum: Int)
        case duplicateIdentifier(String)
        case invalidIdentifier(String)
        case invalidName(String)
        case invalidVersion(String)
        case invalidSummary(String)
        case invalidRepositoryURL(String)
        case invalidPackageURL(String)
        case packageDoesNotMatch(String)

        var errorDescription: String? {
            switch self {
            case .tooManyEntries(let maximum):
                return L10n.format(
                    "The first-party extension catalogue contains more than %lld entries.",
                    Int64(maximum)
                )
            case .duplicateIdentifier(let identifier):
                return L10n.format(
                    "The first-party extension catalogue repeats %@.",
                    identifier
                )
            case .invalidIdentifier(let identifier):
                return L10n.format(
                    "The first-party extension catalogue has an invalid identifier: %@.",
                    identifier
                )
            case .invalidName(let name):
                return L10n.format(
                    "The first-party extension catalogue has an invalid name: %@.",
                    name
                )
            case .invalidVersion(let version):
                return L10n.format(
                    "The first-party extension catalogue has an invalid version: %@.",
                    version
                )
            case .invalidSummary(let summary):
                return L10n.format(
                    "The first-party extension catalogue has an invalid summary: %@.",
                    summary
                )
            case .invalidRepositoryURL(let value):
                return L10n.format(
                    "The first-party extension catalogue has an invalid source URL: %@.",
                    value
                )
            case .invalidPackageURL(let value):
                return L10n.format(
                    "The first-party extension catalogue has an invalid package URL: %@.",
                    value
                )
            case .packageDoesNotMatch(let identifier):
                return L10n.format(
                    "The included package does not match the catalogue entry for %@.",
                    identifier
                )
            }
        }
    }

    struct Entry: Equatable, Sendable {
        static let maximumNameBytes = 120
        static let maximumVersionBytes = 64
        static let maximumSummaryBytes = 500
        let identifier: String
        let name: String
        let version: String
        let summary: String
        let repositoryURL: URL
        let packageURL: URL

        init(
            identifier: String,
            name: String,
            version: String,
            summary: String,
            repositoryURL: URL,
            packageURL: URL
        ) throws {
            guard ExtensionIdentifierRules.isReverseDNSIdentifier(identifier) else {
                throw CatalogError.invalidIdentifier(identifier)
            }
            guard Self.isBoundedText(name, maximumBytes: Self.maximumNameBytes) else {
                throw CatalogError.invalidName(name)
            }
            guard Self.isBoundedText(version, maximumBytes: Self.maximumVersionBytes) else {
                throw CatalogError.invalidVersion(version)
            }
            guard Self.isBoundedText(summary, maximumBytes: Self.maximumSummaryBytes) else {
                throw CatalogError.invalidSummary(summary)
            }
            guard ExtensionInstallSource.isSafeRepositoryURL(repositoryURL) else {
                throw CatalogError.invalidRepositoryURL(repositoryURL.absoluteString)
            }
            guard packageURL.isFileURL,
                  packageURL.pathExtension == ExtensionPackageStore.packageExtension,
                  packageURL.lastPathComponent.utf8.count <= 255 else {
                throw CatalogError.invalidPackageURL(packageURL.absoluteString)
            }

            self.identifier = identifier
            self.name = name
            self.version = version
            self.summary = summary
            self.repositoryURL = repositoryURL
            self.packageURL = packageURL
        }

        var installSource: ExtensionInstallSource {
            .firstPartyCatalog(repositoryURL: repositoryURL)
        }

        func validate(_ bundle: ThreadingExtensionBundle) throws {
            guard bundle.manifest.identifier == identifier,
                  bundle.manifest.name == name,
                  bundle.manifest.version == version else {
                throw CatalogError.packageDoesNotMatch(identifier)
            }
        }

        func validate(_ plan: ExtensionUpdatePlan) throws {
            guard plan.identifier == identifier,
                  plan.candidateName == name,
                  plan.candidateVersion == version else {
                throw CatalogError.packageDoesNotMatch(identifier)
            }
        }

        private static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && trimmed == value
                && value.utf8.count <= maximumBytes
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }

    }

    let entries: [Entry]
    let problem: String?

    init(entries: [Entry]) throws {
        guard entries.count <= Self.maximumEntries else {
            throw CatalogError.tooManyEntries(maximum: Self.maximumEntries)
        }
        var identifiers: Set<String> = []
        for entry in entries where !identifiers.insert(entry.identifier).inserted {
            throw CatalogError.duplicateIdentifier(entry.identifier)
        }
        self.entries = entries
        self.problem = nil
    }

    private init(problem: String) {
        entries = []
        self.problem = problem
    }

    static func appOwned(bundle: Bundle = .main) -> Self {
        guard let resources = bundle.resourceURL else {
            return Self(problem: L10n.string(
                "Threading's included extension resources are unavailable."
            ))
        }
        do {
            let package = resources
                .appendingPathComponent("FirstPartyExtensions", isDirectory: true)
                .appendingPathComponent(
                    "codes.threading.storm.threadingextension",
                    isDirectory: true
                )
            let source = try requiredURL(
                "https://github.com/everlof/threading/tree/master/"
                    + "Packages/ThreadingExtensionKit/Examples/StormThemeExtension"
            )
            return try Self(entries: [
                Entry(
                    identifier: "codes.threading.storm",
                    name: "Storm",
                    version: "0.1.0",
                    summary: L10n.string("Rain-blue chrome for long sessions."),
                    repositoryURL: source,
                    packageURL: package
                )
            ])
        } catch {
            ThreadingLogger.extensions.error(
                "First-party extension catalogue is invalid: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return Self(problem: error.localizedDescription)
        }
    }

    private static func requiredURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw CatalogError.invalidRepositoryURL(value)
        }
        return url
    }
}
