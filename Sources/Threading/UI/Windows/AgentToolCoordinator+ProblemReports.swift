import Foundation

@MainActor
extension AgentToolCoordinator {
    func reportProblem(
        _ arguments: ReportProblemArguments, for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard dependencies.projects.session(withID: sessionID) != nil else {
            completion(.failure("This session is no longer available. Nothing was filed."))
            return
        }
        guard let problemReporter else {
            completion(.failure("Threading's problem-report service is unavailable. Nothing was filed."))
            return
        }
        let isRemote = dependencies.projects.sessionRunsOnRemoteHost(sessionID)
        Task { @MainActor in
            switch await problemReporter.report(arguments, for: sessionID, isRemote: isRemote) {
            case .success(let receipt):
                do {
                    let data = try await Task.detached(priority: .utility) {
                        try JSONEncoder().encode(receipt)
                    }.value
                    let text = String(decoding: data, as: UTF8.self)
                    completion(receipt.status == .failed ? .failure(text) : .success(text))
                } catch {
                    completion(.failure("Threading could not encode the report receipt. Delivery is unconfirmed; retry the same report."))
                }
            case .failure(let refusal):
                completion(.failure(refusal.message))
            }
        }
    }
}
