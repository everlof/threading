import Foundation
import Security

enum SimulatorHelperLocation {
    static let executableName = "threading-simulator-helper"
    static let identifier = "codes.threading.simulator-helper"

    static func bundledExecutable(in bundle: Bundle = .main) -> URL? {
        let helpers = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
        return helpers.appendingPathComponent(executableName, isDirectory: false)
    }
}

enum SimulatorHelperTrust {
    static func verify(executableURL: URL, bundle: Bundle = .main) throws {
        guard executableURL.isFileURL,
              let expected = SimulatorHelperLocation.bundledExecutable(in: bundle),
              executableURL.standardizedFileURL == expected.standardizedFileURL else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "The direct Simulator helper is not inside Threading.app."
            )
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode,
        SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            nil
        ) == errSecSuccess else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "The direct Simulator helper has an invalid code signature."
            )
        }

        let helper = try signingInformation(staticCode)
        guard helper[kSecCodeInfoIdentifier as String] as? String
            == SimulatorHelperLocation.identifier else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "The embedded Simulator helper has an unexpected signing identifier."
            )
        }
        guard let hostExecutableURL = bundle.executableURL else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "Threading could not read its own code signature."
            )
        }
        var hostCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            hostExecutableURL as CFURL,
            SecCSFlags(),
            &hostCode
        ) == errSecSuccess, let hostCode else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "Threading could not read its own code signature."
            )
        }
        let host = try signingInformation(hostCode)
        let helperTeam = helper[kSecCodeInfoTeamIdentifier as String] as? String
        let hostTeam = host[kSecCodeInfoTeamIdentifier as String] as? String
        if helperTeam != nil || hostTeam != nil {
            guard helperTeam == hostTeam else {
                throw SimulatorLiveStreamError.signatureInvalid(
                    "Threading and its Simulator helper are signed by different teams."
                )
            }
        }
    }

    private static func signingInformation(_ code: SecStaticCode) throws -> [String: Any] {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let information = information as? [String: Any] else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "Threading could not inspect the Simulator helper signature."
            )
        }
        return information
    }
}

enum SimulatorDeveloperDirectory {
    static func active() throws -> String {
        if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           !configured.isEmpty {
            return configured
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() }
        catch {
            throw SimulatorLiveStreamError.helperUnavailable(
                "Threading could not find the active Xcode developer directory."
            )
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              data.count <= 4_096,
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw SimulatorLiveStreamError.helperUnavailable(
                "Threading could not find the active Xcode developer directory."
            )
        }
        return path
    }
}
