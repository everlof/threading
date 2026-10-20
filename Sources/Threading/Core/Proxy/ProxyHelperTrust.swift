import Foundation
import Security

struct ProxyHelperAssets: Sendable {
    let executable: URL
    let setupScript: URL
}

enum ProxyHelperLocation {
    static let executableName = "threading-proxyd"
    static let executableIdentifier = "codes.threading.proxyd"
    static let pluginName = NativePluginManagedOffer.proxy.bundleName
    static let pluginIdentifier = NativePluginManagedOffer.proxy.identifier

    static func bundledPlugin(in app: Bundle = .main) -> URL {
        app.bundleURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
    }

    static func installedPlugin(in directory: URL = NativePluginManagedPaths.directory) -> URL {
        directory.appendingPathComponent(pluginName, isDirectory: true)
    }

    static func assets(in plugin: URL) -> ProxyHelperAssets {
        ProxyHelperAssets(
            executable: plugin.appendingPathComponent("Contents/Helpers", isDirectory: true)
                .appendingPathComponent(executableName),
            setupScript: plugin.appendingPathComponent(
                "Contents/Resources/ProxyTools/apple_certificate.py"
            )
        )
    }
}

enum ProxyHelperTrust {
    static func availableAssets(
        in app: Bundle = .main,
        directory: URL = NativePluginManagedPaths.directory
    ) throws -> ProxyHelperAssets {
        let candidates: [(url: URL, installed: Bool)] = [
            (ProxyHelperLocation.installedPlugin(in: directory), true),
            (ProxyHelperLocation.bundledPlugin(in: app), false),
        ]
        var refusal: Error?
        for candidate in candidates {
            let resolved = candidate.url.resolvingSymlinksInPath()
            let assets = ProxyHelperLocation.assets(in: resolved)
            guard FileManager.default.isExecutableFile(atPath: assets.executable.path) else {
                continue
            }
            do {
                return try verify(
                    plugin: candidate.url, installed: candidate.installed,
                    in: app, directory: directory
                )
            } catch {
                refusal = error
            }
        }
        if let refusal { throw refusal }
        throw ProxyProcess.Failure.message(
            L10n.string("Install Network Proxy in Extensions Settings to capture traffic.")
        )
    }

    static func verify(
        plugin visible: URL,
        installed: Bool,
        in app: Bundle = .main,
        directory: URL = NativePluginManagedPaths.directory
    ) throws -> ProxyHelperAssets {
        let expected = installed
            ? ProxyHelperLocation.installedPlugin(in: directory)
            : ProxyHelperLocation.bundledPlugin(in: app)
        guard visible.standardizedFileURL == expected.standardizedFileURL else {
            throw refusal("The Network Proxy plugin is outside its reserved location.")
        }
        let resolved = visible.resolvingSymlinksInPath().standardizedFileURL
        if !installed, resolved != visible.standardizedFileURL {
            throw refusal("The bundled Network Proxy plugin is a symlink.")
        }
        let assets = ProxyHelperLocation.assets(in: resolved)
        guard assets.executable.resolvingSymlinksInPath() == assets.executable,
              assets.setupScript.resolvingSymlinksInPath() == assets.setupScript,
              FileManager.default.isExecutableFile(atPath: assets.executable.path),
              FileManager.default.isReadableFile(atPath: assets.setupScript.path) else {
            throw refusal("The Network Proxy plugin has missing or redirected payload files.")
        }

        let pluginCode = try staticCode(at: resolved)
        let flags = SecCSFlags(rawValue:
            kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(pluginCode, flags, nil) == errSecSuccess else {
            throw refusal("The Network Proxy plugin has an invalid code signature.")
        }
        let pluginIdentity = try signingInformation(pluginCode)
        guard pluginIdentity[kSecCodeInfoIdentifier as String] as? String
            == ProxyHelperLocation.pluginIdentifier else {
            throw refusal("The Network Proxy plugin has an unexpected identifier.")
        }
        if installed {
            let team = pluginIdentity[kSecCodeInfoTeamIdentifier as String] as? String
            let hash = (pluginIdentity[kSecCodeInfoUnique as String] as? Data)?
                .map { String(format: "%02x", $0) }.joined()
            guard let hash,
                  NativePluginManagedReceipt.approves(
                    bundle: visible,
                    identifier: ProxyHelperLocation.pluginIdentifier,
                    team: team,
                    codeDirectoryHash: hash,
                    app: app.bundleURL,
                    directory: directory,
                    expectedResolvedBundle: resolved
                  ) else {
                throw refusal("The installed Network Proxy plugin does not match this Threading release.")
            }
        }

        let helperCode = try staticCode(at: assets.executable)
        guard SecStaticCodeCheckValidity(helperCode, flags, nil) == errSecSuccess else {
            throw refusal("The Network Proxy helper has an invalid code signature.")
        }
        let helperIdentity = try signingInformation(helperCode)
        guard helperIdentity[kSecCodeInfoIdentifier as String] as? String
            == ProxyHelperLocation.executableIdentifier else {
            throw refusal("The Network Proxy helper has an unexpected identifier.")
        }
        guard let hostExecutable = app.executableURL else {
            throw refusal("Threading could not inspect its own code signature.")
        }
        let hostIdentity = try signingInformation(staticCode(at: hostExecutable))
        let hostTeam = hostIdentity[kSecCodeInfoTeamIdentifier as String] as? String
        let pluginTeam = pluginIdentity[kSecCodeInfoTeamIdentifier as String] as? String
        let helperTeam = helperIdentity[kSecCodeInfoTeamIdentifier as String] as? String
        guard hostTeam == pluginTeam, pluginTeam == helperTeam else {
            throw refusal("Threading and its Network Proxy plugin are signed by different teams.")
        }
        return assets
    }

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { throw refusal("Threading could not inspect Network Proxy code.") }
        return code
    }

    private static func signingInformation(_ code: SecStaticCode) throws -> [String: Any] {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess,
              let information = information as? [String: Any] else {
            throw refusal("Threading could not inspect the Network Proxy signature.")
        }
        return information
    }

    private static func refusal(_ message: String) -> ProxyProcess.Failure {
        .message(message)
    }
}
