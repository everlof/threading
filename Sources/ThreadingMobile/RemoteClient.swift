import Foundation
import ThreadingExtensionKit
import ThreadingRemoteKit
import UIKit

enum RemoteDeviceIdentity {
    static var current: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "remoteDeviceID") {
            return existing
        }
        let made = UUID().uuidString.lowercased()
        defaults.set(made, forKey: "remoteDeviceID")
        return made
    }

    /// What the Mac's sharing pane calls this device — "iPhone", "iPad".
    ///
    /// The *model*, not `UIDevice.name`: the user-assigned name is entitlement-gated and, where
    /// it is readable at all, is usually the owner's own first name. A row that has to be
    /// recognised across a room wants the kind of device, and the pane already prints who the
    /// member is beside it.
    @MainActor static var currentName: String {
        UIDevice.current.model
    }
}

enum RemoteClientDefaults {
    static let requestTimeoutSeconds: TimeInterval = 20
    static let resourceTimeoutSeconds: TimeInterval = 30
    /// The conditional-request header carrying the catalogue edition in hand, and the status a
    /// host answers with when that edition is still current.
    static let ifNoneMatchHeader = "If-None-Match"
    static let notModifiedStatus = 304
    /// Concurrent connections the request session keeps to one Mac. Enough for a catalogue,
    /// a few media downloads and a mutation side by side; few enough that a gallery cannot
    /// spend the host's admission cap on its own.
    static let maximumConnectionsPerHost = 6
    /// A support report carries a bounded journal and may carry a screenshot preview, so its
    /// upload is given longer than a control-plane request before the whole transfer is abandoned.
    static let reportResourceTimeoutSeconds: TimeInterval = 60
    /// How far down a Foundation error chain the local-network diagnosis will look. Underlying
    /// errors nest, and an unbounded walk over attacker- or framework-controlled `userInfo` is
    /// not a bound.
    static let underlyingErrorDepthLimit = 4
}

/// Which private-network addresses iOS asks for Local Network permission before reaching.
///
/// The denial produces an ordinary no-route POSIX error, identical to the one a genuinely
/// unreachable host produces, so the address is what separates "you did not grant this" from
/// "that machine is off". Loopback is deliberately absent: it needs no grant.
enum RemoteLocalNetworkAddress {
    static func isPrivate(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered.hasSuffix(".local") { return true }
        if lowered.hasPrefix("fe80:") { return true }
        // Unique local addresses, fc00::/7.
        if lowered.hasPrefix("fc") || lowered.hasPrefix("fd") {
            if lowered.contains(":") { return true }
        }
        let parts = lowered.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch octets[0] {
        case 10: return true
        case 169: return octets[1] == 254
        case 172: return (16 ... 31).contains(octets[1])
        case 192: return octets[1] == 168
        default: return false
        }
    }
}

/// What `/api/me` answered a request that named the edition already in hand.
enum RemoteCatalogueFetch: Sendable {
    case catalogue(RemoteMeDTO)
    /// The host's catalogue is still the edition the request named; the body was not sent.
    case notModified
}

