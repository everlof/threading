import Foundation
import ThreadingController

// What a connected host's controller says its workers spent, read over the same SSH owner-RPC
// the Remote automations page uses. The host keeps the ledger (see
// docs/feature-drafts/agent-usage-ledger.md); this Mac only reads bounded pages of it and never
// recomputes anything from transcripts. See docs/architecture/usage-dashboard.md.

enum RemoteAgentUsageDefaults {
    /// The widest range the Usage page offers, in UTC days.
    static let summaryDays = 90
    /// The ranges read newest first, so a page budget spent on a long history cuts the oldest
    /// days rather than this week's. Each is a span of UTC days ending `offset` days ago.
    static let summarySegments: [(offset: Int, days: Int)] = [(0, 7), (7, 23), (30, 60)]
    /// Summary pages one refresh may read from one host. The controller pages 100 cells at a
    /// time, so this is 5,000 (day × worker × account × model) cells: the scaling contract's
    /// expected ten workers over ninety days several times over. Past it the summary is
    /// `partial` and says from which day it is complete.
    static let maximumSummaryPages = 50
    /// Worker-name pages (50 workers each).
    static let maximumWorkerPages = 4
    /// Hosts read at once. Each read is one `ssh` process at a time.
    static let maximumConcurrentHosts = 3
    /// Hosts kept in the cache at all; a fleet past this is not what the Usage page is for.
    static let maximumHosts = 16
    /// One owner-RPC response. A full receipt page is bounded at 1 MiB by the controller.
    static let maximumResponseBytes = 2_097_152
    /// A summary older than this is shown as stale even when the last read succeeded.
    static let staleAfter: TimeInterval = 30 * 60
    /// The page re-reads hosts on appearance no more often than this unless forced.
    static let refreshInterval: TimeInterval = 5 * 60
    static let cacheFileName = "agent-usage-hosts.json"

    /// Commands this client may send. Reads, plus the one owner mutation the worker page offers.
    static let allowedCommands: Set<String> = [
        "usage-summary", "usage-receipts", "workers", "worker-budget", "worker-budget-set"
    ]
}

enum RemoteAgentUsageError: LocalizedError, Equatable {
    case commandNotAllowed(String)
    case invalidHost
    case rejected(String)
    case invalidResponse
    case cursorDidNotAdvance

    var errorDescription: String? {
        switch self {
        case .commandNotAllowed(let command):
            return L10n.format("“%@” is not a usage operation.", command)
        case .invalidHost:
            return L10n.string("This host's connection is incomplete. Connect to its controller in Automations ▸ Remote first.")
        case .rejected(let output):
            return L10n.format("The host's controller did not answer: %@", output)
        case .invalidResponse:
            return L10n.string("The host's controller sent a response this Mac cannot read.")
        case .cursorDidNotAdvance:
            return L10n.string("The host's controller repeated a page; reading stopped.")
        }
    }
}

/// UTC calendar days, the controller's own day boundary (`endedAt.prefix(10)`).
enum RemoteAgentUsageDay {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static func string(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04lld-%02lld-%02lld",
                      Int64(parts.year ?? 0), Int64(parts.month ?? 0), Int64(parts.day ?? 0))
    }

    static func string(daysBefore offset: Int, _ date: Date) -> String {
        string(calendar.date(byAdding: .day, value: -offset, to: date) ?? date)
    }

    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

// MARK: - Transport

/// One owner-RPC to one host, answered with the controller's stdout. A seam so the client's
/// paging and staleness are tested without `ssh`.
protocol RemoteAgentUsageTransport: Sendable {
    func ownerRPC(endpoint: RemoteAutomationEndpoint, destination: RemoteHostDestination,
                  command: String, arguments: [String]) async throws -> Data
}

/// The Remote automations transport: `ssh host 'controller --database db owner-rpc'` with one
/// JSON request on stdin. Unlike `RemoteAutomationClient` it has no one-request-at-a-time gate,
/// because several hosts are read at once; one host is still read one page at a time.
struct SSHRemoteAgentUsageTransport: RemoteAgentUsageTransport {
    var runner: any RemoteHostCommandRunning = SystemSSHCommandRunner(
        maximumOutputBytes: RemoteAgentUsageDefaults.maximumResponseBytes
    )

    func ownerRPC(endpoint: RemoteAutomationEndpoint, destination: RemoteHostDestination,
                  command: String, arguments: [String]) async throws -> Data {
        try endpoint.validate()
        guard destination.isValid else { throw RemoteAgentUsageError.invalidHost }
        guard RemoteAgentUsageDefaults.allowedCommands.contains(command) else {
            throw RemoteAgentUsageError.commandNotAllowed(command)
        }
        let request = RemoteAutomationClient.Request(
            command: command,
            arguments: arguments.map { RemoteAutomationClient.Argument(value: $0) }
        )
        let data = try JSONEncoder().encode(request)
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shellCommand = quote(endpoint.executable) + " --database " + quote(endpoint.database) + " owner-rpc"
        let runner = self.runner
        let result = try await Task.detached(priority: .utility) {
            try runner.run(on: destination, command: shellCommand, input: .data(data),
                           extraOptions: [], timeout: RemoteHostDefaults.commandTimeout)
        }.value
        guard result.succeeded else {
            throw RemoteAgentUsageError.rejected(String(result.output.suffix(512)))
        }
        return Data(result.output.utf8)
    }
}

