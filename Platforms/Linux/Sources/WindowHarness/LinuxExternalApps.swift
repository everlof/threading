#if os(Linux)
import Foundation
import LinuxWindowBridge

/// A desktop entry that GIO currently reports as able to open a project directory.
struct LinuxExternalApp: Equatable, Sendable {
    let id: String
    let name: String
    /// An absolute file-icon path or a desktop theme icon name. The UI may use its own glyph
    /// when the theme cannot resolve this hint.
    let iconHint: String?
}

enum LinuxExternalApps {
    struct Catalogue: Sendable {
        let apps: [LinuxExternalApp]
        let defaultID: String?
    }

    struct LaunchFailure: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Synchronous desktop registry query. The caller must run this on a bounded worker.
    /// The default handler is first; GIO's other directory handlers follow, at most 64 total.
    static func discover() -> Catalogue {
        var entries = [TWExternalApp](repeating: TWExternalApp(),
                                       count: Int(TW_EXTERNAL_APP_LIMIT))
        var defaultID = [CChar](repeating: 0, count: Int(TW_EXTERNAL_APP_ID_CAPACITY))
        let copied = entries.withUnsafeMutableBufferPointer { entriesBuffer in
            defaultID.withUnsafeMutableBufferPointer { defaultBuffer in
                tw_external_apps_discover(entriesBuffer.baseAddress, Int32(entriesBuffer.count),
                                          defaultBuffer.baseAddress, Int32(defaultBuffer.count))
            }
        }
        guard copied >= 0 else { return Catalogue(apps: [], defaultID: nil) }
        let apps = entries.prefix(Int(copied)).map { item in
            let hint = decode(item.iconHint)
            return LinuxExternalApp(id: decode(item.id), name: decode(item.name),
                                    iconHint: hint.isEmpty ? nil : hint)
        }
        let preferred = decode(defaultID)
        return Catalogue(apps: apps, defaultID: preferred.isEmpty ? nil : preferred)
    }

    /// Synchronous GIO launch. GIO applies the desktop entry's Exec grammar; no path or app ID
    /// passes through a shell. The C leaf revalidates the handler and existing directory.
    static func launch(appID: String, directory: String) throws {
        guard !appID.isEmpty, appID.utf8.count < Int(TW_EXTERNAL_APP_ID_CAPACITY),
              !appID.utf8.contains(0), directory.utf8.count <= 4096,
              !directory.utf8.contains(0) else {
            throw LaunchFailure(message: "Invalid app ID or directory path.")
        }
        var failure = [CChar](repeating: 0, count: 512)
        let status = appID.withCString { id in
            directory.withCString { path in
                failure.withUnsafeMutableBufferPointer { buffer in
                    tw_external_app_launch(id, path, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        guard status == 0 else {
            let message = decode(failure)
            throw LaunchFailure(message: message.isEmpty ? "The app could not be opened." : message)
        }
    }

    private static func decode<Value>(_ value: Value) -> String {
        withUnsafeBytes(of: value) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes.prefix(end), as: UTF8.self)
        }
    }
}
#endif
