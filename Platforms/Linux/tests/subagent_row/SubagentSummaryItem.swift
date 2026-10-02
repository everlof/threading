import AppKit

/// The display-only facts the shared subagent component needs from a provider timeline.
struct SubagentSummaryItem: Equatable {
    enum State: Equatable {
        case pending
        case working
        case completed
        case interrupted
        case failed
        case stopped
    }

    /// What opening the child can reach. A file is necessarily openable, so keeping the URL
    /// inside the state prevents the contradictory "revealable but not openable" combination
    /// that separate `URL?` and `Bool` properties allowed.
    enum TranscriptAvailability: Equatable {
        /// The provider finished without streamed rows or a transcript file.
        case unavailable
        /// Rows are already in memory, or a working child is expected to produce them.
        case openable
        /// A provider transcript exists on disk and can also be revealed in Finder.
        case onDisk(URL)

        var isOpenable: Bool {
            switch self {
            case .unavailable: false
            case .openable, .onDisk: true
            }
        }

        var fileURL: URL? {
            guard case .onDisk(let url) = self else { return nil }
            return url
        }
    }

    let id: String
    let title: String
    let subtitle: String?
    /// The provider's role for the child, when `title` does not already say it — Claude's
    /// `Explore`, Codex's `default`. Drawn beside the configuration rather than as the name,
    /// because a role shared by every row in the list names none of them.
    let role: String?
    let configurationDetail: String?
    let state: State
    let statusDetail: String?
    let usageDetail: String?
    let detailLines: [String]
    let transcriptAvailability: TranscriptAvailability

    init(
        id: String,
        title: String,
        subtitle: String?,
        role: String? = nil,
        configurationDetail: String? = nil,
        state: State,
        statusDetail: String?,
        usageDetail: String? = nil,
        detailLines: [String],
        transcriptAvailability: TranscriptAvailability = .openable
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.role = role
        self.configurationDetail = configurationDetail
        self.state = state
        self.statusDetail = statusDetail
        self.usageDetail = usageDetail
        self.detailLines = detailLines
        self.transcriptAvailability = transcriptAvailability
    }

    /// Role, configuration, progress and usage as one quiet line, each fact once.
    ///
    /// One line rather than one per source: the pane is narrow, and a row that spent a line on
    /// "3.1M tokens" alone read as a list of numbers with a name on top. Facts that repeat each
    /// other — a progress line that already carries the token count — appear once.
    var metaLine: String? {
        let facts = [role, configurationDetail, statusDetail, usageDetail]
            .compactMap { fact -> String? in
                guard let fact, !fact.isEmpty else { return nil }
                return fact
            }
            .reduce(into: [String]()) { unique, fact in
                if !unique.contains(fact) { unique.append(fact) }
            }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
    }

    /// The newest activity line that says something the row's other lines do not.
    var latestDistinctActivity: String? {
        let alreadyShown = Set(
            [title, subtitle, role, configurationDetail, statusDetail, usageDetail]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        )
        return detailLines.reversed().first { detail in
            !detail.isEmpty && !alreadyShown.contains(detail)
        }
    }
}

extension SubagentSummaryItem.State {

    /// The state as the row says it.
    var displayText: String {
        switch self {
        case .pending: return L10n.string("Pending")
        case .working: return L10n.string("Working")
        case .completed: return L10n.string("Done")
        case .interrupted: return L10n.string("Interrupted")
        case .failed: return L10n.string("Failed")
        case .stopped: return L10n.string("Stopped")
        }
    }

    /// The state's ink. Never the only signal: the word beside it says the same thing.
    @MainActor
    var color: NSColor {
        switch self {
        case .pending: return Design.Status.warning
        case .working: return Design.Surface.accent
        case .completed: return Design.Status.positive
        case .interrupted, .stopped: return Design.Text.tertiary
        case .failed: return Design.Status.negative
        }
    }
}
