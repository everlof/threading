import Foundation
import ThreadingExtensionKit

enum ExtensionPackagerError: LocalizedError {
    case destinationExists(String)
    case executableNotRunnable(String)
    case executablePathEscapesPackage(String)
    case editableSourceRequired
    case editableSourceInvalid(String)
    case companionBundleRequired(String)
    case companionNotDeclared(String)
    case companionBundleInvalid(id: String, message: String)
    case assembledPackageInvalid(String)

    var errorDescription: String? {
        switch self {
        case .destinationExists(let path):
            return "Something already exists at \(path)."
        case .executableNotRunnable(let path):
            return "The extension executable is not a runnable file at \(path)."
        case .executablePathEscapesPackage(let path):
            return "The manifest's executable path (\(path)) points outside the package."
        case .editableSourceRequired:
            return "A WebAssembly extension package must include its editable Swift source."
        case .editableSourceInvalid(let message):
            return "The extension source is not a rebuildable Swift project: \(message)"
        case .companionBundleRequired(let id):
            return "The manifest declares companion '\(id)', but no built app bundle was supplied."
        case .companionNotDeclared(let id):
            return "A built app bundle was supplied for undeclared companion '\(id)'."
        case .companionBundleInvalid(let id, let message):
            return "The built app bundle for companion '\(id)' is invalid: \(message)"
        case .assembledPackageInvalid(let message):
            return "The assembled package did not validate: \(message)"
        }
    }
}

/// Assembles a `.threadingextension` from a manifest and a built executable.
///
/// This is the step `README.md` used to spell out as `mkdir`, two `cp`s and a `chmod` — a recipe
/// that is fine to read once and wrong to make every author repeat. It matters more now that
/// extensions are written from inside Threading (`AUTHORING_FLOW.md`): the loop there is edit →
/// build → install, and the middle step is this.
///
/// It is deliberately *not* a build system. The caller has already produced an executable by
/// whatever means; this arranges it into the layout the manifest describes and proves the
/// result is something the host would accept.
enum ExtensionPackager {
    static let packageExtension = ExtensionPackageStore.packageExtension

    /// Writes a package directory and returns the inspected result.
    ///
    /// The package is built in a sibling staging directory and moved into place only once it
    /// validates, so a failed assembly leaves nothing behind for someone to later mistake for
    /// a real package — the same reasoning as `ExtensionPackageStore.install`.
    @discardableResult
    static func assemble(
        manifestURL: URL,
        executableURL: URL,
        sourceDirectoryURL: URL? = nil,
        companionBundleURLs: [String: URL] = [:],
        into destination: URL,
        fileManager: FileManager = .default
    ) throws -> ThreadingExtensionBundle {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ExtensionPackagerError.destinationExists(destination.path)
        }
        let manifest = try ExtensionManifest.decoded(from: manifestURL)
        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: executableURL.path,
            isDirectory: &sourceIsDirectory
        ), !sourceIsDirectory.boolValue else {
            throw ExtensionPackagerError.executableNotRunnable(executableURL.path)
        }
        if manifest.runtime == .native,
           !fileManager.isExecutableFile(atPath: executableURL.path) {
            throw ExtensionPackagerError.executableNotRunnable(executableURL.path)
        }
        let editableSource: ExtensionEditableSource?
        if manifest.runtime == .webAssembly {
            guard let sourceDirectoryURL else {
                throw ExtensionPackagerError.editableSourceRequired
            }
            do {
                editableSource = try ExtensionEditableSource.inspect(
                    projectAt: sourceDirectoryURL
                )
            } catch {
                throw ExtensionPackagerError.editableSourceInvalid(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        } else if let sourceDirectoryURL {
            do {
                editableSource = try ExtensionEditableSource.inspect(
                    projectAt: sourceDirectoryURL
                )
            } catch {
                throw ExtensionPackagerError.editableSourceInvalid(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        } else {
            editableSource = nil
        }
        let declaredCompanionIDs = Set(manifest.companions.map(\.id))
        for id in companionBundleURLs.keys where !declaredCompanionIDs.contains(id) {
            throw ExtensionPackagerError.companionNotDeclared(id)
        }
        for companion in manifest.companions {
            guard let source = companionBundleURLs[companion.id] else {
                throw ExtensionPackagerError.companionBundleRequired(companion.id)
            }
            var isDirectory: ObjCBool = false
            guard source.pathExtension.lowercased() == "app",
                  fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw ExtensionPackagerError.companionBundleInvalid(
                    id: companion.id,
                    message: "\(source.path) is not a macOS '.app' directory"
                )
            }
            if (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ExtensionPackagerError.companionBundleInvalid(
                    id: companion.id,
                    message: "\(source.path) is a symbolic link"
                )
            }
        }

        // Where the executable has to land is the manifest's business, and a manifest that
        // names a path outside the package is refused here rather than producing a package the
        // inspector would refuse later with a less obvious message.
        let relative = manifest.executable
        guard !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else {
            throw ExtensionPackagerError.executablePathEscapesPackage(relative)
        }

        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".assemble-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fileManager.removeItem(at: staging) }

        let stagedExecutable = staging.appendingPathComponent(relative, isDirectory: false)
        try fileManager.createDirectory(
            at: stagedExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: executableURL, to: stagedExecutable)
        if manifest.runtime == .native {
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: stagedExecutable.path
            )
        }
        try fileManager.copyItem(
            at: manifestURL,
            to: staging.appendingPathComponent(
                ExtensionBundleInspector.manifestName,
                isDirectory: false
            )
        )
        if let editableSource {
            try editableSource.copy(
                to: staging.appendingPathComponent(
                    ExtensionEditableSource.packagedDirectoryName,
                    isDirectory: true
                ),
                fileManager: fileManager
            )
            let resources = editableSource.rootURL.appendingPathComponent(
                "Resources",
                isDirectory: true
            )
            var resourcesIsDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: resources.path,
                isDirectory: &resourcesIsDirectory
            ), resourcesIsDirectory.boolValue {
                try fileManager.copyItem(
                    at: resources,
                    to: staging.appendingPathComponent("Resources", isDirectory: true)
                )
            }
        }
        for companion in manifest.companions {
            guard let source = companionBundleURLs[companion.id] else {
                // Completeness was checked before staging was created.
                preconditionFailure("validated companion source disappeared")
            }
            let target = staging.appendingPathComponent(
                companion.bundlePath,
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: target)
        }

        // Validated as the host will read it, not as we believe we wrote it.
        do {
            _ = try ExtensionBundleInspector.inspect(at: staging)
        } catch {
            throw ExtensionPackagerError.assembledPackageInvalid(
                (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: staging, to: destination)
        return try ExtensionBundleInspector.inspect(at: destination)
    }

    /// The conventional package name for an identifier, matching what the store installs to.
    static func packageName(for identifier: String) -> String {
        "\(identifier).\(packageExtension)"
    }
}

private extension ExtensionManifest {
    static func decoded(from url: URL) throws -> ExtensionManifest {
        do {
            let manifest = try JSONDecoder().decode(
                ExtensionManifest.self,
                from: Data(contentsOf: url)
            )
            try manifest.validate()
            return manifest
        } catch {
            throw ExtensionPackagerError.assembledPackageInvalid(
                (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
    }
}