enum RemoteClientError: LocalizedError {
    case invalidResponse
    case unauthorized
    /// A `426` naming the side that is behind. The direction is kept because it decides the
    /// sentence: the same refusal means "update this app" one way and "this Mac needs a newer
    /// app" the other, and telling somebody to update the wrong device is worse than saying
    /// nothing.
    case upgradeRequired(RemoteUpdateTarget)
    /// An authoritative HTTP refusal. `code` and `detail` are absent when the Mac predates
    /// structured REST errors; the status remains the compatibility fallback.
    case server(status: Int, code: String? = nil, detail: String? = nil)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return MobileL10n.string("The Mac returned an unreadable response.")
        case .unauthorized:
            return MobileL10n.string(
                "This invitation is expired or already used, or this membership was revoked."
            )
        case let .upgradeRequired(target):
            return Self.upgradeMessage(for: target)
        case let .server(status, code, detail):
            return Self.serverMessage(status: status, code: code, detail: detail)
        }
    }

    var statusCode: Int? {
        guard case let .server(status, _, _) = self else { return nil }
        return status
    }

    var refusalCode: String? {
        guard case let .server(_, code, _) = self else { return nil }
        return code
    }

    var refusalDetail: String? {
        guard case let .server(_, _, detail) = self else { return nil }
        return detail
    }

    /// A status-only 502/503/504 can have come from a route's gateway. Once the Mac supplies a
    /// bounded refusal code, that answer is authoritative and must not be replaced by a later
    /// route's transport failure.
    var allowsMutationRouteFailover: Bool {
        guard case let .server(status, code, _) = self,
              code == nil else { return false }
        return [502, 503, 504].contains(status)
    }

    var requiresLaunchCatalogRefresh: Bool {
        guard let refusalCode else { return false }
        return Self.launchCatalogRefusalCodes.contains(refusalCode)
    }

    private static let launchCatalogRefusalCodes = Set([
        RemoteRESTErrorCode.unknownLaunchChoice.rawValue,
        RemoteRESTErrorCode.unknownAccount.rawValue,
        RemoteRESTErrorCode.unknownModel.rawValue,
        RemoteRESTErrorCode.unknownReasoningEffort.rawValue,
        RemoteRESTErrorCode.unknownPermissionMode.rawValue,
        RemoteRESTErrorCode.unsupportedSpeed.rawValue,
        RemoteRESTErrorCode.unsupportedSurface.rawValue,
        RemoteRESTErrorCode.unknownRole.rawValue,
        RemoteRESTErrorCode.unsupportedWorkspace.rawValue,
    ])

    static func decodedRefusal(status: Int, data: Data) -> RemoteClientError {
        let payload = try? JSONDecoder().decode(RemoteErrorDTO.self, from: data)
        let error = payload?.type == "error" ? payload : nil
        if status == 401,
           error?.code == nil || error?.code == RemoteRESTErrorCode.unauthorized.rawValue
        {
            return .unauthorized
        }
        return .server(status: status, code: error?.code, detail: error?.detail)
    }

    private static func serverMessage(status: Int, code: String?, detail: String?) -> String {
        switch code.flatMap(RemoteRESTErrorCode.init(rawValue:)) {
        case .unknownLaunchChoice:
            return MobileL10n.string(
                "That project or agent is no longer available. Threading is refreshing the choices; review them and try again."
            )
        case .unknownAccount:
            return MobileL10n.string(
                "That account is no longer available. Threading is refreshing the choices; review them and try again."
            )
        case .unknownModel:
            return MobileL10n.string(
                "That model is no longer available for this account. Threading is refreshing the choices; review them and try again."
            )
        case .unknownReasoningEffort:
            return MobileL10n.string(
                "That reasoning level is no longer available for this model. Threading is refreshing the choices; review them and try again."
            )
        case .unknownPermissionMode:
            return MobileL10n.string(
                "That permission mode is no longer supported by this agent. Review the updated choices and try again."
            )
        case .unsupportedSpeed:
            return MobileL10n.string(
                "That speed is not available for this model. Review the updated choices and try again."
            )
        case .unsupportedSurface:
            return MobileL10n.string(
                "That interface is not available for this agent. Review the updated choices and try again."
            )
        case .unknownRole:
            return MobileL10n.string(
                "That session role is no longer available. Review the updated choices and try again."
            )
        case .unsupportedWorkspace:
            return MobileL10n.string(
                "That workspace option is not available for this project and agent. Review the updated choices and try again."
            )
        case .invalidReportOpening:
            return MobileL10n.string(
                "The screenshot preview could not be prepared. Remove it and try again."
            )
        case .invalidInvitation:
            return MobileL10n.string("This invitation is expired or already used.")
        case .invalidRequestID, .requestIDReused:
            return MobileL10n.string("The Mac couldn’t safely identify that action. Try again.")
        case .replayCacheBusy:
            return MobileL10n.string("The Mac is handling too many actions right now. Try again.")
        case .responseTooLarge:
            return MobileL10n.string("The Mac couldn’t return that result safely.")
        case .hostNotReady:
            return MobileL10n.string("The Mac isn’t ready for that action yet. Try again.")
        case .storageExhausted:
            return MobileL10n.string(
                "The Mac is out of storage space. Free up space on the Mac, then try again."
            )
        case .persistenceUnavailable:
            return MobileL10n.string("The Mac couldn’t save that change. Try again.")
        case .unknownTheme:
            return MobileL10n.string("That theme is no longer available on the Mac.")
        case .unknownSetting, .settingNotMutable, .invalidSettingValue, .unsupportedValue:
            return MobileL10n.string("That setting can’t be changed to the selected value.")
        case .unsupportedRuntime:
            return MobileL10n.string("That action isn’t supported by this agent.")
        case .unsupportedAccount:
            return MobileL10n.string("That account isn’t available for this session.")
        case .unsupportedRecovery:
            return MobileL10n.string("That recovery option isn’t available for this session.")
        case .archiveAlreadyChanging:
            return MobileL10n.string("This session’s archive state is already changing.")
        case .archiveAccountUnavailable:
            return MobileL10n.string("The Mac can’t find the account that owns this session.")
        case .archiveCommandUnavailable:
            return MobileL10n.string("The Mac couldn’t start the agent’s archive command.")
        case .archiveCommandRejected:
            return MobileL10n.string("The agent rejected the archive change.")
        case .invalidSnoozeDeadline:
            return MobileL10n.string("That reminder time is no longer valid.")
        case .accountMoveRefused:
            return accountMoveMessage(detail: detail)
        case .continuationRefused:
            return continuationMessage(detail: detail)
        case .sharingNotAvailable, .hostedServiceUnavailable:
            return MobileL10n.string("That service isn’t available on the Mac right now. Try again.")
        case .ownerAccessRequired:
            return MobileL10n.string("Only the Mac owner can perform that action.")
        case .invalidDevice:
            return MobileL10n.string("The Mac couldn’t identify this iPhone. Pair it again.")
        case .invalidDeviceToken:
            return MobileL10n.string("The Mac couldn’t register this iPhone for notifications.")
        case .localDiagnosticsDisabled:
            return MobileL10n.string("Local diagnostics is disabled on the Mac.")
        case .captureNotRequested:
            return MobileL10n.string("The Mac did not request this diagnostics capture.")
        case .rateLimited:
            return MobileL10n.string("The Mac received too many requests. Wait a moment and try again.")
        default:
            return MobileL10n.string("The Mac returned HTTP %lld.", status)
        }
    }

    /// The Mac's bounded refusal reasons, worded for a phone. An unrecognised or absent detail
    /// is the honest general sentence rather than a guessed cause — a capture failure sends no
    /// code, and a newer Mac may name one this build has never heard of.
    private static func continuationMessage(detail: String?) -> String {
        switch detail {
        case "missingSource":
            return MobileL10n.string("This chat no longer exists.")
        case "sameProvider":
            return MobileL10n.string("A chat can only continue on a different agent.")
        case "nothingRecorded":
            return MobileL10n.string("This chat has nothing recorded to continue from yet.")
        case "persistenceUnavailable", "sessionCreateFailed":
            return MobileL10n.string("The Mac couldn’t save the new chat.")
        case "handoffUnavailable":
            return MobileL10n.string("The Mac couldn’t prepare this chat for another agent.")
        case "snapshotWriteFailed":
            return MobileL10n.string("The Mac couldn’t snapshot this conversation.")
        default:
            return MobileL10n.string("The Mac couldn’t continue this chat on that agent.")
        }
    }

    private static func accountMoveMessage(detail: String?) -> String {
        switch detail {
        case "missingSession":
            return MobileL10n.string("This session no longer exists.")
        case "providerMismatch":
            return MobileL10n.string("A session can only move to another account for the same agent.")
        case "missingTranscript":
            return MobileL10n.string("This session has no recorded conversation to move yet.")
        case "invalidSourceLocation":
            return MobileL10n.string("The Mac couldn’t locate this conversation on disk.")
        case "persistenceUnavailable", "commitRefused":
            return MobileL10n.string("The Mac couldn’t save the moved conversation.")
        case "sourceNotRegular":
            return MobileL10n.string("The conversation transcript is not a regular file.")
        case "rollbackNeedsRecovery":
            return MobileL10n.string(
                "The move couldn’t be saved. The Mac kept the previous target copy for recovery."
            )
        case "copyFailed":
            return MobileL10n.string("The Mac couldn’t copy the conversation.")
        default:
            return MobileL10n.string("The Mac couldn’t move this session to that account.")
        }
    }

    static func upgradeMessage(for target: RemoteUpdateTarget) -> String {
        switch target {
        case .client:
            return MobileL10n.string(
                "This version of Threading can’t connect to this Mac. Update Threading and try again."
            )
        case .host:
            return MobileL10n.string(
                "This Mac needs a newer version of Threading. Update Threading on the Mac and try again."
            )
        }
    }
}

/// Where a person goes to get the newer app either side of a refused protocol version.
///
/// One address for both directions on purpose: it is the page that hands out the Mac app and
/// links the iPhone one, so it is right whichever side the Mac says is behind. Replace it with a
/// direct App Store product link for the `client` direction once that listing exists.
enum RemoteUpdateDefaults {
    static let downloadPage = URL(string: "https://threading.codes")!
}

/// Why a remote connection stopped, in a form a screen can act on.
///
/// A localized sentence is not a state. The 2026-08-17 incident produced a phone stuck on
/// "Connecting…" and a support report that could say only that something answered and it was not
/// the Mac; both halves of that are fixed by naming the cause, keeping a structural code beside
/// the sentence a person reads, and stating what the one available next step is.
struct RemoteConnectionFailure: Equatable {
    /// What the person can do about it, which is not always "try again".
    enum Recovery: Equatable {
        case reconnect
        case pairAgain
        case openLocalNetworkSettings
        case openUpdatePage(URL)
    }

    enum Cause: String, Equatable {
        /// The address answered, and what answered was not this Mac's listener. A Quick Tunnel
        /// hostname outlives the tunnel, so a paired phone keeps reaching a stranger's 404.
        case addressChanged
        /// The address answered with a certificate that is not the one this phone pinned.
        ///
        /// Never folded into `addressChanged` or into a generic network error: those two say
        /// "the Mac moved" and "the network is unhappy", and this says something presented a
        /// different identity at the Mac's address. It is the one failure whose only honest
        /// remedy is scanning the code again, and only after checking that the Mac is the one
        /// that changed.
        case pinnedIdentityMismatch
        /// iOS refused the connection because Local Network access was never granted. It is a
        /// no-route POSIX error on a private address, which is indistinguishable from an absent
        /// host until the address is taken into account.
        case localNetworkDenied
        /// One side is too old for the other. The message says which.
        case upgradeRequired
        /// The socket opened and the Mac never greeted it.
        case helloTimeout
        /// The Mac refused an action over an otherwise healthy socket.
        case remoteAction
        /// Anything else the transport reported.
        case transport
    }

