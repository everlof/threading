import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

extension AgentStartupSpeed {
    var settingsTitle: String {
        switch self {
        case .agentSetting: L10n.string("Agent's Setting")
        case .standard: L10n.string("Standard")
        case .fast: L10n.string("Fast")
        }
    }
}
