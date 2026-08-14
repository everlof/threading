import Foundation
import ThreadingExtensionKit

/// What the host recognizes inside a file, from a bounded prefix it reads itself.
///
/// **`.json` is the ambiguity that decides the design.** A Lottie *is* a `.json`, so an extension
/// that could claim `.json` would claim every configuration file in every session — and a store
/// that admitted `.json` on its extension alone would fill the Attachments pane with
/// `package.json`. Classification therefore stays host-owned and structural: the host reads a
/// bounded prefix, recognizes a signature it knows, and publishes only the *name* of what it
/// recognized. The prefix never leaves this type.
///
/// These are work ceilings, not permission for an extension to supply a parser or receive the
/// prefix. Nothing here takes a pattern from a contribution.
enum MediaContentProbe {

    /// How much of a candidate is read. A bodymovin document states `v`, `fr`, `ip`, `op` and
    /// `layers` in its first object, so a Lottie that needs more than this to identify itself is
    /// one whose signature is not where the format puts it.
    static let prefixBytes = 64 * 1_024

    /// How many ambiguous candidates one scan may probe. The pane is fed by reading whatever an
    /// agent last printed, so the number of `.json` paths in a buffer is not ours to bound —
    /// only the work spent on them is.
    static let maximumCandidatesPerScan = 32

    /// Hints the host will *admit* a file on, as opposed to merely enrich an already-admitted row
    /// with. Deliberately tiny: admission is the gate that keeps configuration files out.
    static let admissionHints: Set<ExtensionFileContentHint> = [.lottie]

    /// Extensions the host is willing to probe *before* deciding whether to record a file.
    ///
    /// The second route in `SessionAttachmentStore`, and the only thing that makes a bare JSON
    /// Lottie possible: adding `json` to the ordinary kind map would fill the pane with
    /// configuration, and probing only what is already recorded would never see JSON at all.
    static let ambiguousExtensions: Set<String> = ["json"]

    // MARK: - Reading

    /// Reads at most `prefixBytes` from a file. Distinct from `BoundedFileReader`, which refuses a
    /// file past its limit rather than truncating it — refusing is right for a document that will
    /// be decoded whole, and wrong for a probe whose entire job is to look at the beginning of
    /// something large.
    static func prefix(of url: URL, maximumBytes: Int = prefixBytes) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maximumBytes)
    }

    static func hint(for url: URL) -> ExtensionFileContentHint? {
        let suffix = url.pathExtension.lowercased()
        if let structural = structuralHint(forExtension: suffix) { return structural }
        guard let prefix = prefix(of: url) else { return nil }
        return hint(forPrefix: prefix, fileExtension: suffix)
    }

    /// A hint decided by the extension alone, where the extension is not ambiguous.
    static func structuralHint(forExtension suffix: String) -> ExtensionFileContentHint? {
        switch suffix {
        case "lottie": .dotLottie
        case "svg": .svg
        case "mmd", "mermaid": .mermaid
        case "dot", "gv": .graphviz
        default: nil
        }
    }

    // MARK: - Signatures

    /// Reads a signature out of a bounded prefix. Declines — rather than guessing — when the
    /// structure is not inside it.
    ///
    /// **Scanned as bytes, not as a `String`.** The overwhelmingly common answer is *no*, and
    /// building a 64 KiB `String` to say so costs a full UTF-8 validation plus several
    /// grapheme-aware passes: measured at 9 ms per candidate, or ~295 ms for one scan's whole
    /// 32-candidate budget, on a worker that a debounced terminal scan shares. A signature is a
    /// literal ASCII key either way, so the bytes answer the same question.
    static func hint(
        forPrefix prefix: Data,
        fileExtension suffix: String
    ) -> ExtensionFileContentHint? {
        if let structural = structuralHint(forExtension: suffix) { return structural }
        switch suffix {
        case "json":
            let found = prefix.signatures()
            if isLottie(found) { return .lottie }
            if isOpenAPI(found, in: prefix) { return .openAPI }
            return nil
        case "yaml", "yml":
            return isOpenAPI(prefix.signatures(), in: prefix) ? .openAPI : nil
        default:
            return nil
        }
    }

    /// The bodymovin signature: a frame rate, an in and out point, and a layer list.
    ///
    /// Four keys rather than one, because `"layers"` alone appears in map styles, design tokens
    /// and half the configuration formats in a modern checkout — and admitting one of those into
    /// Attachments is exactly the failure this probe exists to avoid.
    private static func isLottie(_ found: Set<Signature>) -> Bool {
        guard found.contains(.layers) else { return false }
        return [Signature.frameRate, .inPoint, .outPoint].filter(found.contains).count >= 2
    }

    private static func isOpenAPI(_ found: Set<Signature>, in data: Data) -> Bool {
        if found.contains(.openAPIKey) || found.contains(.swaggerKey) { return true }
        // A YAML document declares the key at the start of a line, so the check is anchored
        // rather than a substring: `# not openapi:` in a comment is not a specification. Only
        // reached when the word is present at all, so the second pass is rare.
        if found.contains(.openAPIYAML), data.containsAtLineStart(ascii: "openapi:") {
            return true
        }
        return found.contains(.swaggerYAML) && data.containsAtLineStart(ascii: "swagger:")
    }

    /// The literals the probe recognizes, scanned for together.
    ///
    /// One pass rather than one per key: seven separate 64 KiB passes per candidate was the whole
    /// cost of a scan's 32-candidate budget once the read had been ruled out (1 ms of reading
    /// against 100 ms of scanning).
    struct SignatureTable: Sendable {
        let all: [Signature]
        let needles: [[UInt8]]
        /// Indexed by first byte: `byFirstByte[b]` is every needle that could start at a `b`.
        let byFirstByte: [[Int]]
    }

    enum Signature: CaseIterable, Sendable {
        case layers, frameRate, inPoint, outPoint
        case openAPIKey, swaggerKey, openAPIYAML, swaggerYAML

        /// The needles, and which of them can start at a given byte, built once.
        ///
        /// Rebuilding a 256-entry table per candidate is 32 allocations per scan for an answer
        /// that never changes.
        static let table: SignatureTable = {
            let all = Signature.allCases
            let needles = all.map(\.bytes)
            var byFirstByte = [[Int]](repeating: [], count: 256)
            for (index, needle) in needles.enumerated() {
                byFirstByte[Int(needle[0])].append(index)
            }
            return SignatureTable(all: all, needles: needles, byFirstByte: byFirstByte)
        }()

        var bytes: [UInt8] {
            switch self {
            case .layers: Array("\"layers\"".utf8)
            case .frameRate: Array("\"fr\"".utf8)
            case .inPoint: Array("\"ip\"".utf8)
            case .outPoint: Array("\"op\"".utf8)
            case .openAPIKey: Array("\"openapi\"".utf8)
            case .swaggerKey: Array("\"swagger\"".utf8)
            case .openAPIYAML: Array("openapi:".utf8)
            case .swaggerYAML: Array("swagger:".utf8)
            }
        }
    }
}

