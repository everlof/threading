import Foundation

enum ProjectAutomationIdentifier {
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 80 && id != "." && id != ".."
            && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}

struct AutomationWorkspace: Codable, Equatable, Sendable {
    let automationID: String
    let checkoutPath: String

    init(automationID: String, checkoutPath: String) {
        self.automationID = automationID
        self.checkoutPath = checkoutPath
    }

    private enum CodingKeys: String, CodingKey { case automationID, checkoutPath }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        automationID = try container.decode(String.self, forKey: .automationID)
        checkoutPath = try container.decode(String.self, forKey: .checkoutPath)
        guard ProjectAutomationIdentifier.isValid(automationID), checkoutPath.hasPrefix("/"), !checkoutPath.contains("\0") else {
            throw DecodingError.dataCorruptedError(forKey: .automationID, in: container, debugDescription: "Invalid automation workspace")
        }
    }

    var executionPath: String {
        URL(fileURLWithPath: checkoutPath).appendingPathComponent(
            ".threading/local/automations/\(automationID)", isDirectory: true).path
    }
}
