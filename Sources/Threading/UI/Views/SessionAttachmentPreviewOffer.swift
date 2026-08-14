import AppKit
import ThreadingExtensionKit

/// Offers one attachment to each candidate extension in turn, and keeps the first acceptance.
///
/// **Ordering is the conflict policy.** There is no "two candidates conflict" state to resolve:
/// the host asks in the user's own extension order and the first valid acceptance wins. A decline,
/// a timeout, a generation that died mid-offer and an invalid body all do the same thing — advance
/// to the next candidate — and exhausting the list reaches the pane's native fallback.
///
/// The offer grants no read authority. A candidate learns the attachment's name, kind, size,
/// origin and the host's content hint; the bytes stay on this side, and the opaque id it is given
/// resolves only while this presentation is the one on screen.
@MainActor
final class SessionAttachmentPreviewOffer {

    struct Outcome {
        let extensionIdentifier: String
        let extensionName: String
        let content: ExtensionNode
        let message: String?
    }

    private weak var router: (any ExtensionAttachmentPreviewRouting)?
    /// Bumped by every new offer and by `cancel()`, so a late answer from a candidate the user has
    /// already scrolled past cannot replace the body of a row they are now looking at.
    private var generation = 0

    private(set) var consultedCandidateCountForTesting = 0

    init(router: (any ExtensionAttachmentPreviewRouting)?) {
        self.router = router
    }

    func cancel() {
        generation += 1
    }

    /// Asks each candidate in order. `completion` receives the winner, or nil when the list is
    /// exhausted — which is the ordinary case, not a failure.
    func offer(
        _ attachment: ExtensionAttachmentContext,
        completion: @escaping (Outcome?) -> Void
    ) {
        generation += 1
        consultedCandidateCountForTesting = 0
        let candidates = router?.attachmentPreviewCandidates() ?? []
        ask(candidates, at: 0, for: attachment, generation: generation, completion: completion)
    }

    private func ask(
        _ candidates: [ExtensionAttachmentPreviewCandidate],
        at index: Int,
        for attachment: ExtensionAttachmentContext,
        generation: Int,
        completion: @escaping (Outcome?) -> Void
    ) {
        guard generation == self.generation else { return }
        guard index < candidates.count, let router else {
            completion(nil)
            return
        }
        let candidate = candidates[index]
        consultedCandidateCountForTesting += 1

        let advance: () -> Void = { [weak self] in
            self?.ask(
                candidates,
                at: index + 1,
                for: attachment,
                generation: generation,
                completion: completion
            )
        }

        let dispatched = router.requestAttachmentPreview(
            extensionIdentifier: candidate.extensionIdentifier,
            attachment: attachment
        ) { [weak self] result in
            guard let self, generation == self.generation else { return }
            switch result {
            case .failure:
                // A timeout, a dead generation, an invalid body: all the same answer here, which
                // is that this candidate is not the one showing this row.
                advance()
            case .success(let response):
                guard response.attachmentID == attachment.attachmentID,
                      let content = response.content else {
                    advance()
                    return
                }
                completion(Outcome(
                    extensionIdentifier: candidate.extensionIdentifier,
                    extensionName: candidate.extensionName,
                    content: content,
                    message: response.message
                ))
            }
        }
        if !dispatched { advance() }
    }
}
