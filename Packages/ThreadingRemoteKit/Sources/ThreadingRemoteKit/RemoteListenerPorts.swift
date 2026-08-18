import Foundation

/// The ports a Mac's routable listener may be answering on, and the order both ends walk them in.
///
/// This is a contract, not a tunable. The listener takes the configured port and, when it is
/// taken, walks a small fixed range and reports the port it actually took; a client that
/// remembers one address walks the same list before deciding the Mac has moved. Ephemeral ports
/// are what this replaces: a port the kernel picked changed the Mac's address on every launch,
/// so a paired phone had to scan a code again after a restart.
///
/// It lives in the shared kit because the two halves have to agree on it. The macOS side owns
/// its own `RemoteAccessDefaults.listenerPortFallbackRange` today and should point here instead;
/// the values are the same and this type is additive, so nothing breaks in the meantime.
public enum RemoteListenerPorts {

    /// The port the listener tries first, and the one a paired client remembers.
    ///
    /// `8760` carries no common assignment, and neither do the nine ports above it.
    public static let defaultPort: UInt16 = 8760

    /// Where the port may land when the configured one is taken.
    ///
    /// Small, fixed and public. Ten ports is short enough for a client to walk in order without
    /// fanning out, and long enough that an ordinary collision does not cost a re-pair.
    public static let fallbackRange: ClosedRange<UInt16> = 8760...8769

    /// The ports to try, in order: the remembered one first, then the rest of the range.
    ///
    /// Deterministic and de-duplicated, so a client attempts each port exactly once and a test
    /// can state the whole sequence. A port outside the range is still tried first, because it
    /// is what the Mac last reported; the range follows it rather than replacing it.
    public static func candidates(
        preferred: UInt16,
        range: ClosedRange<UInt16> = fallbackRange
    ) -> [UInt16] {
        var seen: Set<UInt16> = []
        var ordered: [UInt16] = []
        for port in [preferred] + Array(range) where seen.insert(port).inserted {
            ordered.append(port)
        }
        return ordered
    }
}
