import Foundation

/// Stable IDs for Threading's built-in Settings pages.
///
/// Extensions target these values rather than page titles or sidebar positions. New host pages
/// may be added without changing existing IDs, and the host always appends contributed sections
/// after its own sections in the first contract version.
public enum ExtensionHostSettingsPage: String, Codable, CaseIterable, Equatable, Sendable {
    case general
    case accounts
    case profiles
    case themes
    case motion
    case extensions
    case tools
    case keyboard
    case usage
    case storage
    case archived
}

/// One option in a host-rendered settings pop-up.
public struct ExtensionSettingOption: Codable, Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// A semantic settings control rendered by Threading.
///
/// This is intentionally a compact form vocabulary rather than an AppKit archive. It gives
/// extensions durable values while Threading retains typography, validation presentation,
/// accessibility, keyboard navigation, theme behaviour, and future visual changes.
public enum ExtensionSettingControl: Equatable, Sendable {
    case toggle(defaultValue: Bool)
    case text(defaultValue: String, placeholder: String?, maximumLength: Int)
    case choice(defaultValue: String, options: [ExtensionSettingOption])
    case integer(defaultValue: Int64, minimum: Int64, maximum: Int64, step: Int64)

    public var defaultValue: ExtensionJSONValue {
        switch self {
        case .toggle(let value):
            return .bool(value)
        case .text(let value, _, _), .choice(let value, _):
            return .string(value)
        case .integer(let value, _, _, _):
            return .integer(value)
        }
    }

    /// Whether a persisted or proposed value still fits this control's declared contract.
    public func accepts(_ value: ExtensionJSONValue) -> Bool {
        switch (self, value) {
        case (.toggle, .bool):
            return true
        case (.text(_, _, let maximumLength), .string(let value)):
            return value.count <= maximumLength
        case (.choice(_, let options), .string(let value)):
            return options.contains { $0.id == value }
        case (
            .integer(_, let minimum, let maximum, let step),
            .integer(let value)
        ):
            return step > 0
                && value >= minimum
                && value <= maximum
                && (value - minimum).isMultiple(of: step)
        default:
            return false
        }
    }
}

extension ExtensionSettingControl: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case defaultValue
        case placeholder
        case maximumLength
        case options
        case minimum
        case maximum
        case step
    }

    private enum Kind: String, Codable {
        case toggle
        case text
        case choice
        case integer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .toggle:
            self = .toggle(
                defaultValue: try container.decode(Bool.self, forKey: .defaultValue)
            )
        case .text:
            self = .text(
                defaultValue: try container.decode(String.self, forKey: .defaultValue),
                placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder),
                maximumLength: try container.decode(Int.self, forKey: .maximumLength)
            )
        case .choice:
            self = .choice(
                defaultValue: try container.decode(String.self, forKey: .defaultValue),
                options: try container.decode([ExtensionSettingOption].self, forKey: .options)
            )
        case .integer:
            self = .integer(
                defaultValue: try container.decode(Int64.self, forKey: .defaultValue),
                minimum: try container.decode(Int64.self, forKey: .minimum),
                maximum: try container.decode(Int64.self, forKey: .maximum),
                step: try container.decode(Int64.self, forKey: .step)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toggle(let defaultValue):
            try container.encode(Kind.toggle, forKey: .type)
            try container.encode(defaultValue, forKey: .defaultValue)
        case .text(let defaultValue, let placeholder, let maximumLength):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(defaultValue, forKey: .defaultValue)
            try container.encodeIfPresent(placeholder, forKey: .placeholder)
            try container.encode(maximumLength, forKey: .maximumLength)
        case .choice(let defaultValue, let options):
            try container.encode(Kind.choice, forKey: .type)
            try container.encode(defaultValue, forKey: .defaultValue)
            try container.encode(options, forKey: .options)
        case .integer(let defaultValue, let minimum, let maximum, let step):
            try container.encode(Kind.integer, forKey: .type)
            try container.encode(defaultValue, forKey: .defaultValue)
            try container.encode(minimum, forKey: .minimum)
            try container.encode(maximum, forKey: .maximum)
            try container.encode(step, forKey: .step)
        }
    }
}

public struct ExtensionSettingField: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let control: ExtensionSettingControl

    public init(
        id: String,
        title: String,
        description: String? = nil,
        control: ExtensionSettingControl
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.control = control
    }
}

public struct ExtensionSettingsSection: Codable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let fields: [ExtensionSettingField]

    public init(
        id: String,
        title: String? = nil,
        fields: [ExtensionSettingField]
    ) {
        self.id = id
        self.title = title
        self.fields = fields
    }
}

