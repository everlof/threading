import Foundation

// MARK: - Mirror

/// Mirror: a full-screen stage the Mac opens on its paired owner iPhone, so a page meant for a
/// phone is seen on a phone. The Mac owns the session; the phone renders what the session names
/// and reports whether it showed it.
///
/// Every frame rides the authenticated `/ws/events` socket. Top-level keys deliberately avoid the
/// names the phone's events envelope already decodes with a fixed shape (`session`, `revision`,
/// `streamID`, `sequence`, `terminal`): a clash there would drop the socket on every shipped phone,
/// so the identity is `mirrorID` and the edition is `mirrorRevision`.
public enum RemoteMirror {
    /// How long the Mac keeps an offer no phone has joined.
    public static let offerLifetime: TimeInterval = 600
    /// How long the invite notification stays on a phone: the same two minutes as a Face ID
    /// approval, because the person asked for it seconds ago at the Mac.
    public static let inviteLifetime: Int64 = 120
    /// An app that becomes active this soon after the Mac's click enters the stage by any route:
    /// the person clicked and picked up the phone. Later, only the notification, the Live Activity
    /// or a tap on the quiet offer opens it, because opening Threading may then be for prompting.
    public static let freshStartWindow: TimeInterval = 30
    /// How long the Mac keeps a joined mirror waiting while its phone is away.
    public static let awayLifetime: TimeInterval = 1800
    /// The longest source title either side keeps, in bytes.
    public static let maximumTitleBytes = 160

    /// The machine token the invite notification's thread uses, so nothing mistakes it for a chat.
    public static let inviteThread = "mirror"

    /// A title bounded to `maximumTitleBytes` on a character boundary, on one line.
    public static func boundedTitle(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.utf8.count > maximumTitleBytes else { return trimmed }
        var result = ""
        for character in trimmed {
            guard result.utf8.count + String(character).utf8.count <= maximumTitleBytes - 3 else { break }
            result.append(character)
        }
        return result + "…"
    }
}

/// Whether the person's touches act on the page or only look at it.
public enum RemoteMirrorMode: RemoteLosslessStringToken {
    case interactive
    case viewOnly
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "interactive": self = .interactive
        case "viewOnly": self = .viewOnly
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .interactive: return "interactive"
        case .viewOnly: return "viewOnly"
        case let .unknown(value): return value
        }
    }
}

/// How the phone renders the source. Web content renders in the phone's own WebKit, because the
/// phone is the target; only what it cannot render ever arrives as pixels.
public struct RemoteMirrorRenderDTO: Codable, Equatable, Sendable {
    public enum Kind: RemoteLosslessStringToken {
        /// A page from a shared browser tab: public URLs load directly, a loopback origin through
        /// the tab's existing browser tunnel.
        case web
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "web": self = .web
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .web: return "web"
            case let .unknown(value): return value
            }
        }
    }

    public let kind: Kind
    /// The session whose display panel holds the source, so the tunnel route can be addressed.
    public let sessionID: String
    /// The browser tab the mirror follows.
    public let browserTabID: String
    /// The exact page address, exported under the same policy as Browse on iPhone.
    public let url: String

    public init(kind: Kind = .web, sessionID: String, browserTabID: String, url: String) {
        self.kind = kind
        self.sessionID = sessionID
        self.browserTabID = browserTabID
        self.url = url
    }
}

/// The whole current state of one mirror, addressed to the one phone it targets.
///
/// Sent when the mirror starts, on every revision, and again whenever that phone's events socket
/// attaches while the mirror is pending or live. The phone acts on the newest `mirrorRevision`.
public struct RemoteMirrorStateDTO: Codable, Equatable, Sendable {
    public let type: String
    public let mirrorID: String
    public let mirrorRevision: UInt64
    public let sourceTitle: String
    public let render: RemoteMirrorRenderDTO
    public let mode: RemoteMirrorMode
    /// How long ago the person clicked on the Mac, measured on the Mac, so the phone's
    /// fresh-start rule needs no shared clock.
    public let offerAgeMilliseconds: Int64
    /// The phone had joined this mirror before it went away, so the stage is the screen it left
    /// and a return takes it back directly.
    public let rejoin: Bool

