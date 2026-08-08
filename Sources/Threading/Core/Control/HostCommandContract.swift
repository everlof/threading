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
}

extension AppCommand {
    /// The only projection from the app's stable command record into the host contract. Menus,
    /// shortcut settings and palettes therefore cannot drift on identity or presentation.
    func hostDescriptor(
        shortcut: String?,
        availability: HostCommandDescriptor.Availability
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
            availability: availability
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
    typealias Invoker = @MainActor (String) -> HostCommandInvocationOutcome

    private let catalogProvider: CatalogProvider
    private let invoker: Invoker

    init(catalog: @escaping CatalogProvider, invoke: @escaping Invoker) {
        catalogProvider = catalog
        invoker = invoke
    }

    func commands() -> [HostCommandDescriptor] {
        catalogProvider()
    }

    /// Re-enumerates before invoking. An extension can disappear and a project/session/surface
    /// can change after a palette row was drawn; the stale row never becomes permission.
    func invoke(commandID: String) -> HostCommandInvocationOutcome {
        guard let current = catalogProvider().first(where: { $0.id == commandID }) else {
            return .refused(commandID: commandID, reason: "This command is no longer available.")
        }
        guard current.availability.isAvailable else {
            return .refused(
                commandID: commandID,
                reason: current.availability.disabledReason ?? "This command is unavailable."
            )
        }
        return invoker(commandID)
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

private extension String {
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
