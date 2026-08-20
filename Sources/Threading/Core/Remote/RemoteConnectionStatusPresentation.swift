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
        let ready = statuses.filter(\.isReady)
        if let first = ready.first {
            return RemoteConnectionStatusPresentation(
                title: L10n.string("Ready"),
                // **One address, and it is the one the pairing code carries.** This used to join
                // every ready line into a single sentence, which on a Mac with two interfaces and
                // a tailnet read as four addresses run together at the top of the page — the
                // reader's first question ("can anything reach this Mac?") answered by a
                // paragraph. The ways in are where an address belongs: each one names its own,
                // lists its others, and a way in you are not looking at still shows its state on
                // its segment. So this row states the fact and stops.
                detail: first.fact,
                tone: .ready,
                isBusy: false
            )
        }

        // Bound, and something between the listener and the phone may be swallowing it. The
        // address is real and the doubt is real, and neither may be dropped: a page that said
        // "not reachable" would send somebody looking for a listener that is running.
        if let doubtful = statuses.first(where: { $0.boundAddress != nil }) {
            return RemoteConnectionStatusPresentation(
                title: L10n.string("May not be reachable"),
                detail: doubtful.sentence,
                tone: .attention,
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
                    working.sentence,
                    String(localPort)
                ),
                tone: .working,
                isBusy: true
            )
        }

        let attention = statuses.first { $0.tone == .attention }
        return RemoteConnectionStatusPresentation(
            title: L10n.string("Not reachable"),
            detail: attention?.sentence
                ?? L10n.string("Nothing outside this Mac can reach it right now."),
            tone: .attention,
            isBusy: false
        )
    }
}