private extension Data {

    /// Every signature present in this buffer, found in **one** pass.
    ///
    /// Indexed by first byte, which is the whole performance story. A pass that consults every
    /// needle at every position is worse than several separate passes — measured at 2,480 ms
    /// against 100 ms for one scan's 32-candidate budget, because the per-byte inner loop
    /// dominates everything. Every signature here starts with `"`, `o` or `s`, so a table lookup
    /// makes the common byte cost one comparison and no iteration at all.
    func signatures() -> Set<MediaContentProbe.Signature> {
        let table = MediaContentProbe.Signature.table
        var found: Set<MediaContentProbe.Signature> = []
        withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let length = raw.count
            var start = 0
            while start < length {
                let candidates = table.byFirstByte[Int(base[start])]
                if !candidates.isEmpty {
                    for index in candidates {
                        let needle = table.needles[index]
                        guard length - start >= needle.count else { continue }
                        var offset = 1
                        var matched = true
                        while offset < needle.count {
                            if base[start + offset] != needle[offset] {
                                matched = false
                                break
                            }
                            offset += 1
                        }
                        if matched { found.insert(table.all[index]) }
                    }
                }
                start += 1
            }
        }
        return found
    }

    /// The needle at the beginning of some line, allowing leading spaces and tabs.
    func containsAtLineStart(ascii needle: String) -> Bool {
        containsASCII(Array(needle.utf8), requiringLineStart: true)
    }

    /// One pass over the raw buffer.
    ///
    /// Through `withUnsafeBytes` rather than `Data`'s own indices: subscripting a `Data` by
    /// `Index` is not a pointer dereference, and the difference is not academic here — the same
    /// scan measured 154 ms across a scan's 32-candidate budget through indices and 1 ms through
    /// the buffer. This runs on the worker a debounced terminal scan shares.
    func containsASCII(_ needle: [UInt8], requiringLineStart: Bool) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return withUnsafeBytes { raw -> Bool in
            let length = raw.count
            let width = needle.count
            guard length >= width else { return false }
            let first = needle[0]
            var start = 0
            while start <= length - width {
                guard raw[start] == first else {
                    start += 1
                    continue
                }
                var offset = 1
                var matched = true
                while offset < width {
                    if raw[start + offset] != needle[offset] {
                        matched = false
                        break
                    }
                    offset += 1
                }
                if matched {
                    guard requiringLineStart else { return true }
                    var cursor = start
                    var isLineStart = true
                    while cursor > 0 {
                        let previous = raw[cursor - 1]
                        if previous == 0x0A || previous == 0x0D { break }
                        if previous != 0x20 && previous != 0x09 {
                            isLineStart = false
                            break
                        }
                        cursor -= 1
                    }
                    if isLineStart { return true }
                }
                start += 1
            }
            return false
        }
    }
}