    public init(
        mirrorID: String,
        mirrorRevision: UInt64,
        sourceTitle: String,
        render: RemoteMirrorRenderDTO,
        mode: RemoteMirrorMode,
        offerAgeMilliseconds: Int64,
        rejoin: Bool
    ) {
        type = RemoteMirrorFrame.state.rawValue
        self.mirrorID = mirrorID
        self.mirrorRevision = mirrorRevision
        self.sourceTitle = sourceTitle
        self.render = render
        self.mode = mode
        self.offerAgeMilliseconds = offerAgeMilliseconds
        self.rejoin = rejoin
    }
}

/// Why a mirror ended.
public enum RemoteMirrorEndReason: RemoteLosslessStringToken {
    /// **Stop Mirroring** on the Mac.
    case stoppedOnMac
    /// **End Mirror** on the phone or in its Live Activity.
    case endedOnPhone
    /// The offer was never joined, or the phone stayed away too long.
    case expired
    /// The browser tab it follows closed, became private or lost its page.
    case sourceClosed
    /// A newer mirror took this phone.
    case replaced
    /// The device was revoked or Remote Access turned off.
    case revoked
    /// The phone switched Mirror off for this Mac.
    case disabled
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "stoppedOnMac": self = .stoppedOnMac
        case "endedOnPhone": self = .endedOnPhone
        case "expired": self = .expired
        case "sourceClosed": self = .sourceClosed
        case "replaced": self = .replaced
        case "revoked": self = .revoked
        case "disabled": self = .disabled
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .stoppedOnMac: return "stoppedOnMac"
        case .endedOnPhone: return "endedOnPhone"
        case .expired: return "expired"
        case .sourceClosed: return "sourceClosed"
        case .replaced: return "replaced"
        case .revoked: return "revoked"
        case .disabled: return "disabled"
        case let .unknown(value): return value
        }
    }
}

public struct RemoteMirrorEndedDTO: Codable, Equatable, Sendable {
    public let type: String
    public let mirrorID: String
    public let reason: RemoteMirrorEndReason

    public init(mirrorID: String, reason: RemoteMirrorEndReason) {
        type = RemoteMirrorFrame.ended.rawValue
        self.mirrorID = mirrorID
        self.reason = reason
    }
}

/// The Mac → phone frame types.
public enum RemoteMirrorFrame: String, CaseIterable, Sendable {
    case state = "mirrorState"
    case ended = "mirrorEnded"
}

/// The phone → Mac signals. Each travels as an ordinary `RemoteClientMessage` on the events
/// socket: `id` names the mirror and `state` carries the closed value the signal defines, so the
/// host's one permissive decoder reads them without a new field.
public enum RemoteMirrorSignal: String, CaseIterable, Sendable {
    /// Sent once per events connection by a phone that understands Mirror. `state` is
    /// `RemoteMirrorAvailability` for this Mac.
    case hello = "mirrorHello"
    /// The phone is showing the stage for `id`.
    case join = "mirrorJoin"
    /// The phone received `id` but is not showing it. `state` is a `RemoteMirrorHoldReason`.
    case hold = "mirrorHold"
    /// The person's finger is on, or off, the stage. `state` is a `RemoteMirrorPresence`.
    case presence = "mirrorPresence"
    /// The person ended `id` on the phone.
    case leave = "mirrorLeave"
}

/// Whether this phone takes mirrors from this Mac: the per-Mac switch in Settings ▸ Mirror.
public enum RemoteMirrorAvailability: String, Codable, CaseIterable, Sendable {
    case enabled
    case disabled
}

/// Why a phone that received a mirror is not showing it.
public enum RemoteMirrorHoldReason: String, Codable, CaseIterable, Sendable {
    /// The phone is in use — keyboard up or a finger on the screen — so the mirror waits as a
    /// quiet offer and never takes the screen.
    case inUse
    /// Mirror is switched off for this Mac.
    case disabled
    /// The app opened after the fresh-start window, so the offer waits instead of assuming the
    /// person came back for it.
    case waiting
}

public enum RemoteMirrorPresence: String, Codable, CaseIterable, Sendable {
    case touching
    case idle
}

/// The body of `POST /api/mirror/end`: the Live Activity's **End** runs while the events socket
/// is closed, so it reaches the Mac over REST.
public struct RemoteMirrorEndRequestDTO: Codable, Equatable, Sendable {
    public let mirrorID: String

    public init(mirrorID: String) {
        self.mirrorID = mirrorID
    }
}
