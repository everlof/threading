import Foundation

/// Executes noninteractive extension-authoring commands without a window or confirmation UI.
///
/// Installation belongs to AgentExtensionInstallService; visual preview remains a UI adapter.
/// Catalog/schema validation, scaffolding and durable project registration are application behavior.
@MainActor
final class ExtensionAuthoringCommandService {
    private let projects: ProjectStore
    private let sdkSnapshotURL: () -> URL?

    init(
        projects: ProjectStore,
        sdkSnapshotURL: @escaping () -> URL?
    ) {
        self.projects = projects
        self.sdkSnapshotURL = sdkSnapshotURL
    }

    func listComponents() -> MCPToolResult {
        do {
            return .success(try ExtensionComponentAuthoringCatalog.listJSON())
        } catch {
            return .failure(ExtensionComponentAuthoringCatalog.validationMessage(for: error))
        }
    }

    func scaffoldProject(_ arguments: ExtensionScaffoldProjectArguments) -> MCPToolResult {
        guard let name = arguments.name?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !name.isEmpty else {
            return .failure("Missing required argument: name")
        }
        guard let identifier = arguments.identifier, !identifier.isEmpty else {
            return .failure("Missing required argument: identifier")
        }
        guard let directory = arguments.directory, !directory.isEmpty else {
            return .failure("Missing required argument: directory")
        }
        guard NSString(string: directory).isAbsolutePath else {
            return .failure("directory must be an absolute path")
        }
        guard let sdk = sdkSnapshotURL() else {
            return .failure("This Threading build does not contain its extension SDK snapshot.")
        }

        do {
            let project = try ExtensionProjectScaffolder.scaffold(
                name: name,
                identifier: identifier,
                at: URL(fileURLWithPath: directory, isDirectory: true),
                sdkSnapshotURL: sdk
            )
            guard projects.addProject(folderURL: project.directoryURL) != nil else {
                return .failure(
                    "Created \(project.manifest.name) at \(project.directoryURL.path), but the "
                        + "new Threading project could not be saved."
                )
            }
            return .success(
                "Created \(project.manifest.name) at \(project.directoryURL.path), vendored "
                    + "ThreadingExtensionKit SDK \(project.sdkVersion) with its offline authoring "
                    + "contract, and added it as a Threading project. Start with "
                    + "Vendor/docs/extensions/AGENT_AUTHORING.md. It is source only: build its "
                    + "WebAssembly module, assemble a .threadingextension, then propose "
                    + "installation for capability approval."
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func describeComponent(_ arguments: ExtensionComponentReferenceArguments) -> MCPToolResult {
        guard let component = arguments.component, !component.isEmpty else {
            return .failure("Missing required argument: component")
        }
        do {
            return .success(
                try ExtensionComponentAuthoringCatalog.describeJSON(
                    componentID: component,
                    version: arguments.version
                )
            )
        } catch {
            return .failure(ExtensionComponentAuthoringCatalog.validationMessage(for: error))
        }
    }

    func validateComponentPatch(_ arguments: ExtensionComponentPatchArguments) -> MCPToolResult {
        guard let patch = arguments.patch, !patch.isEmpty else {
            return .failure("Missing required argument: patch")
        }
        do {
            return .success(try ExtensionComponentAuthoringCatalog.validateJSON(patch))
        } catch {
            return .failure(ExtensionComponentAuthoringCatalog.validationMessage(for: error))
        }
    }
}
