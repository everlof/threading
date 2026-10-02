import Foundation

/// An `OSLog`-shaped module for Linux, built because the substitution the import scan called
/// mechanical is not one.
///
/// `sweep-core.sh` classified `os`/`OSLog` as "→ swift-log", which is true of the *logger* and
/// false of the *call sites*. Threading makes 760 `privacy:` interpolations, and that vocabulary
/// is OSLog's string-interpolation machinery, not a logging API — swift-log has no equivalent, so
/// a straight swap would mean rewriting every one of them. Worse, it would delete a policy:
/// `Logger.swift` requires every interpolation to choose `privacy:` explicitly, and
/// `scripts/check_logging_boundaries.py` fails the build over it.
///
/// So the port is not "use swift-log", it is "keep the privacy vocabulary and put something under
/// it". That is what this is: about 120 lines, every call site unchanged, and the boundary script
/// still meaningful. On a real Linux build the `emit` below would hand off to swift-log; here it
/// writes to stderr, because the point is to prove the call sites survive.
public struct LogPrivacy: Sendable {

    public enum Mask: Sendable { case hash, none }

    enum Kind: Sendable { case auto, visible, redacted(Mask), sensitive }

    let kind: Kind

    public static let auto = LogPrivacy(kind: .auto)
    public static let `public` = LogPrivacy(kind: .visible)
    public static let `private` = LogPrivacy(kind: .redacted(.none))
    public static let sensitive = LogPrivacy(kind: .sensitive)

    public static func `private`(mask: Mask) -> LogPrivacy {
        LogPrivacy(kind: .redacted(mask))
    }

    /// Redaction is honoured rather than ignored. A Linux build that quietly logged everything in
    /// the clear would pass every test and violate the contract the call sites were written to.
    func render(_ value: String) -> String {
        switch kind {
        case .visible:
            return value
        // `auto` is OSLog's default and it hides non-literal values; matching that is the whole
        // reason the policy insists a site say `privacy:` out loud.
        case .auto, .sensitive:
            return "<private>"
        case .redacted(let mask):
            switch mask {
            case .none: return "<private>"
            case .hash: return "<private:\(Self.hash(value))>"
            }
        }
    }

    /// FNV-1a, which is enough to correlate two occurrences of the same value in one log without
    /// carrying the value. Not a security primitive and not presented as one.
    private static func hash(_ value: String) -> String {
        var digest: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            digest ^= UInt64(byte)
            digest = digest &* 0x0000_0100_0000_01B3
        }
        return String(digest, radix: 16)
    }
}

/// The message type that gives `privacy:` somewhere to live.
public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {

    public let rendered: String

    public init(stringLiteral value: String) { rendered = value }
    public init(stringInterpolation: StringInterpolation) { rendered = stringInterpolation.text }

    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) { text += literal }

        /// One generic overload stands in for OSLog's many typed ones. `align:` and `format:` are
        /// accepted and ignored, so a call site using them still compiles — they affect
        /// presentation, never whether the value is shown.
        public mutating func appendInterpolation<Value>(
            _ value: @autoclosure () -> Value,
            privacy: LogPrivacy = .auto
        ) {
            text += privacy.render(String(describing: value()))
        }

        public mutating func appendInterpolation<Value>(
            _ value: @autoclosure () -> Value,
            format: Any? = nil,
            align: Any? = nil,
            privacy: LogPrivacy = .auto
        ) {
            text += privacy.render(String(describing: value()))
        }
    }
}

public enum OSLogType: Sendable {
    case debug, info, notice, error, fault
}

public struct Logger: Sendable {

    public let subsystem: String
    public let category: String

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    public init() {
        self.init(subsystem: "", category: "")
    }

    public func trace(_ message: OSLogMessage) { emit(.debug, message) }
    public func debug(_ message: OSLogMessage) { emit(.debug, message) }
    public func info(_ message: OSLogMessage) { emit(.info, message) }
    public func notice(_ message: OSLogMessage) { emit(.notice, message) }
    public func warning(_ message: OSLogMessage) { emit(.error, message) }
    public func error(_ message: OSLogMessage) { emit(.error, message) }
    public func critical(_ message: OSLogMessage) { emit(.fault, message) }
    public func fault(_ message: OSLogMessage) { emit(.fault, message) }
    public func log(level: OSLogType = .notice, _ message: OSLogMessage) { emit(level, message) }
    public func log(_ message: OSLogMessage) { emit(.notice, message) }

    /// Where swift-log would be handed the record on a real port. Silent unless asked, so a spike
    /// harness's output stays its own.
    private func emit(_ level: OSLogType, _ message: OSLogMessage) {
        guard ProcessInfo.processInfo.environment["SPIKE_LOG"] != nil else { return }
        FileHandle.standardError.write(
            Data("[\(category)] \(message.rendered)\n".utf8)
        )
    }
}
