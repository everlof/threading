import Foundation
import Darwin

enum CodexModelRefreshError: Error, Equatable, Sendable {
    case unavailable
    case timedOut
    case malformed
    case tooLarge
    case saveFailed
    case accountMismatch

    var message: String {
        switch self {
        case .unavailable:
            return L10n.string("Could not load models. Check that Codex is installed and reconnect this account if needed.")
        case .timedOut:
            return L10n.string("The model refresh timed out. Check your connection and try again.")
        case .malformed:
            return L10n.string("Codex returned an unreadable model list. Update Codex and try again.")
        case .tooLarge:
            return L10n.string("The model list exceeded the refresh limit.")
        case .saveFailed:
            return L10n.string("The refreshed model list could not be saved. Try again.")
        case .accountMismatch:
            return L10n.string("Codex opened a different account. Check this account's configuration and try again.")
        }
    }
}

/// A finite, turn-free app-server exchange. Called only on the refresh worker: process spawn,
/// framing, JSON codecs, pipe writes and waits never run on the main actor.
enum CodexModelCatalogClient {
    static let maximumModels = 512
    static let pageSize = 64
    static let maximumPages = 8
    static let maximumOutputBytes = 2 * 1_024 * 1_024
    static let timeout: TimeInterval = 25

    struct Catalog: Codable, Equatable, Sendable {
        let version: String
        let options: [AgentModelOption]
    }

    static func fetch(
        plan: AgentLaunchPlan,
        expectedHome: String? = nil,
        timeout: TimeInterval = timeout
    ) throws -> Catalog {
        let input = try ChildPipe()
        guard fcntl(input.writeEnd, F_SETNOSIGPIPE, 1) != -1 else {
            input.closeBothEnds()
            throw CodexModelRefreshError.unavailable
        }
        let output = try ChildPipe(closingOnFailure: [input])
        let child: SpawnedChildProcess
        do {
            child = try ChildProcessSpawn.spawn(
                executableURL: URL(fileURLWithPath: plan.executable),
                arguments: plan.arguments,
                environment: plan.launchEnvironment(),
                workingDirectory: nil,
                descriptors: [0: .inherited(input.readEnd), 1: .inherited(output.writeEnd), 2: .nullDevice]
            )
        } catch {
            input.closeBothEnds()
            output.closeBothEnds()
            throw CodexModelRefreshError.unavailable
        }
        input.closeReadEnd()
        output.closeWriteEnd()
        let writer = input.takeWriteHandle()
        let reader = output.takeReadHandle()
        let deadline = ChildProcessDeadline(
            child: child, timeout: timeout, terminationGrace: BoundedChildDefaults.terminationGrace
        )
        defer {
            try? writer.close()
            // EOF normally ends app-server immediately. Reap the entire helper group even if
            // a provider ignores it; this also covers protocol/output refusals before timeout.
            let stop = ChildProcessEscalation(child: child)
            child.waitUntilExit()
            stop.complete()
            _ = deadline.complete()
            try? reader.close()
        }

        let exchange = Exchange(reader: reader, writer: writer)
        do {
            try exchange.send([
                "id": 1, "method": "initialize", "params": [
                    "clientInfo": ["name": "threading", "title": "Threading", "version": "1"]
                ]
            ])
            let initialized = try exchange.response(id: 1)
            if let expectedHome, let reportedHome = initialized["codexHome"] as? String {
                guard URL(fileURLWithPath: reportedHome).resolvingSymlinksInPath()
                    == URL(fileURLWithPath: expectedHome).resolvingSymlinksInPath() else {
                    throw CodexModelRefreshError.accountMismatch
                }
            }
            guard let userAgent = initialized["userAgent"] as? String,
                  let version = userAgent.split(separator: " ").first?.split(separator: "/").last,
                  version.first?.isNumber == true else { throw CodexModelRefreshError.malformed }
            try exchange.send(["method": "initialized"])

            var options: [AgentModelOption] = []
            var identifiers = Set<String>()
            var cursors = Set<String>()
            var cursor: String?
            for page in 0..<maximumPages {
                var parameters: [String: Any] = ["limit": pageSize, "includeHidden": false]
                if let cursor { parameters["cursor"] = cursor }
                let id = page + 2
                try exchange.send(["id": id, "method": "model/list", "params": parameters])
                let result = try exchange.response(id: id)
                let models = try decodePage(result)
                for option in models where identifiers.insert(option.identifier).inserted {
                    options.append(option)
                }
                guard options.count <= maximumModels else { throw CodexModelRefreshError.tooLarge }
                if result["nextCursor"] == nil || result["nextCursor"] is NSNull {
                    guard !options.isEmpty else { throw CodexModelRefreshError.unavailable }
                    return Catalog(version: String(version), options: options)
                }
                guard let next = result["nextCursor"] as? String, !next.isEmpty,
                      next.utf8.count <= 1_024, cursors.insert(next).inserted else {
                    throw CodexModelRefreshError.malformed
                }
                cursor = next
            }
            throw CodexModelRefreshError.tooLarge
        } catch {
            if deadline.complete() { throw CodexModelRefreshError.timedOut }
            throw (error as? CodexModelRefreshError) ?? .unavailable
        }
    }

