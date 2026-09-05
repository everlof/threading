import Darwin
import Foundation

// MARK: - Sign-In Input

/// The parent's end of a login's standard input, owned and written away from the main actor.
///
/// An authorization code is a few dozen bytes, which is exactly the argument that gets a syscall
/// left on the main thread. A pipe write blocks while the reader is busy, and the CLI on the far
/// end is a Node or Rust process doing an HTTP round trip when the code arrives — so the write
/// waits on somebody else's network, on the thread that draws.
///
/// It owns the descriptor for the reason `ChildOutputStream` owns its own: closing it from a
/// second place races a write already inside the kernel, and the number the kernel hands out next
/// belongs to an unrelated file. Every use is confined to one serial queue, so the close is
/// ordered behind the writes that preceded it.
final class AgentAccountSignInInput: @unchecked Sendable {

    private let queue = DispatchQueue(
        label: AgentAccountSignInDefaults.inputQueueLabel,
        qos: .userInitiated
    )

    /// Touched only on `queue`.
    private var descriptor: Int32

    /// - Parameter writeEnd: an open descriptor whose ownership transfers here. It is closed
    ///   exactly once, by `close()`, and must not be closed by the caller.
    init(writeEnd descriptor: Int32) {
        self.descriptor = descriptor
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard descriptor >= 0 else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                    if written > 0 {
                        offset += written
                        continue
                    }
                    if written < 0, errno == EINTR { continue }
                    // EPIPE, or anything else: the CLI has gone. Its exit status is what decides
                    // the attempt, so there is nothing to report from here.
                    return
                }
            }
        }
    }

    func close() {
        queue.async { [self] in
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    /// A dropped writer still closes, and does so without a queue hop.
    ///
    /// Both enqueued blocks capture this object strongly, so any pending write or close has
    /// already run by the time deinit can be reached — which makes this the one moment the
    /// descriptor is provably untouched by the queue.
    deinit {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
    }
}

// MARK: - Sign-In Prompt

/// What a running provider login has told the person they can do somewhere other than the
/// browser it opened for them.
///
/// Both login adapters launch a browser themselves *and* print the same authorization URL as a
/// fallback, because a launched browser is a guess: it is whichever browser LaunchServices calls
/// default, in whichever profile happens to be signed in. The printed line is the only place that
/// URL exists outside the window the CLI opened, so finishing a sign-in in a private window, a
/// second profile, or a different browser is possible only if Threading shows it.
///
/// It is presentation, not credential: an OAuth authorization URL carries a public client id, a
/// PKCE *challenge* and a state nonce. The verifier that redeems it stays inside the CLI, which is
/// why surfacing this changes nothing about who owns the login.
struct AgentAccountSignInPrompt: Equatable, Sendable {

    /// The URL the CLI printed for a person to open themselves.
    let url: URL

    /// Whether this provider's fallback flow ends by reading a code back from its own stdin.
    ///
    /// The two adapters differ, and the difference is the whole reason this is a field rather
    /// than an assumption. Codex prints a `http://localhost:1455/…` redirect, so its fallback URL
    /// completes by itself in any browser on this Mac. Claude Code's fallback URL redirects to a
    /// page that *displays* a code instead, and the CLI waits on stdin for it — so without a way
    /// to hand that code back, showing its link would be an invitation to a dead end.
    let acceptsPastedCode: Bool

    /// True once a code has been handed to the CLI, so the row can say a second paste is allowed.
    var hasSentCode = false
}

// MARK: - Sign-In Output Scanner

/// Finds the sign-in URL in a provider login's own output, and keeps none of the rest.
///
/// The bound that matters here is the amount *examined*, not the amount kept: a login child may
/// print for as long as the person takes to sign in, and it prints again for every code it
/// rejects. So this stops looking the moment it has a URL — every later byte is read and dropped
/// by the caller, which must keep draining the pipe so the child is never stopped by a full one.
///
/// Until then it holds one bounded carry, because a read boundary can land in the middle of a
/// 500-character URL and the two halves arrive as separate chunks. Carrying only the unterminated
/// tail (or the last few characters, when a chunk ends mid-`https://`) is what makes a split URL
/// recoverable without accumulating output.
struct AgentAccountSignInScanner {

    // MARK: - Properties

    private(set) var url: URL?
    private var carry = ""

    /// The one piece of state whose *size* is the contract, so a test can hold it to it.
    var carriedCharactersForTesting: Int { carry.count }

    // MARK: - Public Methods

    /// Consumes one burst of child output.
    ///
    /// - Returns: the URL on the burst that completes it, and nil every time before and after, so
    ///   a caller can treat a non-nil answer as "this just became known".
    mutating func consume(_ text: String) -> URL? {
        guard url == nil else { return nil }

        let pending = carry + text
        carry = ""
        var searchStart = pending.startIndex

        while let schemeRange = pending.range(
            of: AgentAccountSignInDefaults.scheme,
            range: searchStart..<pending.endIndex
        ) {
            var end = schemeRange.upperBound
            while end < pending.endIndex, Self.isURLCharacter(pending[end]) {
                end = pending.index(after: end)
            }

            if end == pending.endIndex {
                // The chunk ended inside a candidate. Keep it whole for the next burst rather
                // than accepting a URL that is merely the part that has arrived so far.
                carry = Self.bounded(String(pending[schemeRange.lowerBound...]))
                return nil
            }

            let candidate = Self.trimmingSentencePunctuation(
                String(pending[schemeRange.lowerBound..<end])
            )
            if let resolved = Self.validated(candidate) {
                url = resolved
                return resolved
            }
            searchStart = end
        }

        // No candidate at all: carry just enough that a scheme split across the boundary is
        // still recognisable next time.
        carry = String(pending.suffix(AgentAccountSignInDefaults.scheme.count - 1))
        return nil
    }

    // MARK: - Private Methods

    /// Everything a URL may contain, stated as what ends one: whitespace, any control character
    /// (which is also how an escape sequence terminates a candidate), and the quoting and
    /// bracketing characters prose wraps links in.
    private static func isURLCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return false }
        guard scalar.value > 0x20, scalar.value != 0x7F else { return false }
        return !AgentAccountSignInDefaults.terminators.contains(character)
    }

    /// Drops the punctuation that belongs to the sentence rather than to the link.
    private static func trimmingSentencePunctuation(_ candidate: String) -> String {
        var trimmed = candidate
        while let last = trimmed.last,
              AgentAccountSignInDefaults.trailingPunctuation.contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Accepts only an absolute `https` URL with a host, so a bare scheme or a log line reading
    /// `https://` is not offered to somebody as a link.
    private static func validated(_ candidate: String) -> URL? {
        guard let url = URL(string: candidate),
              url.scheme?.lowercased() == AgentAccountSignInDefaults.expectedScheme,
              let host = url.host,
              !host.isEmpty else { return nil }
        return url
    }

    private static func bounded(_ carry: String) -> String {
        guard carry.count > AgentAccountSignInDefaults.maximumCarryCharacters else { return carry }
        // Longer than any authorization URL these CLIs print, so it is output of some other kind
        // that happens to start with the scheme. Dropping it keeps the carry constant-sized.
        return ""
    }
}

// MARK: - Defaults

enum AgentAccountSignInDefaults {
    static let scheme = "https://"
    static let expectedScheme = "https"
    static let maximumCarryCharacters = 2_048
    static let inputQueueLabel = "codes.threading.account-setup.sign-in-input"
    static let terminators: Set<Character> = ["\"", "'", "<", ">", "`", "\\"]
    static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]
}
