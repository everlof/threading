import Darwin
import Foundation

// MARK: - Bridge Output

/// The two descriptors the bridge writes to, with the rules that make them safe to share.
///
/// stdout carries the stdio transport and is therefore *framing*: one JSON message per line, and
/// a line that interleaves with another line is a protocol violation rather than a cosmetic
/// problem. Requests run concurrently, so every write goes through one lock and one `write(2)`
/// loop; nothing else in the bridge is allowed to touch descriptor 1.
///
/// stderr is diagnostics only, and bounded — a socket that flaps for an hour writes at most
/// `BridgeDefaults.maximumDiagnosticLines` lines and then one line saying it stopped.
final class BridgeOutput: @unchecked Sendable {

    // MARK: - Properties

    private let lock = NSLock()
    private var diagnosticsWritten = 0

    private let standardOutput: Int32
    private let standardError: Int32

    // MARK: - Initialization

    init(standardOutput: Int32 = 1, standardError: Int32 = 2) {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    // MARK: - Public Methods

    /// Writes one JSON message and its terminating newline as a single locked operation.
    ///
    /// `message` is sanitised first: a stray newline inside a payload would split one message
    /// into two malformed ones, and the client's parser has no way back from that.
    func writeLine(_ message: Data) {
        var line = Self.singleLine(message)
        line.append(Self.newline)

        lock.lock()
        defer { lock.unlock() }
        Self.writeAll(line, to: standardOutput)
    }

    /// A bounded diagnostic. Never carries a message body — the bridge sees a session's whole
    /// tool traffic, and a log that quoted it would be a transcript in a file nobody chose.
    func diagnose(_ text: String) {
        lock.lock()
        defer { lock.unlock() }

        guard diagnosticsWritten < BridgeDefaults.maximumDiagnosticLines else { return }
        diagnosticsWritten += 1

        let suffix = diagnosticsWritten == BridgeDefaults.maximumDiagnosticLines
            ? " (further diagnostics suppressed)"
            : ""
        Self.writeAll(Data("threading-mcp-bridge: \(text)\(suffix)\n".utf8), to: standardError)
    }

    // MARK: - Private Methods

    private static let newline = Data([0x0A])
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A

    /// Guarantees the payload occupies exactly one line.
    ///
    /// A reply the app encoded with `JSONEncoder` never contains a raw newline, so this normally
    /// costs one scan and returns the original bytes. The re-encode is the fallback for anything
    /// that does, because dropping the message would be worse than reformatting it.
    static func singleLine(_ message: Data) -> Data {
        guard message.contains(where: { $0 == lineFeed || $0 == carriageReturn }) else {
            return message
        }
        if let object = try? JSONSerialization.jsonObject(with: message, options: [.fragmentsAllowed]),
           let compact = try? JSONSerialization.data(
               withJSONObject: object,
               options: [.fragmentsAllowed]
           ) {
            return compact
        }
        return Data(message.filter { $0 != lineFeed && $0 != carriageReturn })
    }

    /// `write(2)` is permitted to write less than it was given, and returns `EINTR` on a signal.
    /// Both leave a partial JSON message on the wire if they are not looped over.
    private static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                return
            }
        }
    }
}
