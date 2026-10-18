import Foundation

/// A subagent's lifecycle follows its parent's: archiving a chat archives the subagents it
/// started, and restoring it brings back the ones that went with it.
///
/// A subagent is part of its parent's work, nested under it, so leaving it running or floating
/// to the project level once the parent is filed away would strand work nobody is waiting for.
/// Driven by the archive edge rather than by the window's archive action, because the iPhone and
/// a provider's own archive file sessions through `ProviderArchiveSync` without the window.
///
/// Only the subagents this archive took are restored with the parent — one the user archived
/// earlier stays archived — and they are taken back under the parent's responsibility with their
/// last brief, since the archive closed that tenure. The record is this run's: Undo is the case
/// it serves, and a restore from Settings ▸ Archived after a relaunch restores the parent alone.
@MainActor
final class SubagentLifecycle {

    // MARK: - Types

    struct Dependencies {
        /// The unarchived subagents a chat started.
        let liveSubagents: (SessionID) -> [SessionID]
        let setArchived: (Bool, SessionID) -> Void
        /// Records `parent` as responsible for `child` again, with the brief of its last tenure.
        let readopt: (_ child: SessionID, _ parent: SessionID) -> Void
    }

    // MARK: - Properties

    static let shared = SubagentLifecycle(dependencies: Dependencies(
        liveSubagents: { parentID in
            ProjectStore.shared.project(forSessionID: parentID)?.sessions
                .filter { $0.subagentParentID == parentID && !$0.isArchived }
                .map(\.id) ?? []
        },
        setArchived: { archived, sessionID in
            ProviderArchiveSync.shared.setArchived(archived, for: sessionID) { result in
                guard case .failure = result else { return }
                EventLog.shared.record(.session, "Subagent did not follow its parent's archive state", [
                    "session": sessionID.uuidString,
                    "archived": String(archived),
                ])
            }
        },
        readopt: { childID, parentID in
            let brief = ControlGrantStore.shared.supervisions(forChild: childID)
                .last(where: { $0.managerID == parentID })?.brief ?? ""
            _ = ControlGrantStore.shared.adopt(childID: childID, by: parentID, brief: brief)
        }
    ))

    private let dependencies: Dependencies
    private let observations: AppEventObservations
    private var isStarted = false
    /// The subagents each parent's archive took this run. Bounded by live subagents per parent.
    private var archivedWithParent: [SessionID: [SessionID]] = [:]

    // MARK: - Initialization

    init(center: NotificationCenter = .default, dependencies: Dependencies) {
        self.dependencies = dependencies
        observations = AppEventObservations(center: center)
    }

    // MARK: - Public Methods

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observations.observe(SessionArchivedStateDidChange.self) { [weak self] event in
            self?.archiveStateChanged(event)
        }
    }

    // MARK: - Private Methods

    private func archiveStateChanged(_ event: SessionArchivedStateDidChange) {
        let sessionID = event.sessionID
        if event.isArchived {
            let subagents = dependencies.liveSubagents(sessionID)
            guard !subagents.isEmpty else { return }
            archivedWithParent[sessionID] = subagents
            for subagent in subagents {
                dependencies.setArchived(true, subagent)
            }
        } else {
            for subagent in archivedWithParent.removeValue(forKey: sessionID) ?? [] {
                dependencies.setArchived(false, subagent)
                dependencies.readopt(subagent, sessionID)
            }
        }
    }
}
