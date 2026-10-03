import Foundation

/// What an unattended automation run may do without a person, fixed in the revision the person
/// approves.
///
/// An unattended run has nobody to answer a permission card, so it must never raise one. The
/// authority it runs with is therefore part of the immutable revision and shown on the approval
/// sheet — never read from files in the project folder, which a cloned repository could check in
/// to widen what an approved automation may do.
///
/// Persisted inside the revision's JSON payload. A revision saved before this existed has no
/// policy and means `readOnly`: Threading's own read-only allowances and nothing else.
enum AutomationPermissionPolicy: Equatable, Sendable, Codable {
    /// Threading's read-only allowances plus exactly these rules; everything else is refused.
    case allowList([AutomationPermissionRule])
    /// Every call of a stage that may edit runs without asking. Only for modes that may edit
    /// files; an assessment stage before a fix still gets read-only answers.
    case full

    /// The explicit default: nothing beyond what only reads.
    static let readOnly = AutomationPermissionPolicy.allowList([])

    static let maximumRules = 64

    var isFull: Bool { self == .full }

    var rules: [AutomationPermissionRule] {
        if case .allowList(let rules) = self { return rules }
        return []
    }

    /// Parses an editor's or an agent's lines into a policy, refusing anything unsupported.
    static func allowList(parsing lines: [String]) throws -> AutomationPermissionPolicy {
        let rules = try lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(AutomationPermissionRule.init(parsing:))
        guard rules.count <= maximumRules else { throw AutomationPermissionPolicyError.tooManyRules }
        return .allowList(rules)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case mode, rules }
    private enum Mode: String, Codable { case allowList, full }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .full:
            guard !container.contains(.rules) else { throw AutomationPermissionPolicyError.fullTakesNoRules }
            self = .full
        case .allowList:
            let rules = try container.decode([AutomationPermissionRule].self, forKey: .rules)
            guard rules.count <= Self.maximumRules else { throw AutomationPermissionPolicyError.tooManyRules }
            self = .allowList(rules)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .full:
            try container.encode(Mode.full, forKey: .mode)
        case .allowList(let rules):
            try container.encode(Mode.allowList, forKey: .mode)
            try container.encode(rules, forKey: .rules)
        }
    }
}

/// One allowance, in the spelling Claude's own permission settings use so a person can copy a
/// rule between the two. The grammar is deliberately small and every form is validated when the
/// rule is saved: a rule that cannot be understood is refused, never guessed at.
///
/// - `Bash(command)` — exactly this simple command; `Bash(command *)` — this command followed by
///   any arguments. Never a chain, pipe, redirection or substitution: each part of a command line
///   is checked on its own when the run asks.
/// - `Write(/absolute/glob)` or `Edit(/absolute/glob)` — files the run may change. `*` stays within
///   one folder, `**` crosses folders.
/// - `WebFetch(domain:host)` — pages from exactly this host.
/// - `mcp__server__tool` — one named MCP tool.
///
/// Reads are not listed: Threading allows tools and commands that only read for every session.
enum AutomationPermissionRule: Hashable, Sendable, Codable {
    case shell(ShellPattern)
    case fileWrite(PathPattern)
    case webFetch(domain: String)
    case mcpTool(String)

    struct ShellPattern: Hashable, Sendable {
        /// The command name and its fixed arguments, as the shell would split them.
        let words: [String]
        /// Whether any further arguments may follow (`Bash(command *)`).
        let allowsMoreArguments: Bool

        /// Whether one simple command — a single segment of a command line — is this pattern.
        /// The name is compared as typed; arguments as the shell will read them, unquoted.
        func matches(words candidate: [String]) -> Bool {
            guard let name = candidate.first, name == words[0] else { return false }
            let arguments = candidate.dropFirst().map(ShellCommandPolicy.unquoted)
            let fixed = Array(words.dropFirst())
            if allowsMoreArguments {
                return arguments.count >= fixed.count && Array(arguments.prefix(fixed.count)) == fixed
            }
            return Array(arguments) == fixed
        }
    }

    struct PathPattern: Hashable, Sendable {
        /// The absolute glob, with a leading `~/` already expanded.
        let glob: String

        func matches(_ path: String) -> Bool {
            path.range(of: Self.expression(for: glob), options: .regularExpression) != nil
        }

        private static func expression(for glob: String) -> String {
            var pattern = "^"
            var index = glob.startIndex
            while index < glob.endIndex {
                let character = glob[index]
                if character == "*" {
                    let next = glob.index(after: index)
                    if next < glob.endIndex, glob[next] == "*" {
                        pattern += ".*"
                        index = glob.index(after: next)
                        continue
                    }
                    pattern += "[^/]*"
                } else {
                    pattern += NSRegularExpression.escapedPattern(for: String(character))
                }
                index = glob.index(after: index)
            }
            return pattern + "$"
        }
    }

    static let maximumRuleBytes = 512

    // MARK: Parsing

