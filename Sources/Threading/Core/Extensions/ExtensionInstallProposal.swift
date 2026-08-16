import Foundation
import ThreadingExtensionKit

/// The complete, user-facing decision made before a local package is copied into Threading.
///
/// Keeping this apart from `NSAlert` makes the security boundary reviewable in tests and keeps
/// Settings import and MCP-assisted authoring on the same wording. Installation never grants
/// execution: a newly copied package remains disabled until the user enables it in Settings.
struct ExtensionInstallProposal: Equatable {
    let source: ExtensionInstallSource
    let name: String
    let identifier: String
    let version: String
    let runtime: ExtensionRuntime
    let dataVersion: Int
    let capabilities: [String]
    let networkGrants: [ExtensionNetworkGrant]
    let companions: [ExtensionCompanion]
    let includesSource: Bool
    let themeNames: [String]
    /// How many of those themes also replace the app icon's glyph.
    let themesWithIconMarks: Int
    let fontFamilies: [String]

    init(
        bundle: ThreadingExtensionBundle,
        source: ExtensionInstallSource = .localImport
    ) {
        let manifest = bundle.manifest
        self.source = source
        name = manifest.name
        identifier = manifest.identifier
        version = manifest.version
        runtime = manifest.runtime
        dataVersion = manifest.dataVersion
        capabilities = manifest.capabilities.map(\.rawValue).sorted()
        networkGrants = manifest.networkGrants.sorted { $0.host < $1.host }
        companions = manifest.companions.sorted { $0.id < $1.id }
        includesSource = bundle.sourceURL != nil
        themeNames = bundle.themes.map(\.theme.name).sorted()
        themesWithIconMarks = bundle.themes.count { $0.iconMark != nil }
        fontFamilies = Array(Set(bundle.fonts.flatMap(\.familyNames))).sorted()
    }

    var title: String {
        "Install “\(name)”?"
    }

    var message: String {
        let sourceDescription: String
        switch source {
        case .localImport:
            sourceDescription =
                "This is an unsigned local import: \(identifier), version \(version)."
        case .firstPartyCatalog(let repositoryURL):
            sourceDescription =
                "This package is included with Threading: \(identifier), version \(version). "
                + "Its source is at \(repositoryURL.absoluteString). The app bundle authenticates "
                + "this copy; the repository is shown for inspection and is not cloned or built."
        }
        var paragraphs = [
            sourceDescription,
            runtime == .webAssembly
                ? "It will run as WebAssembly in Threading’s capability-only runner."
                : "It uses the deprecated native compatibility runner."
        ]
        if capabilities.isEmpty {
            paragraphs.append("It requests no host capabilities.")
        } else {
            paragraphs.append(
                "It requests:\n" + capabilities.map { "  • \($0)" }.joined(separator: "\n")
            )
        }
        if !networkGrants.isEmpty {
            // Disclosed per origin, because the grant list is the entire security boundary of
            // network.brokered: the user approves exactly these hosts, and a credentialed
            // grant is served with their own connected credentials — which is worth a
            // sentence of its own, alongside the bound that makes it approvable.
            let lines = networkGrants.map { grant in
                let methods = grant.methods.joined(separator: "/")
                return grant.credential == nil
                    ? "  • \(grant.host) (\(methods))"
                    : "  • \(grant.host) (\(methods)), using your connected "
                        + "\(grant.credential ?? "") credentials"
            }
            paragraphs.append(
                "It may ask Threading to fetch from:\n" + lines.joined(separator: "\n")
                    + "\nThreading performs those fetches itself; the extension never receives "
                    + "a credential and cannot reach any other host."
            )
        }
        if capabilities.contains(ExtensionCapability.customMetalSurfaces.rawValue) {
            paragraphs.append(
                "It includes Metal shader source that Threading will compile and run in a "
                    + "host-owned visual surface. Shaders cannot access AppKit or host objects, "
                    + "but they can consume GPU resources; review the included source."
            )
        }
        if !themeNames.isEmpty {
            paragraphs.append(
                "It offers \(themeNames.count) app theme(s) for Threading's own chrome: "
                    + themeNames.joined(separator: ", ")
                    + ". They appear in Settings ▸ Themes while the extension is enabled; "
                    + "nothing applies one automatically."
            )
            if themesWithIconMarks > 0 {
                // Disclosed because it is the one contribution that changes how Threading
                // appears *outside* its own window. The plate stays Threading's — the host
                // refuses a mark that fills its bounds — so this says what can change and
                // what cannot, rather than leaving the reader to assume the worst or the best.
                paragraphs.append(
                    "\(themesWithIconMarks) of those theme(s) also replace the glyph on "
                        + "Threading's Dock icon while selected. The icon's plate is still drawn "
                        + "by Threading in the theme's own colours, so the icon cannot be made to "
                        + "look like a different application."
                )
            }
        }
        if !fontFamilies.isEmpty {
            paragraphs.append(
                "It bundles font files Threading will register for its own process while the "
                    + "extension is enabled — family: "
                    + fontFamilies.joined(separator: ", ")
                    + ". Parsing a font exercises the system's font machinery; the licensing "
                    + "of a bundled font is the package author's responsibility."
            )
        }
        if !companions.isEmpty {
            var lines = [
                "This is an advanced extension with \(companions.count) separate macOS "
                    + "companion app(s). Each has its own process identity and signed sandbox "
                    + "authority; it does not inherit additional Threading host data. macOS may "
                    + "attribute interactive privacy grants such as Screen Recording and "
                    + "Accessibility to Threading while it directly supervises the companion."
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
            "The package will be copied into Threading but left disabled. Enable it separately "
                + "in Extensions settings after reviewing it."
        )
        return paragraphs.joined(separator: "\n\n")
    }

    let acceptTitle = "Install Disabled"
}
