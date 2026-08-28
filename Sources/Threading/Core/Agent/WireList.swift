import Foundation
import OSLog

/// Reading a provider's JSON list — an array of objects, an array of strings, or an object whose
/// values are objects — one element at a time instead of all or nothing.
///
/// **`value as? [[String: Any]]` is all-or-nothing, and unlike the object conversion in
/// `JSONValue` it fires on ordinary provider JSON.** `JSONSerialization` renders a JSON `null` as
/// `NSNull`, and one `NSNull` makes the whole cast answer `nil` — not the element that failed:
///
/// ```swift
/// ["c1", null] as? [[String: Any]]   // nil, the whole array
/// ["b", 7]     as? [String]          // nil, every skill name
/// ```
///
/// So one `null` in an assistant message's `content` cost the whole turn, and one number in
/// `skills` cost every skill name. `JSONValue.object(from:)`'s all-or-nothing rule (`6bb2ebfb`)
/// is a different, latent defect: it is fed by an in-process caller, everything
/// `JSONSerialization` emits converts, and that branch needs a `Date` splicing in to fire. This
/// one needs only an agent that writes a `null`, because these readers are fed straight from the
/// wire.
///
/// **Both answers are legitimate, and which one is right is a property of the list** — so this
/// type exists to make the call site say which it chose rather than inherit an accident.
///
/// **Recover where the elements stand alone.** A conversation's content blocks, a replayed
/// transcript row, a command catalogue, a ledger entry, a set of search hits: keeping the elements
/// that *are* readable loses strictly less than losing the container, and each element dropped
/// could not have been read whichever way the cast went. The loss is not silent — every drop is
/// counted against a named site in the unified log, so an agent writing lists this client cannot
/// read is findable without opening a transcript.
///
/// **Refuse where the parts only mean something together**, and where the reader is deciding
/// something rather than showing it. A plan's steps against its own total, a diff's hunks against
/// the change they describe, a scan's error list against an `isEmpty` check: those sites keep
/// spelling `as? [[String: Any]]` and say why in a comment. Two more are `ACPStreamSession`'s
/// permission `options`, where a partial list is what a person's single "Allow" gets mapped onto,
/// and `ClaudeTranscriptInterruption`, whose whole classification is "one text block and nothing
/// else". That follows `6bb2ebfb`, which kept the two permission-path conversions strict for the
/// same reason.
///
/// **Three answers, not two.** Nil means "this was not a list of that kind at all"; `[]` means
/// "the list was there and it was empty"; and the `…IfListed` pair additionally answers nil when
/// *nothing* in the list was readable, on the rule that a list with no readable element in it was
/// never a list of that kind. Several readers branch on exactly that difference: a `content`
/// that is a string is not a `content` that is an empty list, and `{"commands": ["ctx"]}` is not
/// a catalogue of zero commands.
///
/// Nothing here ever drops an element silently. It follows `JSONValue.converting(foundationValue:)`
/// in keeping what it can read and naming what it cannot; here the naming is a warning on the
/// caller's own logger, because these callers produce domain values rather than `JSONValue`s and
/// have nowhere to put an `.unconvertible` marker. The logger is passed per call so a site outside
/// the agent subsystem — an AI provider response, an avatar lookup — reports under its own
/// category rather than under `agent`.
enum WireList {

    // MARK: - Objects

    /// The elements of `value` that are JSON objects, or nil when `value` is not an array.
    ///
    /// Nil is reserved for the one case that means "this reader was looking at the wrong shape".
    /// An array whose elements are *all* unreadable answers with an empty list, because the array
    /// was still there and its emptiness is the honest reading of it — use
    /// `objectsIfListed(_:site:log:)` where that is the wrong answer.
    static func objects(_ value: Any?, site: String, log: Logger) -> [[String: Any]]? {
        guard let elements = value as? [Any] else { return nil }
        let objects = elements.compactMap { $0 as? [String: Any] }
        guard !objects.isEmpty || elements.isEmpty else { return nil }  // DELIBERATE BREAK
        report(kept: objects.count, of: elements.count, site: site, log: log)
        return objects
    }

    /// The objects in a wire list, where a list holding *no* object at all is not an answer.
    ///
    /// The difference from `objects(_:site:log:)` matters wherever an empty list is itself a
    /// statement. `{"commands": ["ctx"]}` is not a catalogue of zero commands; answering `[]`
    /// there would empty a composer catalogue that a malformed message never described, which is
    /// a worse outcome than the ignored message the strict cast produced. An explicitly empty
    /// `[]` still means an empty list and is answered as one.
    static func objectsIfListed(_ value: Any?, site: String, log: Logger) -> [[String: Any]]? {
        guard let elements = value as? [Any] else { return nil }
        let objects = elements.compactMap { $0 as? [String: Any] }
        // Reported only once something was recovered: a list with no object in it is not a list
        // of objects this reader failed to read, so there is no loss to name.
        guard !objects.isEmpty || elements.isEmpty else { return nil }
        report(kept: objects.count, of: elements.count, site: site, log: log)
        return objects
    }

