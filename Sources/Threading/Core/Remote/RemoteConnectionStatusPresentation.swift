import Foundation

/// What the Remote Access page's status row says once the listener is up.
///
/// One line about the whole Mac, over the per-way-in lines below it: a person who has just
/// switched Remote Access on wants to know whether anything can reach this Mac at all, and each
/// way in then says what it is doing. It is a value rather than three `updateConnection(...)`
/// calls inside a view controller because the row and the pairing panel have to agree, and
/// because the states worth reviewing — a door with no interface under it, a tailnet still
/// issuing a certificate, a firewall that may be swallowing connections — take a live network to
/// reach and were reviewed in none of them.
struct RemoteConnectionStatusPresentation: Equatable {

    /// Punctuation, not copy: the status lines below are whole facts already, and this is only
    /// how two of them are set end to end.
    private enum SentenceJoin {
        static let separator = ". "
        static let terminator = "."
    }

    /// The mark beside the row. A colour is a `Design` role, which this layer does not read.
    enum Tone: Equatable {
        case ready
        case attention
        case working
    }

    let title: String
    let detail: String
    let tone: Tone
    let isBusy: Bool

    /// Resolves the row from the ways in that are switched on and what each of them is doing.
    ///
    /// The rule that keeps it honest: **`ready` requires an address**. The listener knows what it
    /// bound, and nothing else here is allowed to claim reachability — not a transport that says
    /// it started, not a firewall reading, not a door that was merely selected.
    static func resolve(
        statuses: [RemoteDoorStatus],
        localPort: UInt16
    ) -> RemoteConnectionStatusPresentation {
        let bound = statuses.filter(\.namesABoundAddress)
        if !bound.isEmpty {
            return RemoteConnectionStatusPresentation(
                title: L10n.string("Ready"),
                // Each bound line already names its own address; the row states them in the
                // order the ways in are listed rather than picking one to speak for the Mac.
                detail: bound.map(\.text).joined(separator: SentenceJoin.separator)
                    + SentenceJoin.terminator,
                tone: .ready,
                isBusy: false
            )
        }

        if statuses.isEmpty || statuses.allSatisfy({ $0.tone == .off }) {
            return RemoteConnectionStatusPresentation(
                title: L10n.string("No way in"),
                detail: L10n.format(
                    "Remote Access is on and nothing outside this Mac can reach it. Turn on a "
                        + "way in below. The local mirror is ready on 127.0.0.1:%@.",
                    String(localPort)
                ),
                tone: .attention,
                isBusy: false
            )
        }

        if let working = statuses.first(where: { $0.tone == .working }) {
            return RemoteConnectionStatusPresentation(
                title: L10n.string("Starting"),
                detail: L10n.format(
                    "%1$@ The local mirror is ready on 127.0.0.1:%2$@.",
                    working.text,
                    String(localPort)
                ),
                tone: .working,
                isBusy: true
            )
        }

        let attention = statuses.first { $0.tone == .attention }
        return RemoteConnectionStatusPresentation(
            title: L10n.string("Not reachable"),
            detail: attention.map { status in
                [status.text, status.hint].compactMap { $0 }.joined(separator: " ")
            } ?? L10n.string("Nothing outside this Mac can reach it right now."),
            tone: .attention,
            isBusy: false
        )
    }
}