    let cause: Cause
    let message: String
    /// Where the person is sent for `upgradeRequired`, which is the only cause carrying an
    /// address of its own.
    let updatePage: URL?

    init(cause: Cause, message: String, updatePage: URL? = nil) {
        self.cause = cause
        self.message = message
        self.updatePage = updatePage
    }

    var recovery: Recovery {
        switch cause {
        case .addressChanged, .pinnedIdentityMismatch: return .pairAgain
        case .localNetworkDenied: return .openLocalNetworkSettings
        case .upgradeRequired:
            return .openUpdatePage(updatePage ?? RemoteUpdateDefaults.downloadPage)
        case .helloTimeout, .remoteAction, .transport: return .reconnect
        }
    }

    /// The one-tap next step, as the label a control or an accessibility hint uses.
    var recoveryTitle: String {
        switch recovery {
        case .reconnect: return MobileL10n.string("Reconnect")
        case .pairAgain: return MobileL10n.string("Scan the QR code again")
        case .openLocalNetworkSettings: return MobileL10n.string("Open Settings")
        case .openUpdatePage: return MobileL10n.string("Open the download page")
        }
    }

    static func helloTimeout() -> RemoteConnectionFailure {
        RemoteConnectionFailure(
            cause: .helloTimeout,
            message: MobileL10n.string("This Mac accepted the connection but never answered.")
        )
    }

    static func remoteAction(_ message: String) -> RemoteConnectionFailure {
        RemoteConnectionFailure(cause: .remoteAction, message: message)
    }

    static func transport(_ message: String) -> RemoteConnectionFailure {
        RemoteConnectionFailure(cause: .transport, message: message)
    }

    static func upgradeRequired(_ target: RemoteUpdateTarget) -> RemoteConnectionFailure {
        RemoteConnectionFailure(
            cause: .upgradeRequired,
            message: RemoteClientError.upgradeMessage(for: target),
            updatePage: RemoteUpdateDefaults.downloadPage
        )
    }

    static func pinnedIdentityMismatch() -> RemoteConnectionFailure {
        RemoteConnectionFailure(
            cause: .pinnedIdentityMismatch,
            message: MobileL10n.string(
                "This Mac’s identity does not match the one you paired with. "
                    + "If Remote Access was reset on the Mac, scan its QR code again."
            )
        )
    }

    /// Classifies a transport error against the address it was aimed at.
    ///
    /// The address is part of the diagnosis rather than decoration: Local Network denial and an
    /// absent host produce the same POSIX code, and only a private destination makes the
    /// permission the likelier of the two. Nothing here is mapped to "address changed" unless
    /// the socket really did get an HTTP answer that was not an upgrade.
    ///
    /// The pinning check is read first and from the delegate rather than from the error,
    /// because a cancelled server-trust challenge arrives as `URLError(-999)` with no underlying
    /// error and is indistinguishable from a user cancelling a request. The delegate's own
    /// verdict for that host is the only place the reason exists.
    static func transport(_ error: Error, host: String?) -> RemoteConnectionFailure {
        transport(
            error,
            host: host,
            trustVerdict: host.flatMap { RemoteClient.pinningDelegate.verdict(forHost: $0) }
        )
    }

    static func transport(
        _ error: Error,
        host: String?,
        trustVerdict: RemoteTrustVerdict?
    ) -> RemoteConnectionFailure {
        if trustVerdict == .rejectedFingerprintMismatch {
            return pinnedIdentityMismatch()
        }
        if let remote = error as? RemoteClientError, case let .upgradeRequired(target) = remote {
            return upgradeRequired(target)
        }
        if isLocalNetworkDenial(error, host: host) {
            return RemoteConnectionFailure(
                cause: .localNetworkDenied,
                message: MobileL10n.string(
                    "Threading needs Local Network access to reach this Mac on Wi-Fi. Turn it on in Settings."
                )
            )
        }
        if (error as? URLError)?.code == .badServerResponse {
            return RemoteConnectionFailure(
                cause: .addressChanged,
                message: MobileL10n.string(
                    "This Mac’s address has changed. Scan its QR code again."
                )
            )
        }
        return RemoteConnectionFailure(
            cause: .transport,
            message: error.localizedDescription
        )
    }

    static func isLocalNetworkDenial(_ error: Error, host: String?) -> Bool {
        guard let host, RemoteLocalNetworkAddress.isPrivate(host) else { return false }
        return hasNoRouteCode(error)
    }

