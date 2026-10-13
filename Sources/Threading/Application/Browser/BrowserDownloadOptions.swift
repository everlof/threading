import Foundation

struct BrowserDownloadOptions {
    let destination: URL?
    let mode: BrowserDownloadMode

    init(_ arguments: BrowserDownloadArguments) throws {
        let hasRef = arguments.ref?.isEmpty == false
        let hasSelector = arguments.selector?.isEmpty == false
        let hasLocator = arguments.locator != nil
        guard [hasRef, hasSelector, hasLocator].filter({ $0 }).count == 1 else {
            throw BrowserDownloadOptionsError(
                "Provide exactly one download target: ref, selector, or locator."
            )
        }

        mode = arguments.mode ?? .chooser
        guard let rawPath = arguments.path else {
            guard mode != .direct else {
                throw BrowserDownloadOptionsError("Direct download requires an absolute path.")
            }
            destination = nil
            return
        }

        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, (path as NSString).isAbsolutePath else {
            throw BrowserDownloadOptionsError("Download path must be absolute.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw BrowserDownloadOptionsError("Download path must name a file, not a directory.")
        }
        if mode == .direct {
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw BrowserDownloadOptionsError("Direct download path already exists.")
            }
            var parentIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: url.deletingLastPathComponent().path,
                isDirectory: &parentIsDirectory
            ), parentIsDirectory.boolValue else {
                throw BrowserDownloadOptionsError("Direct download parent directory does not exist.")
            }
        }
        destination = url
    }
}

private struct BrowserDownloadOptionsError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
