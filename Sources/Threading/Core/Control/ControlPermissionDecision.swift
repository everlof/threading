/// The only decisions a manager can make. There is deliberately no session-wide answer: a
/// manager responds to the exact active request and cannot change the child's future policy.
enum ControlPermissionDecision: String, Equatable, Sendable {
    case allow
    case deny
}
