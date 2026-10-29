import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

/// The three durable answers in a conversation's speed menu on both desktop hosts.
enum ConversationSpeedChoice: CaseIterable, Equatable {
    case followGeneral
    case standard
    case fast

    var fastMode: Bool? {
        switch self {
        case .followGeneral: nil
        case .standard: false
        case .fast: true
        }
    }
}

/// One row layout and chip vocabulary for speed in the opening and reply composers on both hosts.
enum ConversationSpeedMenuContent {
    static let fastSymbol = "bolt.fill"
    static let ordinarySymbol = "gauge"

    static var standardTitle: String { L10n.string("Standard") }
    static var fastTitle: String { L10n.string("Fast") }
    static var standardDetail: String { L10n.string("Normal speed and usage") }
    static var fastDetail: String { L10n.string("1.5× speed, increased usage") }
    static var followGeneralTitle: String { L10n.string("Follow General Setting") }
    static var followGeneralDetail: String {
        L10n.string("Uses the speed chosen in Settings ▸ Chats.")
    }
    static func followGeneralDetail(startupSpeed: AgentStartupSpeed,
                                    whileRunning: Bool) -> String {
        whileRunning && startupSpeed == .agentSetting
            ? L10n.string("Applies the next time this chat starts.")
            : followGeneralDetail
    }

    struct ChipContent: Equatable {
        let symbolName: String
        let title: String
    }

    static func chip(effective: Bool?) -> ChipContent {
        switch effective {
        case true: ChipContent(symbolName: fastSymbol, title: fastTitle)
        case false: ChipContent(symbolName: ordinarySymbol, title: standardTitle)
        case nil: ChipContent(symbolName: ordinarySymbol,
            title: L10n.string("Agent's Setting"))
        }
    }

    static func rows(
        selected: Bool?,
        inheritTitle: String,
        inheritDetail: String
    ) -> [ThemedMenuEntry] {
        [
            .item(ThemedMenuItem(title: inheritTitle, subtitle: inheritDetail,
                representedValue: ConversationSpeedChoice.followGeneral,
                isSelected: selected == nil)),
            .item(ThemedMenuItem(title: standardTitle, subtitle: standardDetail,
                representedValue: ConversationSpeedChoice.standard,
                isSelected: selected == false)),
            .item(ThemedMenuItem(title: fastTitle, subtitle: fastDetail,
                representedValue: ConversationSpeedChoice.fast,
                isSelected: selected == true))
        ]
    }
}