/// A complete new page contributed to Threading's Settings sidebar.
public struct ExtensionSettingsPage: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let sections: [ExtensionSettingsSection]

    public init(
        id: String,
        title: String,
        symbol: String = "puzzlepiece.extension",
        sections: [ExtensionSettingsSection]
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.sections = sections
    }
}

/// A section appended to one stable built-in Settings page.
public struct ExtensionHostSettingsSection: Codable, Equatable, Sendable {
    public let id: String
    public let page: ExtensionHostSettingsPage
    public let title: String?
    public let fields: [ExtensionSettingField]

    public init(
        id: String,
        page: ExtensionHostSettingsPage,
        title: String? = nil,
        fields: [ExtensionSettingField]
    ) {
        self.id = id
        self.page = page
        self.title = title
        self.fields = fields
    }
}

/// All statically inspectable settings UI declared by one extension manifest.
public struct ExtensionSettingsContribution: Codable, Equatable, Sendable {
    public static let maximumPages = 8
    public static let maximumSections = 32
    public static let maximumFields = 128

    public let pages: [ExtensionSettingsPage]
    public let sections: [ExtensionHostSettingsSection]

    public init(
        pages: [ExtensionSettingsPage] = [],
        sections: [ExtensionHostSettingsSection] = []
    ) {
        self.pages = pages
        self.sections = sections
    }

    public var isEmpty: Bool { pages.isEmpty && sections.isEmpty }

    public var fields: [ExtensionSettingField] {
        pages.flatMap(\.sections).flatMap(\.fields) + sections.flatMap(\.fields)
    }

    public func field(id: String) -> ExtensionSettingField? {
        fields.first { $0.id == id }
    }

    public func effectiveValues(
        overriding overrides: [String: ExtensionJSONValue] = [:]
    ) -> [String: ExtensionJSONValue] {
        Dictionary(uniqueKeysWithValues: fields.map { field in
            let value = overrides[field.id].flatMap {
                field.control.accepts($0) ? $0 : nil
            } ?? field.control.defaultValue
            return (field.id, value)
        })
    }

    public func validationIssues(path: String = "settings") -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        let allSections = pages.flatMap(\.sections)

        if pages.count > Self.maximumPages {
            issues.append(.init(
                path: "\(path).pages",
                message: "must contain at most \(Self.maximumPages) pages"
            ))
        }
        if allSections.count + sections.count > Self.maximumSections {
            issues.append(.init(
                path: path,
                message: "must contain at most \(Self.maximumSections) sections"
            ))
        }
        if fields.count > Self.maximumFields {
            issues.append(.init(
                path: path,
                message: "must contain at most \(Self.maximumFields) fields"
            ))
        }

        issues.append(contentsOf: duplicateIssues(
            pages.map(\.id),
            path: "\(path).pages"
        ))
        issues.append(contentsOf: duplicateIssues(
            pages.flatMap(\.sections).map(\.id) + sections.map(\.id),
            path: "\(path).sections"
        ))
        issues.append(contentsOf: duplicateIssues(
            fields.map(\.id),
            path: "\(path).fields"
        ))

        for (pageIndex, page) in pages.enumerated() {
            let pagePath = "\(path).pages[\(pageIndex)]"
            issues.append(contentsOf: contributionIDIssues(page.id, path: "\(pagePath).id"))
            issues.append(contentsOf: textIssues(page.title, path: "\(pagePath).title", maximum: 120))
            issues.append(contentsOf: textIssues(page.symbol, path: "\(pagePath).symbol", maximum: 120))
            if page.sections.isEmpty {
                issues.append(.init(path: "\(pagePath).sections", message: "must not be empty"))
            }
            for (sectionIndex, section) in page.sections.enumerated() {
                issues.append(contentsOf: sectionIssues(
                    id: section.id,
                    title: section.title,
                    fields: section.fields,
                    path: "\(pagePath).sections[\(sectionIndex)]"
                ))
            }
        }

