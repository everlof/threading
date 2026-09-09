import Foundation
import ThreadingPluginKit

/// A native navigator declared by static bundle metadata, before its executable is mapped.
struct NativeWorkspaceNavigatorDescriptor: Equatable, Sendable {
    let pluginIdentifier: String
    let pluginName: String
    let navigatorID: String
    let title: String
    let preferredWidth: Int?
    let bundleURL: URL
    let isBundled: Bool
    /// The complete signed build that supplied installed metadata. `nil` only for code sealed
    /// inside the host bundle. Loading re-reads this identity so a replacement cannot inherit a
    /// stale route or approval between discovery and selection.
    let verifiedInstalledIdentity: PluginLoader.PluginIdentity?

    var selection: WorkspaceNavigatorSelection {
        .nativePluginNavigator(
            pluginIdentifier: pluginIdentifier,
            navigatorID: navigatorID
        )
    }
}

/// The bounded, non-executing discovery half of the native navigator tier.
///
/// `Bundle.principalClass` is deliberately absent from this type. Parsing a plist and validating
/// a signature do not map the executable; loading remains `NativePluginCatalog.load`'s separate,
/// approval-gated operation after the user selects a presentation.
enum NativeWorkspaceNavigatorDiscovery {
    static let maximumInfoPlistBytes = 65_536
    static let maximumNavigatorsPerPlugin = 8
    static let maximumIdentityBytes = 1_024
    static let maximumTitleBytes = 512
    static let minimumPreferredWidth = 180
    static let maximumPreferredWidth = 640
    static let maximumCandidates = 64

    private struct RouteIdentity: Hashable {
        let pluginIdentifier: String
        let navigatorID: String
    }

    struct Candidate: Sendable {
        let url: URL
        let isBundled: Bool
    }

    static func inventory(
        candidates: [Candidate],
        installedIdentity: (URL) throws -> PluginLoader.PluginIdentity = PluginLoader.identity
    ) -> [NativeWorkspaceNavigatorDescriptor] {
        var bundled: [NativeWorkspaceNavigatorDescriptor] = []
        var installedByRoute: [RouteIdentity: [NativeWorkspaceNavigatorDescriptor]] = [:]

        // Cap before sorting: this function remains bounded even if a future caller accidentally
        // hands it an unbounded directory result. Production supplies bundled candidates first,
        // followed by installed candidates, each already capped by the catalogue.
        for candidate in candidates.prefix(maximumCandidates).sorted(by: candidateOrder) {
            let verifiedIdentity = candidate.isBundled
                ? nil
                : try? installedIdentity(candidate.url)
            if !candidate.isBundled, verifiedIdentity == nil { continue }

            let found = descriptors(
                at: candidate.url,
                isBundled: candidate.isBundled,
                verifiedInstalledIdentity: verifiedIdentity
            )
            if candidate.isBundled {
                bundled.append(contentsOf: found)
            } else {
                for descriptor in found {
                    let route = RouteIdentity(
                        pluginIdentifier: descriptor.pluginIdentifier,
                        navigatorID: descriptor.navigatorID
                    )
                    installedByRoute[route, default: []].append(descriptor)
                }
            }
        }

        // A provider identifier owned by the sealed application owns its whole navigator
        // namespace. Installed code cannot append a route beneath it. For installed providers,
        // two bundles claiming one route are ambiguous and both disappear instead of file-system
        // order silently choosing which code the persisted identity will load.
        let bundledProviders = Set(bundled.map(\.pluginIdentifier))
        var seenBundledRoutes = Set<RouteIdentity>()
        let uniqueBundled = bundled.filter {
            seenBundledRoutes.insert(RouteIdentity(
                pluginIdentifier: $0.pluginIdentifier,
                navigatorID: $0.navigatorID
            )).inserted
        }
        let uniqueInstalled: [NativeWorkspaceNavigatorDescriptor] =
            installedByRoute.values.compactMap { descriptors in
            guard descriptors.count == 1,
                  let descriptor = descriptors.first,
                  !bundledProviders.contains(descriptor.pluginIdentifier)
            else { return nil }
            return descriptor
        }
        return (uniqueBundled + uniqueInstalled).sorted(by: descriptorOrder)
    }