    /// iOS reports the denial as `NWError.posix` under whichever URL-loading error wraps it, so
    /// the POSIX code has to be read through a bounded chain rather than off the top error.
    static func hasNoRouteCode(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let candidate = current, depth < RemoteClientDefaults.underlyingErrorDepthLimit {
            if candidate.domain == NSPOSIXErrorDomain,
               noRouteCodes.contains(Int32(candidate.code))
            {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    private static let noRouteCodes: Set<Int32> = [
        EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN,
    ]
}

/// A failure that says nothing about the route or the host: the connection under one request
/// went away, and the next connection is expected to work.
///
/// Distinguished from every other transport error because it is the one worth repeating at
/// once. A pooled keep-alive socket the host has just closed — after a `Connection: close`
/// response, at its idle bound, or past its admission cap — surfaces as
/// `URLError.networkConnectionLost` on the phone (`url.-1005` in the journal, 27 times in one
/// day's audit), or as a reset or a broken pipe beneath whichever URL-loading error wrapped it.
enum RemoteTransientTransportFailure {
    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return false
            case .networkConnectionLost: return true
            default: break
            }
        }
        var current: NSError? = error as NSError
        var depth = 0
        while let candidate = current, depth < RemoteClientDefaults.underlyingErrorDepthLimit {
            if candidate.domain == NSPOSIXErrorDomain,
               resetCodes.contains(Int32(candidate.code)) {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    private static let resetCodes: Set<Int32> = [ECONNRESET, EPIPE]
}

/// Why the rest of one door's sticky-port walk is not worth trying.
///
/// The walk exists for exactly one situation: the Mac's listener took another port of the sticky
/// range because its configured one was busy, at the same address. Two different failures rule
/// the remaining ports out, and they are not the same kind of fact.
///
/// - **The door answered.** An HTTP status, an authentication refusal, or a certificate that is
///   not the pinned one all came from a server. The Mac has said what it has to say and nine
///   more ports will not change it.
/// - **The address cannot be reached.** DNS and explicit network-routing failures rule out every
///   port at that address. A generic request timeout does not: one port may be filtered, or a
///   server may have accepted the connection and stalled before producing a response. Without
///   connection-phase evidence, the timeout belongs to that attempt rather than to the address.
///
/// A refusal is deliberately not on the list. `cannotConnectToHost` over a reachable address is
/// what a Mac says about a port nothing is listening on, which is the walk's whole reason to
/// exist — and it costs milliseconds rather than the timeout. When the same code arrives with a
/// no-route POSIX error beneath it the chain, not the top code, is what decides.
enum RemoteDoorWalk {
    /// What ended a door, as a bounded token a support report can carry.
    enum Ending: String {
        /// Something on the other side answered; the Mac's answer is the answer.
        case answered = "door.answered"
        /// Nothing was reachable at that address, so no port of it is.
        case unreachable = "door.unreachable"
    }

    /// The codes that belong to the address rather than to the port behind it.
    private static let unreachableURLCodes: Set<URLError.Code> = [
        .cannotFindHost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .dataNotAllowed,
        .internationalRoamingOff,
    ]

    /// Whether this failed attempt ends its door, and why. `nil` means keep walking the range.
    ///
    /// The address is deliberately not an input. `RemoteConnectionFailure` needs it because the
    /// same no-route code means "grant Local Network access" on a private address and "that
    /// machine is not answering" on a public one — but both of those mean the same thing to the
    /// walk, and no port of an address the phone cannot reach is reachable either.
    ///
    /// The trust verdict is passed in rather than read here for the reason
    /// `RemoteConnectionFailure.transport` takes it too: a cancelled server-trust challenge
    /// arrives as `URLError(-999)` with nothing underneath naming the pin, so the delegate's own
    /// verdict is the only place that reason exists.
    static func ending(for error: Error, trustVerdict: RemoteTrustVerdict?) -> Ending? {
        // The walk carries its failures wrapped in the address they were aimed at. That carrier
        // bridges to an `NSError` of its own, so reading the chain off it would find nothing.
        let failure = RemoteConnectionAttempt.underlying(error)
        if failure is RemoteClientError { return .answered }
        if trustVerdict == .rejectedFingerprintMismatch { return .answered }
        if let url = failure as? URLError, unreachableURLCodes.contains(url.code) {
            return .unreachable
        }
        // A Local Network denial and an absent machine arrive as the same POSIX code. Both mean
        // this address is not reachable from here, so both end the walk.
        if RemoteConnectionFailure.hasNoRouteCode(failure) { return .unreachable }
        return nil
    }
}

/// A named failure travelling as an error, for the two paths that hand one to a screen rather
/// than to a connection phase: pairing, and anything else that reports `localizedDescription`.
extension RemoteConnectionFailure: LocalizedError {
    var errorDescription: String? { message }
}

/// One failed attempt, carrying the address it was aimed at.
///
/// A Mac has several addresses and the phone tries them in order, so by the time the last error
/// reaches a screen the record's remembered address is not necessarily the one that failed. The
/// diagnosis depends on which: the same no-route code means "grant Local Network access" on a
/// private address and "that machine is not answering" on a public one.
struct RemoteConnectionAttempt: LocalizedError {
    let underlying: Error
    let host: String?

    /// The wrapper is a carrier, not a replacement: anything that reads a sentence off it gets
    /// the failure's own, never Foundation's "the operation could not be completed".
    var errorDescription: String? { underlying.localizedDescription }

    /// The original error, whether or not it was wrapped. Diagnostics reduce errors to a
    /// structural code, and the wrapper is not one of the codes worth recording.
    static func underlying(_ error: Error) -> Error {
        (error as? RemoteConnectionAttempt)?.underlying ?? error
    }
}

/// Share-safe URL loading evidence for one request.
///
/// The stage is useful even when a duration is absent: `tls` with no `tlsMS` means the task was
/// still negotiating TLS when it failed or was cancelled. URLSession does not expose addresses
/// here, and the protocol/path values are reduced to fixed tokens before entering diagnostics.
struct RemoteRequestMetrics: Equatable, Sendable {
    let stage: String
    let dnsMS: Int?
    let tcpMS: Int?
    let tlsMS: Int?
    let serverWaitMS: Int?
    let responseMS: Int?
    let networkProtocol: String?
    let networkPath: String
    let connectionReused: Bool

    init(
        domainLookupStart: Date?,
        domainLookupEnd: Date?,
        connectStart: Date?,
        connectEnd: Date?,
        secureConnectionStart: Date?,
        secureConnectionEnd: Date?,
        requestStart: Date?,
        requestEnd: Date?,
        responseStart: Date?,
        responseEnd: Date?,
        networkProtocolName: String?,
        isCellular: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        isMultipath: Bool,
        isReusedConnection: Bool
    ) {
        if responseStart != nil {
            stage = "response"
        } else if requestEnd != nil {
            stage = "server"
        } else if requestStart != nil {
            stage = "request"
        } else if secureConnectionStart != nil {
            stage = "tls"
        } else if connectStart != nil {
            stage = "tcp"
        } else if domainLookupStart != nil {
            stage = "dns"
        } else {
            stage = "queued"
        }
        dnsMS = Self.milliseconds(from: domainLookupStart, to: domainLookupEnd)
        tcpMS = Self.milliseconds(
            from: connectStart,
            to: secureConnectionStart ?? connectEnd
        )
        tlsMS = Self.milliseconds(from: secureConnectionStart, to: secureConnectionEnd)
        serverWaitMS = Self.milliseconds(from: requestEnd, to: responseStart)
        responseMS = Self.milliseconds(from: responseStart, to: responseEnd)
        networkProtocol = Self.protocolToken(networkProtocolName)
        var path = [isCellular ? "cellular" : "noncellular"]
        if isExpensive { path.append("expensive") }
        if isConstrained { path.append("constrained") }
        if isMultipath { path.append("multipath") }
        if path.count == 1 { path.append("ordinary") }
        networkPath = path.joined(separator: ".")
        connectionReused = isReusedConnection
    }

    init(_ metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else {
            self.init(
                domainLookupStart: nil,
                domainLookupEnd: nil,
                connectStart: nil,
                connectEnd: nil,
                secureConnectionStart: nil,
                secureConnectionEnd: nil,
                requestStart: nil,
                requestEnd: nil,
                responseStart: nil,
                responseEnd: nil,
                networkProtocolName: nil,
                isCellular: false,
                isExpensive: false,
                isConstrained: false,
                isMultipath: false,
                isReusedConnection: false
            )
            return
        }
        self.init(
            domainLookupStart: transaction.domainLookupStartDate,
            domainLookupEnd: transaction.domainLookupEndDate,
            connectStart: transaction.connectStartDate,
            connectEnd: transaction.connectEndDate,
            secureConnectionStart: transaction.secureConnectionStartDate,
            secureConnectionEnd: transaction.secureConnectionEndDate,
            requestStart: transaction.requestStartDate,
            requestEnd: transaction.requestEndDate,
            responseStart: transaction.responseStartDate,
            responseEnd: transaction.responseEndDate,
            networkProtocolName: transaction.networkProtocolName,
            isCellular: transaction.isCellular,
            isExpensive: transaction.isExpensive,
            isConstrained: transaction.isConstrained,
            isMultipath: transaction.isMultipath,
            isReusedConnection: transaction.isReusedConnection
        )
    }

    var diagnosticFields: [RemoteDiagnosticField: String] {
        var fields: [RemoteDiagnosticField: String] = [
            .networkStage: stage,
            .networkPath: networkPath,
            .connectionReused: connectionReused ? "true" : "false",
        ]
        if let dnsMS { fields[.dnsMS] = String(dnsMS) }
        if let tcpMS { fields[.tcpMS] = String(tcpMS) }
        if let tlsMS { fields[.tlsMS] = String(tlsMS) }
        if let serverWaitMS { fields[.serverWaitMS] = String(serverWaitMS) }
        if let responseMS { fields[.responseMS] = String(responseMS) }
        if let networkProtocol { fields[.networkProtocol] = networkProtocol }
        return fields
    }

    private static func milliseconds(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return max(Int((end.timeIntervalSince(start) * 1000).rounded()), 0)
    }

    private static func protocolToken(_ value: String?) -> String? {
        switch value?.lowercased() {
        case "h2": return "h2"
        case "h3": return "h3"
        case "http/1.0": return "http1.0"
        case "http/1.1": return "http1.1"
        case .some: return "other"
        case .none: return nil
        }
    }
}

/// One request owns one collector. URLSession calls the delegate before completing the async
/// request, and the lock makes the snapshot safe across its delegate queue and the caller task.
final class RemoteRequestMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RemoteRequestMetrics?

    var fields: [RemoteDiagnosticField: String] {
        lock.lock()
        defer { lock.unlock() }
        return stored?.diagnosticFields ?? [:]
    }

    /// The metrics as collected, for the connection panel. Nil until the task finished.
    var snapshot: RemoteRequestMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        stored = RemoteRequestMetrics(metrics)
        lock.unlock()
    }
}

struct RemoteClient {
    static let defaultRequestTimeout = RemoteClientDefaults.requestTimeoutSeconds

