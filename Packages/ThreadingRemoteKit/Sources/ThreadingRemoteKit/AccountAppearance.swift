import Foundation

/// Account presentation is separate from routing and provider usage. Optional fields inherit;
/// explicit false is an answer, not an absent preference.
public struct AccountAppearance: Codable, Equatable, Sendable {
    public var badgeMode: String?
    public var badgeText: String?
    public var imageID: String?
    public var backgroundHex: String?
    public var foregroundHex: String?
    public var showBadge: Bool?
    public var showName: Bool?
    public var showEmail: Bool?
    public var showDefaultBadge: Bool?
    public var useShortName: Bool?

    public init() {}

    public func overlaying(_ override: Self?) -> Self {
        guard let override else { return self }
        var result = self
        result.badgeMode = override.badgeMode ?? badgeMode
        result.badgeText = override.badgeText ?? badgeText
        result.imageID = override.imageID ?? imageID
        result.backgroundHex = override.backgroundHex ?? backgroundHex
        result.foregroundHex = override.foregroundHex ?? foregroundHex
        result.showBadge = override.showBadge ?? showBadge
        result.showName = override.showName ?? showName
        result.showEmail = override.showEmail ?? showEmail
        result.showDefaultBadge = override.showDefaultBadge ?? showDefaultBadge
        result.useShortName = override.useShortName ?? useShortName
        return result
    }

    public func normalized() -> Self {
        var result = self
        result.badgeMode = ["automatic", "text", "emoji", "image", "none"].contains(badgeMode ?? "")
            ? badgeMode : nil
        result.badgeText = badgeText.flatMap {
            let value = String($0.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(badgeMode == "emoji" ? 1 : 3))
            return value.isEmpty ? nil : value
        }
        result.backgroundHex = Self.normalizedColor(backgroundHex)
        result.foregroundHex = Self.normalizedColor(foregroundHex)
        result.imageID = imageID.flatMap { UUID(uuidString: $0)?.uuidString }
        return result
    }

    public static func normalizedColor(_ value: String?) -> String? {
        if let text = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           text == "auto" || text == "automatic" { return "automatic" }
        return normalizedHex(value)
    }

    public static func normalizedHex(_ value: String?) -> String? {
        guard let value else { return nil }
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "").uppercased()
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + hex
    }
}

public enum AccountAppearanceSurface: String, Codable, CaseIterable, Sendable {
    case sidebar, chooser, details, usage, notifications
}

/// Presentation only, keyed by stable surface IDs. Account identity never comes from these labels.
public struct AccountAppearancePreferences: Codable, Equatable, Sendable {
    public var shortName: String?
    public var shared: AccountAppearance?
    public var surfaces: [String: AccountAppearance]?
    public init() {}
}