    static func descriptors(
        at bundleURL: URL,
        isBundled: Bool,
        verifiedInstalledIdentity: PluginLoader.PluginIdentity? = nil
    ) -> [NativeWorkspaceNavigatorDescriptor] {
        // Installed metadata is never meaningful without the signature that binds it to bytes.
        guard isBundled || verifiedInstalledIdentity != nil else { return [] }
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macInfo = contents.appendingPathComponent("Info.plist")
        let flatInfo = bundleURL.appendingPathComponent("Info.plist")
        let infoURL = FileManager.default.fileExists(atPath: macInfo.path) ? macInfo : flatInfo

        // The descriptor directory is externally writable. Reading from one opened handle with a
        // byte cap closes the stat/read race where a file could grow after its size was checked.
        guard let handle = try? FileHandle(forReadingFrom: infoURL) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumInfoPlistBytes + 1),
              !data.isEmpty,
              data.count <= maximumInfoPlistBytes,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = root as? [String: Any]
        else { return [] }

        return descriptors(
            in: plist,
            bundleURL: bundleURL,
            isBundled: isBundled,
            verifiedInstalledIdentity: verifiedInstalledIdentity
        )
    }

    static func descriptors(
        in plist: [String: Any],
        bundleURL: URL,
        isBundled: Bool,
        verifiedInstalledIdentity: PluginLoader.PluginIdentity?
    ) -> [NativeWorkspaceNavigatorDescriptor] {
        guard isBundled || verifiedInstalledIdentity != nil,
              let declaredIdentifier = boundedString(
            plist["CFBundleIdentifier"],
            maximumBytes: maximumIdentityBytes
        ) else { return [] }

        // The code-signing identity is authoritative for installed code. Refuse metadata whose
        // bundle identifier claims another identity before it can become a persisted route.
        if let verifiedInstalledIdentity,
           verifiedInstalledIdentity.bundleIdentifier != declaredIdentifier {
            return []
        }

        let pluginName = boundedString(
            plist["CFBundleDisplayName"],
            maximumBytes: maximumTitleBytes
        ) ?? boundedString(plist["CFBundleName"], maximumBytes: maximumTitleBytes)
            ?? declaredIdentifier
        guard let declarations = plist[PluginBundleMetadata.workspaceNavigators]
            as? [[String: Any]] else { return [] }

        var seenIDs = Set<String>()
        return declarations.prefix(maximumNavigatorsPerPlugin).compactMap { declaration in
            guard let navigatorID = boundedString(
                declaration[PluginBundleMetadata.identifier],
                maximumBytes: maximumIdentityBytes
            ),
                  seenIDs.insert(navigatorID).inserted,
                  let title = boundedString(
                    declaration[PluginBundleMetadata.title],
                    maximumBytes: maximumTitleBytes
                  )
            else { return nil }

            let preferredWidth: Int?
            if let rawWidth = declaration[PluginBundleMetadata.preferredWidth] {
                guard let width = rawWidth as? Int,
                      (minimumPreferredWidth...maximumPreferredWidth).contains(width)
                else { return nil }
                preferredWidth = width
            } else {
                preferredWidth = nil
            }
            return NativeWorkspaceNavigatorDescriptor(
                pluginIdentifier: declaredIdentifier,
                pluginName: pluginName,
                navigatorID: navigatorID,
                title: title,
                preferredWidth: preferredWidth,
                bundleURL: bundleURL,
                isBundled: isBundled,
                verifiedInstalledIdentity: verifiedInstalledIdentity
            )
        }
    }

    /// Revalidates an installed descriptor immediately before selection/load. The full identity,
    /// including cdHash, means changed bytes are a different build even when the bundle identifier
    /// and signer stay the same.
    static func installedBuildStillMatches(
        _ descriptor: NativeWorkspaceNavigatorDescriptor,
        identity: (URL) throws -> PluginLoader.PluginIdentity = PluginLoader.identity
    ) -> Bool {
        guard !descriptor.isBundled,
              let discoveredIdentity = descriptor.verifiedInstalledIdentity,
              let currentIdentity = try? identity(descriptor.bundleURL)
        else { return descriptor.isBundled }
        return currentIdentity == discoveredIdentity
    }

    private static func candidateOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.isBundled != rhs.isBundled { return lhs.isBundled }
        return lhs.url.standardizedFileURL.path < rhs.url.standardizedFileURL.path
    }

    private static func descriptorOrder(
        _ lhs: NativeWorkspaceNavigatorDescriptor,
        _ rhs: NativeWorkspaceNavigatorDescriptor
    ) -> Bool {
        if lhs.isBundled != rhs.isBundled { return lhs.isBundled }
        if lhs.pluginName != rhs.pluginName { return lhs.pluginName < rhs.pluginName }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        if lhs.pluginIdentifier != rhs.pluginIdentifier {
            return lhs.pluginIdentifier < rhs.pluginIdentifier
        }
        return lhs.navigatorID < rhs.navigatorID
    }

    private static func boundedString(_ value: Any?, maximumBytes: Int) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              trimmed.utf8.count <= maximumBytes,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator:
                      return false
                  default:
                      return true
                  }
              })
        else { return nil }
        return trimmed
    }
}

