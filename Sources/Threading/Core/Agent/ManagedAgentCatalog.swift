import Foundation

/// Reviewed Apple Silicon releases. These are provider artifacts, downloaded unchanged from
/// their publishers. Changing a pin requires the real installation/startup smoke test for that
/// client. No vendor installer is evaluated and no global package-manager prefix is modified.
struct ManagedAgentRelease: Equatable, Sendable {
    let kind: AgentKind
    let version: String
    let executable: String
    let archiveURL: URL
    let integrity: String

    var versionArguments: [String] { kind.cliUpdateDefinition.versionArguments }
    var minimumMacOS: OperatingSystemVersion {
        switch kind {
        case .cursor: return OperatingSystemVersion(majorVersion: 13, minorVersion: 5, patchVersion: 0)
        case .claude, .codex, .grok, .openCode:
            return OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        }
    }
    var supportsCurrentSystem: Bool { ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumMacOS) }
    var systemRequirement: String {
        L10n.format("Requires macOS %@ or later.", "\(minimumMacOS.majorVersion).\(minimumMacOS.minorVersion)")
    }
    var requiresBrotliUnpacking: Bool {
        switch kind {
        case .grok: return true
        case .claude, .codex, .openCode, .cursor: return false
        }
    }
}

enum ManagedAgentCatalog {
    static func release(for kind: AgentKind) -> ManagedAgentRelease {
        switch kind {
        case .claude:
            return ManagedAgentRelease(
                kind: kind, version: "2.1.304", executable: "claude",
                archiveURL: URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-arm64/-/claude-code-darwin-arm64-2.1.304.tgz")!,
                integrity: "sha512-io7hBh98nUB3wTzg+XKoh2pN4j71w155wj2jAoF9bwWrnT7u6gcm9vTh0geArjABGNSh2+GaApa+lYREWOOwxw=="
            )
        case .codex:
            return ManagedAgentRelease(
                kind: kind, version: "0.163.0", executable: "vendor/aarch64-apple-darwin/bin/codex",
                archiveURL: URL(string: "https://registry.npmjs.org/@openai/codex/-/codex-0.163.0-darwin-arm64.tgz")!,
                integrity: "sha512-i7Dzk2a5aGmuGM9aNZgaUVTojZ/4bc5lRfosz++Y7X2BGhDkz+cySgbD+NYS1pOxfm0VEbLi9PZ3pAulI4kchw=="
            )
        case .grok:
            return ManagedAgentRelease(
                kind: kind, version: "1.0.62", executable: "bin/grok",
                archiveURL: URL(string: "https://registry.npmjs.org/@xai-official/grok-darwin-arm64/-/grok-darwin-arm64-1.0.62.tgz")!,
                integrity: "sha512-RSfT2HoNR9lN7ji6lR2HC9Sz0DJLKTCPRXGtQFL4XDmZU+SFLZ8DzKKbqIfS+odHVQ2FnSLaBGud8Os8ghYpdA=="
            )
        case .openCode:
            return ManagedAgentRelease(
                kind: kind, version: "1.19.3", executable: "bin/opencode",
                archiveURL: URL(string: "https://registry.npmjs.org/opencode-darwin-arm64/-/opencode-darwin-arm64-1.19.3.tgz")!,
                integrity: "sha512-NmDF28jD8W7m9a/k4mc3rajEWftDemGecrzBJItzTWwN0Eu5WFSEFBocvmmasUr4nh8ei9Zl1pwRvv66R4dN6A=="
            )
        case .cursor:
            return ManagedAgentRelease(
                kind: kind, version: "2026.10.19-6bbf2c4", executable: "cursor-agent",
                archiveURL: URL(string: "https://downloads.cursor.com/lab/2026.10.19-6bbf2c4/darwin/arm64/agent-cli-package.tar.gz")!,
                integrity: "sha256-095dccb923488d280aae697ba68c13a92bbd9ce1dc6105401e147e25869f2b13"
            )
        }
    }

    // Grok distributes its native binary compressed with Brotli. The private, verified Node
    // distribution only decodes that artifact; it never installs npm packages or reads accounts.
    static let nodeURL = URL(string: "https://nodejs.org/dist/v22.23.3/node-v22.23.3-darwin-arm64.tar.gz")!
    static let nodeIntegrity = "sha256-23b25245dcfb9af7262f8ff142e9e2e0af025368117329e7a7458a51e5922f53"
    static let nodeArchiveMember = "node-v22.23.3-darwin-arm64/bin/node"
    static let maximumDownloadBytes: Int64 = 512 * 1024 * 1024
    static let maximumArchiveListingBytes = 2 * 1024 * 1024
    static let maximumArchiveEntries = 8_192
    static let maximumRetainedInstallations = 8
    static let receiptMaximumBytes = 32 * 1024
    static let systemPATH = "/usr/bin:/bin:/usr/sbin:/sbin"
}
