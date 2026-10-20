import Foundation

/// A local receipt is only a pointer to the signed release manifest. Recheck the manifest,
/// host build, notarized bundle and the staged loader identity on every admission. A writable
/// receipt alone never makes code first-party.
enum NativePluginManagedReceipt {
    static func isManagedLocation(
        _ bundle: URL,
        directory: URL = NativePluginManagedPaths.directory
    ) -> Bool {
        guard bundle.deletingLastPathComponent().standardizedFileURL.path ==
                  directory.standardizedFileURL.path,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: bundle.path)) != nil
        else { return false }
        let versions = NativePluginManagedPaths.managedDirectory(in: directory)
            .appendingPathComponent("versions", isDirectory: true)
            .resolvingSymlinksInPath()
        return bundle.resolvingSymlinksInPath().path.hasPrefix(versions.path + "/")
    }

    static func approves(
        bundle: URL,
        identifier: String,
        team: String?,
        codeDirectoryHash: String,
        app: URL = Bundle.main.bundleURL,
        directory: URL = NativePluginManagedPaths.directory,
        expectedResolvedBundle: URL? = nil
    ) -> Bool {
        guard team == NativePluginManagedCode.teamIdentifier,
              isManagedLocation(bundle, directory: directory) else {
            return false
        }

        let resolved = bundle.resolvingSymlinksInPath()
        if let expectedResolvedBundle,
           resolved.standardizedFileURL != expectedResolvedBundle.standardizedFileURL {
            return false
        }
        let manifestFile = resolved.deletingLastPathComponent()
            .appendingPathComponent("manifest.json")
        guard let handle = try? FileHandle(forReadingFrom: manifestFile) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024 + 1),
              !data.isEmpty, data.count <= 64 * 1024,
              let distribution = try? NativePluginDistribution.verify(data, for: app),
              let plugin = distribution.plugins.first(where: {
                  $0.bundleIdentifier == identifier &&
                      $0.bundleName == bundle.lastPathComponent &&
                      $0.codeDirectoryHash == codeDirectoryHash
              }),
              (try? NativePluginManagedCode.verify(
                  bundle: resolved,
                  expectedIdentifier: plugin.bundleIdentifier,
                  expectedCodeDirectoryHash: plugin.codeDirectoryHash
              )) != nil else {
            return false
        }
        return true
    }
}
