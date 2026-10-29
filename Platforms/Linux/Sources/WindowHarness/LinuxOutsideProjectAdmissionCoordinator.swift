#if os(Linux)
import Foundation
@testable import CoreSlice

/// SDL has no actor task pump. One mailbox paced custody job at a time admits paths that were
/// withheld before the user widened the shared attachment scope.
@MainActor
final class LinuxOutsideProjectAdmissionCoordinator {
    private let store: SessionAttachmentStore
    private var pending: [SessionID] = []
    private var generation = 0
    private var busy = false

    init(store: SessionAttachmentStore) {
        self.store = store
    }

    func settingChanged(enabled: Bool) {
        generation &+= 1
        pending = enabled ? store.sessionsWithWithheldReferences() : []
        startNext()
    }

    private func startNext() {
        guard !busy, !pending.isEmpty,
              LinuxGeneralSettings.includesAttachmentsOutsideProject else { return }
        let sessionID = pending.removeFirst()
        let currentGeneration = generation
        busy = true
        store.admitWithheldFilesOutsideProject(
            for: sessionID, delivery: NativeConversationDelivery.callbacks,
            shouldAdmit: { [weak self] in
                guard let self else { return false }
                return self.generation == currentGeneration
                    && LinuxGeneralSettings.includesAttachmentsOutsideProject
            },
            completion: { [weak self] in
                guard let self else { return }
                self.busy = false
                self.startNext()
            })
    }
}
#endif
