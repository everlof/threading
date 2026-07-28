import Foundation

/// One package-owned translation table.
///
/// The JSON resource is a flat object whose keys are the extension's base-language strings and
/// whose values are translations. Base strings therefore remain readable in manifests and
/// source, and an absent translation falls back one string at a time.
public struct ExtensionLocalizationContribution: Codable, Equatable, Sendable {
    public static let maximumCount = 16

    public let locale: String
    public let resource: String

    public init(locale: String, resource: String) {
        self.locale = locale
        self.resource = resource
    }

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !Self.isLanguageTag(locale) {
            issues.append(.init(
                path: "\(path).locale",
                message: "must be a BCP-47 language tag"
            ))
        }
        if !ExtensionIdentifierRules.isSafeRelativePath(resource) {
            issues.append(.init(
                path: "\(path).resource",
                message: "must be a relative path without '.' or '..' components"
            ))
        } else if URL(fileURLWithPath: resource).pathExtension.lowercased() != "json" {
            issues.append(.init(
                path: "\(path).resource",
                message: "must end in '.json'"
            ))
        }
        return issues
    }

    private static func isLanguageTag(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Presentation context supplied before an extension registers.
public enum ExtensionLocalizationEnvironment {
    public static let localeIdentifier = "SKALMAN_EXTENSION_LOCALE"
    public static let preferredLanguagesJSON = "SKALMAN_EXTENSION_PREFERRED_LANGUAGES_JSON"
    public static let selectedLanguage = "SKALMAN_EXTENSION_LANGUAGE"
    public static let stringsJSON = "SKALMAN_EXTENSION_LOCALIZED_STRINGS_JSON"
}

/// Localizes dynamic extension copy with the same negotiated table the host uses for static
/// settings, commands, panels, and semantic nodes.
public struct ExtensionLocalizer: Sendable {
    public let localeIdentifier: String
    public let preferredLanguages: [String]
    public let selectedLanguage: String?
    private let strings: [String: String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        localeIdentifier = environment[
            ExtensionLocalizationEnvironment.localeIdentifier
        ] ?? Locale.current.identifier
        preferredLanguages = Self.decode(
            [String].self,
            from: environment[ExtensionLocalizationEnvironment.preferredLanguagesJSON]
        ) ?? Locale.preferredLanguages
        selectedLanguage = environment[ExtensionLocalizationEnvironment.selectedLanguage]
        strings = Self.decode(
            [String: String].self,
            from: environment[ExtensionLocalizationEnvironment.stringsJSON]
        ) ?? [:]
    }

    public init(
        localeIdentifier: String,
        preferredLanguages: [String],
        selectedLanguage: String?,
        strings: [String: String]
    ) {
        self.localeIdentifier = localeIdentifier
        self.preferredLanguages = preferredLanguages
        self.selectedLanguage = selectedLanguage
        self.strings = strings
    }

    public func string(_ key: String) -> String {
        strings[key] ?? key
    }

    public func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale(identifier: localeIdentifier),
            arguments: arguments
        )
    }

    /// RFC 4647-style lookup: exact tag, progressively less-specific tag, then a catalogue
    /// whose language is the requested base language. Declaration order breaks equivalent ties.
    public static func bestLanguage(
        preferredLanguages: [String],
        availableLanguages: [String]
    ) -> String? {
        let available = availableLanguages.map { ($0, normalized($0)) }
        for preferred in preferredLanguages {
            var candidate = normalized(preferred)
            while !candidate.isEmpty {
                if let exact = available.first(where: { $0.1 == candidate }) {
                    return exact.0
                }
                guard let separator = candidate.lastIndex(of: "-") else { break }
                candidate = String(candidate[..<separator])
            }

            let base = normalized(preferred).split(separator: "-").first.map(String.init)
            if let base,
               let languageMatch = available.first(where: {
                   $0.1.split(separator: "-").first.map(String.init) == base
               }) {
                return languageMatch.0
            }
        }
        return nil
    }

    private static func normalized(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from value: String?
    ) -> Value? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
