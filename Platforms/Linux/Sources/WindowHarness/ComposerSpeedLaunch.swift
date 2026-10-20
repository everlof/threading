#if os(Linux)
import Foundation
import Glibc
@testable import CoreSlice

/// The opening Speed choice follows the session onto both Linux launch surfaces.
/// File and account metadata stay on their bounded creation/resume workers.
enum ComposerSpeedLaunch {
    static func admits(_ fastMode: Bool?, kind: AgentKind, model: String?,
                       catalogue: ComposerModelCatalog) -> Bool {
        fastMode == nil || catalogue.supportsFastMode(kind: kind, model: model)
    }

    static func codexOverrides(_ fastMode: Bool?, model: String?,
                               catalogue: ComposerModelCatalog) -> ShellCommand {
        var command = ShellCommand()
        guard let tier = codexServiceTier(fastMode, model: model, catalogue: catalogue) else {
            return command
        }
        command.append(flag: AgentDefaults.codexConfigFlag,
                       value: "\(AgentDefaults.codexServiceTierKey)=\"\(tier)\"")
        if fastMode == true {
            command.append(flag: AgentDefaults.codexConfigFlag,
                           value: "\(AgentDefaults.codexFastModeFeatureKey)=true")
        }
        return command
    }

    static func codexServiceTier(_ fastMode: Bool?, model: String?,
                                 catalogue: ComposerModelCatalog) -> String? {
        guard let fastMode else { return nil }
        guard fastMode else { return AgentDefaults.codexStandardServiceTier }
        let selected = catalogue.options.first { $0.identifier == (model ?? catalogue.defaultModel) }
        let rawTier = selected?.fastServiceTier ?? AgentDefaults.codexFastServiceTier
        let validTier = rawTier.utf8.count <= 64 && !rawTier.isEmpty
            && rawTier.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || byte == 45 || byte == 95 || byte == 46
            }
        return validTier ? rawTier : AgentDefaults.codexFastServiceTier
    }

    static func claudeFlags(_ fastMode: Bool?, store: String, id: SessionID) throws -> ShellCommand {
        var command = ShellCommand()
        guard let fastMode else { return command }
        let directory = URL(fileURLWithPath: store, isDirectory: true)
            .appendingPathComponent("launch-settings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else {
            throw WindowFailure("Could not protect the session settings directory.")
        }
        let file = directory.appendingPathComponent(id.uuidString + ".json")
        let data = Data("{\"fastMode\":\(fastMode ? "true" : "false")}".utf8)
        try data.write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else {
            throw WindowFailure("Could not protect the session settings file.")
        }
        command.append(flag: "--settings", value: file.path)
        return command
    }
}
#endif