    let link: RemoteConnectionLink
    let requestTimeout: TimeInterval?
    /// The route the Mac advertised for this link. An address is only a fallback guess: a
    /// Tailscale IP and a VPN IP do not carry their transport kind in their spelling.
    let endpointKind: RemoteHostEndpointKind

    /// Whether a mutation whose answer was lost is sent once more to this same address. A route
    /// walk turns this off for every attempt but its last, because the next address replays the
    /// request under the same id anyway; see `MobileRouteWalkPlan`.
    let replaysLostResponse: Bool

    init(
        link: RemoteConnectionLink,
        requestTimeout: TimeInterval? = nil,
        endpointKind: RemoteHostEndpointKind? = nil,
        replaysLostResponse: Bool = true
    ) {
        self.link = link
        self.requestTimeout = requestTimeout
        self.endpointKind = endpointKind ?? PairedRemoteHost.endpointKind(for: link.baseURL)
        self.replaysLostResponse = replaysLostResponse
    }

    /// The one pinning delegate, shared by every session this client opens.
    ///
    /// A server-trust challenge goes to the *session-level* delegate whenever that method
    /// exists, which is what makes a `URLSessionWebSocketTask` go through the same check as a
    /// REST call. A socket on a session without it silently keeps stock evaluation, and stock
    /// evaluation refuses a Mac's self-signed leaf outright, so the failure would be a TLS error
    /// on the socket path alone. It is one object rather than two so a pin learned once is in
    /// force everywhere, and `RemoteHostTrust` is the only thing that writes to it.
    static let pinningDelegate = RemoteCertificatePinningDelegate()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = RemoteClientDefaults.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = RemoteClientDefaults.resourceTimeoutSeconds
        // A refresh walks several independently usable doors to the same Mac. Waiting here keeps
        // an unreachable first door suspended inside URLSession, so its per-door timeout never
        // becomes the failure that advances the walk to the next candidate. Every REST attempt
        // must terminalize promptly; the route loop, not URLSession, owns waiting and failover.
        configuration.waitsForConnectivity = false
        // One Mac, one pool. A gallery burst of a dozen thumbnails must queue behind a bounded
        // number of connections rather than open one each against a host that admits 32 in
        // total and closes every attachment response.
        configuration.httpMaximumConnectionsPerHost = RemoteClientDefaults.maximumConnectionsPerHost
        return URLSession(
            configuration: configuration,
            delegate: pinningDelegate,
            delegateQueue: nil
        )
    }()

