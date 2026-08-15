import Foundation
import ThreadingExtensionKit

enum ExtensionComponentAuthoringError: Error, LocalizedError {
    case missingComponent(String, version: Int?)
    case patchTooLarge(maximumBytes: Int)
    case invalidPatchJSON(String)
    case couldNotRenderPreview
    case couldNotWritePreview

    var errorDescription: String? {
        switch self {
        case .missingComponent(let id, let version):
            let suffix = version.map { " version \($0)" } ?? ""
            return "Unknown extension component '\(id)'\(suffix)."
        case .patchTooLarge(let maximumBytes):
            return "The patch JSON exceeds the \(maximumBytes)-byte authoring limit."
        case .invalidPatchJSON(let message):
            return "Could not decode the component patch JSON: \(message)"
        case .couldNotRenderPreview:
            return "Threading could not render the component preview."
        case .couldNotWritePreview:
            return "Threading could not save the component preview image."
        }
    }
}

/// The host-owned, nonvisual extension component authoring contract.
///
/// Catalog identity, schema description, bounded patch decoding, and validation are application
/// behavior. Preview pixels are a UI adapter layered on top of the validated patch returned here.
enum ExtensionComponentAuthoringCatalog {
    private static let maximumPatchBytes = 128 * 1_024

    private struct ComponentSummary: Encodable {
        let id: String
        let version: Int
        let context: String
        let summary: String
    }

    private struct ComponentList: Encodable {
        let formatVersion: Int
        let components: [ComponentSummary]
    }

    private struct ValidationResult: Encodable {
        let valid: Bool
        let patchID: String
        let component: String
        let contractVersion: Int
    }

    static func listJSON() throws -> String {
        try encode(
            ComponentList(
                formatVersion: ExtensionComponentCatalogDocument.currentFormatVersion,
                components: ThreadingComponentCatalog.entries.map {
                    ComponentSummary(
                        id: $0.contract.id.rawValue,
                        version: $0.contract.version,
                        context: $0.contract.context.rawValue,
                        summary: $0.summary
                    )
                }
            )
        )
    }

    static func describeJSON(componentID: String, version: Int?) throws -> String {
        guard let entry = ThreadingComponentCatalog.entry(
            id: ExtensionComponentID(rawValue: componentID),
            version: version
        ) else {
            throw ExtensionComponentAuthoringError.missingComponent(
                componentID,
                version: version
            )
        }
        return try encode(
            ExtensionComponentDescription(
                entry: entry,
                patchSchema: ThreadingComponentCatalog.patchSchema(for: entry.contract)
            )
        )
    }

    static func validateJSON(_ patchJSON: String) throws -> String {
        let (patch, contract) = try decodeAndValidate(patchJSON)
        return try encode(
            ValidationResult(
                valid: true,
                patchID: patch.id,
                component: contract.id.rawValue,
                contractVersion: contract.version
            )
        )
    }

    static func validationMessage(for error: Error) -> String {
        if let validation = error as? ExtensionValidationError {
            return validation.issues.map(\.description).joined(separator: "\n")
        }
        return error.localizedDescription
    }

    static func decodeAndValidate(
        _ patchJSON: String
    ) throws -> (ExtensionComponentPatch, ExtensionComponentContract) {
        let data = Data(patchJSON.utf8)
        guard data.count <= maximumPatchBytes else {
            throw ExtensionComponentAuthoringError.patchTooLarge(
                maximumBytes: maximumPatchBytes
            )
        }

        let patch: ExtensionComponentPatch
        do {
            patch = try JSONDecoder().decode(ExtensionComponentPatch.self, from: data)
        } catch {
            throw ExtensionComponentAuthoringError.invalidPatchJSON(error.localizedDescription)
        }

        guard let entry = ThreadingComponentCatalog.entry(
            id: patch.target.component,
            version: patch.target.contractVersion
        ) else {
            throw ExtensionComponentAuthoringError.missingComponent(
                patch.target.component.rawValue,
                version: patch.target.contractVersion
            )
        }

        try entry.contract.validate(patch)
        return (patch, entry.contract)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
