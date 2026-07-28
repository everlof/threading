import Foundation

enum ExtensionEditableSourceError: LocalizedError {
    case directoryMissing(String)
    case packageManifestMissing(String)
    case swiftSourcesMissing(String)
    case symbolicLink(String)

    var errorDescription: String? {
        switch self {
        case .directoryMissing(let path):
            return L10n.format("The extension’s editable source directory is missing at %@.", path)
        case .packageManifestMissing(let path):
            return L10n.format("The extension source has no Package.swift at %@.", path)
        case .swiftSourcesMissing(let path):
            return L10n.format("The extension source has no Swift file under %@/Sources.", path)
        case .symbolicLink(let path):
            return L10n.format("The extension source contains a symbolic link at %@.", path)
        }
    }
}

/// A rebuildable Swift project retained beside a prebuilt WebAssembly artifact.
///
/// A packaged extension keeps it under `Source/`. An unpacked development project may instead
/// place `Package.swift` and `Sources/` at its root. Both forms are inspectable without running
/// a compiler, which lets import reject an opaque WebAssembly-only package while keeping
/// installation deterministic.
struct ExtensionEditableSource: Equatable {
    static let packagedDirectoryName = "Source"
    static let excludedDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".swiftpm",
        "DerivedData"
    ]

    let rootURL: URL

    static func inspect(inBundle bundleRoot: URL) throws -> Self {
        let packaged = bundleRoot.appendingPathComponent(
            packagedDirectoryName,
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: packaged.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return try inspect(projectAt: packaged)
        }
        return try inspect(projectAt: bundleRoot)
    }

    static func inspect(projectAt sourceRoot: URL) throws -> Self {
        let root = sourceRoot.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ExtensionEditableSourceError.directoryMissing(root.path)
        }

        let packageManifest = root.appendingPathComponent("Package.swift")
        var packageIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: packageManifest.path,
            isDirectory: &packageIsDirectory
        ), !packageIsDirectory.boolValue else {
            throw ExtensionEditableSourceError.packageManifestMissing(root.path)
        }

        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        var sourcesIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: sources.path,
            isDirectory: &sourcesIsDirectory
        ), sourcesIsDirectory.boolValue,
              try containsSwiftSource(in: sources) else {
            throw ExtensionEditableSourceError.swiftSourcesMissing(root.path)
        }

        try rejectSymbolicLinks(in: root)
        return Self(rootURL: root)
    }

    /// Copies source while deliberately omitting local build and VCS state.
    ///
    /// Those directories are not editable source, routinely dwarf the 256 MiB package limit,
    /// and may contain absolute paths or unrelated checkout data. Package.resolved and ordinary
    /// dotfiles remain because they are part of a reproducible project.
    func copy(to destination: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try copyContents(
            of: rootURL,
            to: destination,
            relativeTo: rootURL,
            fileManager: fileManager
        )
    }

    private func copyContents(
        of directory: URL,
        to destination: URL,
        relativeTo root: URL,
        fileManager: FileManager
    ) throws {
        for source in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            let values = try source.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            let relative = source.pathComponents
                .dropFirst(root.pathComponents.count)
                .joined(separator: "/")
            if values.isSymbolicLink == true {
                throw ExtensionEditableSourceError.symbolicLink(relative)
            }
            if values.isDirectory == true,
               Self.excludedDirectoryNames.contains(source.lastPathComponent) {
                continue
            }
            if source.lastPathComponent == ".DS_Store" {
                continue
            }

            let target = destination.appendingPathComponent(
                source.lastPathComponent,
                isDirectory: values.isDirectory == true
            )
            if values.isDirectory == true {
                try fileManager.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
                try copyContents(
                    of: source,
                    to: target,
                    relativeTo: root,
                    fileManager: fileManager
                )
            } else {
                try fileManager.copyItem(at: source, to: target)
            }
        }
    }

    private static func containsSwiftSource(in directory: URL) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                return true
            }
        }
        return false
    }

    private static func rejectSymbolicLinks(in directory: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ExtensionEditableSourceError.directoryMissing(directory.path)
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            let relative = item.pathComponents
                .dropFirst(directory.pathComponents.count)
                .joined(separator: "/")
            if values.isSymbolicLink == true {
                throw ExtensionEditableSourceError.symbolicLink(relative)
            }
            if values.isDirectory == true,
               excludedDirectoryNames.contains(item.lastPathComponent) {
                enumerator.skipDescendants()
            }
        }
    }
}