    /// The WebSocket half deliberately does not share the request session's configuration.
    ///
    /// `waitsForConnectivity` turns an unreachable host into an indefinite wait rather than an
    /// error, and whether `URLSessionWebSocketTask` honours `timeoutIntervalForResource` is not
    /// established (the 2026-08-17 hang was never reproduced), so a socket opened through the
    /// request session had no failure path anyone could rely on: the receive loop awaited a
    /// message that never came, nothing reconnected, and the phone showed "Connecting…" until
    /// the user gave up. Here the connect fails immediately when there is no route, and the
    /// hello deadline in `RemoteSessionConnection` is the authority that bounds a host which
    /// accepts the connection and then says nothing. The resource timeout is left at its default
    /// on purpose: a healthy session socket is long-lived, and the request session's 30 seconds
    /// would be a ceiling on the conversation rather than on the handshake.
    private static let socketSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        return URLSession(
            configuration: configuration,
            delegate: pinningDelegate,
            delegateQueue: nil
        )
    }()

    /// The session support-report delivery uses, and the reason it is not `URLSession.shared`.
    ///
    /// `URLSession.shared` is the one session in this app that cannot be given a delegate, so the
    /// report intake was the single network path with no server-trust hook: nothing could decide
    /// what to do about the certificate it was offered, and nothing recorded what was decided. In
    /// the 2026-08-21 report that is exactly the hole — 250 deliveries, every one of them
    /// `url.-1200`, and no verdict anywhere in the journal saying whether an identity check had
    /// passed, refused, or never run. Sharing the one pinning delegate answers that question on
    /// this path too, and it is the same object rather than a second one so a pin learned
    /// anywhere is in force here as well.
    ///
    /// The intake is a public host today and stock evaluation is what `notPinned` falls through
    /// to, so this changes no accept/refuse outcome by itself. What it changes is that the outcome
    /// is now the app's, and observable.
    private static let reportSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // The outbox owns retry and its own backoff. Waiting inside URLSession would turn a
        // deliverable report into an indefinite suspension with no queued record to show for it.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = RemoteClientDefaults.reportResourceTimeoutSeconds
        return URLSession(
            configuration: configuration,
            delegate: pinningDelegate,
            delegateQueue: nil
        )
    }()

    /// Delivers one support report. The caller owns the request, the retry policy and the records.
    static func deliverIssueReport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await reportSession.data(for: request)
    }

    func fetchMe(
        timeout: TimeInterval? = nil,
        metrics: RemoteRequestMetricsCollector? = nil
    ) async throws -> RemoteMeDTO {
        switch try await fetchCatalogue(timeout: timeout, metrics: metrics) {
        case let .catalogue(me):
            return me
        case .notModified:
            // Not asked for: no validator was sent, so a host answering this way is not one
            // this client can reason about.
            throw RemoteClientError.invalidResponse
        }
    }

    /// The catalogue, or the host's word that the edition this phone named is still current.
    ///
    /// `ifNoneMatch` is the entity tag of the catalogue in hand. The Mac answers `304` with no
    /// body when its catalogue is still that edition, which costs one round trip and no
    /// decoding; an older Mac that knows no validators ignores the header and answers in full,
    /// which is also correct. `URLSession` advertises gzip and inflates a compressed body
    /// before it reaches here, so nothing on this side reads `Content-Encoding`. This runs off
    /// the caller's actor — `RemoteClient` is not isolated — so a large body is decoded on a
    /// worker even when the model awaits it from the main actor.
    func fetchCatalogue(
        timeout: TimeInterval? = nil,
        metrics: RemoteRequestMetricsCollector? = nil,
        ifNoneMatch: String? = nil
    ) async throws -> RemoteCatalogueFetch {
        var request = request(url: link.meURL)
        if let timeout { request.timeoutInterval = timeout }
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: RemoteClientDefaults.ifNoneMatchHeader)
        }
        let (data, response): (Data, URLResponse)
        if let metrics {
            (data, response) = try await Self.session.data(for: request, delegate: metrics)
        } else {
            (data, response) = try await Self.session.data(for: request)
        }
        if ifNoneMatch != nil,
           let http = response as? HTTPURLResponse,
           http.statusCode == RemoteClientDefaults.notModifiedStatus {
            return .notModified
        }
        return .catalogue(try decodeMe(data: data, response: response))
    }

    func fetchUsage(
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> RemoteUsageDashboardDTO {
        try await get(
            RemoteUsageDashboardDTO.self,
            from: link.usageURL(cursor: cursor, limit: limit)
        )
    }

    func fetchUsageLimit(seriesID: String, days: Int) async throws -> RemoteUsageLimitDTO {
        try await get(
            RemoteUsageLimitDTO.self,
            from: link.usageLimitURL(seriesID: seriesID, days: days)
        )
    }

    func fetchBankedUsageResetOffer(
        seriesID: String
    ) async throws -> RemoteBankedUsageResetOfferDTO {
        try await get(
            RemoteBankedUsageResetOfferDTO.self,
            from: link.usageResetURL(seriesID: seriesID)
        )
    }

    func consumeBankedUsageReset(
        _ offer: RemoteBankedUsageResetOfferDTO,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteBankedUsageResetResponseDTO {
        try await postResponse(
            RemoteBankedUsageResetRequestDTO(
                seriesID: offer.seriesID,
                availableCount: offer.availableCount,
                offerFingerprint: offer.offerFingerprint,
                letsProviderChooseCredit: offer.letsProviderChooseCredit
            ),
            to: link.usageResetURL,
            requestID: requestID
        )
    }

    func search(
        _ query: RemoteSearchRequestDTO,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteSearchResponseDTO {
        try await postResponse(query, to: link.searchURL, requestID: requestID)
    }

    func resolveSearchResult(
        token: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteSearchResolutionDTO {
        try await postResponse(
            RemoteSearchResolveRequestDTO(token: token),
            to: link.searchResolveURL,
            requestID: requestID
        )
    }

    func acceptInvitation(
        displayName: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteAcceptInvitationResponseDTO {
        try await postResponse(
            RemoteAcceptInvitationRequestDTO(displayName: displayName),
            to: link.invitationAcceptanceURL,
            requestID: requestID
        )
    }

    func issueHostedDeviceCredential(
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteHostedDeviceCredentialDTO {
        try await postResponse(
            RemoteHostedDeviceCredentialRequestDTO(),
            to: link.hostedDeviceCredentialURL,
            requestID: requestID
        )
    }

    func resume(
        sessionID: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws {
        var request = request(url: link.resumeURL(sessionID: sessionID))
        request.httpMethod = "POST"
        request.setValue(requestID, forHTTPHeaderField: RemoteHeader.requestID.rawValue)
        let (data, response) = try await dataReplayingNetworkFailure(for: request)
        _ = try validate(data: data, response: response, accepted: 200 ... 299)
    }

    func resumeTerminal(
        terminalID: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws {
        var request = request(url: link.resumeTerminalURL(terminalID: terminalID))
        request.httpMethod = "POST"
        request.setValue(requestID, forHTTPHeaderField: RemoteHeader.requestID.rawValue)
        let (data, response) = try await dataReplayingNetworkFailure(for: request)
        _ = try validate(data: data, response: response, accepted: 200 ... 299)
    }

    func setAppTheme(
        themeID: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetAppThemeRequestDTO(themeID: themeID),
            to: link.appThemeURL,
            requestID: requestID
        )
    }

    func setSessionTheme(
        sessionID: String,
        themeID: String?,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetTerminalThemeRequestDTO(themeID: themeID),
            to: link.sessionThemeURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func createSession(
        _ creation: RemoteCreateSessionRequestDTO,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteCreateSessionResponseDTO {
        try await postResponse(creation, to: link.createSessionURL, requestID: requestID)
    }

    func renameSession(
        sessionID: String,
        title: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteRenameSessionRequestDTO(title: title),
            to: link.renameSessionURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func setSessionPinned(
        sessionID: String,
        isPinned: Bool,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionPinnedRequestDTO(isPinned: isPinned),
            to: link.pinnedSessionURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func setSessionArchived(
        sessionID: String,
        isArchived: Bool,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionArchivedRequestDTO(isArchived: isArchived),
            to: link.archivedSessionURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func setSessionSnoozed(
        sessionID: String,
        until deadline: Date?,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionSnoozeRequestDTO(
                snoozedUntil: deadline?.timeIntervalSince1970
            ),
            to: link.snoozedSessionURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func setSessionSurface(
        sessionID: String,
        surface: RemoteSessionSurface,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionSurfaceRequestDTO(surface: surface),
            to: link.sessionSurfaceURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func moveSessionAccount(
        sessionID: String,
        accountID: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteMoveSessionAccountRequestDTO(accountID: accountID),
            to: link.sessionAccountURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    /// Where this conversation could continue, asked when the screen offering the choice opens.
    /// The Mac owns eligibility, so an empty list means the control is not offered at all.
    func sessionContinuationOptions(
        sessionID: String
    ) async throws -> RemoteSessionContinuationOptionsDTO {
        try await get(
            RemoteSessionContinuationOptionsDTO.self,
            from: link.sessionContinuationURL(sessionID: sessionID)
        )
    }

    func continueSession(
        sessionID: String,
        agentID: String,
        accountID: String?,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteContinueSessionResponseDTO {
        try await postResponse(
            RemoteContinueSessionRequestDTO(agentID: agentID, accountID: accountID),
            to: link.sessionContinuationURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func setSessionLimitRecovery(
        sessionID: String,
        policy: RemoteLimitRecoveryPolicyDTO,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionLimitRecoveryRequestDTO(policy: policy),
            to: link.sessionLimitRecoveryURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func registerNotifications(
        _ registration: RemoteNotificationRegistrationDTO,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteNotificationRegistrationResponseDTO {
        try await postResponse(
            registration,
            to: link.notificationRegistrationURL,
            requestID: requestID
        )
    }

    func uploadDiagnostics(
        _ records: [RemoteDiagnosticRecord],
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteDiagnosticUploadResponseDTO {
        try await postResponse(
            RemoteDiagnosticUploadRequestDTO(source: .iOSClient, records: records),
            to: link.diagnosticUploadURL,
            requestID: requestID
        )
    }

    func uploadMobileDiagnosticsCapture(
        _ capture: RemoteMobileDiagnosticsCaptureDTO
    ) async throws -> RemoteMobileDiagnosticsCaptureUploadResponseDTO {
        try await postResponse(
            RemoteMobileDiagnosticsCaptureUploadRequestDTO(capture: capture),
            to: link.mobileDiagnosticsCaptureUploadURL,
            requestID: capture.requestID
        )
    }

    func createShare(
        sessionID: String,
        capability: RemoteCapability,
        canApprovePermissions: Bool,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteCreateShareResponseDTO {
        try await postResponse(
            RemoteCreateShareRequestDTO(
                capability: capability,
                canApprovePermissions: canApprovePermissions
            ),
            to: link.sessionShareURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func revokeShares(
        sessionID: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteRevokeSharesRequestDTO(),
            to: link.sessionUnshareURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func createTerminalShare(
        terminalID: String,
        capability: RemoteCapability,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteCreateShareResponseDTO {
        try await postResponse(
            RemoteCreateShareRequestDTO(capability: capability),
            to: link.terminalShareURL(terminalID: terminalID),
            requestID: requestID
        )
    }

    func revokeTerminalShares(
        terminalID: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteRevokeSharesRequestDTO(),
            to: link.terminalUnshareURL(terminalID: terminalID),
            requestID: requestID
        )
    }

    func gitReview(
        sessionID: String,
        mode: RemoteGitReviewMode
    ) async throws -> RemoteGitReviewSnapshotDTO {
        try await get(
            RemoteGitReviewSnapshotDTO.self,
            from: link.gitReviewURL(sessionID: sessionID, mode: mode)
        )
    }

    func repositoryFiles(sessionID: String) async throws -> RemoteRepositoryFilesDTO {
        try await get(
            RemoteRepositoryFilesDTO.self,
            from: link.repositoryFilesURL(sessionID: sessionID)
        )
    }

    func repositoryFile(sessionID: String, path: String) async throws -> RemoteRepositoryFileDTO {
        guard let url = link.repositoryFileURL(sessionID: sessionID, path: path) else {
            throw RemoteClientError.invalidResponse
        }
        return try await get(RemoteRepositoryFileDTO.self, from: url)
    }

    func attachments(sessionID: String) async throws -> RemoteAttachmentsDTO {
        try await get(
            RemoteAttachmentsDTO.self,
            from: link.attachmentsURL(sessionID: sessionID)
        )
    }

    func attachmentData(sessionID: String, id: String) async throws -> Data {
        guard let url = link.attachmentURL(sessionID: sessionID, id: id) else {
            throw RemoteClientError.invalidResponse
        }
        let (data, response) = try await dataRetryingTransientFailure(for: request(url: url))
        _ = try validate(data: data, response: response, accepted: 200 ... 299)
        return data
    }

    /// One authenticated piece of a movie. The AVFoundation resource loader walks a larger
    /// decoder request through these bounded calls and responds to the decoder after each one,
    /// so a recording is never accumulated in this process.
    func attachmentVideoData(
        sessionID: String,
        id: String,
        range: Range<Int64>,
        totalBytes: Int64
    ) async throws -> Data {
        let length = range.upperBound - range.lowerBound
        guard range.lowerBound >= 0,
              length > 0,
              length <= Int64(RemoteAttachmentVideo.maximumChunkBytes),
              totalBytes >= range.upperBound,
              let url = link.attachmentURL(sessionID: sessionID, id: id) else {
            throw RemoteClientError.invalidResponse
        }
        var request = request(url: url)
        request.setValue(
            "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
            forHTTPHeaderField: "Range"
        )
        let (data, response) = try await dataRetryingTransientFailure(for: request)
        let http = try validate(data: data, response: response, accepted: 206 ... 206)
        guard data.count == Int(length),
              http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
              http.value(forHTTPHeaderField: "Content-Range")
                == "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(totalBytes)" else {
            throw RemoteClientError.invalidResponse
        }
        return data
    }

    /// A bounded raster of one attachment for the gallery's ledger. Ask only where
    /// `RemoteRESTFeature.attachmentThumbnails` was advertised; an older Mac answers 404.
    func attachmentThumbnail(sessionID: String, id: String) async throws -> Data {
        guard let url = link.attachmentThumbnailURL(sessionID: sessionID, id: id) else {
            throw RemoteClientError.invalidResponse
        }
        let (data, response) = try await dataRetryingTransientFailure(for: request(url: url))
        _ = try validate(data: data, response: response, accepted: 200 ... 299)
        return data
    }

    /// One more attempt for a read whose connection was lost under it.
    ///
    /// A GET is safe to repeat, and `networkConnectionLost` is the error a pooled connection
    /// produces when the host closed it — after an attachment response, at its idle bound, or
    /// past its admission cap — a moment before this request reused it. The second attempt
    /// takes a fresh connection. Anything else is thrown as it was: a timeout or an unreachable
    /// host is not made better by asking again at once, and the route loop owns that.
    private func dataRetryingTransientFailure(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        do {
            return try await Self.session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch where RemoteTransientTransportFailure.isTransient(error) {
            try Task.checkCancellation()
            return try await Self.session.data(for: request)
        }
    }

    /// Hands one composer attachment to the Mac, a chunk at a time, and answers its upload id.
    ///
    /// The id is the only thing the phone learns: where the file landed is the Mac's business,
    /// and a prompt names the upload rather than a path. Nothing is attached to the session yet
    /// — a completed upload waits in staging until a prompt claims it, or until the Mac reaps it.
    ///
    /// Cancelling mid-transfer simply stops: the partial upload is left for that reaper rather
    /// than raced with a delete the phone may not be online to send.
    func uploadAttachment(
        sessionID: String,
        name: String,
        mediaType: String,
        data: Data,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        guard !data.isEmpty else { throw RemoteClientError.invalidResponse }

        let url = link.attachmentUploadURL(sessionID: sessionID)
        let chunkSize = RemoteAttachmentUploadClientDefaults.chunkBytes
        let chunkCount = max(1, (data.count + chunkSize - 1) / chunkSize)
        var uploadID: String?

        for index in 0 ..< chunkCount {
            try Task.checkCancellation()
            let start = index * chunkSize
            let end = min(start + chunkSize, data.count)
            let body = RemoteAttachmentUploadRequestDTO(
                uploadID: uploadID,
                name: name,
                mediaType: mediaType,
                totalBytes: data.count,
                chunkIndex: index,
                chunkCount: chunkCount,
                chunk: data[start ..< end].base64EncodedString()
            )
            // Each chunk carries its own request id: they are distinct mutations, and sharing one
            // would make the Mac's replay cache treat chunk two as a retry of chunk one.
            let result: RemoteAttachmentUploadResponseDTO = try await postResponse(
                body,
                to: url,
                requestID: UUID().uuidString
            )
            uploadID = result.uploadID
            onProgress?(Double(result.receivedBytes) / Double(data.count))
            if result.isComplete { return result.uploadID }
        }

        // Every chunk was accepted and the Mac still does not consider the file whole. Nothing
        // usable came of it, so this is a failure rather than an id the composer would name.
        throw RemoteClientError.invalidResponse
    }

    func workspace(sessionID: String) async throws -> RemoteWorkspaceDTO {
        try await get(
            RemoteWorkspaceDTO.self,
            from: link.workspaceURL(sessionID: sessionID)
        )
    }

    func browserPreviewData(sessionID: String, tabID: String) async throws -> Data {
        guard let url = link.browserPreviewURL(sessionID: sessionID, tabID: tabID) else {
            throw RemoteClientError.invalidResponse
        }
        let (data, response) = try await Self.session.data(for: request(url: url))
        _ = try validate(data: data, response: response, accepted: 200 ... 299)
        return data
    }

    func extensionPanel(
        sessionID: String,
        extensionIdentifier: String,
        panelID: String
    ) async throws -> RemoteExtensionPanelDTO {
        guard let url = link.extensionPanelURL(
            sessionID: sessionID,
            extensionIdentifier: extensionIdentifier,
            panelID: panelID
        ) else {
            throw RemoteClientError.invalidResponse
        }
        return try await get(RemoteExtensionPanelDTO.self, from: url)
    }

    func invokeExtensionPanelAction(
        sessionID: String,
        extensionIdentifier: String,
        panelID: String,
        processGeneration: String,
        actionID: String,
        value: ExtensionJSONValue? = nil,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteExtensionPanelActionResponseDTO {
        guard let url = link.extensionPanelURL(
            sessionID: sessionID,
            extensionIdentifier: extensionIdentifier,
            panelID: panelID
        ) else {
            throw RemoteClientError.invalidResponse
        }
        return try await postResponse(
            RemoteExtensionPanelActionRequestDTO(
                processGeneration: processGeneration,
                actionID: actionID,
                value: value
            ),
            to: url,
            requestID: requestID
        )
    }

    func extensionPanelResourceData(
        sessionID: String,
        extensionIdentifier: String,
        panelID: String,
        path: String
    ) async throws -> Data {
        guard let url = link.extensionPanelResourceURL(
            sessionID: sessionID,
            extensionIdentifier: extensionIdentifier,
            panelID: panelID,
            path: path
        ) else {
            throw RemoteClientError.invalidResponse
        }
        let (data, response) = try await Self.session.data(for: request(url: url))
        _ = try validate(data: data, response: response, accepted: 200 ... 299)
        return data
    }

    func webSocketTask(sessionID: String) throws -> URLSessionWebSocketTask {
        guard let url = link.webSocketURL(sessionID: sessionID) else {
            throw RemoteClientError.invalidResponse
        }
        return Self.socketSession.webSocketTask(with: url)
    }

    func terminalWebSocketTask(terminalID: String) throws -> URLSessionWebSocketTask {
        guard let url = link.terminalWebSocketURL(terminalID: terminalID) else {
            throw RemoteClientError.invalidResponse
        }
        return Self.socketSession.webSocketTask(with: url)
    }

    func eventsWebSocketTask() throws -> URLSessionWebSocketTask {
        guard let url = link.eventsWebSocketURL else {
            throw RemoteClientError.invalidResponse
        }
        return Self.socketSession.webSocketTask(with: url)
    }

    /// True when a socket opened by this client cannot wait for connectivity.
    ///
    /// Asserted rather than assumed: the whole failure this fixes was a socket silently
    /// inheriting the request session's `waitsForConnectivity`.
    static var socketWaitsForConnectivity: Bool {
        socketSession.configuration.waitsForConnectivity
    }

    /// True when a REST request can suspend instead of returning control to the route walk.
    static var requestWaitsForConnectivity: Bool {
        session.configuration.waitsForConnectivity
    }

    /// The delegate each session actually installed, so a test can prove they are the same
    /// object rather than two that happen to be configured alike.
    static var requestSessionDelegate: URLSessionDelegate? { session.delegate }
    static var socketSessionDelegate: URLSessionDelegate? { socketSession.delegate }
    static var reportSessionDelegate: URLSessionDelegate? { reportSession.delegate }

    /// Protocol header names come from the shared `RemoteHeader` vocabulary, so the phone and
    /// the host cannot drift apart on a rename. Those raw values are lowercase while this client
    /// historically spelled them in title case; field names are case-insensitive by RFC 9110, the
    /// host lowercases every name as it parses and looks them up lowercased, and HTTP/2 requires
    /// lowercase names in transit anyway — so only the bytes change, never the meaning.
    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            String(RemoteProtocol.current),
            forHTTPHeaderField: RemoteHeader.protocolVersion.rawValue
        )
        request.setValue(
            String(RemoteProtocol.minimumSupported),
            forHTTPHeaderField: RemoteHeader.protocolMinimum.rawValue
        )
        request.setValue(RemoteClientKind.iOS.rawValue, forHTTPHeaderField: RemoteHeader.client.rawValue)
        request.setValue(RemoteDeviceIdentity.current, forHTTPHeaderField: RemoteHeader.device.rawValue)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let requestTimeout { request.timeoutInterval = requestTimeout }
        return request
    }

    private func post<Body: Encodable>(
        _ body: Body,
        to url: URL,
        requestID: String
    ) async throws -> RemoteMeDTO {
        try await postResponse(body, to: url, requestID: requestID)
    }

    private func get<Response: Decodable>(
        _ responseType: Response.Type,
        from url: URL
    ) async throws -> Response {
        let (data, response) = try await Self.session.data(for: request(url: url))
        _ = try validate(data: data, response: response, accepted: 200 ... 299)
        return try JSONDecoder().decode(responseType, from: data)
    }

    private func postResponse<Body: Encodable, Response: Decodable>(
        _ body: Body,
        to url: URL,
        requestID: String
    ) async throws -> Response {
        var request = request(url: url)
        request.httpMethod = "POST"
        request.httpBody = try Self.encodeMutationBody(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID, forHTTPHeaderField: RemoteHeader.requestID.rawValue)
        let (data, response) = try await dataReplayingNetworkFailure(for: request)
        _ = try validate(data: data, response: response, accepted: 200 ... 299)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// A route walk rebuilds its URL request for each address while preserving one mutation id.
    /// Stable JSON bytes keep that replay compatible with installed hosts whose exactly-once
    /// cache predates semantic JSON fingerprints.
    static func encodeMutationBody<Body: Encodable>(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    /// A lost response is ambiguous: the Mac may already have applied the mutation. Retrying
    /// the same immutable request once is safe because the request id is replayed verbatim and
    /// the Mac coalesces or returns the original response for that id. A client inside a route
    /// walk leaves the replay to the walk's next address, which sends the same id; replaying on
    /// an address that just timed out only doubled its cost (2026-09-06: sixteen seconds per dead
    /// LAN address against an eight-second budget).
    private func dataReplayingNetworkFailure(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        do {
            return try await Self.session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code != .cancelled && replaysLostResponse {
            return try await Self.session.data(for: request)
        }
    }

    private func decodeMe(data: Data, response: URLResponse) throws -> RemoteMeDTO {
        _ = try validate(data: data, response: response, accepted: 200 ... 299)
        return try JSONDecoder().decode(RemoteMeDTO.self, from: data)
    }

    @discardableResult
    private func validate(
        data: Data,
        response: URLResponse,
        accepted: ClosedRange<Int>
    ) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw RemoteClientError.invalidResponse
        }
        if response.statusCode == 426 {
            // The body names the side that is behind. Without it the refusal is still terminal,
            // and "this app is too old" is the safer of the two guesses to make about a host
            // that could not say.
            let upgrade = try? JSONDecoder().decode(RemoteUpgradeRequiredDTO.self, from: data)
            throw RemoteClientError.upgradeRequired(upgrade?.update ?? .client)
        }
        guard accepted.contains(response.statusCode) else {
            throw RemoteClientError.decodedRefusal(status: response.statusCode, data: data)
        }
        return response
    }
}