    init(parsing raw: String) throws {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= Self.maximumRuleBytes else {
            throw AutomationPermissionPolicyError.ruleTooLong(String(text.prefix(80)))
        }
        if text.hasPrefix("mcp__") {
            guard Self.isToolName(text), text.dropFirst(5).contains("__") else {
                throw AutomationPermissionPolicyError.unsupported(text)
            }
            self = .mcpTool(text)
            return
        }
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else {
            throw AutomationPermissionPolicyError.unsupported(text)
        }
        let kind = String(text[..<open])
        let body = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        switch kind {
        case "Bash":
            self = .shell(try Self.shellPattern(body, rule: text))
        case "Write", "Edit":
            self = .fileWrite(try Self.pathPattern(body, rule: text))
        case "WebFetch":
            guard body.hasPrefix("domain:") else { throw AutomationPermissionPolicyError.unsupported(text) }
            let host = body.dropFirst("domain:".count).lowercased()
            guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
                  host.unicodeScalars.allSatisfy(\.isASCII), !host.hasPrefix("."), !host.hasSuffix(".") else {
                throw AutomationPermissionPolicyError.unsupported(text)
            }
            self = .webFetch(domain: String(host))
        case "Read":
            throw AutomationPermissionPolicyError.readsAreAlwaysAllowed(text)
        default:
            throw AutomationPermissionPolicyError.unsupported(text)
        }
    }

    /// The canonical spelling, which is also the persisted one.
    var text: String {
        switch self {
        case .shell(let pattern):
            return "Bash(" + (pattern.words + (pattern.allowsMoreArguments ? ["*"] : [])).joined(separator: " ") + ")"
        case .fileWrite(let pattern): return "Write(\(pattern.glob))"
        case .webFetch(let domain): return "WebFetch(domain:\(domain))"
        case .mcpTool(let name): return name
        }
    }

    private static func shellPattern(_ body: String, rule: String) throws -> ShellPattern {
        // A rule names one simple command. Anything that could chain, redirect or substitute is
        // refused here, so a rule can never stand for more than the words it shows.
        guard ShellCommandPolicy.segments(ofVettable: body) == [body] else {
            throw AutomationPermissionPolicyError.compoundCommand(rule)
        }
        var words = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var allowsMore = false
        if words.last == "*" {
            allowsMore = true
            words.removeLast()
        }
        guard let name = words.first else { throw AutomationPermissionPolicyError.everyCommand(rule) }
        guard !name.contains("="), !words.contains(where: { $0.contains("*") }) else {
            throw AutomationPermissionPolicyError.unsupported(rule)
        }
        return ShellPattern(words: [name] + words.dropFirst().map(ShellCommandPolicy.unquoted),
                            allowsMoreArguments: allowsMore)
    }

    private static func pathPattern(_ body: String, rule: String) throws -> PathPattern {
        var glob = body
        if glob.hasPrefix("~/") { glob = NSHomeDirectory() + glob.dropFirst(1) }
        if glob.hasPrefix("//") { glob.removeFirst() }
        guard glob.hasPrefix("/"), !glob.contains("?"),
              !glob.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw AutomationPermissionPolicyError.relativePath(rule)
        }
        return PathPattern(glob: glob)
    }

    private static func isToolName(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
        }
    }

    // MARK: Codable

    init(from decoder: Decoder) throws {
        try self.init(parsing: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// Thrown as itself through `JSONDecoder`, so an agent or the editor reads the actual reason.
enum AutomationPermissionPolicyError: LocalizedError, Equatable {
    case unsupported(String)
    case readsAreAlwaysAllowed(String)
    case relativePath(String)
    case compoundCommand(String)
    case everyCommand(String)
    case ruleTooLong(String)
    case tooManyRules
    case fullTakesNoRules
    case fullNeedsEditingMode

    var errorDescription: String? {
        switch self {
        case .unsupported(let rule):
            L10n.format("“%@” is not a supported rule. Use Bash(…), Write(…), Edit(…), WebFetch(domain:…) or mcp__server__tool.", rule)
        case .readsAreAlwaysAllowed(let rule):
            L10n.format("Reads are always allowed for automation runs, so “%@” is not needed.", rule)
        case .relativePath(let rule):
            L10n.format("“%@” must name an absolute path, such as /Users/you/folder/**.", rule)
        case .compoundCommand(let rule):
            L10n.format("“%@” must be one simple command, without ;, &&, |, redirection or substitution.", rule)
        case .everyCommand(let rule):
            L10n.format("“%@” would allow every command. Choose full permission instead.", rule)
        case .ruleTooLong(let rule):
            L10n.format("“%@” is too long for a rule.", rule)
        case .tooManyRules:
            L10n.format("An automation can list at most %lld rules.", Int64(AutomationPermissionPolicy.maximumRules))
        case .fullTakesNoRules:
            L10n.string("Full permission takes no rules.")
        case .fullNeedsEditingMode:
            L10n.string("Full permission needs a mode that may edit files: “Task with local edits” or “Assess, then fix if straightforward”.")
        }
    }
}

extension TriggerRevision {
    /// The policy an unattended run of this revision runs under. A revision saved before
    /// policies existed has none, which means read-only.
    var effectivePermissions: AutomationPermissionPolicy { permissions ?? .readOnly }
}
