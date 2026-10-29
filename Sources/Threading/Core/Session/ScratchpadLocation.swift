import Foundation

/// The portable path rule behind both hosts' Scratchpad services.
enum ScratchpadLocation {
    static func directoryURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    static func defaultFolderURL(home: URL) -> URL {
        directoryURL(home
            .appendingPathComponent(ScratchpadDefaults.containerName, isDirectory: true)
            .appendingPathComponent(ScratchpadDefaults.folderName, isDirectory: true))
    }

    static func configuredFolderURL(path: String?) -> URL? {
        guard let path, path.hasPrefix("/"), path != "/" else { return nil }
        return directoryURL(URL(fileURLWithPath: path))
    }

    static func destination(parent: URL) -> URL {
        directoryURL(parent.appendingPathComponent(ScratchpadDefaults.folderName,
            isDirectory: true))
    }

    static func displayPath(_ folder: URL, home: URL) -> String {
        let path = directoryURL(folder).path
        let homePath = directoryURL(home).path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
