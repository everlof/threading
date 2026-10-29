import Foundation
import ThreadingPluginKit

/// One signed bundle's static, versioned pane declaration. Discovery never maps plugin code.
struct NativePluginPaneDescriptor: Equatable, Sendable {
    enum Placement: String, Sendable { case panel, drawer }
    enum Context: String, Sendable { case selectedDevice = "selected-device" }

    struct Route: Equatable, Sendable {
        let identifier: String
        let section: String
        let placement: Placement
        let context: Context
    }

    struct Command: Equatable, Sendable {
        let title: String
        let symbol: String
        let detail: String?
    }

    struct Section: Equatable, Sendable {
        let identifier: String
        let title: String
        let command: Command?
    }

    let bundleURL: URL
    let pluginIdentifier: String
    let sections: [Section]
    let routes: [Route]
    let verifiedInstalledIdentity: PluginLoader.PluginIdentity?

    var primarySection: String { sections[0].identifier }
    func contains(_ section: String) -> Bool { sections.contains { $0.identifier == section } }
    func route(_ identifier: String) -> Route? {
        routes.first { $0.identifier == identifier }
    }
}

enum NativePluginPaneDiscovery {
    private static let maximumInfoPlistBytes = 65_536
    private static let maximumSections = 8
    private static let maximumRoutes = 8
    private static let identifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    static func inventory(bundled: [URL], installed: [URL]) -> [NativePluginPaneDescriptor] {
        let sealed = bundled.prefix(32).compactMap { url -> NativePluginPaneDescriptor? in
            guard let pane = descriptor(at: url, isBundled: true),
                  agreesWithManagedOffer(pane) else { return nil }
            return pane
        }
        let sealedIdentifiers = Set(sealed.map(\.pluginIdentifier))
        let signed = installed.prefix(32).compactMap { url -> NativePluginPaneDescriptor? in
            guard let identity = try? PluginLoader.identity(of: url),
                  let pane = descriptor(at: url, isBundled: false,
                                        verifiedInstalledIdentity: identity),
                  !sealedIdentifiers.contains(pane.pluginIdentifier),
                  agreesWithManagedOffer(pane) else { return nil }
            if NativePluginManagedOffer.all.contains(where: {
                $0.identifier == pane.pluginIdentifier || $0.bundleName == url.lastPathComponent
            }) {
                guard NativePluginManagedReceipt.approves(
                    bundle: url, identifier: identity.bundleIdentifier,
                    team: identity.team, codeDirectoryHash: identity.cdHash
                ) else { return nil }
            }
            return pane
        }
        let counts = Dictionary(signed.map { ($0.pluginIdentifier, 1) },
                                uniquingKeysWith: +)
        return sealed + signed.filter { counts[$0.pluginIdentifier] == 1 }
    }

    private static func agreesWithManagedOffer(_ pane: NativePluginPaneDescriptor) -> Bool {
        guard let offer = NativePluginManagedOffer.all.first(where: {
            $0.identifier == pane.pluginIdentifier
        }), !offer.paneSections.isEmpty else { return true }
        guard offer.paneSections.map(\.identifier) == pane.sections.map(\.identifier) else {
            return false
        }
        guard zip(offer.paneSections, pane.sections).allSatisfy({ expected, declared in
            guard expected.titleKey == declared.title else { return false }
            switch (expected.command, declared.command) {
            case (nil, nil): return true
            case (let command?, let metadata?):
                return command.titleKey == metadata.title &&
                    command.symbol == metadata.symbol &&
                    command.detailKey == metadata.detail
            default: return false
            }
        }) else { return false }
        return offer.paneRoutes.count == pane.routes.count &&
            zip(offer.paneRoutes, pane.routes).allSatisfy { expected, declared in
                expected.identifier == declared.identifier &&
                    expected.section == declared.section &&
                    expected.placement.rawValue == declared.placement.rawValue &&
                    expected.context.rawValue == declared.context.rawValue
            }
    }

    static func descriptor(
        at bundleURL: URL,
        isBundled: Bool,
        verifiedInstalledIdentity: PluginLoader.PluginIdentity? = nil
    ) -> NativePluginPaneDescriptor? {
        guard isBundled || verifiedInstalledIdentity != nil else { return nil }
        let macInfo = bundleURL.appendingPathComponent("Contents/Info.plist")
        let flatInfo = bundleURL.appendingPathComponent("Info.plist")
        let infoURL = FileManager.default.fileExists(atPath: macInfo.path) ? macInfo : flatInfo
        guard let handle = try? FileHandle(forReadingFrom: infoURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumInfoPlistBytes + 1),
              !data.isEmpty, data.count <= maximumInfoPlistBytes,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        return descriptor(in: plist, bundleURL: bundleURL,
                          verifiedInstalledIdentity: verifiedInstalledIdentity)
    }