        for (sectionIndex, section) in sections.enumerated() {
            issues.append(contentsOf: sectionIssues(
                id: section.id,
                title: section.title,
                fields: section.fields,
                path: "\(path).sections[\(sectionIndex)]"
            ))
        }
        return issues
    }

    private func sectionIssues(
        id: String,
        title: String?,
        fields: [ExtensionSettingField],
        path: String
    ) -> [ExtensionValidationIssue] {
        var issues = contributionIDIssues(id, path: "\(path).id")
        if let title {
            issues.append(contentsOf: textIssues(
                title,
                path: "\(path).title",
                maximum: 120
            ))
        }
        if fields.isEmpty {
            issues.append(.init(path: "\(path).fields", message: "must not be empty"))
        }
        for (fieldIndex, field) in fields.enumerated() {
            issues.append(contentsOf: fieldIssues(
                field,
                path: "\(path).fields[\(fieldIndex)]"
            ))
        }
        return issues
    }

    private func fieldIssues(
        _ field: ExtensionSettingField,
        path: String
    ) -> [ExtensionValidationIssue] {
        var issues = contributionIDIssues(field.id, path: "\(path).id")
        issues.append(contentsOf: textIssues(field.title, path: "\(path).title", maximum: 120))
        if let description = field.description {
            issues.append(contentsOf: textIssues(
                description,
                path: "\(path).description",
                maximum: 500
            ))
        }

        switch field.control {
        case .toggle:
            break
        case .text(let defaultValue, let placeholder, let maximumLength):
            if !(1...4_096).contains(maximumLength) {
                issues.append(.init(
                    path: "\(path).control.maximumLength",
                    message: "must be between 1 and 4096"
                ))
            }
            if defaultValue.count > maximumLength {
                issues.append(.init(
                    path: "\(path).control.defaultValue",
                    message: "must not exceed maximumLength"
                ))
            }
            if let placeholder, placeholder.count > 200 {
                issues.append(.init(
                    path: "\(path).control.placeholder",
                    message: "must contain at most 200 characters"
                ))
            }
        case .choice(let defaultValue, let options):
            if options.isEmpty {
                issues.append(.init(path: "\(path).control.options", message: "must not be empty"))
            }
            issues.append(contentsOf: duplicateIssues(
                options.map(\.id),
                path: "\(path).control.options"
            ))
            for (optionIndex, option) in options.enumerated() {
                let optionPath = "\(path).control.options[\(optionIndex)]"
                issues.append(contentsOf: contributionIDIssues(
                    option.id,
                    path: "\(optionPath).id"
                ))
                issues.append(contentsOf: textIssues(
                    option.title,
                    path: "\(optionPath).title",
                    maximum: 120
                ))
            }
            if !options.contains(where: { $0.id == defaultValue }) {
                issues.append(.init(
                    path: "\(path).control.defaultValue",
                    message: "must name one of the declared options"
                ))
            }
        case .integer(let defaultValue, let minimum, let maximum, let step):
            if minimum > maximum {
                issues.append(.init(
                    path: "\(path).control.minimum",
                    message: "must not exceed maximum"
                ))
            }
            if step <= 0 {
                issues.append(.init(path: "\(path).control.step", message: "must be positive"))
            } else if defaultValue < minimum
                        || defaultValue > maximum
                        || !(defaultValue - minimum).isMultiple(of: step) {
                issues.append(.init(
                    path: "\(path).control.defaultValue",
                    message: "must be an in-range step value"
                ))
            }
        }
        return issues
    }

    private func contributionIDIssues(
        _ value: String,
        path: String
    ) -> [ExtensionValidationIssue] {
        guard ExtensionIdentifierRules.isContributionIdentifier(value) else {
            return [.init(path: path, message: ExtensionIdentifierRules.contributionMessage)]
        }
        return []
    }

    private func textIssues(
        _ value: String,
        path: String,
        maximum: Int
    ) -> [ExtensionValidationIssue] {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.init(path: path, message: "must not be empty")]
        }
        if value.count > maximum {
            return [.init(path: path, message: "must contain at most \(maximum) characters")]
        }
        return []
    }

    private func duplicateIssues(
        _ identifiers: [String],
        path: String
    ) -> [ExtensionValidationIssue] {
        var seen: Set<String> = []
        return identifiers.enumerated().compactMap { index, identifier in
            guard !seen.insert(identifier).inserted else { return nil }
            return .init(path: "\(path)[\(index)].id", message: "duplicates '\(identifier)'")
        }
    }
}

/// Environment payload available before an extension writes its registration.
public enum ExtensionSettingsEnvironment {
    public static let valuesJSON = "THREADING_EXTENSION_SETTINGS_JSON"

    public static func values(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: ExtensionJSONValue] {
        guard let json = environment[valuesJSON], !json.isEmpty else { return [:] }
        return try JSONDecoder().decode(
            [String: ExtensionJSONValue].self,
            from: Data(json.utf8)
        )
    }
}
