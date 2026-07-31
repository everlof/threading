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
actor TokenUsageManager {

    // MARK: - Singleton

    static let shared = TokenUsageManager()

    // MARK: - Constants

    private enum Keys {
        static let tokenUsage = "tokenUsage"
    }

    // MARK: - Properties

    private let persistence: RecoverableDefaultsStore<[String: TokenUsage]>
    private(set) var usageByModel: [String: TokenUsage]

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard) {
        self.persistence = RecoverableDefaultsStore(
            defaults: defaults,
            key: Keys.tokenUsage,
            criticality: .userAuthored
        )
        self.usageByModel = persistence.load(defaultValue: [:]).value
    }

    // MARK: - Public Methods

    /// Records token usage for a specific model.
    func record(model: String, inputTokens: Int, outputTokens: Int) {
        var usage = usageByModel
        var modelUsage = usage[model] ?? TokenUsage()
        modelUsage.add(input: inputTokens, output: outputTokens)
        usage[model] = modelUsage
        if persistence.save(usage) {
            usageByModel = usage
        }
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
        if persistence.save(usage) {
            usageByModel = usage
        }
    }

    /// Resets all token usage data.
    func resetAll() {
        if persistence.save([:]) {
            usageByModel = [:]
        }
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