    static func descriptor(
        in plist: [String: Any],
        bundleURL: URL,
        verifiedInstalledIdentity: PluginLoader.PluginIdentity?
    ) -> NativePluginPaneDescriptor? {
        guard let identifier = boundedIdentifier(plist["CFBundleIdentifier"]),
              verifiedInstalledIdentity?.bundleIdentifier == nil ||
                verifiedInstalledIdentity?.bundleIdentifier == identifier,
              let declaration = plist[PluginBundleMetadata.paneSections] as? [String: Any],
              declaration[PluginBundleMetadata.schemaVersion] as? Int ==
                PluginBundleMetadata.paneSectionsVersion,
              let rawSections = declaration[PluginBundleMetadata.sections] as? [[String: Any]],
              !rawSections.isEmpty, rawSections.count <= maximumSections else { return nil }

        var seen = Set<String>()
        var sections: [NativePluginPaneDescriptor.Section] = []
        for raw in rawSections {
            guard let sectionID = boundedIdentifier(raw[PluginBundleMetadata.identifier]),
                  seen.insert(sectionID).inserted,
                  let title = bounded(raw[PluginBundleMetadata.title], maximumBytes: 512)
            else { return nil }
            let command: NativePluginPaneDescriptor.Command?
            if let rawCommand = raw[PluginBundleMetadata.command] {
                guard let values = rawCommand as? [String: Any],
                      let commandTitle = bounded(values[PluginBundleMetadata.title], maximumBytes: 512),
                      let symbol = boundedIdentifier(values[PluginBundleMetadata.symbol]),
                      values[PluginBundleMetadata.detail] == nil ||
                        bounded(values[PluginBundleMetadata.detail], maximumBytes: 1_024) != nil
                else { return nil }
                command = .init(title: commandTitle, symbol: symbol,
                                detail: values[PluginBundleMetadata.detail] as? String)
            } else {
                command = nil
            }
            sections.append(.init(identifier: sectionID, title: title, command: command))
        }
        guard let routes = routes(in: declaration, sections: seen) else { return nil }
        return .init(bundleURL: bundleURL, pluginIdentifier: identifier,
                     sections: sections, routes: routes,
                     verifiedInstalledIdentity: verifiedInstalledIdentity)
    }

    private static func routes(
        in declaration: [String: Any], sections: Set<String>
    ) -> [NativePluginPaneDescriptor.Route]? {
        let rawRoutes: [[String: Any]]
        if let declared = declaration[PluginBundleMetadata.routes] as? [[String: Any]] {
            rawRoutes = declared
        } else if declaration[PluginBundleMetadata.routes] == nil {
            rawRoutes = []
        } else {
            return nil
        }
        guard rawRoutes.count <= maximumRoutes else { return nil }
        var seen = Set<String>()
        var routes: [NativePluginPaneDescriptor.Route] = []
        for raw in rawRoutes {
            guard let identifier = boundedIdentifier(raw[PluginBundleMetadata.identifier]),
                  seen.insert(identifier).inserted,
                  let section = boundedIdentifier(raw[PluginBundleMetadata.section]),
                  sections.contains(section),
                  let placementName = raw[PluginBundleMetadata.placement] as? String,
                  let placement = NativePluginPaneDescriptor.Placement(rawValue: placementName),
                  let contextName = raw[PluginBundleMetadata.context] as? String,
                  let context = NativePluginPaneDescriptor.Context(rawValue: contextName)
            else { return nil }
            routes.append(.init(identifier: identifier, section: section,
                                placement: placement, context: context))
        }
        return routes
    }

    private static func bounded(_ value: Any?, maximumBytes: Int) -> String? {
        guard let value = value as? String,
              !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= maximumBytes,
              value.unicodeScalars.allSatisfy({
                  switch $0.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator: return false
                  default: return true
                  }
              })
        else { return nil }
        return value
    }

    private static func boundedIdentifier(_ value: Any?) -> String? {
        guard let value = bounded(value, maximumBytes: 128),
              value.unicodeScalars.allSatisfy(identifierCharacters.contains) else { return nil }
        return value
    }
}
