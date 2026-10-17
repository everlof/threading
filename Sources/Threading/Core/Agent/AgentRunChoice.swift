import Foundation

/// The choices a new session runs with — model, reasoning effort and speed — and the one rule for
/// whether a login can honour them.
///
/// Every path that starts a session from choices made somewhere else asks this question: a
/// phone's create request, the report-launch choices the catalogue publishes, and a send moved
/// onto another default account. Each used to carry its own copy of the rule, and the copies
/// drifted apart twice: the gate refused a Fast the catalogue had advertised for a nil model,
/// and later refused a login's configured `opus[1m]` — which the catalogue offered as that
/// login's default — on every chat a phone started there.
///
/// `refusal(kind:account:)` is the gate. `honoured(kind:account:)` applies the same gate one
/// choice at a time and drops what fails to the login's own default, so what it returns is
/// admitted by construction. Both read `AgentModels.launchableOptions`, the list the pickers
/// are filtered from, which is what keeps "offered" and "accepted" one answer.
struct AgentRunChoice: Equatable, Sendable {

    // MARK: - Types

    /// Which choice the login cannot honour, in the order they are checked.
    enum Refusal: Equatable, Sendable {
        case unknownModel
        case unknownReasoningEffort
        case unsupportedSpeed
    }

    // MARK: - Properties

    /// Nil leaves each choice to the login: the model and effort its configuration names, and
    /// the speed it would start at.
    var model: String?
    var reasoningEffort: String?
    var fastMode: Bool?

    // MARK: - Public Methods

    /// Why `account` cannot start a session with these choices, or nil when it can.
    ///
    /// An effort or speed sent with a nil model is checked against the model the login would
    /// run, which is what the session will actually start on.
    func refusal(kind: AgentKind, account: AgentAccount?) -> Refusal? {
        let options = AgentModels.launchableOptions(for: kind, account: account)
        if let model, !options.contains(where: { $0.identifier == model }) {
            return .unknownModel
        }
        guard AgentModels.supports(
            reasoningEffort: reasoningEffort,
            kind: kind,
            model: model,
            account: account,
            options: options
        ) else { return .unknownReasoningEffort }
        if fastMode != nil,
           !AgentModels.supportsFastMode(kind: kind, model: model, account: account) {
            return .unsupportedSpeed
        }
        return nil
    }

    /// These choices with each one `account` cannot honour dropped to its default. Never
    /// refused: for a choice that has already been accepted somewhere else, landing on the
    /// login's own default is better than failing the send.
    ///
    /// Dropped in order, each judged against what survived before it, so an effort chosen for
    /// a model the login does not offer is judged against the model it will run instead.
    func honoured(kind: AgentKind, account: AgentAccount?) -> AgentRunChoice {
        let options = AgentModels.launchableOptions(for: kind, account: account)
        let keptModel = model.flatMap { model in
            options.contains { $0.identifier == model } ? model : nil
        }
        let keptEffort = reasoningEffort.flatMap { effort in
            AgentModels.supports(
                reasoningEffort: effort,
                kind: kind,
                model: keptModel,
                account: account,
                options: options
            ) ? effort : nil
        }
        let keptFastMode = fastMode.flatMap { fastMode in
            AgentModels.supportsFastMode(kind: kind, model: keptModel, account: account)
                ? fastMode
                : nil
        }
        return AgentRunChoice(
            model: keptModel,
            reasoningEffort: keptEffort,
            fastMode: keptFastMode
        )
    }
}
