import Foundation
import SkalmanExtensionKit

/// The complete, user-facing decision made before a local package is copied into Skalman.
///
/// Keeping this apart from `NSAlert` makes the security boundary reviewable in tests and keeps
/// Settings import and MCP-assisted authoring on the same wording. Installation never grants
/// execution: a newly copied package remains disabled until the user enables it in Settings.
struct ExtensionInstallProposal: Equatable {
    let name: String
    let identifier: String
    let version: String
    let runtime: ExtensionRuntime
    let dataVersion: Int
    let capabilities: [String]
    let companions: [ExtensionCompanion]
    let includesSource: Bool

    init(bundle: SkalmanExtensionBundle) {
        let manifest = bundle.manifest
        name = manifest.name
        identifier = manifest.identifier
        version = manifest.version
        runtime = manifest.runtime
        dataVersion = manifest.dataVersion
        capabilities = manifest.capabilities.map(\.rawValue).sorted()
        companions = manifest.companions.sorted { $0.id < $1.id }
        includesSource = bundle.sourceURL != nil
    }

    var title: String {
        "Install “\(name)”?"
    }

    var message: String {
        var paragraphs = [
            "This is an unsigned local import: \(identifier), version \(version).",
            runtime == .webAssembly
                ? "It will run as WebAssembly in Skalman’s capability-only runner."
                : "It uses the deprecated native compatibility runner."
        ]
        if capabilities.isEmpty {
            paragraphs.append("It requests no host capabilities.")
        } else {
            paragraphs.append(
                "It requests:\n" + capabilities.map { "  • \($0)" }.joined(separator: "\n")
            )
        }
        if capabilities.contains(ExtensionCapability.customMetalSurfaces.rawValue) {
            paragraphs.append(
                "It includes Metal shader source that Skalman will compile and run in a "
                    + "host-owned visual surface. Shaders cannot access AppKit or host objects, "
                    + "but they can consume GPU resources; review the included source."
            )
        }
        if !companions.isEmpty {
            var lines = [
                "This is an advanced extension with \(companions.count) separate macOS "
                    + "companion app(s). Each has its own process identity and signed sandbox "
                    + "authority; it does not inherit additional Skalman host data. macOS may "
                    + "attribute interactive privacy grants such as Screen Recording and "
                    + "Accessibility to Skalman while it directly supervises the companion."
            ]
            for companion in companions {
                let activation = companion.activation == .onDemand
                    ? "starts on demand"
                    : "runs while the extension is enabled"
                let authorities = companion.capabilities.isEmpty
                    ? "no OS-facing capabilities"
                    : companion.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
                let operations = companion.operations.isEmpty
                    ? "no callable operations"
                    : "operations: "
                        + companion.operations.map(\.id).sorted().joined(separator: ", ")
                let surfaces = companion.surfaces.isEmpty
                    ? "no remote surfaces"
                    : "surfaces: "
                        + companion.surfaces.map(\.id).sorted().joined(separator: ", ")
                lines.append(
                    "  • \(companion.id) · \(activation) · \(authorities) · "
                        + "\(operations) · \(surfaces)"
                )
            }
            paragraphs.append(lines.joined(separator: "\n"))
        }
        if runtime == .webAssembly {
            paragraphs.append(
                includesSource
                    ? "Rebuildable Swift source is included."
                    : "Rebuildable source is missing."
            )
        }
        paragraphs.append(
            "The package will be copied into Skalman but left disabled. Enable it separately "
                + "in Extensions settings after reviewing it."
        )
        return paragraphs.joined(separator: "\n\n")
    }

    let acceptTitle = "Install Disabled"
}
