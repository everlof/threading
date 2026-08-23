import Foundation

// MARK: - Frontend-neutral command operations

/// One command as every frontend sees it. AppKit objects and input events deliberately stop at
/// the Mac adapter; a remote or future frontend receives only stable semantic values.
struct HostCommandDescriptor: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case builtIn
        case extensionCommand(identifier: String, name: String, localID: String)
        /// A command the open checkout declares in `.threading.json`. It is neither the host's
        /// own nor an installed extension's, and the palette says so: what runs is decided by
        /// the repository in front of you.
        case projectScript(localID: String)
    }

    enum Scope: String, Equatable, Sendable {
        case application
        case project
        case session
    }

    enum Risk: String, Equatable, Sendable {
        case ordinary
        case destructive
    }

    enum Availability: Equatable, Sendable {
        case available
        case unavailable(reason: String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        var disabledReason: String? {
            guard case .unavailable(let reason) = self else { return nil }
            return reason
        }
    }

    let id: String
    let title: String
    let detail: String?
    let group: String
    let shortcut: String?
    let origin: Origin
    let scope: Scope
    let risk: Risk
    let availability: Availability
    /// The next value a frontend may collect when the command has no implicit context.
    /// Menus still treat the command as unavailable; an interactive frontend can advance to
    /// this input without inventing command semantics of its own.
    let nextInput: HostCommandInputRequest?
    let shortcutEditable: Bool

    init(
        id: String,
        title: String,
        detail: String?,
        group: String,
        shortcut: String?,
        origin: Origin,
        scope: Scope,
        risk: Risk,
        availability: Availability,
        nextInput: HostCommandInputRequest? = nil,
        shortcutEditable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.group = group
        self.shortcut = shortcut
        self.origin = origin
        self.scope = scope
        self.risk = risk
        self.availability = availability
        self.nextInput = nextInput
        self.shortcutEditable = shortcutEditable
    }
}

struct HostCommandInputRequest: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case session
    }

    let kind: Kind
    let prompt: String
    let searchPlaceholder: String
}

struct HostCommandInputOption: Equatable, Sendable {
    let id: String
    let title: String
    let detail: String?
}

struct HostCommandInputValue: Equatable, Sendable {
    let kind: HostCommandInputRequest.Kind
    let id: String
}

struct HostCommandInvocationRequest: Equatable, Sendable {
    let commandID: String
    let input: HostCommandInputValue?

    init(commandID: String, input: HostCommandInputValue? = nil) {
        self.commandID = commandID
        self.input = input
    }
}

extension AppCommand {
    /// The only projection from the app's stable command record into the host contract. Menus,
    /// shortcut settings and palettes therefore cannot drift on identity or presentation.
    func hostDescriptor(
        shortcut: String?,
        availability: HostCommandDescriptor.Availability,
        nextInput: HostCommandInputRequest? = nil
    ) -> HostCommandDescriptor {
        let hostOrigin: HostCommandDescriptor.Origin
        switch origin {
        case .builtIn:
            hostOrigin = .builtIn
        case .extensionCommand(let identifier, let name, let localID):
            hostOrigin = .extensionCommand(
                identifier: identifier,
                name: name,
                localID: localID
            )
        case .projectScript(let localID):
            hostOrigin = .projectScript(localID: localID)
        }
        return HostCommandDescriptor(
            id: id,
            title: title,
            detail: detail,
            group: group.rawValue,
            shortcut: shortcut,
            origin: hostOrigin,
            scope: HostCommandDescriptor.Scope(rawValue: scope.rawValue) ?? .application,
            risk: HostCommandDescriptor.Risk(rawValue: risk.rawValue) ?? .ordinary,
            availability: availability,
            nextInput: nextInput,
            shortcutEditable: isEditable
        )
    }
}

enum HostCommandInvocationOutcome: Equatable, Sendable {
    case invoked(commandID: String)
    case refused(commandID: String, reason: String)
}

/// Catalog and invocation share these closures, which is what makes invocation identity and
/// last-moment availability authoritative instead of a copy baked into one frontend.
@MainActor
final class HostCommandPlane {
    typealias CatalogProvider = @MainActor () -> [HostCommandDescriptor]
    typealias InputProvider = @MainActor (
        String,
        HostCommandInputRequest
    ) -> [HostCommandInputOption]
    typealias Invoker = @MainActor (HostCommandInvocationRequest) -> HostCommandInvocationOutcome

    private let catalogProvider: CatalogProvider
    private let inputProvider: InputProvider
    private let invoker: Invoker

    init(
        catalog: @escaping CatalogProvider,
        invoke: @escaping @MainActor (String) -> HostCommandInvocationOutcome
    ) {
        catalogProvider = catalog
        inputProvider = { _, _ in [] }
        invoker = { invoke($0.commandID) }
    }