    /// The objects in `value` paired with the position each held in the original array.
    ///
    /// Nil and `[]` mean what they mean in `objects(_:site:log:)`. The positions are carried
    /// because a reader that names an element by its index — the way a background task with no id
    /// of its own does — needs the index the wire used, not the index left after a compaction, or
    /// the same entry is renamed the moment a neighbour breaks.
    static func indexed(
        _ value: Any?,
        site: String,
        log: Logger
    ) -> [(offset: Int, element: [String: Any])]? {
        guard let elements = value as? [Any] else { return nil }
        var kept: [(offset: Int, element: [String: Any])] = []
        kept.reserveCapacity(elements.count)
        for (offset, raw) in elements.enumerated() {
            guard let object = raw as? [String: Any] else { continue }
            kept.append((offset: offset, element: object))
        }
        report(kept: kept.count, of: elements.count, site: site, log: log)
        return kept
    }

    // MARK: - Strings

    /// The elements of `value` that are strings, or nil when `value` is not an array.
    ///
    /// The string form of `objects(_:site:log:)`, and nil and `[]` mean the same things here.
    static func strings(_ value: Any?, site: String, log: Logger) -> [String]? {
        guard let elements = value as? [Any] else { return nil }
        let strings = elements.compactMap { $0 as? String }
        report(kept: strings.count, of: elements.count, site: site, log: log)
        return strings
    }

    /// The strings in a wire list, where a list holding *no* string at all is not an answer.
    ///
    /// Every caller distinguishes "the agent did not state this list" from "the agent stated an
    /// empty list", so the same rule as `objectsIfListed(_:site:log:)` applies: `["a", 2]` is a
    /// list of one readable name, `[1, 2]` is not a list of names at all, and `[]` is an empty one.
    static func stringsIfListed(_ value: Any?, site: String, log: Logger) -> [String]? {
        guard let elements = value as? [Any] else { return nil }
        let strings = elements.compactMap { $0 as? String }
        guard !strings.isEmpty || elements.isEmpty else { return nil }
        report(kept: strings.count, of: elements.count, site: site, log: log)
        return strings
    }

    // MARK: - Dictionary Values

    /// The values of `value` that are JSON objects, or nil when `value` is not an object.
    ///
    /// The dictionary form of the same defect: `as? [String: [String: Any]]` is all-or-nothing
    /// too, so one `null` value costs every *other* key's object as well.
    static func values(_ value: Any?, site: String, log: Logger) -> [String: [String: Any]]? {
        guard let object = value as? [String: Any] else { return nil }
        let values = object.compactMapValues { $0 as? [String: Any] }
        report(kept: values.count, of: object.count, site: site, log: log)
        return values
    }

    // MARK: - Private Methods

    /// Names the site and counts the loss, once per read, and says nothing when there was none.
    ///
    /// Only the counts and the site reach the log. The site is a source-level label and the counts
    /// are structural: an element this client could not model is still provider content, and
    /// naming its value here would route it around the redaction every other provider payload
    /// passes through.
    private static func report(kept: Int, of total: Int, site: String, log: Logger) {
        guard kept != total else { return }
        log.warning(
            """
            wire list at \(site, privacy: .public): kept \(kept, privacy: .public) of \
            \(total, privacy: .public) element(s); the rest were not of the expected shape
            """
        )
    }
}

// MARK: - Sites

/// The labels `WireList` reports under, spelled once so a log line names a place in the source.
enum WireListSite {
    static let claudeAssistantContent = "claude.assistant.content"
    static let claudeUserContent = "claude.user.content"
    static let claudeUserText = "claude.user.content.text"
    static let claudeToolResultContent = "claude.tool_result.content"
    static let claudeLedgerContent = "claude.ledger.message.content"
    static let claudeAPIErrorContent = "claude.api_error.message.content"
    static let claudeSubagentStatusContent = "claude.subagent.status.content"
    static let claudeSubagentContent = "claude.subagent.assistant.content"
    static let claudeCommands = "claude.system.commands"
    static let claudeSlashCommands = "claude.system.slash_commands"
    static let claudeSkills = "claude.system.skills"
    static let claudeCapabilities = "claude.system.capabilities"
    static let claudeCommandAliases = "claude.system.commands.aliases"
    static let claudeAdditionalModels = "claude.state.additional_models"
    static let codexToolOutput = "codex.transcript.tool_output"
    static let codexUserMessageContent = "codex.item.user_message.content"
    static let codexCollaborationReceivers = "codex.collab.receiver_thread_ids"
    static let codexCollaborationStates = "codex.collab.agents_states"
    static let codexSkillScopes = "codex.skills.data"
    static let acpAvailableCommands = "acp.session_update.availableCommands"
    static let grokAvailableCommands = "grok.initialize._meta.availableCommands"
    static let hookBackgroundTasks = "hook.background_tasks"
    static let aiClaudeResponseContent = "ai.claude.response.content"
    static let aiOpenAIResponseChoices = "ai.openai.response.choices"
    static let gitHubUserSearchItems = "github.user_search.items"
}
