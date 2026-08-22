#if DEBUG
@MainActor
extension AgentToolCoordinator: MobileDebugToolProviding {
    var mobileDebugInspection: MobileDebugInspectionService {
        dependencies.mobileDebugInspection
    }
}
#endif
