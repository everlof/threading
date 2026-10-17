import Foundation

/// Pure provider catalogue decoding shared by platform hosts. File reads, account discovery,
/// freshness, admission bounds and presentation remain the calling host's responsibility.
enum ProviderModelCatalog {
    static func decodeCodex(_ data: Data) -> (options: [AgentModelOption], version: String?)? {
        guard let cache = try? JSONDecoder().decode(CodexModelsCache.self, from: data) else { return nil }
        let options = cache.models
            .filter { $0.visibility == AgentDefaults.codexVisibleModel }
            .map { model in
                let fastTier = model.serviceTiers?.first {
                    $0.name.caseInsensitiveCompare(AgentDefaults.codexFastModeName) == .orderedSame
                }?.id ?? (
                    model.additionalSpeedTiers?.contains(
                        AgentDefaults.codexFastServiceTierAlias
                    ) == true
                        ? AgentDefaults.codexFastServiceTier
                        : nil
                )

                return AgentModelOption(
                    identifier: model.slug,
                    displayName: model.displayName,
                    fastServiceTier: fastTier,
                    defaultServiceTier: model.defaultServiceTier,
                    defaultReasoningLevel: model.defaultReasoningLevel,
                    reasoningLevels: model.supportedReasoningLevels?.map {
                        AgentReasoningLevel(
                            effort: $0.effort,
                            description: $0.description
                        )
                    } ?? []
                )
            }
        return (options, cache.clientVersion)
    }

    static func organisationModel(inClaudeState state: [String: Any]) -> String? {
        guard let value = state[AgentDefaults.claudeOrgDefaultModelKey] else { return nil }

        if let identifier = value as? String {
            return identifier.isEmpty ? nil : identifier
        }
        guard let nested = value as? [String: Any] else { return nil }
        for key in AgentDefaults.claudeOrgDefaultNestedKeys {
            if let identifier = nested[key] as? String, !identifier.isEmpty {
                return identifier
            }
        }
        return nil
    }

    static func additionalModels(inClaudeState state: [String: Any]) -> [AgentModelOption] {
        guard let entries = WireList.objects(
            state[AgentDefaults.claudeAdditionalModelsKey],
            site: WireListSite.claudeAdditionalModels,
            log: ThreadingLogger.agent
        ) else { return [] }

        return entries.compactMap { entry in
            guard let identifier = entry["value"] as? String, !identifier.isEmpty else {
                return nil
            }
            return claudeOption(
                identifier: identifier,
                displayName: cachedModelName(identifier: identifier, entry: entry)
            )
        }
    }

    static func cachedModelName(identifier: String, entry: [String: Any]) -> String {
        if ModelName.read(identifier) != nil {
            return ModelName.display(for: identifier)
        }
        let described: String? = (entry["description"] as? String).flatMap { description in
            let parts = description.components(
                separatedBy: AgentDefaults.claudeModelDescriptionSeparator
            )
            return parts.count > 1 ? parts[0] : nil
        }
        let name = [described, entry["label"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.utf8.count <= AgentDefaults.claudeModelLabelMaximumBytes }
        guard let name else { return ModelName.display(for: identifier) }
        return ModelName.display(serviceLabel: name, for: identifier)
    }

    static func claudeOption(
        identifier: String,
        displayName: String
    ) -> AgentModelOption {
        AgentModelOption(
            identifier: identifier,
            displayName: displayName,
            fastServiceTier: nil,
            defaultServiceTier: nil,
            reasoningLevels: AgentDefaults.claudeReasoningEfforts.map {
                AgentReasoningLevel(effort: $0, description: "")
            }
        )
    }

    static func codexAssignments(in contents: String) -> [String: String] {
        var assignments: [String: String] = [:]

        for line in contents.split(separator: "\n") {
            // A `[table]` header carries no `=` and drops out here. Keys *under* one are still
            // collected, exactly as the previous scan matched them wherever they appeared.
            let parts = line.trimmingCharacters(in: .whitespaces).split(
                separator: "=",
                maxSplits: 1
            )
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, assignments[key] == nil else { continue }

            assignments[key] = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        return assignments
    }
}

private struct CodexModelsCache: Decodable {
    let models: [Model]
    let clientVersion: String?

    private enum CodingKeys: String, CodingKey {
        case models
        case clientVersion = "client_version"
    }

    struct Model: Decodable {
        let slug: String
        let displayName: String
        let visibility: String?
        let additionalSpeedTiers: [String]?
        let serviceTiers: [ServiceTier]?
        let defaultServiceTier: String?
        let defaultReasoningLevel: String?
        let supportedReasoningLevels: [ReasoningLevel]?

        private enum CodingKeys: String, CodingKey {
            case slug, visibility
            case displayName = "display_name"
            case additionalSpeedTiers = "additional_speed_tiers"
            case serviceTiers = "service_tiers"
            case defaultServiceTier = "default_service_tier"
            case defaultReasoningLevel = "default_reasoning_level"
            case supportedReasoningLevels = "supported_reasoning_levels"
        }
    }

    struct ServiceTier: Decodable {
        let id: String
        let name: String
    }

    struct ReasoningLevel: Decodable {
        let effort: String
        let description: String
    }
}