struct NativeWorkspaceNavigatorsDidChange: AppEvent {
    static let name = Notification.Name("nativeWorkspaceNavigatorsDidChange")
}

/// Main-actor cache for menus and windows; all file and signature work runs on a bounded worker.
@MainActor
final class NativeWorkspaceNavigatorRegistry {
    static let shared = NativeWorkspaceNavigatorRegistry()

    typealias Discover = @Sendable (Bool) -> [NativeWorkspaceNavigatorDescriptor]

    private(set) var inventory: [NativeWorkspaceNavigatorDescriptor] = []
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private let discover: Discover

    init(
        inventory: [NativeWorkspaceNavigatorDescriptor] = [],
        discover: @escaping Discover = {
            NativeWorkspaceNavigatorRegistry.discoverInventory(includeInstalled: $0)
        }
    ) {
        self.inventory = inventory
        self.discover = discover
    }

    func descriptor(
        pluginIdentifier: String,
        navigatorID: String
    ) -> NativeWorkspaceNavigatorDescriptor? {
        inventory.first {
            $0.pluginIdentifier == pluginIdentifier && $0.navigatorID == navigatorID
        }
    }

    func refresh(includeInstalled: Bool = true) {
        generation &+= 1
        let requestedGeneration = generation
        let discover = discover
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .utility) {
                discover(includeInstalled)
            }.value
            guard let self,
                  !Task.isCancelled,
                  requestedGeneration == self.generation else { return }
            self.refreshTask = nil
            guard discovered != self.inventory else { return }
            self.inventory = discovered
            NotificationCenter.default.post(NativeWorkspaceNavigatorsDidChange())
        }
    }

    private nonisolated static func discoverInventory(
        includeInstalled: Bool
    ) -> [NativeWorkspaceNavigatorDescriptor] {
        var candidates = NativePluginCatalog.bundledPlugins().map {
            NativeWorkspaceNavigatorDiscovery.Candidate(url: $0, isBundled: true)
        }
        if includeInstalled {
            candidates.append(contentsOf: NativePluginCatalog.installedBundles().map {
                NativeWorkspaceNavigatorDiscovery.Candidate(url: $0, isBundled: false)
            })
        }
        return NativeWorkspaceNavigatorDiscovery.inventory(candidates: candidates)
    }
}
