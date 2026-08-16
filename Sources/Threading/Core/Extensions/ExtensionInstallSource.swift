import Foundation

/// Host-owned classification of the package source used for installation or update.
///
/// The source changes provenance wording only. It never changes inspection, capability review,
/// runtime containment, or enablement. Keeping it out of the manifest prevents an extension from
/// declaring itself first-party.
enum ExtensionInstallSource: Equatable, Sendable {
    static let maximumRepositoryURLBytes = 2_048

    case localImport
    case firstPartyCatalog(repositoryURL: URL)

    static func isSafeRepositoryURL(_ url: URL) -> Bool {
        url.absoluteString.utf8.count <= maximumRepositoryURLBytes
            && url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
            && url.port == nil
            && url.query == nil
            && url.fragment == nil
    }
}
