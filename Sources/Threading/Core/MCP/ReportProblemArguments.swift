import Foundation

/// Optional wire fields let the application return an actionable refusal for an incomplete call.
struct ReportProblemArguments: Codable, Sendable {
    var title: String?
    var description: String?
    var reproductionSteps: String?
    var expectedBehavior: String?
    var actualBehavior: String?
    var evidence: String?
    var imagePaths: [String]?

    private enum CodingKeys: String, CodingKey {
        case title, description, evidence
        case reproductionSteps = "reproduction_steps"
        case expectedBehavior = "expected_behavior"
        case actualBehavior = "actual_behavior"
        case imagePaths = "image_paths"
    }
}
