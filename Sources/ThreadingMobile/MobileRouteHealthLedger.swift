import Foundation
import ThreadingRemoteKit

/// Which of a Mac's advertised addresses have refused the phone's identity check the same way,
/// enough times in a row, to stop knocking on for a while.
///
/// The audit of 4–5 Sep 2026 counted 758 attempts against two of one Mac's three Tailscale
/// origins — its IPv4 address and its MagicDNS name — every one of them `url.-1200` inside
/// 30 ms, while the third origin and the LAN address answered. A route race retried both on all
/// 384 refreshes that day, because nothing remembered that they had never once answered. The
/// race stays a race; this only takes the addresses that have proven they will refuse out of
/// it for a bounded, doubling interval, and tries each again when that interval ends.
///
/// Only a **refusal** counts: a TLS failure is the address answering and saying no, which is
/// a fact about the address. A timeout or an unreachable route is a fact about where the phone
/// is standing, changes with every network, and is never held against an address here.
@MainActor
final class MobileRouteHealthLedger {
    struct Entry: Equatable {
        var consecutiveRefusals: Int
        var lastCode: String
        var cooldownUntil: Date?
    }

    private var entries: [String: Entry] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Whether `code` is an answer about the address rather than about the network. The TLS
    /// family of `URLError` — a handshake the other side ended, a certificate it would not
    /// present acceptably — sits in one contiguous range.
    static func isRefusal(code: String) -> Bool {
        guard code.hasPrefix(MobileRouteHealthDefaults.urlCodePrefix),
              let value = Int(code.dropFirst(MobileRouteHealthDefaults.urlCodePrefix.count))
        else { return false }
        return MobileRouteHealthDefaults.tlsRefusalCodes.contains(value)
    }

    func noteSuccess(origin: URL) {
        entries[Self.key(origin)] = nil
    }

    /// Records one failed attempt. Anything but a refusal clears the count: an address that
    /// timed out is not one that refused, and the two must not add up.
    func noteFailure(origin: URL, code: String) {
        let key = Self.key(origin)
        guard Self.isRefusal(code: code) else {
            entries[key] = nil
            return
        }
        var entry = entries[key] ?? Entry(consecutiveRefusals: 0, lastCode: code, cooldownUntil: nil)
        entry.consecutiveRefusals = entry.lastCode == code ? entry.consecutiveRefusals + 1 : 1
        entry.lastCode = code
        let excess = entry.consecutiveRefusals - MobileRouteHealthDefaults.refusalsBeforeCooldown
        if excess >= 0 {
            let doublings = min(excess, MobileRouteHealthDefaults.maximumDoublings)
            let interval = min(
                MobileRouteHealthDefaults.initialCooldown * pow(2, Double(doublings)),
                MobileRouteHealthDefaults.maximumCooldown
            )
            entry.cooldownUntil = now().addingTimeInterval(interval)
        }
        entries[key] = entry
    }

    /// Whether the address is in a cooldown that has not yet ended. An ended cooldown admits
    /// exactly one more attempt; another refusal starts a longer one.
    func isCoolingDown(origin: URL) -> Bool {
        guard let until = entries[Self.key(origin)]?.cooldownUntil else { return false }
        return now() < until
    }

    func entry(for origin: URL) -> Entry? {
        entries[Self.key(origin)]
    }

    /// Keeps every candidate that is not cooling down — and every candidate at all when they
    /// all are, because a race with no lanes is not a race.
    func admitting<Candidate>(
        _ candidates: [Candidate],
        origin: (Candidate) -> URL,
        skipped: (Candidate) -> Void = { _ in }
    ) -> [Candidate] {
        var admitted: [Candidate] = []
        var held: [Candidate] = []
        for candidate in candidates {
            if isCoolingDown(origin: origin(candidate)) {
                held.append(candidate)
            } else {
                admitted.append(candidate)
            }
        }
        guard !admitted.isEmpty else { return candidates }
        held.forEach(skipped)
        return admitted
    }

    private static func key(_ origin: URL) -> String {
        let scheme = origin.scheme?.lowercased() ?? "none"
        let host = origin.host?.lowercased() ?? "none"
        let port = origin.port.map(String.init) ?? "default"
        return "\(scheme)://\(host):\(port)"
    }
}

enum MobileRouteHealthDefaults {
    /// Identical refusals in a row before an address is rested. Three, so one bad handshake
    /// during a network change never costs a route.
    static let refusalsBeforeCooldown = 3
    static let initialCooldown: TimeInterval = 5 * 60
    static let maximumCooldown: TimeInterval = 60 * 60
    /// Doublings from the initial cooldown to the maximum: 5 → 10 → 20 → 40 → 60 minutes.
    static let maximumDoublings = 4
    static let urlCodePrefix = "url."
    /// `URLError.secureConnectionFailed` (-1200) through `clientCertificateRequired` (-1206):
    /// the whole TLS family, every one an address answering the phone with a refusal.
    static let tlsRefusalCodes: ClosedRange<Int> = -1206 ... -1200
}
