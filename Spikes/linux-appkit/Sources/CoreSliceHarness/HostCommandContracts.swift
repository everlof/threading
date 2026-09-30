@testable import CoreSlice
import Foundation

/// Exercise the exact production command boundary without AppCommand, AppKit or an executable
/// command implementation. The Actions picker must not turn its earlier catalogue into authority.
@MainActor
func runHostCommandContracts() throws {
    func command(_ id: String, availability: HostCommandDescriptor.Availability = .available,
                 nextInput: HostCommandInputRequest? = nil) -> HostCommandDescriptor {
        HostCommandDescriptor(id: id, title: "Open shell", detail: nil, group: "Project",
            shortcut: nil, origin: .builtIn, scope: .project, risk: .ordinary,
            availability: availability, nextInput: nextInput)
    }
    var catalogue = [command("project.shell")]
    var invocations: [String] = []
    let plane = HostCommandPlane(catalog: { catalogue }, invoke: { id in
        invocations.append(id)
        return .invoked(commandID: id)
    })
    try require(plane.commands().map(\.id) == ["project.shell"], "stable command identity")
    try require(plane.invoke(commandID: "project.shell") == .invoked(commandID: "project.shell"),
                "available command reaches shared invoker")
    catalogue = [command("project.shell", availability: .unavailable(reason: "Runtime limit reached."))]
    try require(plane.invoke(commandID: "project.shell") == .refused(commandID: "project.shell",
                    reason: "Runtime limit reached."), "invocation rechecks changed availability")
    try require(plane.commands().first?.availability.disabledReason == "Runtime limit reached.",
                "frontend receives current refusal reason")
    catalogue.removeAll()
    guard case .refused(let missingID, let missingReason) = plane.invoke(commandID: "project.shell") else {
        throw ContractFailure.failed("disappeared command reached invoker")
    }
    try require(missingID == "project.shell" && !missingReason.isEmpty, "stale identity refusal")
    try require(invocations == ["project.shell"], "refused commands never dispatch")
    print("PASS host commands revalidate availability and catalogue disappearance")

    let input = HostCommandInputRequest(kind: .project, prompt: "Choose a project.",
                                        searchPlaceholder: "Project")
    catalogue = [command("project.shell", availability: .unavailable(reason: "Select a project."),
                         nextInput: input)]
    var options = [HostCommandInputOption(id: "project-a", title: "A", detail: nil)]
    var requests: [HostCommandInvocationRequest] = []
    let typed = HostCommandPlane(catalog: { catalogue }, inputOptions: { id, requested in
        precondition(id == "project.shell" && requested == input)
        return options
    }, invokeRequest: { request in
        requests.append(request)
        return .invoked(commandID: request.commandID)
    })
    try require(typed.inputOptions(commandID: "project.shell") == options, "typed option projection")
    try require(typed.invoke(commandID: "project.shell") == .refused(commandID: "project.shell",
                    reason: input.prompt), "missing input requests the declared next step")
    let wrongKind = HostCommandInvocationRequest(commandID: "project.shell",
        input: HostCommandInputValue(kind: .session, id: "project-a"))
    try require(typed.invoke(wrongKind) == .refused(commandID: "project.shell", reason: input.prompt),
                "matching ID with wrong input kind cannot dispatch")
    let request = HostCommandInvocationRequest(commandID: "project.shell",
        input: HostCommandInputValue(kind: .project, id: "project-a"))
    try require(typed.invoke(request) == .invoked(commandID: "project.shell"),
                "validated next input satisfies the missing-context prerequisite")
    options.removeAll()
    try require(typed.invoke(request) == .refused(commandID: "project.shell",
                    reason: "That selection is no longer available."), "stale typed target refuses")
    catalogue.removeAll()
    try require(typed.inputOptions(commandID: "project.shell").isEmpty, "removed command has no target step")
    guard case .refused = typed.invoke(request) else {
        throw ContractFailure.failed("typed request dispatched after catalogue removal")
    }
    try require(requests == [request], "only freshly validated typed request dispatches")
    print("PASS host commands validate input kind and fresh target membership")

    let large = (0..<25_000).map { command("command.\($0)") }
    try require(HostCommandSearch.results(in: large, matching: "shell", limit: 1_000).count == 100,
                "command search preserves shared result cap at stress cardinality")
    try require(HostCommandSearch.results(in: large, matching: "", limit: 0).isEmpty,
                "zero visible result request stays empty")
    print("PASS host command search retains the 100-result bound across 25,000 commands")
}
