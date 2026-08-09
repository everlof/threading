import Foundation

public struct ExtensionValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String {
        "\(path): \(message)"
    }
}

public struct ExtensionValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let issues: [ExtensionValidationIssue]

    public init(issues: [ExtensionValidationIssue]) {
        self.issues = issues
    }

    public var description: String {
        issues.map(\.description).joined(separator: "\n")
    }
}