// MARK: - Client

/// What one host's usage summary read produced.
struct RemoteAgentUsageSummaryRead: Sendable, Equatable {
    var cells: [UsageDailyCell]
    /// The oldest UTC day whose cells were read completely. Equal to the requested start when
    /// the read was not cut by the page budget.
    var completeFrom: String
    var isTruncated: Bool
}

/// Pages a host's owner reads. Sendable and stateless: every call is bounded by its own page
/// budget and runs off the main actor through the transport.
struct RemoteAgentUsageClient: Sendable {
    var transport: any RemoteAgentUsageTransport = SSHRemoteAgentUsageTransport()

    /// Daily cells for the last `summaryDays` UTC days ending at `now`, newest segment first.
    func summary(endpoint: RemoteAutomationEndpoint, destination: RemoteHostDestination,
                 now: Date, maximumPages: Int = RemoteAgentUsageDefaults.maximumSummaryPages) async throws
        -> RemoteAgentUsageSummaryRead {
        var cells: [UsageDailyCell] = []
        var pagesLeft = maximumPages
        var completeFrom = RemoteAgentUsageDay.string(now)
        for segment in RemoteAgentUsageDefaults.summarySegments {
            let through = RemoteAgentUsageDay.string(daysBefore: segment.offset, now)
            let from = RemoteAgentUsageDay.string(daysBefore: segment.offset + segment.days - 1, now)
            var cursor: Int64 = 0
            var finished = false
            while pagesLeft > 0 {
                try Task.checkCancellation()
                pagesLeft -= 1
                let page: ControllerPage<UsageDailyCell> = try await decode(
                    endpoint: endpoint, destination: destination,
                    command: "usage-summary", arguments: [from, through, String(cursor)]
                )
                cells.append(contentsOf: page.items)
                if page.items.isEmpty { finished = true; break }
                guard page.next > cursor else { throw RemoteAgentUsageError.cursorDidNotAdvance }
                cursor = page.next
            }
            guard finished else {
                return .init(cells: cells, completeFrom: completeFrom, isTruncated: true)
            }
            completeFrom = from
        }
        return .init(cells: cells, completeFrom: completeFrom, isTruncated: false)
    }

    /// Every worker's name, up to the page budget.
    func workers(endpoint: RemoteAutomationEndpoint, destination: RemoteHostDestination) async throws -> [ControllerWorker] {
        var workers: [ControllerWorker] = []
        var cursor: Int64 = 0
        for _ in 0..<RemoteAgentUsageDefaults.maximumWorkerPages {
            let page: ControllerPage<ControllerWorker> = try await decode(
                endpoint: endpoint, destination: destination, command: "workers", arguments: [String(cursor)]
            )
            workers.append(contentsOf: page.items)
            if page.items.isEmpty { break }
            guard page.next > cursor else { throw RemoteAgentUsageError.cursorDidNotAdvance }
            cursor = page.next
        }
        return workers
    }

    /// One page of a worker's receipts, oldest first, continuing from `cursor`.
    func receipts(endpoint: RemoteAutomationEndpoint, destination: RemoteHostDestination,
                  worker: WorkerID, cursor: Int64) async throws -> ControllerPage<UsageReceipt> {
        try await decode(endpoint: endpoint, destination: destination,
                         command: "usage-receipts", arguments: [worker.description, String(cursor)])
    }

    func budget(endpoint: RemoteAutomationEndpoint, destination: RemoteHostDestination,
                worker: WorkerID) async throws -> WorkerBudget? {
        try await decode(endpoint: endpoint, destination: destination,
                         command: "worker-budget", arguments: [worker.description])
    }

    /// The owner mutation. The controller refuses a stale `expectedRevision`, so two editors
    /// cannot silently overwrite each other.
    func setBudget(endpoint: RemoteAutomationEndpoint, destination: RemoteHostDestination,
                   worker: WorkerID, expectedRevision: Int, tokensPerDay: Int64?) async throws -> WorkerBudget {
        try await decode(endpoint: endpoint, destination: destination, command: "worker-budget-set",
                         arguments: [worker.description, String(expectedRevision), tokensPerDay.map(String.init) ?? "none"])
    }

    private func decode<Value: Decodable & Sendable>(
        endpoint: RemoteAutomationEndpoint, destination: RemoteHostDestination,
        command: String, arguments: [String]
    ) async throws -> Value {
        guard RemoteAgentUsageDefaults.allowedCommands.contains(command) else {
            throw RemoteAgentUsageError.commandNotAllowed(command)
        }
        let data = try await transport.ownerRPC(endpoint: endpoint, destination: destination,
                                                command: command, arguments: arguments)
        guard data.count <= RemoteAgentUsageDefaults.maximumResponseBytes else { throw RemoteAgentUsageError.invalidResponse }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw RemoteAgentUsageError.invalidResponse
        }
    }
}
