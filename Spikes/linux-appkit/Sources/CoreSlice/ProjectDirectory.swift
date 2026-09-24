import Foundation

/// The filesystem identity used when a project is added or a local child is launched.
/// Resolving symlinks here keeps two spellings of one checkout from becoming two projects.
enum ProjectDirectory {
    static func canonicalURL(_ folder: URL) -> URL {
        folder.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func existing(at path: String) -> URL? {
        let folder = canonicalURL(URL(fileURLWithPath: path, isDirectory: true))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return folder
    }
}
