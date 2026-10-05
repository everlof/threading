import Foundation
import ThreadingExtensionKit

/// One reviewed, currently enabled backdrop. Assets are authenticated separately; the phone
/// receives no executable or extension capability. Invalid optional surfaces leave the palette.
public struct RemoteThemeSurface: Codable, Equatable, Sendable {
    public let sourceDigest: String
    public let definition: ExtensionCustomSurface

    public init(sourceDigest: String, specification: ExtensionMetalSurface) {
        self.sourceDigest = sourceDigest
        definition = .metal(specification)
    }

    public var specification: ExtensionMetalSurface {
        switch definition { case .metal(let value): value }
    }

    public var isValid: Bool {
        guard RemoteThemeAsset.acceptsDigest(sourceDigest), specification.isValid else { return false }
        // The shared ABI stores float32 values. Finite Double authoring values must also
        // survive that conversion, including the mapping interval used on the phone.
        return specification.inputs.allSatisfy { input in
            switch input.value {
            case .constant(let value): return Float(value).isFinite
            case .signal(_, let mapping):
                return [mapping.inputMinimum, mapping.inputMaximum, mapping.outputMinimum,
                        mapping.outputMaximum, mapping.fallback,
                        mapping.inputMaximum - mapping.inputMinimum,
                        mapping.outputMaximum - mapping.outputMinimum].allSatisfy { Float($0).isFinite }
            case .setting:
                // The phone has no access to the Mac's extension settings: the Mac resolves a
                // setting binding to the constant it reads before projecting the surface.
                return false
            }
        }
    }
}
