import Foundation

/// Represents token usage for a single AI request.
struct TokenUsage: Codable, Equatable {

    // MARK: - Properties

    var inputTokens: Int
    var outputTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    // MARK: - Initialization

    init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    // MARK: - Mutating Methods

    mutating func add(input: Int, output: Int) {
        inputTokens += input
        outputTokens += output
    }
}

/// Manages persistent storage of token usage statistics per model.
final class TokenUsageManager {

    // MARK: - Singleton

    static let shared = TokenUsageManager()

    // MARK: - Constants

    private enum Keys {
        static let tokenUsage = "tokenUsage"
    }

    // MARK: - Properties

    private let defaults = UserDefaults.standard

    /// Current usage by model name.
    private(set) var usageByModel: [String: TokenUsage] {
        get {
            guard let data = defaults.data(forKey: Keys.tokenUsage),
                  let usage = try? JSONDecoder().decode([String: TokenUsage].self, from: data) else {
                return [:]
            }
            return usage
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.tokenUsage)
            }
        }
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Records token usage for a specific model.
    func record(model: String, inputTokens: Int, outputTokens: Int) {
        var usage = usageByModel
        var modelUsage = usage[model] ?? TokenUsage()
        modelUsage.add(input: inputTokens, output: outputTokens)
        usage[model] = modelUsage
        usageByModel = usage
    }

    /// Returns the total usage for a specific model.
    func total(for model: String) -> TokenUsage? {
        usageByModel[model]
    }

    /// Returns all models with their usage.
    func allModels() -> [String: TokenUsage] {
        usageByModel
    }

    /// Resets usage for a specific model.
    func reset(model: String) {
        var usage = usageByModel
        usage.removeValue(forKey: model)
        usageByModel = usage
    }

    /// Resets all token usage data.
    func resetAll() {
        usageByModel = [:]
    }

    /// Returns total tokens across all models.
    func totalAcrossAllModels() -> TokenUsage {
        var total = TokenUsage()
        for (_, usage) in usageByModel {
            total.add(input: usage.inputTokens, output: usage.outputTokens)
        }
        return total
    }
}