    static func decodePage(_ result: [String: Any]) throws -> [AgentModelOption] {
        guard let raw = result["data"] as? [Any] else { throw CodexModelRefreshError.malformed }
        guard raw.count <= pageSize else { throw CodexModelRefreshError.tooLarge }
        guard let models = WireList.objectsIfListed(raw, site: "codex.model.list", log: ThreadingLogger.agent) else {
            throw CodexModelRefreshError.malformed
        }
        return try models.compactMap { model in
            if model["hidden"] as? Bool == true { return nil }
            guard let identifier = model["model"] as? String, !identifier.isEmpty,
                  let displayName = model["displayName"] as? String, !displayName.isEmpty,
                  identifier.utf8.count <= 512, displayName.utf8.count <= 512 else {
                throw CodexModelRefreshError.malformed
            }
            let tiers = WireList.objects(model["serviceTiers"], site: "codex.model.service_tiers", log: ThreadingLogger.agent) ?? []
            guard tiers.count <= 16 else { throw CodexModelRefreshError.tooLarge }
            let fastTier = tiers.first {
                ($0["name"] as? String)?.caseInsensitiveCompare(AgentDefaults.codexFastModeName) == .orderedSame
            }?["id"] as? String ?? (
                WireList.strings(model["additionalSpeedTiers"], site: "codex.model.speed_tiers", log: ThreadingLogger.agent)?
                    .contains(AgentDefaults.codexFastServiceTierAlias) == true
                    ? AgentDefaults.codexFastServiceTier : nil
            )
            let levels = WireList.objects(model["supportedReasoningEfforts"], site: "codex.model.reasoning", log: ThreadingLogger.agent) ?? []
            guard levels.count <= 16 else { throw CodexModelRefreshError.tooLarge }
            let reasoning = try levels.map { level -> AgentReasoningLevel in
                guard let effort = level["reasoningEffort"] as? String, !effort.isEmpty,
                      let description = level["description"] as? String,
                      effort.utf8.count <= 128, description.utf8.count <= 2_048 else {
                    throw CodexModelRefreshError.malformed
                }
                return AgentReasoningLevel(effort: effort, description: description)
            }
            return AgentModelOption(
                identifier: identifier, displayName: displayName,
                fastServiceTier: fastTier,
                defaultServiceTier: model["defaultServiceTier"] as? String,
                defaultReasoningLevel: model["defaultReasoningEffort"] as? String,
                reasoningLevels: reasoning
            )
        }
    }

    private final class Exchange {
        let reader: FileHandle
        let writer: FileHandle
        var buffer = Data()
        var scannedBytes = 0
        var totalBytes = 0

        init(reader: FileHandle, writer: FileHandle) {
            self.reader = reader
            self.writer = writer
        }

        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try writer.write(contentsOf: data)
        }

        func response(id: Int) throws -> [String: Any] {
            while true {
                // Scan each byte once, including when a malformed peer never sends a newline.
                // Rescanning the accumulated line after every read makes an output refusal quadratic.
                while let newline = buffer.dropFirst(scannedBytes).firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    scannedBytes = 0
                    guard let envelope = JSONRPCLineEnvelope.parse(line) else {
                        throw CodexModelRefreshError.malformed
                    }
                    switch envelope {
                    case .response(let responseID, let result, let error):
                        guard responseID == .integer(Int64(id)) else { continue }
                        guard error == nil else { throw CodexModelRefreshError.unavailable }
                        guard let result else { throw CodexModelRefreshError.malformed }
                        return result
                    case .request(let requestID, _, _):
                        try send(["id": requestID.foundationValue, "error": [
                            "code": -32601, "message": "Client method not supported"
                        ]])
                    case .notification: break
                    }
                }
                scannedBytes = buffer.count
                // Foundation's read(upToCount:) can wait to fill the requested count on a
                // pipe. An RPC peer is waiting for our next request, so use one bounded read
                // syscall: it returns the bytes available now, including a short response.
                var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
                let count = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CodexModelRefreshError.unavailable }
                totalBytes += count
                guard totalBytes <= maximumOutputBytes else { throw CodexModelRefreshError.tooLarge }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }
    }
}
