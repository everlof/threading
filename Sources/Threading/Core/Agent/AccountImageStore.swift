import AppKit
import Foundation
import CryptoKit

/// User-selected badge images: one bounded worker, immutable PNG custody, memory-only drawing.
/// At most 64 resident 64px images (1 MiB decoded); queued loads are deduplicated.
@MainActor
enum AccountImageStore {
    private static let images = NSCache<NSString, NSImage>()
    private static let bytes = NSCache<NSString, NSData>()
    private static var loading: Set<String> = []
    private static var missing: Set<String> = []
    private static var automaticIDs: [AccountID: String] = [:]
    private static let worker = DispatchQueue(label: "codes.threading.account-images", qos: .utility)
    nonisolated private static let maximumBytes = 4 * 1024 * 1024
    nonisolated private static let maximumPNGBytes = 32 * 1024

    nonisolated private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threading/AccountImages", isDirectory: true)
    }

    static func image(_ id: String?) -> NSImage? {
        guard let id, UUID(uuidString: id) != nil else { return nil }
        images.countLimit = 64
        bytes.countLimit = 64
        if let image = images.object(forKey: id as NSString) { return image }
        guard !missing.contains(id), loading.count < 64, loading.insert(id).inserted else { return nil }
        worker.async {
            let url = directory.appendingPathComponent(id + ".png")
            let data = try? BoundedFileReader.read(url, maximumBytes: maximumPNGBytes)
            let image = data.flatMap(NSImage.init(data:))
            Task { @MainActor in
                loading.remove(id)
                if let image, let data {
                    images.setObject(image, forKey: id as NSString)
                    bytes.setObject(data as NSData, forKey: id as NSString)
                    NotificationCenter.default.post(AccountPreferencesDidChange())
                } else if missing.count < 256 { missing.insert(id) }
            }
        }
        return nil
    }

    static func automaticImageID(for account: AgentAccount) -> String? {
        guard AppSettings.shared.discoversAccountAvatars else { return nil }
        let id: String
        if let cached = automaticIDs[account.id] { id = cached }
        else {
            let digest = Array(SHA256.hash(data: Data(account.id.rawValue.utf8)).prefix(16))
            id = NSUUID(uuidBytes: digest).uuidString
            if automaticIDs.count >= 256 { automaticIDs.removeAll(keepingCapacity: true) }
            automaticIDs[account.id] = id
        }
        images.countLimit = 64
        bytes.countLimit = 64
        if bytes.object(forKey: id as NSString) != nil { return id }
        guard !missing.contains(id), loading.count < 64, loading.insert(id).inserted else { return nil }
        let url = AccountAvatarStore.cachedImageURL(for: account)
        worker.async {
            let source = try? BoundedFileReader.read(url, maximumBytes: maximumBytes)
            let data = source.flatMap { ProjectIconStore.normalizedPNGData(from: $0, maxPixelSize: 64) }
            let image = data.flatMap(NSImage.init(data:))
            Task { @MainActor in
                loading.remove(id)
                if let data, data.count <= maximumPNGBytes, let image {
                    images.setObject(image, forKey: id as NSString)
                    bytes.setObject(data as NSData, forKey: id as NSString)
                    NotificationCenter.default.post(AccountPreferencesDidChange())
                } else {
                    if missing.count < 256 { missing.insert(id) }
                    AccountAvatarStore.discoverIfNeeded(account)
                }
            }
        }
        return nil
    }

    static func avatarDidArrive(for account: AgentAccount) {
        if let id = automaticIDs[account.id] {
            missing.remove(id)
            images.removeObject(forKey: id as NSString)
            bytes.removeObject(forKey: id as NSString)
        }
        _ = automaticImageID(for: account)
    }

    static func png(_ id: String?) -> Data? {
        _ = image(id)
        return id.flatMap { bytes.object(forKey: $0 as NSString) as Data? }
    }

    static func importImage(
        _ url: URL,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        worker.async {
            let id = UUID().uuidString
            let result: String?
            do {
                let source = try BoundedFileReader.read(url, maximumBytes: maximumBytes)
                guard let data = ProjectIconStore.normalizedPNGData(from: source, maxPixelSize: 64),
                      data.count <= maximumPNGBytes else {
                    Task { @MainActor in completion(nil) }
                    return
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(id + ".png"), options: .atomic)
                result = id
            } catch { result = nil }
            Task { @MainActor in
                if let result { _ = image(result) }
                completion(result)
            }
        }
    }
}
