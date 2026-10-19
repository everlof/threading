import WebKit

/// WebKit keeps Apple's session; neither the agent Browser nor URLSession receives its cookies.
@MainActor
enum BluetoothProfileWebsiteData {
    static let identifier = UUID(uuidString: "4CBCDFDD-18C6-4B55-8453-FA3C77496758")!
    static let store: WKWebsiteDataStore = {
        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: identifier)
        }
        // macOS 13 cannot name a separate persistent store. Reuse one private session until quit.
        return .nonPersistent()
    }()

    static func forget(in store: WKWebsiteDataStore, completion: @escaping @MainActor @Sendable () -> Void) {
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast,
                         completionHandler: completion)
    }
}
