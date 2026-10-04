import Foundation

/// The public listing is an index; the complete authoring vocabulary is fetched one block at a
/// time. Both come from the same schema, so adding a field cannot leave the read path behind.
extension MCPTools {
    static var appVariantListingSchema: [String: MCPPropertySchema] {
        let summaries = [
            "roles": "Semantic chrome colours, #RRGGBB or #RRGGBBAA.",
            "terminal_colors": "Terminal palette plus optional glow {radius, opacity}.",
            "material": "Geometry, type, controls, identity_marks and backdrop {gradient, image, particles}.",
            "sidebar": "Sidebar gradient/image, logo, wordmark and mascot mood poses.",
            "chrome": "Opt-in window title band, buttons and frame.",
            "transition": "Switch-in particles, wash and duration.",
            "sprites": "Up to 8 named particle pictures, each a source {path} or {base64}.",
            "moments": "Sounds and particles for turn_finished and needs_attention.",
            "words": "Working words, composer_placeholder and untitled_session.",
            "title_morph": "Chat-name transition style and optional scramble alphabet.",
        ]
        return Dictionary(uniqueKeysWithValues: appVariantSchema.map { key, schema in
            // Object members stay open; argument decoding and validators remain authoritative.
            let description = summaries[key].map {
                $0 + " See get_app_theme(section: \"\(key)\")."
            } ?? schema.description
            return (key, MCPPropertySchema(type: schema.type, description: description,
                items: schema.items.map { MCPArrayItemSchema(type: $0.type) }))
        })
    }

    static func appThemeDocumentation(section: String) -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data: Data
            if section == "schema" {
                data = try encoder.encode(appVariantListingSchema)
            } else if let entry = appThemeSchemaEntries[section] {
                data = try encoder.encode(entry)
            } else {
                return .failure("Unknown theme section '\(section)'. Use section: schema for the block index; nested fields use dotted paths.")
            }
            return .success(String(decoding: data, as: UTF8.self))
        } catch {
            return .failure("Could not encode theme documentation: \(error.localizedDescription)")
        }
    }

    /// Includes array members using dotted paths, e.g. sprites.source.path.
    static var appThemeSchemaEntries: [String: MCPPropertySchema] {
        var entries: [String: MCPPropertySchema] = [:]
        func visit(_ properties: [String: MCPPropertySchema], prefix: String = "") {
            for (key, value) in properties {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                entries[path] = value
                if let children = value.properties { visit(children, prefix: path) }
                if let children = value.items?.properties { visit(children, prefix: path) }
            }
        }
        visit(appVariantSchema)
        return entries
    }
}
