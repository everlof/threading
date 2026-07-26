import Foundation
import SkalmanExtensionKit

enum ExtensionProjectScaffolderError: LocalizedError {
    case destinationMustBeAbsolute
    case destinationExists(String)
    case sdkSnapshotMissing(String)
    case sdkDocumentationMissing(String)
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .destinationMustBeAbsolute:
            return "The extension project destination must be an absolute path."
        case .destinationExists(let path):
            return "Something already exists at \(path)."
        case .sdkSnapshotMissing(let path):
            return "Skalman's embedded extension SDK is missing or incomplete at \(path)."
        case .sdkDocumentationMissing(let path):
            return "Skalman's embedded extension authoring documentation is missing or "
                + "incomplete at \(path)."
        case .invalidManifest(let message):
            return "The generated extension manifest is invalid: \(message)"
        }
    }
}

struct ScaffoldedExtensionProject: Equatable {
    let directoryURL: URL
    let manifest: ExtensionManifest
    let sdkVersion: String
}

/// Creates the small, self-contained project an agent should edit for a new extension.
///
/// The operation is atomic and refuses overwrite. The exact app-shipped SDK is copied into
/// `Vendor/`, so the result has no path dependency on Skalman's checkout and no network
/// dependency. It deliberately does not build, install, enable, or approve capabilities.
enum ExtensionProjectScaffolder {
    static func scaffold(
        name: String,
        identifier: String,
        at destination: URL,
        sdkSnapshotURL: URL,
        fileManager: FileManager = .default
    ) throws -> ScaffoldedExtensionProject {
        guard destination.path.hasPrefix("/") else {
            throw ExtensionProjectScaffolderError.destinationMustBeAbsolute
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ExtensionProjectScaffolderError.destinationExists(destination.path)
        }

        let sdkVersionURL = sdkSnapshotURL.appendingPathComponent("SDK_VERSION")
        let sdkManifestURL = sdkSnapshotURL.appendingPathComponent("Package.swift")
        let documentationURL = sdkSnapshotURL
            .deletingLastPathComponent()
            .appendingPathComponent("docs/extensions", isDirectory: true)
        guard fileManager.fileExists(atPath: sdkManifestURL.path),
              let sdkVersion = try? String(
                contentsOf: sdkVersionURL,
                encoding: .utf8
              ).trimmingCharacters(in: .whitespacesAndNewlines),
              !sdkVersion.isEmpty else {
            throw ExtensionProjectScaffolderError.sdkSnapshotMissing(sdkSnapshotURL.path)
        }
        let requiredDocumentation = [
            "AGENT_AUTHORING.md",
            "API_V1.md",
            "schema/extension-manifest.schema.json"
        ]
        guard requiredDocumentation.allSatisfy({
            fileManager.fileExists(
                atPath: documentationURL.appendingPathComponent($0).path
            )
        }) else {
            throw ExtensionProjectScaffolderError.sdkDocumentationMissing(
                documentationURL.path
            )
        }

        let manifest = ExtensionManifest(
            identifier: identifier,
            name: name,
            version: "0.1.0",
            dataVersion: 1,
            runtime: .webAssembly,
            executable: "bin/extension.wasm",
            capabilities: [.panels]
        )
        do {
            try manifest.validate()
        } catch {
            throw ExtensionProjectScaffolderError.invalidManifest(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".skalman-scaffold-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        let sourceDirectory = staging.appendingPathComponent(
            "Sources/ExtensionMain",
            isDirectory: true
        )
        let vendorDirectory = staging.appendingPathComponent(
            "Vendor",
            isDirectory: true
        )
        let scriptsDirectory = staging.appendingPathComponent(
            "Scripts",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: vendorDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: scriptsDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(
            at: sdkSnapshotURL,
            to: vendorDirectory.appendingPathComponent(
                "SkalmanExtensionKit",
                isDirectory: true
            )
        )
        let vendoredDocumentation = vendorDirectory.appendingPathComponent(
            "docs/extensions",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: vendoredDocumentation.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(
            at: documentationURL,
            to: vendoredDocumentation
        )

        try Data(packageManifest.utf8).write(
            to: staging.appendingPathComponent("Package.swift")
        )
        try Data(source(name: name, manifest: manifest).utf8).write(
            to: sourceDirectory.appendingPathComponent("main.swift")
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try manifestEncoder.encode(manifest).write(
            to: staging.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )
        try Data(readme(
            name: name,
            identifier: identifier,
            sdkVersion: sdkVersion
        ).utf8).write(
            to: staging.appendingPathComponent("README.md")
        )
        let packageScript = scriptsDirectory.appendingPathComponent("package.sh")
        try Data(packagingScript(identifier: identifier).utf8).write(to: packageScript)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: packageScript.path
        )
        try Data(".build/\nBuild/\n*.skalmanextension\n".utf8).write(
            to: staging.appendingPathComponent(".gitignore")
        )

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: staging, to: destination)
        return ScaffoldedExtensionProject(
            directoryURL: destination,
            manifest: manifest,
            sdkVersion: sdkVersion
        )
    }

    private static let packageManifest = """
    // swift-tools-version: 5.9

    import PackageDescription

    let package = Package(
        name: "SkalmanExtension",
        products: [
            .executable(name: "ExtensionMain", targets: ["ExtensionMain"])
        ],
        dependencies: [
            .package(path: "Vendor/SkalmanExtensionKit")
        ],
        targets: [
            .executableTarget(
                name: "ExtensionMain",
                dependencies: [
                    .product(
                        name: "SkalmanExtensionKit",
                        package: "SkalmanExtensionKit"
                    )
                ],
                plugins: [
                    .plugin(
                        name: "SkalmanExtensionPolicyPlugin",
                        package: "SkalmanExtensionKit"
                    )
                ]
            )
        ]
    )

    """

    private static func source(name: String, manifest: ExtensionManifest) throws -> String {
        let nameLiteral = String(
            decoding: try JSONEncoder().encode(name),
            as: UTF8.self
        )
        let identifierLiteral = String(
            decoding: try JSONEncoder().encode(manifest.identifier),
            as: UTF8.self
        )
        return """
        #if canImport(Darwin)
        import Darwin
        #elseif canImport(WASILibc)
        import WASILibc
        #endif
        import Foundation
        import SkalmanExtensionKit

        let manifest = ExtensionManifest(
            identifier: \(identifierLiteral),
            name: \(nameLiteral),
            version: "0.1.0",
            dataVersion: 1,
            runtime: .webAssembly,
            executable: "bin/extension.wasm",
            capabilities: [.panels]
        )

        let registration = ExtensionRegistration(panels: [
            ExtensionPanel(
                id: "welcome",
                title: \(nameLiteral),
                root: .stack(
                    axis: .vertical,
                    spacing: .medium,
                    children: [
                        .text(\(nameLiteral), role: .heading),
                        .status("Extension is running", role: .positive)
                    ]
                )
            )
        ])

        func write<Value: Encodable>(_ value: Value) throws {
            var data = try JSONEncoder().encode(value)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
        }

        switch Array(CommandLine.arguments.dropFirst()) {
        case ["--skalman-register"]:
            try manifest.validate()
            try registration.validate(for: manifest)
            try write(registration)

        case ["--skalman-serve"]:
            let migration = ExtensionDataMigrationContext()
            _ = migration // Add idempotent migrations before registration when dataVersion grows.
            try manifest.validate()
            try registration.validate(for: manifest)
            try write(registration)
            while readLine(strippingNewline: true) != nil {
                FileHandle.standardError.write(Data("This scaffold has no actions yet.\\n".utf8))
            }

        default:
            FileHandle.standardError.write(
                Data("Use --skalman-register or --skalman-serve.\\n".utf8)
            )
            exit(64)
        }

        """
    }

    private static func readme(
        name: String,
        identifier: String,
        sdkVersion: String
    ) -> String {
        """
        # \(name)

        Safe Skalman WebAssembly extension scaffold using vendored SDK \(sdkVersion).

        Start by reading `Vendor/docs/extensions/AGENT_AUTHORING.md` completely, followed by
        `Vendor/docs/extensions/API_V1.md`. The manifest and wire schemas are under
        `Vendor/docs/extensions/schema/`; component contracts are under
        `Vendor/docs/extensions/generated/`. These files are the authoring contract—do not infer
        extension APIs from Skalman's application internals.

        1. Choose the smallest capability set that covers the requested behavior.
        2. Select a Swift.org toolchain and install its official WebAssembly SDK.
        3. Run `swift sdk list` and choose its exact `_wasm` identifier.
        4. Build and assemble an immutable source-bundled package with:

           `Scripts/package.sh <sdk-id>`

           Set `SKALMAN_SWIFT_EXEC=/absolute/path/to/swift` when the selected toolchain is not
           first on `PATH`. The result is `Build/\(identifier).skalmanextension`.

        5. Ask Skalman's `extension_propose_install` MCP tool to review that package. Skalman
           shows its runtime and complete capability set, asks the user, and installs it disabled
           only after approval.

        The vendored SDK, authoring contract, schemas, and editable project are retained in the
        distributed package. Editing this directory does not change an installed copy until you
        build and update it.

        """
    }

    private static func packagingScript(identifier: String) -> String {
        """
        #!/bin/sh
        set -eu

        if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
          echo "usage: Scripts/package.sh <swift-wasm-sdk-id> [output-directory]" >&2
          exit 64
        fi

        SDK_ID="$1"
        SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
        PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
        SWIFT_COMMAND="${SKALMAN_SWIFT_EXEC:-swift}"
        OUTPUT_ROOT="${2:-"$PROJECT_DIR/Build"}"
        PACKAGE_NAME="\(identifier).skalmanextension"
        OUTPUT="$OUTPUT_ROOT/$PACKAGE_NAME"

        if [ -e "$OUTPUT" ]; then
          echo "refusing to overwrite existing package: $OUTPUT" >&2
          exit 73
        fi

        "$SWIFT_COMMAND" build --disable-sandbox \
          --package-path "$PROJECT_DIR" \
          --swift-sdk "$SDK_ID" \
          --product ExtensionMain

        MODULE="$PROJECT_DIR/.build/wasm32-unknown-wasip1/debug/ExtensionMain.wasm"
        if [ ! -f "$MODULE" ]; then
          echo "WebAssembly build did not produce $MODULE" >&2
          exit 66
        fi

        mkdir -p "$OUTPUT_ROOT"
        STAGING="$(mktemp -d "$OUTPUT_ROOT/.skalman-package.XXXXXX")"
        mkdir -p "$STAGING/bin" "$STAGING/Source"
        cp "$PROJECT_DIR/skalman-extension.json" "$STAGING/skalman-extension.json"
        cp "$MODULE" "$STAGING/bin/extension.wasm"
        rsync -a \
          --exclude .build \
          --exclude Build \
          --exclude .git \
          --exclude .swiftpm \
          --exclude DerivedData \
          --exclude .DS_Store \
          "$PROJECT_DIR/" "$STAGING/Source/"
        if [ -d "$PROJECT_DIR/Resources" ]; then
          rsync -a "$PROJECT_DIR/Resources/" "$STAGING/Resources/"
        fi
        mv "$STAGING" "$OUTPUT"
        echo "$OUTPUT"

        """
    }
}
