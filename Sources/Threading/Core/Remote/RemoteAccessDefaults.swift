import Foundation

/// Tunables for remote access — the second loopback HTTP/WebSocket server that the selected HTTPS
/// transports expose so a session can be watched and driven from a browser or the iOS app.
///
/// This server is deliberately separate from `MCPServer` and `ExtensionHostService`: those
/// endpoints broker tool permissions and host extensions, and the tunnel must never reach
/// them. A value here is a decision about the one surface a remote client can touch.
enum RemoteAccessDefaults {

    // MARK: - Listener

    /// Loopback only. A selected transport forwards to this port; nothing binds to a routable address.
    static let host = "127.0.0.1"

    /// The serial queue that owns the listener, every connection's I/O, WebSocket framing and
    /// the broadcast fan-out. Stores and AppKit are main-only, so anything touching them hops.
    static let queueLabel = "codes.threading.remote"

    /// Ceiling on concurrent connections. A tunnel is a public URL; a flood of half-open
    /// sockets should cost a bounded amount of memory, not an unbounded one.
    static let maximumConnections = 32

    // MARK: - HTTP phase

    /// A request that never completes must not grow a connection's buffer forever.
    static let maximumRequestBytes = 1 * 1024 * 1024

    /// How long a connection may sit in the HTTP phase (no upgrade, no complete request) before
    /// it is closed. A tunnel attracts probes that open a socket and say nothing.
    static let httpIdleSeconds: TimeInterval = 60

    // MARK: - WebSocket

    /// Largest single WebSocket frame (and reassembled message) accepted from a client. Terminal
    /// input and control messages are tiny; anything approaching this is a client misbehaving.
    static let maximumFrameBytes = 1 * 1024 * 1024

    /// The frame ceiling protects the parser; these action-specific ceilings protect the main
    /// actor from a valid-token client queuing megabyte-sized keystrokes or prompts faster than
    /// AppKit can consume them. A terminal paste may still be substantial, while a native prompt
    /// gets more room for code and logs.
    static let maximumBearerTokenBytes = 256
    static let maximumDeviceIDBytes = 128
    static let maximumMemberNameBytes = 120

    /// What a name field may weigh **before** it is normalized.
    ///
    /// `normalizedMemberName` strips control characters and collapses runs of whitespace, so it
    /// cannot judge the length until it has done that work — and the work is one `String` per
    /// scalar. A megabyte frame of spaces therefore bought a megabyte of allocation to produce a
    /// name that was going to be refused for being empty. The result can only ever shrink, so
    /// the ceiling is generous rather than exact: sixteen times the answer's own limit leaves
    /// room for any real name plus padding, and refuses the frame-sized ones outright.
    static let maximumNameInputBytes = maximumMemberNameBytes * 16
    static let maximumTerminalInputBytes = 64 * 1024
    static let maximumPromptBytes = 256 * 1024
    static let maximumPermissionIDBytes = 256
    static let maximumThemeIDBytes = 256
    static let maximumSessionTitleBytes = 1 * 1024
    static let maximumLaunchIdentifierBytes = 256
    static let maximumRepositoryPathBytes = 16 * 1024
    static let maximumAttachmentBytes = 24 * 1024 * 1024
    static let maximumPushDeviceTokenBytes = 256
    static let maximumNotificationTitleBytes = 160
    static let maximumNotificationBodyBytes = 1_500
    static let attentionRequestCooldown: TimeInterval = 30
    /// A guest can cross a brief network handoff without losing control. After this grace the
    /// Mac owner gets control back, so a dead phone cannot strand a shared terminal.
    static let focusedControllerDisconnectGrace: TimeInterval = 30

    /// A freshly upgraded socket must send its `auth` frame within this window or be closed. The
    /// browser `WebSocket` API cannot set headers, so the token arrives in the first frame — an
    /// unauthenticated socket that lingers is refused rather than served.
    static let authDeadlineSeconds: TimeInterval = 5

    /// Protocol-level ping cadence, and how many consecutive missed pongs close the socket. Also
    /// the tick on which expiry and revocation are swept.
    static let pingIntervalSeconds: TimeInterval = 30
    static let missedPongLimit = 2

    /// A slow remote consumer is dropped rather than buffered: if a connection's unsent outbound
    /// bytes exceed this, it is closed (1013). A live terminal must never back-pressure the mirror.
    static let outboundHighWaterBytes = 2 * 1024 * 1024

    /// A selected image/PDF is served over a closing HTTP response rather than the live socket.
    /// The serialized head is tiny; this margin keeps the explicit response cap easy to audit.
    static let maximumAttachmentResponseBytes = maximumAttachmentBytes + 64 * 1024

    /// The initial conversation window and each requested history page stay well below the
    /// connection high-water mark. Live changes travel as row deltas after that first window.
    static let maximumRemoteConversationRows = 160
    static let maximumRemoteConversationPageRows = 64
    static let maximumRemoteConversationContentBytes = 128 * 1024
    static let maximumRemoteConversationFieldBytes = 32 * 1024
    static let maximumRemoteStreamingBytes = 32 * 1024
    static let maximumRemotePermissionBytes = 64 * 1024
    static let maximumRemoteComposerCapabilities = 256
    static let maximumRemoteComposerCapabilityBytes = 64 * 1024

    // MARK: - Terminal mirror

    /// Per-session ring of the most recent raw PTY bytes, replayed verbatim into a joining
    /// client so it sees roughly the current screen. Large enough to hold a full TUI repaint.
    static let ringBufferBytes = 512 * 1024

    // MARK: - Auth rate limiting

    /// Failed-auth attempts (bad token, unapproved device rejected) are counted per device and
    /// globally over this rolling window; past the limit the source is refused without detail.
    static let failedAuthWindow: TimeInterval = 60
    static let failedAuthLimitPerDevice = 10
    static let failedAuthLimitGlobal = 60

    // MARK: - Shares

    /// A minted share expires after this unless the caller chose otherwise. A share is a public
    /// door, so it closes on its own rather than staying open until someone remembers to revoke.
    static let defaultShareExpiry: TimeInterval = 24 * 60 * 60

    /// A consumed owner bootstrap is cached just long enough for the same device to retry a lost
    /// acceptance response. The QR rotates immediately, so a photographed old code cannot pair a
    /// second device during this window.
    static let pairingRetrySeconds: TimeInterval = 60
    static let maximumPendingSharePreparations = 32
    static let sharePreparationTimeout: TimeInterval = 20

    // MARK: - Mutation replay

    static let maximumMutationRequestIDBytes = 80
    static let maximumMutationReplayEntries = 256
    static let maximumMutationReplayWaiters = 8
    static let mutationReplayLifetime: TimeInterval = 5 * 60

    /// WebSocket prompts become safely retryable only while their compact result remains in this
    /// in-memory cache. Nothing here persists prompt text; only a SHA-256 fingerprint and status
    /// are retained, bounded across all live sessions.
    static let maximumPromptReplayEntries = 256
    static let promptReplayLifetime: TimeInterval = 5 * 60

    /// How long the device-approval poll (`GET /api/me` returning `pendingApproval`) waits
    /// between polls, echoed to the client so the two agree.
    static let approvalPollSeconds: TimeInterval = 2
}
