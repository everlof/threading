import Foundation

/// The host's current composer settings. An absent value means the host predates this capability.
/// Choices carry provider values; clients never infer permissions or configuration from labels.
public struct RemoteConversationConfigurationDTO: Codable, Equatable, Sendable {
    public enum Setting: String, Codable, CaseIterable, Sendable {
        case model, effort, permissions, speed
    }

    public struct Choice: Codable, Equatable, Sendable {
        public let title: String
        public let detail: String?
        public let value: String?
        public let isSelected: Bool

        public init(title: String, detail: String? = nil, value: String?, isSelected: Bool = false) {
            self.title = title
            self.detail = detail
            self.value = value
            self.isSelected = isSelected
        }
    }

    public struct Control: Codable, Equatable, Sendable {
        public let setting: Setting
        public let title: String
        public let isEnabled: Bool
        public let choices: [Choice]

        public init(setting: Setting, title: String, isEnabled: Bool, choices: [Choice]) {
            self.setting = setting
            self.title = title
            self.isEnabled = isEnabled
            self.choices = Array(choices.prefix(RemoteConversationConfigurationDTO.maximumChoices))
        }
    }

    public static let maximumChoices = 100
    public static let maximumContentUTF8Bytes = 64 * 1024
    public let controls: [Control]

    public init(controls: [Control]) {
        self.controls = controls
    }

    public var isValid: Bool {
        guard controls.count <= Setting.allCases.count
            && Set(controls.map(\.setting)).count == controls.count else { return false }
        let fieldsAreBounded = controls.allSatisfy { control in
                control.title.utf8.count <= 512
                    && control.choices.count <= Self.maximumChoices
                    && control.choices.allSatisfy {
                        $0.title.utf8.count <= 512 && ($0.detail?.utf8.count ?? 0) <= 2_048
                            && ($0.value?.utf8.count ?? 0) <= 256
                    }
            }
        guard fieldsAreBounded else { return false }
        let contentBytes = controls.reduce(0) { total, control in
            total + control.title.utf8.count + control.choices.reduce(0) { subtotal, choice in
                subtotal + choice.title.utf8.count + (choice.detail?.utf8.count ?? 0) + (choice.value?.utf8.count ?? 0)
            }
        }
        return contentBytes <= Self.maximumContentUTF8Bytes
    }
}

/// A request is settled only after the existing host setting path has applied and persisted it.
public struct RemoteConversationConfigurationResultDTO: Codable, Equatable, Sendable {
    public let type: String
    public let requestID: String
    public let error: String?

    public init(requestID: String, error: String? = nil) {
        type = "conversationConfigurationResult"
        self.requestID = requestID
        self.error = error
    }
}
