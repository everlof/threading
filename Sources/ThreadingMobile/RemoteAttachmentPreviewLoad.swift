import Foundation
import ThreadingRemoteKit

/// When a preview page asks the paired Mac for one attachment's whole bytes.
///
/// The rule is deliberately about *what the page holds*, never about whether an attempt is
/// already running, and that distinction is the whole point of this type.
///
/// SwiftUI cancels a lazy gallery page's `.task` the moment the page leaves the retained
/// window. A cancelled attempt is suspended off the main actor, so it releases an `isLoading`
/// flag only after hopping back — which is *after* SwiftUI has already started the page's next
/// task in the same layout pass. Gating on that flag therefore read a stale `true`: the retry
/// returned without asking for anything, the cancelled attempt then cleared the flag with
/// nobody left to notice, and the page kept its loading placeholder for as long as it was on
/// screen. No bytes, no error, no Try Again, and — because cancellation is correctly not a
/// degradation — nothing in the journal either. A report filed from that screen could not
/// answer its own question.
///
/// Holding the bytes is the only state that ends the asking. Two overlapping requests for one
/// bounded file cost a duplicate GET; a page that stops asking costs the person the file.
enum RemoteAttachmentPreviewLoad {

    enum Decision: Equatable {
        case requestBytes
        case alreadyLoaded
        case localFixture
        case previewUnavailable
    }

    /// Kinds that never use the ordinary whole-file GET. Archives and documents have no phone
    /// renderer; movies use their separate bounded range loader instead.
    static let excludesFromWholeFileLoad: Set<RemoteAttachmentKind> = [
        .archive, .document, .diagram, .media, .video,
    ]

    static func excludesFromWholeFileLoad(_ kind: RemoteAttachmentKind) -> Bool {
        excludesFromWholeFileLoad.contains(kind)
    }

    /// Why this invocation will or will not ask. Keeping the early-return reasons distinct is
    /// what lets diagnostics record a real renderer skip without calling a demo fixture or a
    /// page that already holds bytes a skipped request.
    static func decision(
        kind: RemoteAttachmentKind,
        hasData: Bool,
        loadsRemotely: Bool
    ) -> Decision {
        guard loadsRemotely else { return .localFixture }
        guard !hasData else { return .alreadyLoaded }
        guard !excludesFromWholeFileLoad(kind) else { return .previewUnavailable }
        return .requestBytes
    }

    /// Compatibility helper for callers and focused tests that only need the binary gate.
    static func shouldRequestBytes(
        kind: RemoteAttachmentKind,
        hasData: Bool,
        loadsRemotely: Bool
    ) -> Bool {
        decision(kind: kind, hasData: hasData, loadsRemotely: loadsRemotely) == .requestBytes
    }
}