    init(
        catalog: @escaping CatalogProvider,
        inputOptions: @escaping InputProvider,
        invokeRequest: @escaping Invoker
    ) {
        catalogProvider = catalog
        inputProvider = inputOptions
        invoker = invokeRequest
    }

    func commands() -> [HostCommandDescriptor] {
        catalogProvider()
    }

    func inputOptions(commandID: String) -> [HostCommandInputOption] {
        guard let command = catalogProvider().first(where: { $0.id == commandID }),
              let request = command.nextInput else { return [] }
        return inputProvider(commandID, request)
    }

    /// Re-enumerates before invoking. An extension can disappear and a project/session/surface
    /// can change after a palette row was drawn; the stale row never becomes permission.
    func invoke(commandID: String) -> HostCommandInvocationOutcome {
        invoke(HostCommandInvocationRequest(commandID: commandID))
    }

    func invoke(_ request: HostCommandInvocationRequest) -> HostCommandInvocationOutcome {
        guard let current = catalogProvider().first(where: { $0.id == request.commandID }) else {
            return .refused(
                commandID: request.commandID,
                reason: "This command is no longer available."
            )
        }

        if let nextInput = current.nextInput {
            guard let input = request.input, input.kind == nextInput.kind else {
                return .refused(commandID: current.id, reason: nextInput.prompt)
            }
            guard inputProvider(current.id, nextInput).contains(where: { $0.id == input.id }) else {
                return .refused(
                    commandID: current.id,
                    reason: "That selection is no longer available."
                )
            }
            return invoker(request)
        }

        guard current.availability.isAvailable else {
            return .refused(
                commandID: request.commandID,
                reason: current.availability.disabledReason ?? "This command is unavailable."
            )
        }
        return invoker(request)
    }
}

enum HostCommandSearch {
    static let maximumResults = 100

    /// Pure and bounded so a frontend can run it away from its drawing thread.
    static func results(
        in commands: [HostCommandDescriptor],
        matching rawQuery: String,
        limit: Int = maximumResults
    ) -> [HostCommandDescriptor] {
        let boundedLimit = max(0, min(limit, maximumResults))
        guard boundedLimit > 0 else { return [] }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).folded
        guard !query.isEmpty else { return Array(commands.prefix(boundedLimit)) }

        var ranked: [(Int, HostCommandDescriptor)] = []
        ranked.reserveCapacity(min(commands.count, maximumResults * 2))
        for (index, command) in commands.enumerated() {
            if index.isMultiple(of: 128), Task.isCancelled { return [] }
            let title = command.title.folded
            let detail = command.detail?.folded ?? ""
            let origin: String
            switch command.origin {
            case .builtIn: origin = ""
            case .extensionCommand(_, let name, _): origin = name.folded
            // A script's origin is the checkout that declares it, and the group is what the
            // palette shows for it, so searching "project scripts" finds them as a set.
            case .projectScript: origin = command.group.folded
            }
            let score: Int
            if title == query { score = 0 }
            else if title.hasPrefix(query) { score = 10 }
            else if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { score = 20 }
            else if title.contains(query) { score = 30 }
            else if detail.contains(query) { score = 40 }
            else if origin.contains(query) { score = 50 }
            else { continue }
            ranked.append((score, command))
        }
        return ranked.sorted { left, right in
            if left.0 != right.0 { return left.0 < right.0 }
            return left.1.title.localizedStandardCompare(right.1.title) == .orderedAscending
        }
        .prefix(boundedLimit)
        .map(\.1)
    }
}

enum HostCommandInputSearch {
    static let maximumResults = HostCommandSearch.maximumResults

    static func results(
        in options: [HostCommandInputOption],
        matching rawQuery: String,
        limit: Int = maximumResults
    ) -> [HostCommandInputOption] {
        let boundedLimit = max(0, min(limit, maximumResults))
        guard boundedLimit > 0 else { return [] }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).folded
        guard !query.isEmpty else { return Array(options.prefix(boundedLimit)) }

        var ranked: [(Int, HostCommandInputOption)] = []
        ranked.reserveCapacity(min(options.count, maximumResults * 2))
        for (index, option) in options.enumerated() {
            if index.isMultiple(of: 128), Task.isCancelled { return [] }
            let title = option.title.folded
            let detail = option.detail?.folded ?? ""
            let id = option.id.folded
            let score: Int
            if title == query { score = 0 }
            else if title.hasPrefix(query) { score = 10 }
            else if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { score = 20 }
            else if title.contains(query) { score = 30 }
            else if detail.contains(query) { score = 40 }
            else if id.contains(query) { score = 50 }
            else { continue }
            ranked.append((score, option))
        }
        return ranked.sorted { left, right in
            if left.0 != right.0 { return left.0 < right.0 }
            return left.1.title.localizedStandardCompare(right.1.title) == .orderedAscending
        }
        .prefix(boundedLimit)
        .map(\.1)
    }
}

private extension String {
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
