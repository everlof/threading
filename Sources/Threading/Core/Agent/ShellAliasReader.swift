import Foundation

/// Reads shell aliases that route an agent CLI to an alternate account.
///
/// Accounts are discovered from the filesystem, not from aliases; this only recovers the
/// name the user already calls each account by. An alias qualifies only if it sets a config
/// directory, so a plain path shortcut such as `alias claude='~/.local/bin/claude'` is
/// ignored rather than mistaken for an account.
enum ShellAliasReader {

    // MARK: - Public Methods

    /// Maps a config directory path to the alias name pointing at it.
    ///
    /// Later definitions win, matching how the shell resolves duplicate aliases.
    static func accountAliasesByConfigPath() -> [String: String] {
        var result: [String: String] = [:]

        for file in shellConfigFiles() {
            guard let data = try? BoundedFileReader.read(
                file,
                maximumBytes: AliasDefaults.maximumConfigBytes
            ), let contents = String(data: data, encoding: .utf8) else { continue }

            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let alias = parseAlias(String(line)) else { continue }
                result[normalized(alias.configPath)] = alias.name
            }
        }

        return result
    }

    // MARK: - Private Methods

    /// Extracts an alias name and the config directory it sets, if it sets one.
    static func parseAlias(_ line: String) -> (name: String, configPath: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(AliasDefaults.keyword) else { return nil }

        let body = trimmed.dropFirst(AliasDefaults.keyword.count)
        guard let equalsIndex = body.firstIndex(of: "=") else { return nil }

        let name = body[body.startIndex..<equalsIndex].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy(isAliasNameCharacter) else { return nil }

        let definition = unquoted(String(body[body.index(after: equalsIndex)...]))

        // Only aliases that redirect the account are relevant.
        for environmentKey in AliasDefaults.accountEnvironmentKeys {
            guard let path = value(forEnvironmentKey: environmentKey, in: definition) else { continue }
            return (name, expandingHome(path))
        }

        return nil
    }

    /// Reads `KEY=value` out of an alias body, tolerating quoting around the value.
    private static func value(forEnvironmentKey key: String, in body: String) -> String? {
        guard let keyRange = body.range(of: "\(key)=") else { return nil }

        let remainder = body[keyRange.upperBound...]
        guard let first = remainder.first else { return nil }

        // A quoted value runs to its closing quote; a bare one ends at the next space.
        if first == "\"" || first == "'" {
            let afterQuote = remainder.dropFirst()
            guard let closing = afterQuote.firstIndex(of: first) else { return nil }
            return String(afterQuote[afterQuote.startIndex..<closing])
        }

        let terminator = remainder.firstIndex(of: " ") ?? remainder.endIndex
        return String(remainder[remainder.startIndex..<terminator])
    }

    /// Strips one layer of surrounding quotes from an alias body.
    private static func unquoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "\"" || first == "'",
              trimmed.count >= 2, trimmed.last == first else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    /// Expands the `$HOME` and `~` forms that appear in hand-written aliases.
    private static func expandingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var expanded = path
        for token in AliasDefaults.homeTokens where expanded.hasPrefix(token) {
            expanded = home + expanded.dropFirst(token.count)
            break
        }

        return expanded
    }

    private static func isAliasNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Shell startup files that may define aliases, newest definition winning.
    private static func shellConfigFiles() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AliasDefaults.configFileNames
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Alias Defaults

enum AliasDefaults {
    static let keyword = "alias "
    static let maximumConfigBytes = 2 * 1024 * 1024

    /// Environment variables that redirect an agent CLI to an alternate account.
    static let accountEnvironmentKeys = ["CLAUDE_CONFIG_DIR", "CODEX_HOME"]

    /// Home-directory prefixes to expand in alias values.
    static let homeTokens = ["$HOME", "${HOME}", "~"]

    static let configFileNames = [
        ".zshenv",
        ".zprofile",
        ".zshrc",
        ".bashrc",
        ".bash_profile",
        ".profile"
    ]
}
